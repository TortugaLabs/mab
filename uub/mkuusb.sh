#!/bin/sh
#
# Create a USB from ISO
#
# TODO:
# - partition should use the whole disk?
#   - this is because if we create additional paritions
#     it messes up the /media/usb mapping.
#   - Otherwise, we should change the partition methodology
#     allthough, this is more relevant in order to save
#     apkovl into separate partition. But then fstab in OVL
#     needs to be modified.
#   - Alternatively, we can look into apkovl for LABEL names
#
set -euf -o pipefail
MAXPART=8192 # only use 8G of partitioned space
syslinux_lib=/usr/lib/syslinux
mydir=$(dirname "$(readlink -f "$0")")
. "$mydir/skel/scripts/lib.sh"
saved_args="$(print_args -1 "$@")"

get_fstab_dir() {
  local ovl="$1" media="$2"
  ( tar --to-stdout -zxf "$ovl" etc/fstab 2>/dev/null || : ) | awk '
    $1 ~ /^LABEL=/ && $2 == "'"$media"'" { print substr($1,7); }
  '
}

check_part_sz() {
  if [ -z "$boot_size" ] ; then
    # So, there is no partition size specified...
    # Pick one based on the device size...
    boot_size=$1
    $data && boot_size=$(expr $boot_size / 2)
    if [ $boot_size -gt $MAXPART ] ; then
      boot_size=$MAXPART
    else
      boot_size=$(expr $boot_size - 32)
    fi
  fi
  if $data ; then
    [ -n "$data_size" ] && data_size=$(numfmt --to-unit=Mi --from=iec "$data_size")
  fi

  # Make sure that the size specified is OK
  local req_boot_sz=$(expr $(stat -c '%s' "$iso") / 1024 / 1024)
  case "$iso" in
    *.tar.gz)
      # OK, it is a compressed tarball, assume that we need twice as much
      # storage...
      req_boot_sz=$(expr $req_boot_sz '*' 2)
      ;;
  esac
  if [ -n "$ovl" ] ; then
    local req_ovl_sz=$(expr $(stat -c '%s' "$ovl") / 1024 / 1024)
  else
    local req_ovl_sz=0
  fi
  if ! $data ; then
    req_boot_sz=$(expr $req_boot_sz + $req_ovl_sz)
  fi
  # Double it because we want to have space for updates
  req_boot_siz=$(expr $req_boot_sz  '*' 2)

  if [ $req_boot_sz -gt "$boot_size" ] ; then
    echo "Partition size of $psiz not supported" 1>&2
    echo "$minsz: Required" 1>&2
    exit 1
  fi
}

default_label() {
  if eval [ -z \"\$"$1"\" ] ; then
    if [ -n "$ovl" ] ; then
      eval $1='$(get_fstab_dir "$ovl" "$2")'
    fi
    if eval [ -z \"\$"$1"\" ] ; then
      eval $1='"$(printf "$3" $(expr $RANDOM % 10000))"'
    fi
  fi
}

data_part() {
  $data || return 0
  [ -n "$data_size" ] && local data_size="${data_size}M"
  echo ";${data_size};linux;"
  #~ echo ";${data_size};linux;" 1>&2
}

prep_image() {
  #
  # Create image file
  #
  fallocate -l "$img_sz" "$img"
  dd bs=440 count=1 conv=notrunc if=$syslinux_lib/mbr.bin of="${img}"

  # Create partitions
  sfdisk "$img" <<-_EOF_
	label: dos
	;${boot_size}M;c;*
	$(data_part)
	_EOF_

  local part_data=$(
    t=$(mktemp -d) ; (
      ln -s "$(readlink -f "$img")" "$t/PART"
      sfdisk -d "$t/PART" | tr -d , | sed -e 's/= */=/g'
    ) || rc=$?
    rm -rf "$t"
    exit ${rc:-0}
  )
  local \
    sector_size=$(echo "$part_data" | awk '$1 == "sector-size:" { print $2 }')
    part_opts=$(echo "$part_data" | grep '/PART1 :' | cut -d: -f2-)
  local \
    part_start=$(check_opt start $part_opts) \
    part_size=$(check_opt size $part_opts)
  local offset=$(expr $part_start '*' $sector_size)

  # Format partition
  default_label boot_label /media/boot ALPS%04d
  mkfs.vfat \
	-F 32 \
	-n "$boot_label" \
	-S $sector_size --offset $part_start \
	-v "$img"  $(expr $part_size '*' $sector_size / 1024)
  mtools_img="$img@@$offset"
  mmd -i "$mtools_img" "::bios"

  echo "Installing SYSLINUX"

  syslinux \
	--install \
	--offset $offset \
	--directory bios \
	--force \
	"$img" || :

  if ! $data ; then
    # No DATA partition
    if [ -n "$ovl" ] ; then
      mcopy -i "$mtools_img" -p -n -m -v "$ovl" "::"
    fi
  else
    local \
      data_part_opts=$(echo "$part_data" | grep '/PART2 :' | cut -d: -f2-)
    local \
      data_part_start=$(check_opt start $data_part_opts) \
      data_part_size=$(check_opt size $data_part_opts)
    local data_offset=$(expr $data_part_start '*' $sector_size)

    # Format data partition
    default_label data_label /media/data DATA%04d

    mkfs.vfat \
	-F 32 \
	-n "$data_label" \
	-S $sector_size --offset $data_part_start \
	-v "$img"  $(expr $data_part_size '*' $sector_size / 1024)

    if [ -n "$ovl" ] ; then
      mcopy -i "$img@@$data_offset" -p -n -m -v "$ovl" "::"
    fi
  fi
}

prep_drive() {
  #
  # Prepare USB key
  #
  # Erase Boot partition
  dd if=/dev/zero of=$bdev bs=512 count=200

  # Create partitions
  sfdisk $bdev <<-_EOF_
	label: gpt
	;${boot_size}M;uefi;*
        $(data_part)
	_EOF_
  sleep 2

  case "$bdev" in
    *[0-9]) mtools_img="${bdev}p1" ; local s=p ;;
    *) mtools_img="${bdev}1" ; local s="" ;;
  esac
  [ ! -b ${mtools_img} ] && die "Failed to create partitions"

  # Format partition
  default_label boot_label /media/boot ALPS%04d
  mkfs.vfat \
	-F 32 \
	-n "$boot_label" \
	-v "${mtools_img}"

  if ! $data ; then
    if [ -n "$ovl" ] ; then
      mcopy -i "$mtools_img" -p -n -m -v "$ovl" "::"
    fi
  else
    # Format data partition
    default_label data_label /media/data DATA%04d
    mkfs.vfat \
	-F 32 \
	-n "$data_label" \
	-v "${bdev}${s}2"
    if [ -n "$ovl" ] ; then
      mcopy -i "${bdev}${s}2" -p -n -m -v "$ovl" "::"
    fi
  fi
}

config_bios() {
  local fsdir="$1" x
  mkdir -p "$fsdir/bios"
  for x in menu libutil libcom32 mboot
  do
    [ ! -f "$syslinux_lib/$x.c32" ] && continue
    cp -av "$syslinux_lib/$x.c32" "$fsdir/bios"
  done
}

config_uefi() {
  local dst="$1"

  if [ -f "$mydir/bootx64.efi" ] ; then
    mkdir -p "$dst/EFI/BOOT"
    cp -av "$mydir/bootx64.efi" "$dst/EFI/BOOT"
    mkdir -p "$dst/boot/grub"
  fi
}

main() {
  local ovl='' serial=false
  local boot_label= boot_size=
  local data=false data_label= data_size=

  while [ $# -gt 0 ]
  do
    case "$1" in
    --ovl=*) ovl=${1#--ovl=} ;;
    --serial) serial=true ;;
    --boot-label=*) boot_label=${1#--boot-label=} ;;
    --boot-size=*) psiz=${1#--partsize=} ;;
    --data) data=true ;;
    --data-label) data=true; data_label=${1#--data-label=} ;;
    --data-size=*) data=true; data_size=${1#--data-size=} ;;
    *) break ;;
    esac
    shift
  done

  if [ $# -eq 0 ] ; then
    local devs=$(bd_unused)
    [ -z "$devs" ] && devs="(none)"
    cat 2>&1 <<-EOF
	Usage:
	    $0 [options] isofile [usbdev]
	Options:
	  --ovl=ovlfile : overlay file to use
	  --boot-label=label : boot partition label
	    Defaults to a random label unless ovl is specifed
	    will take the label from the filesystem mounted as
	    /media/boot from fstab
	  --boot-size=size : boot partition size
	    If not specified it will default to the entire drive
	    or up to half the drive (if data partition is enabled)
	    up to 8GB.
	  --data : create a data partition
	  --data-label=label : label for data partition_disc
	    Defaults to a random label unless ovl is specifed
	    will take the label from the filesystem mounted as
	    /media/data from fstab
	  --data-size=size : data partition size
	    If data partition is enabled size defaults to the remaining of the disk
	  isofile : ISO file to use as the base alpine install
	  usbhdd : /dev/path to the thumb drive that will be installed.
	    Defaults to "$(echo $devs)" or you can specified a image file
	    using:

	    img:path/to/image/file[,size]

	The script will invoke "sudo" automatically if needed.
	EOF
    exit 1
  fi
  iso="$1" ; shift

  local osname flavor frel farch
  parse_iso_name "$iso"

  if [ $# -gt 0 ] ; then
    bdev="$1"
    case "$bdev" in
    img:*)
      bdev=${bdev#img:}
      if (echo "$bdev" | grep -q ,) ; then
        img_sz=${bdev#*,}
	img=${bdev%,*}
	#~ die "img: $img - $img_sz"
      else
	img="$bdev"
	img_sz=16G
      fi
      bdev=""
      ;;
    /dev/*)
      [ ! -b "$bdev" ] && die "$bdev: not a valid device"
      ;;
    *)
      if [ -b "/dev/$bdev" ] ; then
	bdev="/dev/$bdev"
	echo "Using device: $bdev" 1>&2
      else
	[ ! -b "$bdev"  ] &&  die "$bdev: not a valid device"
	bdev=$(readlink -f "$bdev")
      fi
      ;;
    esac
  else
    bdev="/dev/$(bd_unused)"
    echo "Selecting $bdev" 1>&2
  fi

  [ -z "$iso" ] && die "No iso specified"
  [ ! -r "$iso" ] && die "$iso: not found"
  if [ -n "$ovl" ] ; then
    [ ! -r "$ovl" ] && die "$ovl: not found"
  fi

  if [ $(id -u) -ne 0 ] ; then
    if ($is_iso && ! type 7z >/dev/null 2>&1) || [ -n "$bdev" ] ; then
      echo "Running sudo..." 1>&2

      oIFS="$IFS"
      IFS="$(echo | tr '\n' '\1')"
      set - $saved_args
      IFS="$oIFS"
      unset oIFS
      set -x
      exec sudo "$0" "$@"
      exit 1
    fi
  fi

  cat 1>&2 <<-_EOF_
	osname: $osname
	flavor: $flavor
	frel:   $frel
	farch:  $farch
	_EOF_

  if [ -n "$bdev" ] ; then
    local dsize=$(blockdev --getsz "$bdev")
    [ -z "$dsize" ] && die "$bdev: unable to determine disk size"
    dsize=$(expr $dsize '*' 1024 / 2)
    check_part_sz $dsize
    prep_drive
  else
    check_part_sz $(numfmt --to-unit=Mi --from=iec "$img_sz")
    prep_image
  fi

  local tmp1=$(mktemp -d) rc=0
  trap 'exit 1' INT
  trap 'rm -rf "$tmp1"' EXIT
  (
    alpdir="alpine-$flavor-$frel"
    mkdir -p "$tmp1/src"
    mkdir -p "$tmp1/src/$alpdir"

    echo "Unpack $iso" 1>&2
    unpack_src "$iso" "$tmp1/src/$alpdir"

    # Copy support files
    if [ -d "$mydir/skel" ] ; then
      cp -av "$mydir/skel/." "$tmp1/src" 2>&1 | summarize "DONE CUSTOMIZING"
    fi
    mkdir -p "$tmp1/src/apks"  # This is needed by alpine initramfs to boot properly
    > "$tmp1/src/apks/.boot_repository"

    # Hack initramfs
    find "$tmp1/src/$alpdir/boot" -type f -name 'initramfs-*' | while read rd
    do
      echo "Preparing $rd"
      sh "$mydir/skel/scripts/tweak_initfs.sh" "$rd"
    done

    echo 'Adding BIOS support...'
    config_bios "$tmp1/src" | summarize
    echo "Adding UEFI support..."
    config_uefi "$tmp1/src" | summarize

    ls -sh "$tmp1/src"
    IN_CHROOT=true sh "$tmp1/src/mkmenu.sh" $($serial && echo --serial)

    find "$tmp1/src" -maxdepth 1 -mindepth 1 | ( while read src
    do
      mcopy -i "$mtools_img" -s -p -Q -n -m -v "$src" "::"
    done ) 2>&1 | summarize "Writting IMG...DONE"

  ) || rc=$?
  exit $rc

}


main "$@"

#

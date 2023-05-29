#!/bin/sh
#
# Create a USB from ISO
#
set -euf -o pipefail
MAXPART=8192 # only use 8G of partitioned space
syslinux_lib=/usr/lib/syslinux
mydir=$(dirname "$(readlink -f "$0")")
savedargs=$(for i in "$@" ; do echo "$i" ; done)

if [ -n "${SAVED_ARGS:-}" ] ; then
  oIFS="$IFS"
  IFS="$(echo | tr '\n' '\1')"
  set - $(echo "$SAVED_ARGS" | tr '\n' '\1')
  IFS=$oIFS
  unset oIFS
fi
. "$mydir/skel/scripts/lib.sh"

check_opt() {
  local out=echo
  if [ x"$1" = x"-q" ] ; then
    out=:
    shift
  fi
  local flag="$1" ; shift
  for j in "$@"
  do
    if [ x"${j%=*}" = x"$flag" ] ; then
      $out "${j#*=}"
      return 0
    fi
  done
  return 1
}

calc_min_sz() {
  # Make sure that the size specified is OK
  local minsz=$(expr $(stat -c '%s' "$iso") / 1024 / 1024)
  case "$iso" in
    *.tar.gz)
      # OK, it is a compressed tarball, assume that we need twice as much
      # storage...
      minsz=$(expr $minsz '*' 2)
      ;;
  esac
  minsz=$(expr $minsz '*' 2) # Double it because we want to have space for updates
  if [ "$minsz" -gt "$psiz" ] ; then
    echo "Partition size of $psiz not supported" 1>&2
    echo "$minsz: Required" 1>&2
    exit 1
  fi
  echo "minsz=$minsz psiz=$psiz"
}

prep_image() {
  if [ -z "$psiz" ] ; then
    # So, there is no partition size specified...
    # Pick one based on the device size...
    local dsiz=$(numfmt --to-unit=Mi --from=iec "$img_sz")
    if [ -n "$dsiz" ] ; then
      if [ $dsiz -gt $MAXPART ] ; then # We really don't need more than 8 GB
	psiz=$MAXPART
      else
	psiz=$(expr $dsiz - 32)
      fi
    else
      die "$bdev: unable to determine disk size"
    fi
  fi
  calc_min_sz

  #
  # Create image file
  #
  # Erase Boot partition
  fallocate -l "$img_sz" "$img"
  dd bs=440 count=1 conv=notrunc if=$syslinux_lib/mbr.bin of="${img}"

  # Create partitions
  sfdisk "$img" <<-_EOF_
	label: dos
	;${psiz}M;c;*
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

  data_part_offset "$part_data"

  # Format partition
  label="ALPS$(printf "%04d" $(expr $RANDOM % 10000))"
  mkfs.vfat \
	-F 32 \
	-n "$label" \
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
}


prep_drive() {
  if [ -z "$psiz" ] ; then
    # So, there is no partition size specified...
    # Pick one based on the device size...
    local dsiz=$(awk '$4 == "'$(basename "$bdev")'" { print int($3/1024+0.5) }' /proc/partitions)
    if [ -n "$dsiz" ] ; then
      if [ $dsiz -gt $MAXPART ] ; then # We really don't need more than 8 GB
	psiz=$MAXPART
      else
	psiz=$(expr $dsiz - 32)
      fi
    else
      die "$bdev: unable to determine disk size"
    fi
  fi
  calc_min_sz

  #
  # Prepare USB key
  #
  # Erase Boot partition
  dd if=/dev/zero of=$bdev bs=512 count=200

  # Create partitions
  sfdisk $bdev <<-_EOF_
	label: gpt
	;${psiz}M;uefi;*
        $(data_part)
	_EOF_
  sleep 2

  case "$bdev" in
    *[0-9]) mtools_img="${bdev}p1" ;;
    *) mtools_img="${bdev}1" ;;
  esac
  [ ! -b ${mtools_img} ] && die "Failed to create partitions"

  data_part_offset

  # Format partition
  label="ALPS$(printf "%04d" $(expr $RANDOM % 10000))"
  mkfs.vfat \
	-F 32 \
	-n "$label" \
	-v "${mtools_img}"

}

data_part() {
  $data || return 0
  echo ";${data_size};linux;"
}

data_part_offset() {
  $data || return 0
  if [ $# -eq 0 ] ; then
    data_bdev="${bdev}2"
    data_opts=""
  else
    local \
      part_opts=$(echo "$1" | grep '/PART2 :' | cut -d: -f2-)
    local \
      part_start=$(check_opt start $part_opts) \
      part_size=$(check_opt size $part_opts)

    data_opts=",offset=$(expr $part_start '*' $sector_size)"
    data_bdev="$img"

    data_size=$(expr $part_size '*' $sector_size / $data_bsize)
  fi
}

data_mkfs() {
  $data || return 0

  local t=$(mktemp -d) rc=0
  (
    trap 'rm -rf $t' EXIT
    trap 'exit' INT

    if [ -f "$data_src" ] ; then
      echo "Unpacking data tarball"
      tar -C "$t" -zxvf "$data_src" | summarize
      data_src="$t"
    fi

    set -x
    mke2fs -F \
	-t $data_type \
	-b $data_bsize \
	-d "$data_src" \
	-E "root_owner=0:0$data_opts" \
	-L "$data_label" \
	"$data_bdev" $data_size
  ) || rc=0
  return "$rc"
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
  local psiz='' ovl='' serial=false data=false x_data=""

  while [ $# -gt 0 ]
  do
    case "$1" in
    --partsize=*) psiz=${1#--partsize=} ;;
    --ovl=*) ovl=${1#--ovl=} ;;
    --serial) serial=true ;;
    --data=*)
      data=true ; x_data="$1"
      data_src=$(echo "${1#--data=}" | cut -d, -f1)
      data_size=$(IFS=, ; check_opt size ${1#--data=}) || :
      data_type=$(IFS=, ; check_opt type ${1#--data=}) || data_type=ext4
      data_label=$(IFS=, ; check_opt label ${1#--data=}) || data_label=$(basename "$data_src" .tar.gz)
      data_bsize=$(IFS=, ; check_opt bsize ${1#--data=}) || data_bsize=4096
      if [ -f "$data_src" ] ; then
	case "$data_src" in
	*.tar.gz) : ;;
	*)
	  echo "$data_src: Only .tar.gz format supported" 1>&2
	  exit 40
	  ;;
	esac
	data_fsz=$(expr $(stat -c '%s' "$data_src") / 1024 / 1024 '*' 4 / 3 + 1)
      elif [ -d "$data_src" ] ; then
	data_fsz=$(du -sm "$data_src" | (read a b ; echo ${a}M))
      else
        echo "$data_src: source not found" 1>&2
	exit 38
      fi
      if [ -n "$data_size" ] && [ $(numfmt --to-unit=Mi --from=iec "$data_size") -lt $(numfmt --to-unit=Mi --from=iec "$data_fsz") ] ; then
        echo "Partition size of $data_size is less than the file system size of $data_fsz" 1>&2
	exit 52
      fi
      ;;
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
	  --partsize=value: Partition size in Megs
	    If not specified it defaults to entire drive up to 8GB.
	  --data=xxx: Data partition specification (DEPRECATED)
	  --ovl=apkovl : APK overlay file
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

  if [ $(id -u) -ne 0 ] ; then
    if ($is_iso && ! type 7z >/dev/null 2>&1) || [ -n "$bdev" ] ; then
      echo "Running sudo..." 1>&2
      exec sudo env SAVED_ARGS="$savedargs" "$0"
      #~ exec sudo "$0" --ovl="$ovl" --partsize="$psiz" $x_data "$iso" "$@"
      exit 1
    fi
  fi

  [ -z "$iso" ] && die "No iso specified"
  [ ! -r "$iso" ] && die "$iso: not found"
  if [ -n "$ovl" ] ; then
    [ ! -r "$ovl" ] && die "$ovl: not found"
  fi

  cat 1>&2 <<-_EOF_
	osname: $osname
	flavor: $flavor
	frel:   $frel
	farch:  $farch
	_EOF_

  if [ -n "$bdev" ] ; then
    prep_drive
  else
    prep_image
  fi
  $data && data_mkfs

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

    if $serial ; then
      echo "modules=loop,squashfs,sd-mod,usb-storage quiet console=tty0 console=ttyS0,115200" | tee "$tmp1/src/cmdline.txt"
    fi

    sh "$tmp1/src/mkmenu.sh"

    # Copy OVL files if any
    if [ -n "$ovl" ] ; then
      cp -av "$ovl" "$tmp1/src"
    fi

    #~ (cd "$tmp1/src" ; find)

    find "$tmp1/src" -maxdepth 1 -mindepth 1 | ( while read src
    do
      mcopy -i "$mtools_img" -s -p -Q -n -m -v "$src" "::"
    done ) 2>&1 | summarize "Writting IMG...DONE"

  ) || rc=$?
  exit $rc
}


main "$@"

#

#!/bin/sh
#
#
set -euf -o pipefail
[ -z "${O:-}" ] && O="$0"
. $(dirname "$0")/lib.sh
saved_args="$(print_args -1 "$@")"

get_fstab_dir() {
  local ovl="$1" media="$2"
  tar --to-stdout -zxf "$ovl" etc/fstab | awk '
    $1 ~ /^LABEL=/ && $2 == "'"$media"'" { print substr($1,7); }
  '
}

customize_initrd() {
  local rd="$1" t="$(mktemp -d -p "$2")" rc=0
  (
    trap 'exit 1' INT
    trap 'rm -rf "$t"' EXIT
    echo "Updating $rd"
    gzip -d < "$rd" | ( cd "$t" && cpio -ivd) 2>&1 | summarize UNPACKED
    sed -i \
	 -e 's/^\([ 	]*\)\(rc_add[ 	]*swclock[ 	]\)/\1echo \2/' \
	 "$t/init"
    (( cd "$t" ; find . -print0 | cpio --null -ov --format=newc ) \
	| gzip -v > "$rd" ) 2>&1 | summarize REPACKED
  ) || rc=$?
  return $rc
}

partition_disc() {
  local getsz=$(blockdev --getsz "$sdev")
  [ -z "$getsz" ] && die -11 "$sdev: unable to get size"

  local maxsz=$(expr $getsz / 2)
  local bootpsz=$(numfmt --to-unit=1024 --from=iec $bootpsz)
  local total=$bootpsz bootpsz=${bootpsz}K

  local n=1
  bootpart=$sdev$n
  n=$(expr $n + 1)

  if [ -n "$swappsz" ] ; then
    local swappsz=$(numfmt --to-unit=1024 --from=iec $swappsz)
    total=$(expr $total + $swappsz)
    swappsz=${swappsz}K
    swappart=$sdev$n
    n=$(expr $n + 1)
  fi

  datapart=$sdev$n
  n=$(expr $n + 1)
  if [ -n "$datapsz" ] ; then
    local datapsz=$(numfmt --to-unit=1024 --from=iec $datapsz)
    total=$(expr $total + $datapsz)
    datapsz=${datapsz}K
  fi

  [ $total -gt $maxsz ] && die "$sdev: too small ($maxsz, required $total)"

  (
    echo "label: dos"
    echo ''
    echo ",${bootpsz},0xc,"
    [ -n "$swappsz" ] && echo ",$(numfmt --to-unit=1024 --from=iec $swappsz)K,S,"
    echo ",${datapsz},L,"
  ) | sfdisk "$sdev"
  sleep 2
}

run() {
  local tarball="$1"; shift
  partition_disc

  echo "Making filesystems"
  if [ -z "$bootlabel" ] ; then
    if [ -n "$ovl" ] ; then
      bootlabel=$(get_fstab_dir "$ovl" /media/boot)
    fi
    [ -z "$bootlabel" ] && bootlabel="ALP$RANDOM"
  fi
  mkfs.vfat -F 32 -n "$bootlabel" "${bootpart}"

  if [ -z "$datalabel" ] ; then
    if [ -n "$ovl" ] ; then
      datalabel=$(get_fstab_dir "$ovl" /media/data)
    fi
    [ -z "$datalabel" ] && datalabel="DAT$RANDOM"
  fi
  mkfs.vfat -F 32 -n "$datalabel" "${datapart}"

  if [ -n "$swappsz" ] ; then
    if [ -z "$swaplabel" ] ; then
      if [ -n "$ovl" ] ; then
	swaplabel=$(get_fstab_dir "$ovl" swap)
      fi
      [ -z "$swaplabel" ] && swaplabel="SWP$RANDOM"
    fi
    mkswap -L "$swaplabel" "$swappart"
  fi

  local mdir=$(mktemp -d)
  rc=0
  (
    mkdir "$mdir/boot" "$mdir/data"
    mount -t vfat "$bootpart" "$mdir/boot"
    mount -t vfat "$datapart" "$mdir/data"
    trap "exit 1" INT
    trap "umount $mdir/boot $mdir/data ; rm -rf $mdir" EXIT

    echo Writing files
    tar -zxf "$tarball" -C "$mdir/boot"

    echo Customize image
    find "$mdir/boot" -name "initramfs-*" | while read f
    do
      customize_initrd "$f" "$mdir"
    done

    # This enables the HW RTC (RasClock) https://afterthoughtsoftware.com/products/rasclock
    tee -a "$mdir/boot/config.txt" <<-_EOF_

	[all]
	dtparam=i2c_arm=on
	dtparam=watchdog=on
	hdmi_force_hotplug=1
	dtoverlay=i2c-rtc,pcf2127
	_EOF_
    mkdir "$mdir/boot/cache"

    if [ -n "$ovl" ] ; then
      cp -av "$ovl" "$mdir/data"
    fi

    #~ tee "$mdir/rtc.sh" <<-_EOF_
	#~ echo pcf2127 0x51 > /sys/class/i2c-adapter/i2c-1/new_device
	#~ _EOF_
  ) || rc=$?

  # i2c-dev
  # rtc-pcf2127.ko
  # i2c-bcm2788
  # regmap.spi
}

usage() {
  if [ $# -gt 0 ] ; then
    echo "$@" 1>&2
    echo '---' 1>&2
  fi
  dev="$(bd_unused)"
  [ -z "$dev" ] && dev="(none)"

  cat 1>&2 <<-_EOV_
	Usage: $0 [options] {tarball}

	Options:
	* --dev=/dev/xyz - /dev/sdisc (default to $dev)
	* --ovl=apkovl  - specify a apk overlay file
	* tarball - Alpine Linux tarball
	_EOV_
  exit 1
}

sdev=""
bootpsz=1G
datapsz=4G
swappsz=""
bootlabel=
datalabel=
swaplabel=
ovl=


while [ $# -gt 0 ]
do
  case "$1" in
  --dev=*) sdev=${1#--dev=} ;;
  /dev/*) sdev="$1" ;;
  --boot-sz=*) bootpsz=${1#--boot-sz=} ;;
  --data-sz=*) datapsz=${1#--data-sz=} ;;
  --swap-sz=*) swappsz=${1#--swap-sz=} ;;
  --boot-label=*) bootlabel=${1#--boot-label=} ;;
  --data-label=*) datalabel=${1#--data-label=} ;;
  --swap-label=*) swaplabel=${1#--swap-label=} ;;
  --ovl=*) ovl=${1#--ovl=} ;;
  *) break ;;
  esac
  shift
done
[ $# -eq 0 ] && usage

if [ -z "$sdev" ] ; then
  sdev=$(bd_unused)
  [ -z "$sdev" ] && die Must specify --dev
  echo "Default: $sdev" 1>&2
fi
( echo "$sdev" | grep -q '^/dev/' ) || sdev=/dev/$sdev

[ ! -f "$1" ] && die -93 "$1: tarball not found"
[ ! -b "$sdev" ] && die -55 "$sdev: block device not found"


if [ -n "$ovl" ] ; then
  [ ! -f "$ovl" ] && die -84 "$ovl: not found"
fi

if [ $(id -u) -ne 0 ] ; then
  oIFS="$IFS"
  IFS="$(echo | tr '\n' '\1')"
  set - $saved_args
  IFS="$oIFS"
  unset oIFS
  exec sudo "$0" "$@"
fi


run "$@"



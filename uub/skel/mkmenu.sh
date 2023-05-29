#!/bin/sh
#
# Simple boot menu generator
#
# Updates a grub and SYSLINUX menus
#
# TODO: kernel selection
#   current, latest, select one
#   current checks /proc/dmdline
#
set -euf -o pipefail
LATEST() { echo "<LATEST>"; }

read_opts() {
  [ ! -f "$1" ] && return 1
  sed -e 's/#.*$//' "$1" | tr '\n' ' '
  return $?
}

xen_opts() {
  local kver="$1" i; shift
  if [ -n "$serial" ] ; then
    #   XEN CMD LINE:  com1=115200,8n1 console=com1
    local \
	unit=$(echo "$serial" | cut -d, -f1) \
	speed=$(echo "$serial" | cut -d, -f2)
    local com=com"$(expr $unit + 1)"
    echo -n "${com}=${speed},8n1 console=$com "
  fi
  for i in "$bootdir/$kver/xen_opts.txt" "$bootdir/xen_opts.txt"
  do
    read_opts "$i" && return
  done
  # Default to limit the memory to 2G
  echo "dom0_mem=2048M"
}

linux_opts() {
  local kver="$1" flavor="$2" kflavor="$2" i ; shift

  [ "$flavor" = "xen" ] && kflavor="lts"

  if [ -n "$serial" ] ; then
    #   KERNEL CMD LINE(xen):  console=tty0
    #   KERNEL CMD LINE:
    local \
	unit=$(echo "$serial" | cut -d, -f1) \
	speed=$(echo "$serial" | cut -d, -f2)
    case "$flavor" in
    xen)
      echo -n "console=tty0 console=hvc0 earlyprintk=xen nomodeset "
      ;;
    *)
      echo -n "console=tty0 console=ttyS$unit,$speed "
      ;;
    esac
  fi

  echo -n "modloop=$kver/boot/modloop-$kflavor "
  if [ -d "$bootdir/$kver/apks" ] ; then
    echo -n "apks=$kver/apks "
  fi
  for i in "$bootdir/$kver/cmdline.txt" "$bootdir/cmdline.txt"
  do
    read_opts "$i" && return
  done
  echo "modules=loop,squashfs,sd-mod,usb-storage quiet"
}

find_kernels() {
  find "$bootdir" -maxdepth 3 -mindepth 3 -type f -name 'vmlinuz*' \
	| sed -e "s!$bootdir/!!" | (while read k
  do
    kver=$(echo "$k" | cut -d/ -f1)
    kfs=$(basename "$k" | cut -d- -f2)
    if [ -f "$bootdir/$(dirname "$k")/xen.gz" ] ; then
      # Special handling for Xen kernels
      echo $kver,xen
    fi
    echo $kver,$kfs
  done) | sort -r -V
}

pick_kernel() {
  local j="$1" c=0 i

  if [ -z "$j" ] ; then
    echo 'No default kernel sepcified' 1>&2
    exit 40
  fi
  if [ x"$(echo "$j" | tr -dc 0-9)" = x"$j" ] ; then
    # It is a number
    for i in $kernels ''
    do
      c=$(expr $c + 1)
      [ $j -eq $c ] && break
    done
  else
    for i in $kernels ''
    do
      c=$(expr $c + 1)
      [ x"$i" = x"$j" ]  && break
    done
  fi
  if [ -z "$i" ] ; then
    echo "$j: unknown kernel" 1>&2
    exit 58
  fi

  default="$i"
  default_k="$c"
}

pick_latest() {
  default=$(echo "$kernels" | head -1)
  default_k=1
}

k_date() {
  local flavor="$1"
  [ "$flavor" = "xen" ] && flavor=lts
  date --reference="$bootdir/$kver/boot/vmlinuz-$flavor" +"%Y-%m-%d"

}

grub_get_serial() {
  #   GRUB: serial --unit=0 --speed=115200
  #   GRUB: terminal_input console serial
  #   GRUB: terminal_output console serial

  set - $(awk '$1 == "serial" { print }' "$1")
  [ $# -eq 0 ] && return 0
  local unit=0 speed=115200 found=false i
  for i in "$@"
  do
    case "$i" in
    --unit=*) unit=${i#--unit=} ; found=true ;;
    --speed=*) speed=${i#--speed=} ; found=true ;;
    esac
  done
  $found || return 0
  echo "$unit,$speed"
}

gen_grub_menu() {
  [ ! -d "$bootdir/boot/grub" ] && return
  (
    grubcfg="$bootdir/boot/grub/grub.cfg"
    if [ -z "$timeout" ] ; then
      if [ -f "$grubcfg" ] ; then
        timeout=$(awk -F= '$1 == "set timeout" { print $2 }' "$grubcfg")
      fi
      [ -z "$timeout" ] && timeout=10
    fi

    if [ -z "$serial" ] ; then
      if [ -f "$grubcfg" ] ; then
        serial=$(grub_get_serial "$grubcfg")
      fi
    else
      case "$serial" in
      NO) serial='' ;;
      esac
    fi

    exec >"$grubcfg"
    echo "Creating GRUB menu" 1>&2

    echo "set timeout=$timeout"
    echo "set default=$default"
    if [ -n "$serial" ] ; then
      #   GRUB: serial --unit=0 --speed=115200
      #   GRUB: terminal_input console serial
      #   GRUB: terminal_output console serial
      local \
	unit=$(echo "$serial" | cut -d, -f1) \
	speed=$(echo "$serial" | cut -d, -f2)
      echo "serial --unit=$unit --speed=$speed"
      echo 'terminal_input console serial'
      echo 'terminal_output console serial'
    fi

    for kvalue in $kernels
    do
      local \
	kver=$(echo $kvalue | cut -d, -f1)
	kvar=$(echo $kvalue | cut -d, -f2)

      echo "menuentry \"$kvalue ($(k_date $kvar))\" --id $kvalue {"
      echo "  echo \"Booting $kvalue ...\""
      if [ "$kvar" = "xen" ] ; then
        # This is a Xen kernel
	echo "  multiboot2 /$kver/boot/xen.gz $(xen_opts "$kver")"
	echo "  module2 /$kver/boot/vmlinuz-lts $(linux_opts "$kver" "$kvar")"
	echo "  module2 /$kver/boot/initramfs-lts"
      else
	echo "  linux /$kver/boot/vmlinuz-$kvar $(linux_opts "$kver" "$kvar")"
	echo "  initrd /$kver/boot/initramfs-$kvar"
      fi
      echo "}"
    done
  )
}

gen_syslinux_menu() {
  (
    syscfg="$bootdir/syslinux.cfg"
    if [ -z "$timeout" ] ; then
      if [ -f "$syscfg" ] ; then
        timeout=$(awk '$1 == "TIMEOUT" { print $2/10 }' "$syscfg")
      fi
      [ -z "$timeout" ] && timeout=10
    fi
    if [ -z "$serial" ] ; then
      if [ -f "$syscfg" ] ; then
        serial=$(awk '$1 == "SERIAL" { OFS="," ; $1 = ""; print substr($0,2); }' "$syscfg")
      fi
    else
      case "$serial" in
      NO) serial='' ;;
      esac
    fi

    exec > "$bootdir/syslinux.cfg"
    echo "Creating syslinux menu" 1>&2

    #   SYSLINUX: SERIAL 0 115200
    [ -n "$serial" ] && echo "SERIAL $serial" | tr ',' ' '

    if [ -f "$bootdir/bios/menu.c32" ] ; then
      echo "PROMPT 0"
      echo "UI menu.c32"
    else
      echo "PROMPT 1"
    fi
    echo "DEFAULT $default"
    echo "TIMEOUT $(expr $timeout '*' 10)"
    echo ''

    for kvalue in $kernels
    do
      local \
	kver=$(echo $kvalue | cut -d, -f1)
	kvar=$(echo $kvalue | cut -d, -f2)

      echo "LABEL $kvalue"
      echo "  MENU LABEL $kvalue ($(k_date $kvar))"
      if [ "$kvar" = "xen" ] ; then
        # This is a Xen kernel
	echo "  KERNEL mboot.c32"
	echo "  APPEND /$kver/boot/xen.gz $(xen_opts "$kver") --- /$kver/boot/vmlinuz-lts $(linux_opts "$kver" "$kvar") --- /$kver/boot/initramfs-lts"
      else
	echo "  KERNEL $kver/boot/vmlinuz-$kvar"
	echo "  INITRD $kver/boot/initramfs-$kvar"
	echo "  APPEND $(linux_opts "$kver" "$kvar")"
      fi
      echo ""
    done
  )
}

bootdir=$(cd $(dirname $0) && pwd)
[ -z "$bootdir" ] &&  exit 1
. "$bootdir/scripts/lib.sh"

if yesno "${IN_CHROOT:-}" ; then
  in_chroot=true
else
  in_chroot=false
  if ! sh "$bootdir/scripts/run.sh" --boot="$bootdir" --test ; then
    set -x
    exec sh "$bootdir/scripts/run.sh" --boot="$bootdir" sh "$0" "$@"
    exit $?
  fi
fi

timeout=
uefi=true
bios=true
default=''
serial=''

while [ $# -gt 0 ]
do
  case "$1" in
  --bootdir=*) bootdir=${1#--bootdir=} ;;
  --bios) bios=true ;;
  --no-bios) bios=false ;;
  --uefi) uefi=true ;;
  --no-uefi) uefi=false ;;
  --timeout=*) timeout=${1#--timeout=} ;;
  --default=*) default="${1#--default=}" ;;
  --latest) default="$(LATEST)" ;;
  --serial=*) serial=${1#--serial=} ;;
  --serial) serial=0,115200 ;;
  --no-serial) serial=NO ;;
  *) break ;;
  esac
  shift
done

kernels=$(find_kernels)
[ -z "$kernels" ] && die "No kernels found"
echo "Kernels:"
echo "$kernels"

if [ -n "$default" ] ; then
  if [ x"$default" = x"$(LATEST)" ] ; then
    pick_latest
  else
    pick_kernel $default
  fi
else
  modloop=''
  pick_latest  	# Default to latest kernel

  if [ -n "${F_CMDLINE:-}" ] ; then
    # Force a F_CMDLINE
    modloop=$(check_opt modloop ${F_CMDLINE}) || :
  elif ! $in_chroot ; then
    # Check /proc/cmdline for boot args
    modloop=$(check_opt modloop)
  fi
  if [ -n "$modloop" ] ; then
    kver=$(echo "$modloop" | cut -d/ -f1)
    kflavor=$(basename "$modloop" | cut -d- -f2)
    [ -f "$bootdir/$kver/boot/xen.gz" ] \
	&& [ -f /sys/hypervisor/uuid ] \
	&& [ -n $(cat /sys/hypervisor/uuid) ] \
	&& [ -z "$(tr -d 0- < /sys/hypervisor/uuid)" ] \
	&& kflavor=xen
    pick_kernel $kver,$kflavor
  fi
fi

$uefi && gen_grub_menu
$bios && gen_syslinux_menu

# label
# size
# tar/dir




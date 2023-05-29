#!/bin/sh
#
# Simple boot menu generator
#
# Updates a REFIND and SYSLINUX menus
#
set -euf -o pipefail

read_opts() {
  [ ! -f "$1" ] && return 1
  sed -e 's/#.*$//' "$1" | tr '\n' ' '
  return $?
}

xen_opts() {
  local kver="$1" i; shift
  for i in "$bootdir/$kver/xen_opts.txt" "$bootdir/xen_opts.txt"
  do
    read_opts "$i" && return
  done
}

linux_opts() {
  local kver="$1" flavor="$2" i ; shift

  [ "$flavor" = "xen" ] && flavor="lts"
  echo -n "modloop=$kver/boot/modloop-$flavor "
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

k_date() {
  local flavor="$1"
  [ "$flavor" = "xen" ] && flavor=lts
  date --reference="$bootdir/$kver/boot/vmlinuz-$flavor" +"%Y-%m-%d"

}

gen_grub_menu() {
  [ ! -d "$bootdir/boot/grub" ] && return
  ( exec >"$bootdir/boot/grub/grub.cfg"
    echo "Creating GRUB menu" 1>&2

    echo "set timeout=$timeout"
    echo "set default=$default"

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
  ( exec > "$bootdir/syslinux.cfg"
    echo "Creating syslinux menu" 1>&2

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
	echo "  APPEND /$kver/boot/xen.gz --- /$kver/boot/vmlinuz-lts $(linux_opts "$kver" "$kvar") --- /$kver/boot/initramfs-lts"
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

kernels=$(find_kernels)

default=$(echo "$kernels" | head -1)
default_k=1
timeout=10
uefi=true
bios=true

while [ $# -gt 0 ]
do
  case "$1" in
  --bios) bios=true ;;
  --no-bios) bios=false ;;
  --uefi) uefi=true ;;
  --no-uefi) uefi=false ;;
  --timeout=*) timeout=${1#--timeout=} ;;
  --append=*) def_cmdline=${1#--append=*} ;;
  --default=*) pick_kernel "${1#--default=}" ;;
  *) break ;;
  esac
  shift
done

$uefi && gen_grub_menu
$bios && gen_syslinux_menu

# label
# size
# tar/dir




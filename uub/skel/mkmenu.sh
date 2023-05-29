#!/bin/sh
#
# Simple boot menu generator
#
# Updates a REFIND and SYSLINUX menus
#
set -euf -o pipefail

read_cmdline() {
  local f="$1" ; shift
  if [ -f "$f" ] ; then
    sed -e 's/#.*$//' "$f" | tr '\n' ' '
  else
    echo "$*"
  fi
}

std_kopts() {
  local kver="$1" kvar="$2" ; shift 2

  local f_opts="modloop=$kver/boot/modloop-$kvar"
  if [ -d "$bootdir/$kver/apks" ] ; then
    # Add media repos
    f_opts="$f_opts apks=$kver/apks"
  fi
  f_opts="$f_opts $(read_cmdline "$bootdir/$kver/cmdline" "$@")"
  echo $f_opts
}

find_kernels() {
  find "$bootdir" -maxdepth 3 -mindepth 3 -type f -name 'vmlinuz*' \
	| sed -e "s!$bootdir/!!" | (while read k
  do
    kver=$(echo "$k" | cut -d/ -f1)
    kfs=$(basename "$k" | cut -d- -f2)
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

gen_refind_menu() {
  [ ! -d "$bootdir/EFI/BOOT" ] && return
  ( exec >"$bootdir/EFI/BOOT/refind.conf"
    echo "Creating REFIND menu" 1>&2

    echo "scanfor manual"
    echo "timeout $timeout"
    echo "default_selection $default_k"

    for kvalue in $(find_kernels)
    do
      kver=$(echo $kvalue | cut -d, -f1)
      kvar=$(echo $kvalue | cut -d, -f2)

      date=$(date --reference="$bootdir/$kver/boot/vmlinuz-$kvar" +"%Y-%m-%d")

      echo "menuentry \"$kvalue ($date)\" {"
      echo "  loader $kver/boot/vmlinuz-$kvar"
      echo "  initrd $kver/boot/initramfs-$kvar"
      echo "  options \"$(std_kopts "$kver" "$kvar" $def_cmdline)\""
      echo "}"
    done
  )
}

gen_syslinux_menu() {
  ( exec > "$bootdir/syslinux.cfg"
    echo "Creating syslinux menu" 1>&2

    if [ -f "$bootdir/menu.c32" ] ; then
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
      local date=$(date --reference="$bootdir/$kver/boot/vmlinuz-$kvar" +"%Y-%m-%d")

      echo "LABEL $kvalue"
      echo "  MENU LABEL $kvalue ($date)"
      if [ -f "$bootdir/$kver/boot/xen.gz" ] ; then
        # This is a Xen kernel
	echo "  KERNEL $kver/boot/syslinux/mboot.c32"
	echo "  APPEND /$kver/boot/xen.gz --- /$kver/boot/vmlinuz-$kvar $(std_kopts "$kver" "$kvar" $def_cmdline) --- /$kver/boot/initramfs-$kvar"
      else
	echo "  KERNEL $kver/boot/vmlinuz-$kvar"
	echo "  INITRD $kver/boot/initramfs-$kvar"
	echo "  APPEND $(std_kopts "$kver" "$kvar" $def_cmdline)"
	echo ""
      fi
    done
  )
}

bootdir=$(cd $(dirname $0) && pwd)
[ -z "$bootdir" ] &&  exit 1

kernels=$(find_kernels)
def_cmdline=$(read_cmdline "$bootdir/cmdline" auto)

default=$(echo "$kernels" | head -1)
default_k=1
timeout=3
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

$uefi && gen_refind_menu
$bios && gen_syslinux_menu





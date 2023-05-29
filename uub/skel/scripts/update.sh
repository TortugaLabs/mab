#!/bin/sh
#
# Update host scripts
#
set -euf -o pipefail
target=
rbootdir=/media/boot
skel=$(dirname $(dirname $(readlink -f "$0")))
. "$skel/scripts/lib.sh"

while [ $# -gt 0 ]
do
  case "$1" in
  --boot=*) rbootdir=${1#--boot=} ;;
  *) break ;;
  esac
  shift
done

if [ $# -eq 0 ] ; then
  echo "Usage; $0 [--boot=/media/boot] target"
  exit 1
fi

target="$1" ; shift

# Check if RO-FS
rrun="$rbootdir/scripts/run.sh"

ssh "$target" true || exit 1

if ssh "$target" "$rrun" --test ; then
  ro=false
else
  ro=true
fi

if $ro ; then
  ssh "$target" mount -o remount,rw "$rbootdir"
  trap 'ssh "$target" mount -o remount,ro "$rbootdir"' EXIT
  trap 'exit 1' INT # Need this so that EXIT handler gets called on CTRL+C
fi

tar -zcf - -C "$skel" $(cd "$skel" ; find . -maxdepth 1 -mindepth 1 | sed -e 's!^./!!') \
    |  ( ssh "$target" tar -C "$rbootdir" -zxvf - 2>&1 | summarize  )


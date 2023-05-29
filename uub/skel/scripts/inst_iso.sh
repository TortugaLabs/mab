#!/bin/sh
#
# Install an iso
#
set -euf -o pipefail
mydir=$(dirname "$(readlink -f "$0")")

. "$mydir/lib.sh"

usage() {
  cat 1>&2 <<-_EOF_
	Usage: $0 [options] file-or-url
	_EOF_
  exit
}

main() {
  local bootdir=""
  while [ $# -gt 0 ]
  do
    case "$1" in
    --boot=*) bootdir=${1#--boot=} ;;
    *) break ;;
    esac
    shift
  done

  [ $# -eq 0 ] && usage
  local srcfile="$1"
  if [ -f "$srcfile" ] ; then
    # This is a valid file
    ls -sh "$srcfile"
  else
    case "$srcfile" in
    http://*|https://*|ftp://*)
      wget --spider "$srcfile" || die "$srcfile: not found"
      ;;
    *)
      die "$srcfile: unknown object"
      ;;
    esac
  fi

  if "$mydir/run.sh" --boot="$bootdir" --test ; then
    # R/W FS...
    :
  else
    set -x
    exec "$mydir/run.sh" --boot="$bootdir" "$0" --boot="$bootdir" "$srcfile"
    exit $?
  fi

  [ -z "$bootdir" ] && bootdir=$(dirname "$mydir")
  parse_iso_name "$srcfile"

  local t=$(mktemp -d -p "$bootdir") rc=0
  trap 'rm -rf $t' EXIT
  trap 'exit 1' INT
  (
    if [ ! -f "$srcfile" ] ; then
      basefile=$(basename "$srcfile")
      wget -O "$t/$basefile" "$srcfile"
      srcfile="$t/$basefile"
    fi
    alpdir="$osname-$flavor-$frel"
    mkdir "$bootdir/$alpdir"
    echo "Copying $srcfile..." 1>&2
    unpack_src "$srcfile" "$bootdir/$alpdir"

    # Hack initramfs
    find "$bootdir/$alpdir" -type f -name 'initramfs-*' | while read rd
    do
      echo "repacking $rd" 1>&2
      sh "$mydir/tweak_initfs.sh" "$rd"
    done
    sh "$bootdir/mkmenu.sh"
  ) || rc=$?
  exit $rc
}

main "$@"


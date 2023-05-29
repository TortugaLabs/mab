#!/bin/sh
#
# Install an iso
#
set -euf -o pipefail
mydir=$(dirname "$(readlink -f "$0")")

usage() {
  cat 1>&2 <<-_EOF_
	Usage: $0 [options] cmd
	--boot : Specify the boot directory.
	--test: just check if R/O status (exit 1 if ro-fs)
	_EOF_
  exit
}

main() {
  local bootdir="" i
  while [ $# -gt 0 ]
  do
    case "$1" in
    --boot=*) bootdir=${1#--boot=} ;;
    *) break ;;
    esac
    shift
  done

  [ $# -eq 0 ] && usage
  if [ -z "$bootdir" ] ; then
    # Check if these is specified in the run arguments
    for i in "$@"
    do
      case "$i" in
      --boot=*) bootdir=${i#--boot=} ;;
      esac
    done
  fi
  [ -z "$bootdir" ] && bootdir=$(dirname "$mydir")

  local cleanup=true rc=0
  [ -e "$bootdir/ro-check" ] && cleanup=false
  if touch "$bootdir/ro-check" ; then
    $cleanup && rm -f "$bootdir/ro-check"
    [ x"$1" = x"--test" ] && exit 0
  else
    [ x"$1" = x"--test" ] && exit 1
    mount -o remount,rw "$bootdir"
    trap 'mount -o remount,ro "$bootdir"' EXIT
    trap 'exit 1' INT # Need this so that EXIT handler gets called on CTRL+C
  fi

  rc=0
  [ -f "$1" ] && [ ! -x "$1" ] && set -- sh "$@"
  "$@" || rc=$?
  exit $rc
}

main "$@"


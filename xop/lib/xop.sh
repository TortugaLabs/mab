#!/bin/sh
#
# XOPs main file
#
set -euf -o pipefail
mydir=$(dirname "$(readlink -f "$0")")
O=${O:-$0}

for i in $(find "$mydir" -name '*.sh' -print)
do
  [ x"$(basename "$i")" = x"$(basename "$0")" ] && continue
  . "$i"
done
unset i

usage() {
  if [ $# -gt 0 ] ; then
    echo "$*"
  fi
  cat <<-_EOF_
	Usage: $O [opts] {subcmd} [args]

	Sub commands:

	_EOF_

  find "$mydir" -name '*.sh' -print0 | xargs -0 grep -h '^xop_' \
    | sort | sed -e 's/^xop_//' | tr -d '()' \
    | sed -e 's/[ 	]*{[ 	]*#[ 	]*/ : /' \
    | while read op line
    do
      echo "- $op $line"
      summary=""
      summary=$(xop_${op} -h  2>/dev/null | head -1 | sed -e 's/^Usage:[ 	]*//' ) || :
      [ -n "$summary" ] && echo "  $summary"
    done

  cat <<-_EOF_

	Help options:

	- $O help {subcmd}
	  get subcmd information.
	- $O help xl
	  get list of xl sub-commands

	_EOF_

  exit 1
}


main() {
  [ $# -eq 0 ] && usage
  local op="$1" ; shift

  case "$op" in
  help)
    [ $# -eq 0 ] && usage
    if [ x"$1" = x"xl" ] ; then
      xl
    elif ! type xop_"$1" >/dev/null 2>&1 ; then
      echo "$1: unknown sub-command"
    else
      xop_"$1" -h
    fi
    exit
  esac

  if type xop_"$op" >/dev/null 2>&1 ; then
    xop_"$op" "$@"
    exit $?
  else
    exec xl "$op" "$@"
  fi
  exit $?
}

main "$@"


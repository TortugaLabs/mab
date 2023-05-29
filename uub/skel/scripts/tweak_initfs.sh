#!/bin/sh
#
# Tweak initramfs
#
set -euf -o pipefail

###$_begin-include: summarize.sh

summarize() {
  set +x
  while read -r L
  do
    printf '\r'
    local w=$(tput cols 2>/dev/null)
    if [ -n "$w" ] && [ $(expr length "$L") -gt $w ] ; then
      L=${L:0:$w}
    fi
    echo -n "$L"
    printf '\033[K'
  done
  [ $# -eq 0 ] && set - "Done"
  printf '\r'"$*"'\033[K\r\n'
}

###$_end-include: summarize.sh
###$_begin-include: die.sh

die() {
  local rc=1
  [ $# -eq 0 ] && set - -1 EXIT
  case "$1" in
    -[0-9]*) rc=${1#-}; shift ;;
  esac
  echo "$@" 1>&2
  exit $rc
}

###$_end-include: die.sh

output=""
while [ $# -gt 0 ]
do
  case "$1" in
  --output=*) output=${1#--output=} ;;
  *) break
  esac
  shift
done

[ $# -ne 1 ] && die "Usage: $0 initramfs"
img="$1"
[ ! -f "$img" ] && "$img: not found"
[ -z "$output"  ] && output="$img"
if [ -f "$output" ] ; then
  [ ! -w "$output" ] && "$output: not writable"
fi

t=$(mktemp -d) ; rc=0
trap 'rm -rf $t' EXIT
trap 'exit' INT
(
  mkdir -p "$t/initrd"
  gzip -d < "$img" | ( cd "$t/initrd" ; cpio -ivd ) 2>&1 | summarize "cpio-extracted"
  cp -av "$t/initrd/init" "$t/init.sh"
  (
    head -1 "$t/init.sh"
    cat <<-'_EOF_'
	x_find_boot_repos_x() {
	  if [ -n "$ALPINE_REPO" ]; then
	    echo "$ALPINE_REPO"
	  else
	    local i j KOPT_apks

	    for i in $(cat /proc/cmdline)
	    do
	      case "$i" in
	        apks=*) KOPT_apks=${i#apks=} ;;
	      esac
	    done

	    if [ -n "$KOPT_apks" ] ; then
	      for i in /media/*
	      do
		for j in $(echo $KOPT_apks | tr ',' ' ')
		do
		  if [ -f "$i/$j/.boot_repository" ] ; then
		    echo "$i/$j"
		    return 0
		  fi
		done
	      done
	    fi

	    find /media/* -name .boot_repository -type f -maxdepth 3 \
			  | sed 's:/.boot_repository$::'
	  fi
	}
	_EOF_
    sed -e  's/find_boot_repositories /x_find_boot_repos_x /' < "$t/init.sh"
  ) >"$t/initrd/init"
  echo 'Re-packing initrd'
  ((
    cd "$t/initrd"
    find . | sed -e 's!^./!!' | cpio -ov -H newc | gzip -v9
  ) > "$output"  ) 2>&1 | summarize
  ls -sh "$output"
) || rc=0
rm -rf "$t"
exit $rc


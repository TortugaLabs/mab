#!/bin/sh

parse_iso_name() {
  local iso="$(basename "$1")"
  #
  # Parse ISO name
  #
  case "$iso" in
    *.iso) is_iso=true ;;
    *.tar.gz) is_iso=false ;;
    *) die "$iso: unsupported image type" ;;
  esac
  osname=$(echo "$iso" |cut -d- -f1)
  flavor=$(echo "$iso" |cut -d- -f2)
  frel=$(echo "$iso" |cut -d- -f3)
  farch=$(echo "$iso" |cut -d- -f4 | cut -d. -f1)

  [ -z "$osname" ] && die "No osname found"
  [ -z "$flavor" ] && die "No flavor found"

  (echo "$frel" | grep -q -e '^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$') || die "$frel: Unrecognized release format"
  case "$farch" in
    x86_64) echo "sysarch: $farch" 1>&2 ;;
    *) die "$farch: Unsupported system architecture"
  esac
}


unpack_src() {
  local iso="$1" dst="$2"

  mkdir -p "$dst"
  case "$iso" in
  *.iso)
    if type 7z >/dev/null 2>&1 ; then
      # Use 7z
      7z x -y -o"$dst" "$iso"
    else
      # This requires root
      # So, since this is an ISO, we should mount it first
      local t=$(mktemp -d)
      (
	trap 'exit 1' INT
	trap 'rm -rf $t' EXIT
	mount -t iso9660 -r "$iso" "$t" || exit 38
	trap 'umount "$t" ; rm -rf "$t"' EXIT
	[ ! -f "$t/.alpine-release" ] && die "$iso: not an Alpine ISO image"
	cp -av "$t/." "$dst" 2>&1 | summarize "COPY(ISO)...DONE"
      ) || rc=$?
      [  $rc -ne 0 ] && exit $rc
    fi
    ;;
  *.tar.gz)
    # It is a tarball
    tar -C "$dst" -zxvf "$iso" | summarize "Extracting TARBALL...DONE"
    ;;
  *)
    die "$iso: unknown file type"
    ;;
  esac
}


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
###$_begin-include: blkdevs.sh

bd_in_use() {
  lsblk -n -o NAME,FSTYPE,MOUNTPOINTS --raw | while read name fstype mounted
  do
    [ ! -b /dev/$name ] && continue
    [ -z "$fstype" ] && continue
    if [ -n "$mounted" ] ; then
      echo "mounted $name"
    elif [ -n "$fstype" ] ; then
      case "$fstype" in
      crypto*|LVM2*)
	echo "$fstype $name"
	;;
      esac
    fi
  done | awk '
	{
	  if (match($2,/[0-9]p[0-9]+$/)) {
	    sub(/p[0-9]+$/,"",$2)
	    mounted[$2] = $2
	  } else {
	    sub(/[0-9]+$/,"",$2)
	    mounted[$2] = $2
	  }
	}
	END {
	  for (i in mounted) {
	    print mounted[i]
	  }
	}
  '
}
bd_list() {
  find /sys/block -mindepth 1 -maxdepth 1 -type l -printf '%l\n' | grep -v '/virtual/' | while read dev
  do
    dev=$(basename "$dev")
    [ ! -e /sys/block/$dev/size ] && continue
    [ $(cat /sys/block/$dev/size) -eq 0 ] && continue
    echo $dev
  done
}


bd_unused() {

  local used_devs=$(bd_in_use) i j
  for i in $(bd_list)
  do
    for j in $used_devs
    do
      [ "$i" = "$j" ] && continue 2
    done
    echo "$i"
  done
}


###$_end-include: blkdevs.sh

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
###$_begin-include: check_opt.sh

check_opt() {
  local out=echo default=
  while [ $# -gt 0 ]
  do
    case "$1" in
    -q) out=: ;;
    --default=*) default=${1#--default=} ;;
    *) break ;;
    esac
    shift
  done
  local flag="$1" ; shift
  [ $# -eq 0 ] && set - $(cat /proc/cmdline)

  for j in "$@"
  do
    if [ x"${j%=*}" = x"$flag" ] ; then
      $out "${j#*=}"
      return 0
    fi
  done
  [ -n "$default" ] && $out "$default"
  return 1
}

###$_end-include: check_opt.sh
###$_begin-include: param.sh

param() {
  local src="$1" key="$2"
  awk '
    $1 == "'"$key"'" {
      $1="";
      print substr($0,2);
    }
  ' "$src"
}

###$_end-include: param.sh
###$_begin-include: yesno.sh

yesno() {
        [ -z "${1:-}" ] && return 1

        # Check the value directly so people can do:
        # yesno ${VAR}
        case "$1" in
                [Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]|[Oo][Nn]|1) return 0;;
                [Nn][Oo]|[Ff][Aa][Ll][Ss][Ee]|[Oo][Ff][Ff]|0) return 1;;
        esac

        # Check the value of the var so people can do:
        # yesno VAR
        # Note: this breaks when the var contains a double quote.
        local value=
        eval value=\"\$$1\"
        case "$value" in
                [Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]|[Oo][Nn]|1) return 0;;
                [Nn][Oo]|[Ff][Aa][Ll][Ss][Ee]|[Oo][Ff][Ff]|0) return 1;;
                *) echo "\$$1 is not set properly" 1>&2; return 1;;
        esac
}

###$_end-include: yesno.sh
###$_begin-include: solv_ln.sh

solv_ln() {
  local target="$1" linknam="$2"

  [ -d "$linknam" ] && linknam="$linknam/$(basename "$target")"

  local linkdir=$(readlink -f "$(dirname "$linknam")")
  local targdir=$(readlink -f "$(dirname "$target")")

  linkdir=$(echo "$linkdir" | sed 's!^/!!' | tr ' /' '/ ')
  targdir=$(echo "$targdir" | sed 's!^/!!' | tr ' /' '/ ')

  local a='' b=''

  while :
  do
    set - $linkdir ; a="$1"
    set - $targdir ; b="$1"
    [ $a != $b ] && break
    set - $linkdir ; shift ; linkdir="$*"
    set - $targdir ; shift ; targdir="$*"
    [ -z "$linkdir" ] && break;
    [ -z "$targdir" ] && break;
  done

  if [ -n "$linkdir" ] ; then
    set - $linkdir
    local q=""
    linkdir=""
    while [ $# -gt 0 ]
    do
      shift
      linkdir="$linkdir$q.."
      q=" "
    done
  fi
  echo $linkdir $targdir $(basename $target) | tr '/ ' ' /'
}


###$_end-include: solv_ln.sh

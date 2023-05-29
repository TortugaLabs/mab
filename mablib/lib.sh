#!/bin/sh

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
###$_begin-include: print_args.sh

print_args() {
  [ "$#" -eq 0 ] && return 0
  case "$1" in
  --sep=*|-1)
    if [ x"$1" = x"-1" ] ; then
      local sep='\x1'
    else
      local sep="${1#--sep=}"
    fi
    shift
    local i notfirst=false
    for i in "$@"
    do
      $notfirst && echo -n -e "$sep" ; notfirst=true
      echo -n "$i"
    done
    return
    ;;
  esac
  local i
  for i in "$@"
  do
    echo "$i"
  done
}

###$_end-include: print_args.sh
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

#!/bin/sh

stderr() {
  echo "$@" 1>&2
}

_vg_extent_size() {
  vgs --units b  --no-headings -o vg_extent_size "$1" | tr -dc 0-9
}
_to_bytes() {
  echo "$1" | tr A-Z a-z |awk 'BEGIN{b=1;k=1024;m=k*k;g=k^3;t=k^4}
	/^[0-9.]+[kgmt]?b?$/&&/[kgmtb]$/{
		sub(/b$/,"")
	        sub(/g/,"*"g)
	        sub(/k/,"*"k)
        	sub(/m/,"*"m)
        	sub(/t/,"*"t)
	"echo "$0"|bc"|getline r; print r; exit;}
	{print "invalid input"}'
}
_to_extent() {
  local vg="$1" num="$2" bytes extsz extcnt
  extsz=$(_vg_extent_size "$vg")
  bytes=$(_to_bytes "$num")
  extcnt=$(expr $bytes / $extsz)
  if [ $(expr $bytes % $extsz) -gt 0 ] ; then
    extcnt=$(expr $extcnt + 1)
  fi
  echo $extcnt
}


cfg_or_file() {
  local try tryname trybase found=false
  for try in "$1" "/etc/xen/$1" "$1.cfg" "/etc/xen/$1.cfg" ''
  do
    [ ! -f "$try" ] && continue
    found=true
    tryname=$(grep '^[ 	]*name[ 	]*=' "$try" | sed -e 's/^[ 	]*name[ 	]*=[ 	]*//' -e 's/[ 	]*$//' | tr -d \"\')
    if [ -z "$tryname" ] ; then
      stderr "$try: missing name"
      continue
    fi
    trybase=$(basename "$try" | cut -d. -f1)
    if [ x"$tryname" != x"$trybase" ] ; then
      stderr "$try: does not match name $tryname"
      continue
    fi
    vmname="$tryname"
    vmcfg="$try"
    return 0
  done
  $found || stderr "$1: not found"
  exit 24
}

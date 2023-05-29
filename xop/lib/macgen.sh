#!/bin/sh

# Select from: http://standards-oui.ieee.org/oui/oui.txt
# Random OUI
oui_random() { echo "44:d2:ca" ; }
oui_prefix() { echo "b8:78:79" ; }
oui_changed() { echo "d8:60:b0" ; }

random_hex() {
  echo $(od -An -N1 -t x1 /dev/urandom)
}

macaddr() {
  [ $# -eq 0 ] && set - $(oui_random)
  echo ${1}:$(random_hex):$(random_hex):$(random_hex)
}

uuid() {
  cat /proc/sys/kernel/random/uuid
}

xop_macgen() { # Generate ids
  local prefix=""
  while [ $# -gt 0 ]
  do
    case "$1" in
    -h)
      cat <<-_EOF_
	$O macgen [opts] [prefix]

	opts:
	- -1 : Use the random unused OUI $(oui_random)
	- -2 : Std (Roche Diagnostics GmbH OUI $(oui_prefix))
	- -3 : changed OUI (bioMÃ©rieux Italia S.p.A. $(oui_changed))
	- --mac: Generate a single random mac
	- --uuid|-u : Generate uuid
	- prefix: xx:xx:xx
	   Generate a mac address with the given prefix.
	_EOF_
      exit
      ;;
    -1|--mac)
      prefix="$(oui_random)"
      ;;
    -2)
      prefix="$(oui_prefix)"
      ;;
    -3)
      prefix="$(oui_changed)"
      ;;
    ??:??:??)
      prefix="$1"
      ;;
    --uuid|-u)
      uuid
      exit
      ;;
    *)
      break
    esac
    shift
  done

  if [ -n "$prefix" ] ; then
    macaddr "$prefix"
  else
    echo "OUI random:   $(macaddr "$(oui_random)")"
    echo "OUI prefix:   $(macaddr "$(oui_prefix)")"
    echo "OUI changed:  $(macaddr "$(oui_changed)")"
    echo "UUID:         $(uuid)"
  fi
}

#!/bin/sh
#
# XL extensions
#
xop_start() { # Start a VM
  local paused= vv=stderr conio= run= quiet=
  while [ $# -gt 0 ]
  do
    case "$1" in
    -h)
      cat <<-_EOF_
	$O start [opts] cfgfile|vm

	opts:
	- -n : Dry-run
	- -q : quiet
	- -p : leave domain paused after creation
	- -c : connect to console
	_EOF_
      exit
      ;;
    -n) run=stderr ;;
    -q) vv=: ; quiet="$1" ;;
    -p) paused="$1" ;;
    -c) conio="$1" ;;
    *) break ;;
    esac
    shift
  done

  [ $# -eq 0 ] && xop_start -h

  cfg_or_file "$1"
  $vv "vm:  $vmname"
  $vv "cfg: $vmcfg"

  if [ -n "$conio" ] ; then
    if [ -n "$paused" ] ; then
      $run xl create $quiet $paused "$vmcfg"
    else
      $run xl create $quiet -p "$vmcfg"
      $run sleep 1
      $run xl unpause "$vmname"
      $run xl console "$vmname"
    fi
  else
    $run xl create $quiet $paused "$vmcfg"
  fi
}
xop_stop() { # Terminate a domain immediately.
  while [ $# -gt 0 ]
  do
    case "$1" in
    -h)
      cat <<-_EOF_
	$O stop cfgfile|vm
	_EOF_
      exit
      ;;
    *) break ;;
    esac
    shift
  done
  [ $# -eq 0 ] && xop_stop -h
  cfg_or_file "$1"
  xl destroy "$vmname"
}

xop_stopstart() { # Terminate a domain immediately, and re-start it again
  while [ $# -gt 0 ]
  do
    case "$1" in
    -h)
      cat <<-_EOF_
	$O stopstart cfgfile|vm
	_EOF_
      exit
      ;;
    *) break ;;
    esac
    shift
  done
  [ $# -eq 0 ] && xop_stopstart -h

  cfg_or_file "$1"
  xl destroy "$vmname"
  sleep 1
  xl create "$vmcfg"
}

xop_doms() { # List all defined domains
  while [ $# -gt 0 ]
  do
    case "$1" in
    -h)
      cat <<-_EOF_
	$O doms
	_EOF_
      exit
      ;;
    *) break ;;
    esac
    shift
  done

  find /etc/xen -maxdepth 1 -mindepth 1 -type f -name '*.cfg' | (
  while read cfg
  do
    (
      cfg_or_file "$cfg" 2>/dev/null
      if ! status=$(xl uptime -s "$vmname" 2>/dev/null | cut -d, -f1) ; then
	status=""
      fi
      echo "$vmname	$status"
    )
  done)
}

xop_list() { # List information about all/some domains.
  #| - list [options] [Domain]
  #|
  #|   Options:
  #|
  #|  - -l, --long : Output all VM details
  #|  - -v, --verbose : Prints out UUIDs and security context
  #|  - -Z, --context : Prints out security context
  #|  - -c, --cpupool : Prints the cpupool the domain is in
  #|  - -n, --numa : Prints out NUMA node affinity
  #|
  xl list "$@"
}

xop_shutdown() { # Issue a shutdown signal to a domain.
  #|- shutdown [options] <-a|Domain>
  #|
  #|  Options:
  #|
  #|  - -a, --all : Shutdown all guest domains.
  #|  - -F : Fallback to ACPI power event for HVM guests with no PV drivers.
  #|  - -w, --wait : Wait for guest(s) to shutdown.
  #|
  xl shutdown "$@"
}

xop_reboot() { # Issue a reboot signal to a domain.
  #|- reboot [options] <-a|Domain>
  #|
  #|  Options:
  #|
  #|  - -a, --all : Reboot all guest domains.
  #|  - -F : Fallback to ACPI power event for HVM guests with no PV drivers.
  #|  - -w, --wait : Wait for guest(s) to shutdown.
  xl reboot "$@"
}

xop_uptime() { # Print uptime for all/some domains.
  local opt=""
  while [ $# -gt 0 ]
  do
    case "$1" in
    -h)
      cat <<-_EOF_
	$O uptime [-s] [cfgfile|vm]
	_EOF_
      exit
      ;;
    -s) opt="$1" ;;
    *) break ;;
    esac
    shift
  done
  [ $# -gt 1 ] && xop_uptime -h
  if [ $# -eq 0 ] ; then
    xl uptime $opt
  else
    cfg_or_file "$1"
    xl uptime $opt "$vmname"
  fi
}

xop_top() { # Monitor a host and the domains in real time.
  #| - top
  xl top "$@"
}

xop_console() { # Attach to domain's console
  local type="" num=""
  while [ $# -gt 0 ]
  do
    case "$1" in
    -h)
      cat <<-_EOF_
	$O console [options] <cfgfile|vm>

	 Options
	 - -t <type> : console type, pv , serial or vuart
	 - -n <number> : console number
	_EOF_
      exit
      ;;
    -t) type="$1 $2" ; shift ;;
    -n) num="$1 $2" ; shift ;;
    *) break
    esac
    shift
  done

  [ $# -eq 0 ] && xop_console -h
  cfg_or_file "$1"
  xl console $type $num "$vmname"
}




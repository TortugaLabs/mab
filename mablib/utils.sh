#!/bin/sh

# Example: add nameif command
#~ mdev_append '-SUBSYSTEM=net;DEVPATH=.*/net/.*;.*     root:root 600 @/sbin/nameif -s'

mdev_append() {
  # Add a config line to mdev.conf (before fallback rule)

  local line="$*"
  awk '
    $0 == "'"$line"'" {
      found = 1;
    }

    $1 == "#" && $2 == "fallback" {
      if (!found) {
	found = 1;
	print "'"$line"'";
      }
    }
    $1 == "(.*)!(.*)" {
      if (!found) {
	found = 1;
	print "'"$line"'";
      }
    }
    { print }
    '
}


#
# Parse an Apline ISO file name
#
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

#
# Unpack ISO file
#
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



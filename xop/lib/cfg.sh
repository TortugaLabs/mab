#!/bin/sh


xcf_apk_ovl() {
  # Create APK OVL file
  local r=$(mktemp -d) tarball="$1" vmname="$2" xvdsk="$3" isov="$4"
  (
    trap 'exit 1' INT
    trap 'rm -rf $r' EXIT

    # Create /etc skeleton
    mkdir -p "$r/etc"
    cp -a /etc/localtime "$r/etc/localtime"
    cp -a /etc/zoneinfo "$r/etc/zoneinfo"

    mkdir -p "$r/etc/apk/protected_paths.d"
    cat > "$r/etc/apk/protected_paths.d/lbu.list" <<-_EOF_
	+usr/local
	+root/.ssh/authorized_keys
	_EOF_

    mkdir "$r/etc/ssh"
    [ -d /etc/ssh/userkeys ] && cp -a /etc/ssh/userkeys "$r/etc/ssh/userkeys"
    [ -f /etc/ssh/sshd_config ] && cp -a /etc/ssh/sshd_config "$r/etc/ssh/sshd_config"
    if [ -f "/root/.ssh/authorized_keys" ] ; then
      mkdir -p "$r/root/.ssh"
      chmod 700 "$r/root"
      cp -a /root/.ssh/authorized_keys "$r/root/.ssh"
    fi

    # Configure lbu.conf
    mkdir -p "$r/etc/lbu"
    cat > "$r/etc/lbu/lbu.conf" <<-_EOF_
	# what cipher to use with -e option
	DEFAULT_CIPHER=aes-256-cbc

	# Uncomment the row below to encrypt config by default
	# ENCRYPTION=\$DEFAULT_CIPHER

	# Uncomment below to avoid <media> option to 'lbu commit'
	# Can also be set to 'floppy'
	# LBU_MEDIA=usb
	LBU_MEDIA=$xvdsk

	# Set the LBU_BACKUPDIR variable in case you prefer to save the apkovls
	# in a normal directory instead of mounting an external media.
	# LBU_BACKUPDIR=/root/config-backups

	# Uncomment below to let lbu make up to 3 backups
	# BACKUP_LIMIT=3
	_EOF_

    cat > "$r/etc/hosts" <<-_EOF_
	127.0.0.1	$vmname localhost.localdomain localhost
	::1		localhost localhost.localdomain
	_EOF_
    echo $vmname > "$r/etc/hostname"

    mkdir -p "$r/etc/apk"
    cat > "$r/etc/apk/world" <<-_EOF_
	alpine-base
	openssl
	openssh
	_EOF_
    # configure repositories
    cat > "$r/etc/apk/repositories" <<-_EOF_
	/media/cdrom/apks
	http://dl-cdn.alpinelinux.org/alpine/v$isov/main
	#http://dl-cdn.alpinelinux.org/alpine/v$isov/community
	#http://dl-cdn.alpinelinux.org/alpine/edge/main
	#http://dl-cdn.alpinelinux.org/alpine/edge/community
	#http://dl-cdn.alpinelinux.org/alpine/edge/testing
	_EOF_

    for runlevel in boot default shutdown sysinit; do
	mkdir -p $r/etc/runlevels/$runlevel
    done

    for initd in bootmisc hostname hwclock modules sysctl syslog networking; do
	    ln -s /etc/init.d/$initd $r/etc/runlevels/boot/$initd
    done

    for initd in devfs dmesg hwdrivers mdev modloop; do
	    ln -s /etc/init.d/$initd $r/etc/runlevels/sysinit/$initd
    done

    for initd in killprocs mount-ro savecache; do
	    ln -s /etc/init.d/$initd $r/etc/runlevels/shutdown/$initd
    done
    ln -s /etc/init.d/sshd $r/etc/runlevels/default/sshd

    mkdir -p $r/etc/network
    cat > "$r/etc/network/interfaces" <<-_EOF_
	auto lo
	iface lo inet loopback

	auto eth0
	iface eth0 inet dhcp
	  hostname $vmname
	_EOF_

    tar zcf "$tarball" -C "$r" etc root
    $vv $(ls -lh "$tarball")
  )
}

xcf_lbuvol() {
  # Create APK OVL file
  local r=$(mktemp -d) vmname="$1" lv="$2" xvdsk="$3" diskcfg="$4"

  local cdrom=$(xcf_query_disk '[ x"$xvmode" = x"cdrom" ]' 'echo $xvpath' "$diskcfg")
  local isov=$(basename "$cdrom" .iso | cut -d- -f3 | cut -d. -f1-2)

  $vv Creating FS
  $run mkdosfs -n LBU$RANDOM $lv

  local td=$(mktemp -d) rc=0
  (
    trap 'exit 1' INT
    trap 'rm -rf "$td"' EXIT
    mkdir "$td/mnt"
    $run mount -t vfat "$lv" "$td/mnt"
    trap '$run umount "$td/mnt" && rm -rf "$td"' EXIT

    $vv Create APKOVL
    xcf_apk_ovl \
	"$td/mnt/$vmname.apkovl.tar.gz" \
	"$vmname" \
	"$xvdsk" \
	"$isov"
  ) || rc=$?
  return $rc
}


xcf_parse_disk() {
  local ln=$(echo "$*" | sed -e 's/^[ 	]*//' -e 's/,*[ 	]*#.*//' -e 's/,*[ 	]*$//'  | tr -d \"\')

  xvpath=$(echo "$ln" | cut -d, -f1)
  xvmethod=$(echo "$ln" | cut -d, -f2)
  xvdev=$(echo "$ln" | cut -d, -f3)
  xvmode=$(echo "$ln" | cut -d, -f4)

  if (echo "$*" | grep -q '#') ; then
    ln=$(echo "$*" | cut -d'#' -f2)
    xvtag=$(echo "$ln" | cut -d: -f1)
    xvattrs=$(echo "$ln" | cut -d: -f2- | sed -e 's/^[ 	]*//' -e 's/[ 	]$//')
  else
    xvtag=""
    xvattrs=""
  fi

  #~ for z in xvpath xvmethod xvdev xvmode xvtag xvattrs
  #~ do
    #~ eval echo $z=\${$z:-}
  #~ done
}

xcf_tagsect() {
  (while read ln
  do
    if (echo "$ln" | grep -q "$1") ; then
      while ! (echo "$ln" | grep -q '\[') ; do
	read ln || return 1
      done
      ln=$(echo "$ln" | sed -e 's/^.*\[//' -e 's/[ 	]*$//')
      [ -n "$ln" ] && echo "$ln"
      while read ln
      do
	[ -z "$ln" ] && continue
	if (echo "$ln" | grep -q ']') ; then
	  ln=$(echo "$ln" | sed -e 's/].*$//' -e 's/^[ 	]*//')
	  [ -n "$ln" ] && echo "$ln"
	  return 0
	fi
	echo "$ln"
      done
    fi
  done) < "$2"
}

xcf_query_disk() {
  local query="$1" select="$2" datcfg="$3"
  echo "$datcfg" | (while read ln
  do
    xcf_parse_disk "$ln"
    eval "$query" || continue
    eval "$select"
  done)
}

xcf_new_lv() {
  local vgname="$1" lvname="$2" lvsize="$3"
}


xcf_setup() {
  local vm="$1" xencfg="$2"

  local disk_cfg=$(xcf_tagsect "disk" "$xencfg")
  echo "$disk_cfg" | (while read ln
  do
    xcf_parse_disk "$ln"
    [ -z "$xvtag" ] && continue
    [ x"$xvtag" != x"CFG" ] && continue

    case "$xvpath" in
    /dev/*)
      # /dev -- assume LVM
      if ! (echo "$xvpath" | grep -q '^/dev/[^/]*/[^/]*$' ) ; then
	stderr "$xvpath: invalid path (must math /dev/vgname/lvname)"
	continue
      fi
      vgname=$(echo "$xvpath" | cut -d/ -f3)
      lvname=$(echo "$xvpath" | cut -d/ -f4)

      if [ ! -d "/dev/$vgname" ] ; then
        stderr "$xvpath: volume group not found"
	continue
      fi
      if [ -e "/dev/$vgname/$lvname" ] ; then
        if [ ! -b "/dev/$vgname/$lvname" ] ; then
	  stderr "$xvpath: is not a block device"
	  continue
	fi

        if size=$(check_opt size $xvattrs) ; then
	  # Check current size
	  local \
	      extcnt=$(_to_extent "$vgname" "$size") \
	      curcnt=$(expr $(lvs --units b --no-headings -o lv_size /dev/$vgname/$lvname | tr -dc 0-9) / $(_vg_extent_size "$vgname"))

	  if [ $extcnt -lt $curcnt ] ; then
	    if $danger ; then
	      $vv "$xvpath: shrink $curcnt => $extcnt"
	      $run lvreduce -y -l "$extcnt" /dev/$vgname/$lvname
	    else
	      stderr "$xvpath: $extcnt < $curcnt, shrink danger, use -x option"
	      continue
	    fi
	  elif [ $extcnt -gt $curcnt ] ; then
	    $vv "$xvpath: growing $curcnt => $extcnt"
	    $run lvextend -y -l $extcnt /dev/$vgname/$lvname
	  fi
	fi
      else
        if size=$(check_opt size $xvattrs) ; then
	  local extcnt=$(_to_extent "$vgname" "$size")

	  $vv "create LVM $vgname/$lvname ($size)"
	  $run lvcreate -y -l "$extcnt" -n "$lvname" "$vgname"

	  if check_opt -q apkovl $xvattrs ; then
	    xcf_lbuvol "$vm" "$xvpath" "$xvdev" "$disk_cfg"
	  fi
	fi
      fi
      ;;
    /*.img)
      # *.img -- assume raw image
      if [ -f "$xvpath" ] ; then
	# Already exists
        if size=$(check_opt size $xvattrs) ; then
	  local csz=$(stat -c "%s" "$xvpath") size=$(_to_bytes "$size")

	  if [ $size -lt $csz ] ; then
	    if $danger ; then
	      $vv "$xvpath: shrink $csz => $size"
	      $run truncate -s "$size" "$xvpath"
	    else
	      stderr "$xvpath: $size < $csz, shrink danger, use -x option"
	      continue
	    fi
	  elif [ $size -gt $csz ] ; then
	    $vv "$xvpath: growing $csz => $size"
	    $run truncate -s "$size" "$xvpath"
	  fi

	fi
      else
	if [ -e "$xvpath" ] ; then
	  stderr "$xvpath: is not a plain file"
	  continue
	fi
	if [ ! -d "$(dirname "$xvpath")" ] ; then
	  stderr "$xvpath: invalid path"
	  continue
	fi

        if size=$(check_opt size $xvattrs) ; then
	  $vv "Creating raw volume: $xvpath ($size)"
	  $run truncate -s $(_to_bytes $size) "$xvpath"

	  if check_opt -q apkovl $xvattrs ; then
	    xcf_lbuvol "$vm" "$xvpath" "$xvdev" "$disk_cfg"
	  fi
	fi
      fi
      ;;
    *)
      # Unsupported
      stderr "$ln: unsupported format"
      ;;
    esac
  done)
}



xop_cfg() { # Configure a VM, creating storage devices as needed
  local run="" vv=stderr danger=false
  while [ $# -gt 0 ]
  do
    case "$1" in
    -h)
      cat <<-_EOF_
	$O cfg [opts] <cfgfile|vm>

	opts:
	- -n : Dry-run
	- -q : quiet
	- -x : Do dangerous changes (i.e. reduce volume size)

	_EOF_
      exit
      ;;
    -n) run=stderr ;;
    -q) vv=: ;;
    -x) danger=true ;;
    *) break ;;
    esac
    shift
  done

  [ $# -eq 0 ] && xop_cfg -h

  cfg_or_file "$1"
  $vv "vm:  $vmname"
  $vv "cfg: $vmcfg"

  xcf_setup "$vmname" "$vmcfg"
  xcf_check_autostart "$vmcfg"
}

xcf_check_autostart() {
  local rcfg="$(readlink -f "$1")"  autodir=/etc/xen/auto
  local acf=$(basename "$rcfg")

  if yesno $(param "$rcfg" '#AUTOSTART:') ; then
    if [ -e "$autodir/$acf" ] ; then
      [ x"$(readlink -f "$autodir/$acf")" = x"$rcfg" ] && return 0
      stderr "$autodir/$acf: Already exists, but mis-configured"
      return 1
    fi
    local t=$(solv_ln "$rcfg" "$autodir/$acf")
    if [ -n "$t" ] ; then
      $vv "$1: adding to autostart"
      $run rm -f "$autodir/$acf"
      $run ln -s "$t" "$autodir/$acf"
    else
      stderr "$1: path error"
      return 1
    fi
  else
    [ ! -e "$autodir/$acf" ] && return 0
    if [ x"$(readlink -f "$autodir/$acf")" = x"$rcfg" ] ; then
      $vv "$1: removing from autostart"
      $run rm -f "$autodir/$acf"
    else
      stderr "$autodir/$acf: Already exists, but mis-configured"
      return 1
    fi
  fi
}

xop_drop() { # Configure a VM, creating storage devices as needed
  local run=stderr vv=stderr undefine=false

  #|- drop [opts] cfgfile|vm
  #|
  #|
  #|  opts:
  #|
  while [ $# -gt 0 ]
  do
    case "$1" in
    -h)
      cat <<-_EOF_
	$O drop [opts] <cfgfile|vm>

	opts:
	- -n : dry-run
	- -x : execute (defaults to dry-run)
	- -q : quiet
	- -u: undefine (deletes config file too)
	_EOF_
      exit
      ;;
    -n) run=stderr ;;
    -x) run='' ;;
    -q) vv=: ;;
    -u) undefine=true ;;
    *) break ;;
    esac
    shift
  done

  [ $# -eq 0 ] && xop_drop -h

  cfg_or_file "$1"
  $vv "vm:  $vmname"
  $vv "cfg: $vmcfg"
  case "$run" in
    stderr) stderr "Dry-run: Use -x to execute" ;;
  esac

  $run xl destroy "$vmname" || :

  local disk_cfg=$(xcf_tagsect "disk" "$vmcfg")
  echo "$disk_cfg" | (while read ln
  do
    xcf_parse_disk "$ln"
    [ -z "$xvtag" ] && continue
    [ x"$xvtag" != x"CFG" ] && continue

    case "$xvpath" in
    /dev/*)
      # /dev -- assume LVM
      if ! (echo "$xvpath" | grep -q '^/dev/[^/]*/[^/]*$' ) ; then
	stderr "$xvpath: invalid path (must math /dev/vgname/lvname)"
	continue
      fi
      vgname=$(echo "$xvpath" | cut -d/ -f3)
      lvname=$(echo "$xvpath" | cut -d/ -f4)

      if [ ! -d "/dev/$vgname" ] ; then
        stderr "$xvpath: volume group not found"
	continue
      fi
      if [ ! -b "/dev/$vgname/$lvname" ] ; then
	stderr "$xvpath: is not a block device"
	continue
      fi

      $vv "Destroying LV $vgname/$lvname"
      $run lvremove -y /dev/$vgname/$lvname
      ;;
    /*.img)
      # *.img -- assume raw image
      if [ ! -f "$xvpath" ] ; then
	stderr "$xvpath: Does not exists"
	continue
      fi

      $vv "Removing $xvpath"
      $run rm -f "$xvpath"
      ;;
    *)
      # Unsupported
      stderr "$ln: unsupported format"
      ;;
    esac
  done)
  if $undefine ; then
    $vv "Removing config $vmcfg"
    $run rm -f "$vmcfg"
  fi
}




# mkuusb

# Hearbeat
  - ping WAN IP
  - Witness is ADSL modem




# Decision

- ~~virtualize~~ or bare metal
  - access to WIFI as AP
  - Xen boot doesn't work well
- MASQ or ~~arp-proxy~~
  - MASQ is easier
  - Performance due to MASQ is not that impactful
  - Statistics using `darkstats` is prone to drops.  Use
    the UPNP statistics or IPTABLES accounting
- ~~Single RJ45+VLAN~~ or two NICs
  - we are using x86 with multiple NICs.
- ~~PI4~~ vs x86
  - Difficult to source PI4.
  - Only single NIC.
  - PI4 has built-in WIFI
  - x86 can be found with multipe NICs maybe with 2.5G, and probably built-in WIFI

# ISSUES

- xen boot
  - don't know how to boot using REFIND
  - switching to grub tha comes with it works:
    - `(ISO)/efi/boot/bootx64.efi` : grub bootloader
    - Read config from `(ISO)/boot/grub/grub.cfg`
  - would need to replace REFIND with grub, so need to configure
    grub but examples use the overly complicated grub.d
  - there are examples of grub.cfg, but I don't know how to
    set the default menu entry.
  - Still, the graphics mode are f*ck'ed.
  - **WE DO NOT VIRTUALIZE**


#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
# Ubuntu Base 24.04 LTS riscv64 (glibc, dpkg and apt, no init system) as an
# ext4 disk image for kwblk, built without root privileges like
# alpine-disk.sh: `mke2fs -d` from the extracted tree, then debugfs gives
# every file the owner and mode (setuid/setgid included) from the tarball
# (tools/ext4-owners.py). The tarball has no device nodes and no xattrs; its
# two hard links survive `mke2fs -d`.
#
#   DISK_SIZE=2G kernel/guest/ubuntu-disk.sh   -> vendor/build/disk/ubuntu.ext4
#   (UBUNTU_TARBALL=file overrides the pinned release in tools/env.sh)
#
# Boot: bun js/cli.ts --disk vendor/build/disk/ubuntu.ext4 --snapshot
#       (cmdline "console=hvc0 root=/dev/wda rw"). Ubuntu Base has no init,
#       so /sbin/init is /usr/local/sbin/kw-init: it mounts /proc, /sys,
#       /dev/pts, /dev/shm and /run, then runs a root login shell on the
#       console; leaving that shell, `poweroff` or `reboot` shuts down with
#       / left clean. `init=/bin/bash` works too (nothing mounted but / and
#       /dev). Installing systemd-sysv replaces /sbin/init, and then the
#       poweroff/reboot wrappers in /usr/local/sbin hand over to systemctl.
set -euo pipefail

. "$(dirname "$0")/../tools/env.sh"   # root, UBUNTU_*, fetch_verified
out="$build/disk"
dl="$root/vendor/downloads"
size="${DISK_SIZE:-2G}"
mkdir -p "$out" "$dl"

export PATH="$PATH:/usr/sbin:/sbin"
for t in mke2fs debugfs e2fsck; do
	command -v "$t" >/dev/null || { echo "need $t (e2fsprogs >= 1.43 for mke2fs -d)" >&2; exit 1; }
done

if [ -z "${UBUNTU_TARBALL:-}" ]; then
	UBUNTU_TARBALL="$dl/$UBUNTU_TARBALL_NAME"
	fetch_verified "$UBUNTU_URL" "$UBUNTU_TARBALL" "$UBUNTU_SHA256"
fi
echo "ubuntu: $UBUNTU_TARBALL"

stage="$out/ubuntu-root"
rm -rf "$stage"
mkdir -p "$stage"
# No device nodes in Ubuntu Base, so an unprivileged extraction is complete
# apart from owners and setuid bits, which ext4-owners.py restores.
tar -xzf "$UBUNTU_TARBALL" -C "$stage" --no-same-owner --no-same-permissions
chmod -R u+rwX "$stage"
# --no-same-permissions applies the umask, which drops the sticky,
# world-writable mode of /tmp and /var/tmp.
chmod 1777 "$stage/tmp" "$stage/var/tmp"

# --- boot configuration -----------------------------------------------------
echo unkernel > "$stage/etc/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\tunkernel\n::1\tlocalhost ip6-localhost ip6-loopback\n' > "$stage/etc/hosts"
# The CLI's user-mode network (js/node) answers DNS at 10.0.2.3.
echo "nameserver 10.0.2.3" > "$stage/etc/resolv.conf"

cat > "$stage/etc/fstab" <<'EOF'
/dev/wda	/		ext4	rw,relatime		0 1
proc		/proc		proc	nosuid,nodev,noexec	0 0
sysfs		/sys		sysfs	nosuid,nodev,noexec	0 0
devpts		/dev/pts	devpts	gid=5,mode=620		0 0
tmpfs		/dev/shm	tmpfs	nosuid,nodev,mode=1777	0 0
tmpfs		/run		tmpfs	nosuid,nodev,mode=755	0 0
EOF

mkdir -p "$stage/usr/local/sbin"
# PID 1 without an init system. Bash, because Ubuntu Base has no busybox
# and its dash cannot wait for a child and a signal at once.
cat > "$stage/usr/local/sbin/kw-init" <<'EOF'
#!/bin/bash
# unkernel: PID 1 for Ubuntu Base without an init system. Mounts the API
# file systems, runs a root login shell on the console, and powers off when
# it exits; poweroff/reboot (/usr/local/sbin) signal this process.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
shutdown_now() {
	trap '' USR1 USR2 TERM
	# From here on, not bash's "Killed" notices for its children (it may
	# print them at any later command).
	exec 3>&2 2>/dev/null
	kill -TERM -1
	sleep 0.2
	kill -KILL -1
	wait
	sync
	# Remounting read-only flushes the journal and marks the fs clean.
	mount -o remount,ro / 2>&3 && echo "kw-shutdown: / is clean (read-only)"
	sync
	# reboot(2) is syscall 142 on riscv64: no reboot binary without systemd.
	exec perl -e 'syscall(142, 0xfee1dead, 0x28121969, hex($ARGV[0])); die "reboot: $!\n"' "$1" 2>&3
}
if [ $$ != 1 ]; then
	echo "kw-init: not PID 1" >&2
	exit 1
fi
mountpoint -q /dev || mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/pts /dev/shm
mount -a
mkdir -p /run/lock
: > /run/kw-init
hostname -F /etc/hostname 2>/dev/null
kw-net
. /etc/os-release
echo "Welcome to $PRETTY_NAME on unkernel ($(uname -m)), root $(tr ' ' '\n' < /proc/cmdline | sed -n 's/^root=//p')"
action=0x4321fedc   # LINUX_REBOOT_CMD_POWER_OFF
trap 'action=0x4321fedc; stop=1' USR1
trap 'action=0x01234567; stop=1' USR2   # LINUX_REBOOT_CMD_RESTART
stop=
# A new session with the console as its controlling terminal, so the shell
# has job control and ^C reaches its foreground job.
cd /root
setsid -c /bin/bash -l <>/dev/console >&0 2>&0 &
shell=$!
while [ -z "$stop" ] && kill -0 $shell 2>/dev/null; do
	wait $shell
done
shutdown_now $action
EOF
# Network without iproute2 or a DHCP client (neither is in Ubuntu Base): lo,
# and eth0 with the fixed addresses of the host's user-mode network
# (js/core/net.ts: guest 10.0.2.15/24, gateway 10.0.2.2, DNS 10.0.2.3),
# set with the classic ioctls from perl (perl-base is Essential).
cat > "$stage/usr/local/sbin/kw-net" <<'EOF'
#!/usr/bin/perl
# unkernel: bring up lo, and eth0 as 10.0.2.15/24 via 10.0.2.2 if present.
use strict;
use warnings;
use Socket;
socket(my $s, AF_INET, SOCK_DGRAM, 0) or die "kw-net: socket: $!\n";
sub sin_ { pack("S n a4 x8", AF_INET, 0, inet_aton($_[0])) }
sub ifreq { pack("Z16 a24", $_[0], $_[1]) }
sub up {
	my ($if) = @_;
	my $r = ifreq($if, "");
	ioctl($s, 0x8913, $r) or die "kw-net: $if: $!\n";            # SIOCGIFFLAGS
	my $flags = unpack("x16 S", $r) | 0x41;                       # IFF_UP | IFF_RUNNING
	ioctl($s, 0x8914, ifreq($if, pack("S", $flags))) or die "kw-net: $if up: $!\n";
}
up("lo");
exit 0 unless -e "/sys/class/net/eth0";
ioctl($s, 0x8916, ifreq("eth0", sin_("10.0.2.15"))) or die "kw-net: address: $!\n";      # SIOCSIFADDR
ioctl($s, 0x891c, ifreq("eth0", sin_("255.255.255.0"))) or die "kw-net: netmask: $!\n"; # SIOCSIFNETMASK
up("eth0");
# struct rtentry (LP64): pad, dst, gateway, genmask, flags, ..., dev, ...
my $rt = pack("Q a16 a16 a16 S x6 Q Q s x6 Q Q Q S x6",
	0, sin_("0.0.0.0"), sin_("10.0.2.2"), sin_("0.0.0.0"), 0x3, 0, 0, 0, 0, 0, 0, 0); # RTF_UP|RTF_GATEWAY
ioctl($s, 0x890b, $rt) or $!{EEXIST} or die "kw-net: default route: $!\n";              # SIOCADDRT
EOF
for cmd in poweroff reboot halt; do
	cat > "$stage/usr/local/sbin/$cmd" <<EOF
#!/bin/sh
# unkernel: $cmd under /usr/local/sbin/kw-init; else the system's own.
if [ -e /run/kw-init ]; then
	trap 'exit 0' TERM   # kw-init stops everything: no "Terminated"
	kill -$([ $cmd = reboot ] && echo USR2 || echo USR1) 1
	sleep 10
	exit
fi
exec /usr/sbin/$cmd "\$@"
EOF
done
chmod 755 "$stage"/usr/local/sbin/{kw-init,kw-net,poweroff,reboot,halt}
ln -s ../local/sbin/kw-init "$stage/usr/sbin/init"

# Once systemd is installed (apt-get install systemd systemd-sysv udev;
# kernel/README.md, Ubuntu): root logged in on the console, as on Alpine.
mkdir -p "$stage/etc/systemd/system/serial-getty@hvc0.service.d"
cat > "$stage/etc/systemd/system/serial-getty@hvc0.service.d/autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --keep-baud 115200,57600,38400,9600 - $TERM
EOF

# TERM: the console starts as "linux"; the page's xterm.js and the CLI's
# host terminal are xterm-compatible.
printf '%s\n' 'case $TERM in linux|vt102|"") export TERM=xterm-256color ;; esac' > "$stage/etc/profile.d/kw-term.sh"

# --- image ------------------------------------------------------------------
img="$out/ubuntu.ext4"
rm -f "$img.tmp"
truncate -s "$size" "$img.tmp"
# Inode tables and journal zeroed now (sparse, so free) rather than by the
# kernel's lazyinit thread after the first boot.
mke2fs -q -F -t ext4 -b 4096 -m 1 -L ubuntu \
	-E lazy_itable_init=0,lazy_journal_init=0,root_owner=0:0 \
	-d "$stage" "$img.tmp"
python3 "$root/kernel/tools/ext4-owners.py" "$stage" "$UBUNTU_TARBALL" > "$out/ubuntu-owners.debugfs"
debugfs -w -f "$out/ubuntu-owners.debugfs" "$img.tmp" >/dev/null 2>"$out/ubuntu-owners.log" || {
	cat "$out/ubuntu-owners.log" >&2; exit 1; }
if grep -v '^debugfs ' "$out/ubuntu-owners.log" | grep -q .; then
	cat "$out/ubuntu-owners.log" >&2; exit 1
fi
e2fsck -fn "$img.tmp" >/dev/null 2>&1 || { e2fsck -fn "$img.tmp"; exit 1; }
mv "$img.tmp" "$img"
echo "disk: $img ($size, $(du -h "$img" | cut -f1) allocated)"

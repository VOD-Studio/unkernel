#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
# Alpine Linux riscv64 minirootfs as an ext4 disk image for kwblk, built
# without root privileges: `mke2fs -d` from the extracted tree, then debugfs
# fixes ownership/modes from the tarball (tools/ext4-owners.py).
#
#   DISK_SIZE=512M kernel/guest/alpine-disk.sh   -> vendor/build/disk/alpine.ext4
#
# Boot: bun js/cli.ts --disk vendor/build/disk/alpine.ext4
#       (cmdline "console=hvc0 root=/dev/wda rw"; /sbin/init is busybox init)
set -euo pipefail

. "$(dirname "$0")/../tools/env.sh"   # root, ALPINE_*, fetch_verified
out="$build/disk"
dl="$root/vendor/downloads"
size="${DISK_SIZE:-512M}"
mkdir -p "$out" "$dl"

# e2fsprogs live in sbin (not on every user's PATH).
export PATH="$PATH:/usr/sbin:/sbin"
for t in mke2fs debugfs e2fsck; do
	command -v "$t" >/dev/null || { echo "need $t (e2fsprogs >= 1.43 for mke2fs -d)" >&2; exit 1; }
done

# ALPINE_TARBALL=file overrides the pinned release (tools/env.sh).
if [ -z "${ALPINE_TARBALL:-}" ]; then
	ALPINE_TARBALL="$dl/$ALPINE_TARBALL_NAME"
	fetch_verified "$ALPINE_URL" "$ALPINE_TARBALL" "$ALPINE_SHA256"
fi
echo "alpine: $ALPINE_TARBALL"

stage="$out/alpine-root"
rm -rf "$stage"
mkdir -p "$stage"
tar -xzf "$ALPINE_TARBALL" -C "$stage" --no-same-owner 2>/dev/null || true
chmod -R u+rwX "$stage"
# busybox, zlib, openssl and apk-tools rebuilt for kwemu (see alpine.sh).
"$root/kernel/guest/alpine-opt.sh" --install "$stage"
# apk with main only, community in /etc/kw-apk-lazy (see alpine.sh).
r="$stage/etc/apk/repositories"
grep '/community$' "$r" > "$stage/etc/kw-apk-lazy" || { echo "alpine: no community line in $r" >&2; exit 1; }
grep -v '/community$' "$r" > "$r.kw" && mv "$r.kw" "$r"

# --- boot configuration -----------------------------------------------------
echo unkernel > "$stage/etc/hostname"

cat > "$stage/etc/fstab" <<'EOF'
/dev/wda	/		ext4	rw,relatime		0 1
proc		/proc		proc	nosuid,nodev,noexec	0 0
sysfs		/sys		sysfs	nosuid,nodev,noexec	0 0
cgroup2		/sys/fs/cgroup	cgroup2	nosuid,nodev,noexec	0 0
devpts		/dev/pts	devpts	gid=5,mode=620		0 0
tmpfs		/dev/shm	tmpfs	nosuid,nodev,mode=1777	0 0
tmpfs		/run		tmpfs	nosuid,nodev,mode=755	0 0
EOF

# sysinit: the kernel already mounted / (root=/dev/wda rw) and devtmpfs.
cat > "$stage/etc/kw-rc" <<'EOF'
#!/bin/sh
mountpoint -q /dev || mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/pts /dev/shm
mount -a
hostname -F /etc/hostname
echo "Welcome to $(. /etc/os-release; echo $PRETTY_NAME) on unkernel ($(uname -m)), root $(tr ' ' '\n' < /proc/cmdline | sed -n 's/^root=//p')"
EOF

# shutdown (poweroff/reboot): stop everything, then leave / clean.
cat > "$stage/etc/kw-shutdown" <<'EOF'
#!/bin/sh
kill -TERM -1 2>/dev/null
sleep 0.2
kill -KILL -1 2>/dev/null
sync
/etc/kw-data.sh stop
# Remounting read-only flushes the journal and marks the fs clean.
mount -o remount,ro / && echo "kw-shutdown: / is clean (read-only)"
sync
EOF
# Files shared with the initramfs, taken from alpine.sh so the two stay the
# same: from_alpine_sh PATH PATTERN copies the `cat > "$stage/PATH"` heredoc
# and checks that the result contains PATTERN.
from_alpine_sh() {
	awk -v h="cat > \"\$stage/$1\" <<'EOF'" '$0 == h { on = 1; next } on && $0 == "EOF" { exit } on' \
		"$root/kernel/guest/alpine.sh" > "$stage/$1"
	grep -q "$2" "$stage/$1" || { echo "cannot extract $1 from alpine.sh" >&2; exit 1; }
}
# Network (kwnet, if the host provides one).
from_alpine_sh etc/kw-net.sh udhcpc
# /data on a kwdata disk after the root disk (mounted only: / persists anyway).
install -m 755 "$root/kernel/guest/kw-data.sh" "$stage/etc/kw-data.sh"
chmod 755 "$stage/etc/kw-rc" "$stage/etc/kw-shutdown" "$stage/etc/kw-net.sh"

cat > "$stage/etc/inittab" <<'EOF'
# unkernel (disk root): no services, a root shell on the console.
::sysinit:/etc/kw-rc
::sysinit:/etc/kw-data.sh
::sysinit:/etc/kw-net.sh
::sysinit:/etc/kw-binfmt.sh
hvc0::respawn:-/bin/sh
::ctrlaltdel:/sbin/reboot
::shutdown:/etc/kw-shutdown
EOF
grep -qx hvc0 "$stage/etc/securetty" 2>/dev/null || echo hvc0 >> "$stage/etc/securetty"
# TERM: busybox init gives the console vt102 (no colors); the page's xterm.js
# and the CLI's host terminal are xterm-compatible.
printf '%s\n' 'case $TERM in linux|vt102|"") export TERM=xterm-256color ;; esac' > "$stage/etc/profile.d/kw-term.sh"
# Home (/root, not busybox init's /), the prompt, and installing missing
# commands with apk.
from_alpine_sh etc/profile.d/kw-home.sh HOME=/root
from_alpine_sh etc/profile.d/kw-prompt.sh PS1
from_alpine_sh etc/profile.d/kw-apk.sh command_not_found_handle
from_alpine_sh etc/kw-apk-install APKINDEX
from_alpine_sh etc/kw-apk-enable kw-apk-lazy
install -m 755 "$root/kernel/guest/curl-shim.sh" "$stage/usr/local/bin/curl"
chmod 755 "$stage/etc/kw-apk-install" "$stage/etc/kw-apk-enable"
# x86_64, aarch64, i386 and arm binaries through qemu-user (binfmt_misc),
# and kw-arch to fake uname -m for installers.
from_alpine_sh etc/kw-binfmt.sh register
from_alpine_sh etc/kw-qemu qemu-
from_alpine_sh usr/bin/kw-arch KW_ARCH
mkdir -p "$stage/usr/lib/kw-arch"
from_alpine_sh usr/lib/kw-arch/uname KW_ARCH
ln -sf uname "$stage/usr/lib/kw-arch/arch"
chmod 755 "$stage/etc/kw-binfmt.sh" "$stage/etc/kw-qemu" "$stage/usr/bin/kw-arch" "$stage/usr/lib/kw-arch/uname"

# --- image ------------------------------------------------------------------
img="$out/alpine.ext4"
rm -f "$img.tmp"
truncate -s "$size" "$img.tmp"
# Inode tables and journal zeroed now (sparse, so free) rather than by the
# kernel's lazyinit thread after the first boot.
mke2fs -q -F -t ext4 -b 4096 -m 1 -L alpine \
	-E lazy_itable_init=0,lazy_journal_init=0,root_owner=0:0 \
	-d "$stage" "$img.tmp"
python3 "$root/kernel/tools/ext4-owners.py" "$stage" "$ALPINE_TARBALL" > "$out/owners.debugfs"
debugfs -w -f "$out/owners.debugfs" "$img.tmp" >/dev/null 2>"$out/owners.log" || {
	cat "$out/owners.log" >&2; exit 1; }
if grep -v '^debugfs ' "$out/owners.log" | grep -q .; then
	cat "$out/owners.log" >&2; exit 1
fi
e2fsck -fn "$img.tmp" >/dev/null 2>&1 || { e2fsck -fn "$img.tmp"; exit 1; }
mv "$img.tmp" "$img"
echo "disk: $img ($size, $(du -h "$img" | cut -f1) allocated)"

#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
# Cross-build DOSBox 0.74-3 (GPL-2.0-or-later) against a static SDL 1.2
# (LGPL-2.1-or-later) with its fbcon video driver, as a static riscv64 musl
# binary for the unkernel guest's `dosbox` command (kernel/guest/dosbox),
# and pack it as dosbox-riscv64.tar.gz.
#
#   kernel/guest/dosbox-build/build.sh [OUT]   (default vendor/build/dosbox)
#
# SDL 1.2 is cloned at a pinned commit into a new OUT/src-sdl, DOSBox comes
# from its release tarball (sha256 pinned) in a new OUT/src-dosbox, the
# patches next to this script are applied (sdl-*.patch to SDL), and both are
# built with `zig cc`/`zig c++ -target riscv64-linux-musl` (rv64gc, lp64d)
# out of tree. SDL keeps only fbcon and the dummy video driver, and the dummy
# and OSS audio drivers (the guest's sound card has OSS emulation at
# /dev/dsp; the dosbox script sets SDL_AUDIODRIVER=dsp). DOSBox is
# built without OpenGL, SDL_net, SDL_sound, libpng (no screenshots) and
# without its x86 dynamic recompiler, so it runs the normal core.
# Output: OUT/dosbox (stripped) and OUT/dosbox-riscv64.tar.gz.
#
# Patches:
#   dosbox-0001  never show SDL's software cursor, which fbcon would draw into
#             the picture (DOS programs draw their own mouse cursor)
#   sdl-0002  fbcon with a driver that takes any size (kwfb): every size is
#             offered, and a mode change unmaps the buffer first (kwfb refuses
#             a new size with EBUSY while it is mapped) and maps it again.
#   sdl-0001  fbcon without a VT: SDL 1.2 fbcon insists on a VT (VT_*,
#             KDSKBMODE, KDSETMODE), which the unkernel has not. The keyboard
#             and mouse then come from evdev (/dev/input/event*) or from
#             the terminal on stdin (characters and escape sequences turned
#             into key presses with timed releases).
set -euo pipefail

sdl_repo=https://github.com/libsdl-org/SDL-1.2
sdl_commit=81490298a02fe6806c05ac7b5afde7d88fcc7bf9   # main, 2026-10-15
dosbox_url=https://downloads.sourceforge.net/project/dosbox/dosbox/0.74-3/dosbox-0.74-3.tar.gz
dosbox_sha256=c0d13dd7ed2ed363b68de615475781e891cd582e8162b5c3669137502222260a

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
out=${1:-$root/vendor/build/dosbox}
zig=${ZIG:-$(command -v zig || true)}
[ -n "$zig" ] || { echo "dosbox-build: no zig on PATH (Zig 0.17, see .agents/toolchain.md)" >&2; exit 1; }
mkdir -p "$out"
out=$(cd "$out" && pwd)
jobs=$(nproc 2>/dev/null || echo 4)
cc="$zig cc -target riscv64-linux-musl"
cxx="$zig c++ -target riscv64-linux-musl"

# SDL 1.2
src=$out/src-sdl
rm -rf "$src"
mkdir "$src"
git -C "$src" init -q
git -C "$src" fetch -q --depth 1 "$sdl_repo" "$sdl_commit"
git -C "$src" -c advice.detachedHead=false checkout -q FETCH_HEAD
[ "$(git -C "$src" rev-parse HEAD)" = "$sdl_commit" ] || { echo "dosbox-build: unexpected SDL commit" >&2; exit 1; }
git -C "$src" -c user.name=build -c user.email=build@localhost am -q "$here"/sdl-*.patch

prefix=$out/sdl-prefix
rm -rf "$out/obj-sdl" "$prefix"
mkdir "$out/obj-sdl"
(
	cd "$out/obj-sdl"
	"$src/configure" --host=riscv64-linux-musl --prefix="$prefix" \
		--disable-shared --enable-static --disable-rpath \
		CC="$cc" AR="$zig ar" RANLIB="$zig ranlib" CFLAGS="-O2" \
		--disable-video-x11 --disable-video-dga --disable-video-directfb \
		--disable-video-ggi --disable-video-svga --disable-video-vgl \
		--disable-video-wscons --disable-video-opengl --disable-video-aalib \
		--disable-video-caca --disable-video-qtopia --disable-video-picogui \
		--disable-video-photon --disable-video-ps3 \
		--enable-video-fbcon --enable-video-dummy \
		--disable-alsa --disable-esd --disable-pulseaudio --disable-arts \
		--disable-nas --disable-sndio --disable-diskaudio \
		--enable-dummyaudio --enable-oss \
		--disable-input-tslib --disable-loadso >configure.log
	make -j"$jobs" >make.log 2>&1
	make install >/dev/null
)

# DOSBox 0.74-3
dl=$out/dl-dosbox-tarball
rm -rf "$dl"
mkdir "$dl"
curl -fsSL -o "$dl/dosbox.tar.gz" "$dosbox_url"
echo "$dosbox_sha256  $dl/dosbox.tar.gz" | sha256sum -c --quiet
src=$out/src-dosbox
rm -rf "$src"
mkdir "$src"
tar -xzf "$dl/dosbox.tar.gz" -C "$src" --strip-components=1
for p in "$here"/dosbox-*.patch; do
	[ -e "$p" ] && patch -d "$src" -p1 -s <"$p"
done

rm -rf "$out/obj-dosbox"
mkdir "$out/obj-dosbox"
(
	cd "$out/obj-dosbox"
	"$src/configure" --host=riscv64-linux-musl --prefix=/usr \
		CC="$cc" CXX="$cxx" AR="$zig ar" RANLIB="$zig ranlib" \
		CFLAGS="-O2" CXXFLAGS="-O2 -std=gnu++11 -w" LDFLAGS="-static -s" \
		--with-sdl-prefix="$prefix" --disable-opengl --disable-dynamic-x86 \
		--disable-fpu-x86 --disable-alsa-midi --disable-debug >configure.log
	make -j"$jobs" >make.log 2>&1
)
cp "$out/obj-dosbox/src/dosbox" "$out/dosbox"

pkg=$out/pkg
rm -rf "$pkg"
mkdir -p "$pkg/dosbox"
cp "$out/dosbox" "$pkg/dosbox/dosbox"
cp "$src/COPYING" "$pkg/dosbox/COPYING"
cp "$here"/*.patch "$pkg/dosbox/"
cat >"$pkg/dosbox/README" <<EOF
DOSBox 0.74-3 for riscv64 Linux (static, musl), built for the unkernel guest,
with SDL 1.2 (fbcon video) linked in.
Sources: $dosbox_url (sha256 $dosbox_sha256)
         $sdl_repo commit $sdl_commit
plus the patches here.
Licenses: DOSBox GNU GPL version 2 or later (COPYING); SDL 1.2 GNU LGPL
version 2.1 or later.
EOF
tar -C "$pkg" --sort=name --owner=0 --group=0 --numeric-owner \
	--mtime=2026-01-01T00:00:00Z -cf - dosbox | gzip -n9 >"$out/dosbox-riscv64.tar.gz"
ls -l "$out/dosbox" "$out/dosbox-riscv64.tar.gz"
sha256sum "$out/dosbox" "$out/dosbox-riscv64.tar.gz"

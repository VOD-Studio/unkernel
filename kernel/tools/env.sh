# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
# Sourced by setup.sh and the kernel/ build scripts (bash). Sets:
#   root, vendor        repository root and its vendor/ directory
#   build               where the build outputs go: $KW_BUILD (an absolute
#                       path), default vendor/build; sources, downloads and
#                       the toolchain stay in vendor/
#   zig                 the zig binary ($ZIG, else zig on PATH)
# and provides real_bin, use_real_host_tools and fetch_verified.
#
# Pinned external inputs (the only things downloaded besides the git clones
# in kernel/build.sh) also live here, so they are in one place.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
vendor="$root/vendor"
build="$(realpath -m "${KW_BUILD:-$vendor/build}")"
zig="${ZIG:-$(command -v zig || true)}"

ALPINE_VERSION=3.24.4
ALPINE_TARBALL_NAME="alpine-minirootfs-$ALPINE_VERSION-riscv64.tar.gz"
ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION%.*}/releases/riscv64/$ALPINE_TARBALL_NAME"
ALPINE_SHA256=010683db6c73b3ad1c334fc8f93f64ae748ef67ae6d69e964929aeaf8517bff3

# Ubuntu Base (the minimal root file system), for kernel/guest/ubuntu-disk.sh.
UBUNTU_VERSION=24.04.5
UBUNTU_TARBALL_NAME="ubuntu-base-$UBUNTU_VERSION-base-riscv64.tar.gz"
UBUNTU_URL="https://cdimage.ubuntu.com/ubuntu-base/releases/${UBUNTU_VERSION%.*}/release/$UBUNTU_TARBALL_NAME"
UBUNTU_SHA256=651c516f291259ec913caa1efd0cfff738cd223adfc6617c884f07af487f08cf

# real_bin NAME: the first NAME on PATH that is an ELF executable, else the
# first NAME on PATH at all (empty if none). Some hosts put wrapper scripts
# (for example auto-installing shims) ahead of the real tools; a wrapper that
# does not pass stdin through breaks steps that pipe into a tool
# (flex -> m4, `echo $HZ | bc` in the kernel build, `cc -x c -` probes).
real_bin() {
	local p magic
	while IFS= read -r p; do
		magic="$(head -c 4 "$p" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
		if [ "$magic" = 7f454c46 ]; then
			echo "$p"
			return
		fi
	done < <(type -aP "$1")
	type -P "$1" || true
}

# use_real_host_tools: put symlinks to the real binaries of the host tools the
# builds run (see real_bin) first on PATH, in vendor/toolchain/host-bin. On a
# host without wrappers this changes nothing.
use_real_host_tools() {
	local dir="$vendor/toolchain/host-bin" t p
	mkdir -p "$dir"
	for t in m4 bc flex bison gcc g++ cc c++ clang clang++ ld.lld cmake ninja make perl python3; do
		p="$(real_bin "$t")"
		if [ -n "$p" ] && [ "$p" != "$dir/$t" ]; then
			ln -sfn "$p" "$dir/$t"
		fi
	done
	case ":$PATH:" in *":$dir:"*) ;; *) export PATH="$dir:$PATH" ;; esac
	export M4="${M4:-$dir/m4}"
}

# fetch_verified URL FILE SHA256: download URL to FILE unless FILE already
# exists with that checksum; fails if the download does not match.
fetch_verified() {
	local url="$1" file="$2" sum="$3"
	if [ -f "$file" ] && echo "$sum  $file" | sha256sum -c --status; then
		return 0
	fi
	mkdir -p "$(dirname "$file")"
	curl -fL --retry 3 -o "$file.part" "$url"
	if ! echo "$sum  $file.part" | sha256sum -c --status; then
		echo "checksum mismatch for $url (expected $sum, got $(sha256sum "$file.part" | cut -d' ' -f1))" >&2
		rm -f "$file.part"
		return 1
	fi
	mv "$file.part" "$file"
}

need_zig() {
	if [ -z "$zig" ] || [ ! -x "$zig" ]; then
		echo "zig not found (need Zig 0.17; put it on PATH or set ZIG=/path/to/zig)" >&2
		exit 1
	fi
}

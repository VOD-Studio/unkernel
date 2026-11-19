#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
# Set up unkernel from a fresh clone: check prerequisites, then build
# everything (kwemu, patched wasm-ld, the UP and SMP kernels + their
# 32-bit-memory variants, Alpine initramfs and the bundle with the patch
# to the SMP kernel, Alpine disk image). The browser page (web/)
# needs its npm dependencies, which this script does not install: run
# pnpm install, then pnpm dev.
#
#   ./setup.sh           check, then build (idempotent; re-run to resume)
#   ./setup.sh --check   only check prerequisites
#
# Environment: JOBS=n (parallelism), ZIG=/path/to/zig, KWEMU_JIT=0 (kwemu
# without its JIT tier), KW_SMP=0 (no SMP kernel; see kernel/build.sh). Downloads go to
# vendor/ (gitignored); nothing is installed outside the repository and
# nothing runs as root. Missing system packages are reported, not installed.
set -euo pipefail

. "$(dirname "$0")/kernel/tools/env.sh"   # root, vendor, zig, real_bin, ...
cd "$root"
export PATH="$PATH:/usr/sbin:/sbin"   # e2fsprogs live in sbin on some distros

missing=()
note() { printf '  %-13s %s\n' "$1" "$2"; }
fail() { note "$1" "MISSING: $2"; missing+=("$1"); }

# tool NAME [HINT]: NAME must be on PATH as a real executable; sets $bin.
# Only ELF binaries are run for version checks, so a wrapper script that
# installs packages on first use is never triggered by this script.
tool() {
	bin="$(real_bin "$1")"
	if [ -z "$bin" ]; then
		fail "$1" "${2:-install it}"
		return 1
	fi
	if [ "$(head -c 4 "$bin" | od -An -tx1 | tr -d ' \n')" != 7f454c46 ]; then
		fail "$1" "only a wrapper script was found ($bin); install the real tool"
		return 1
	fi
}

check() {
	local v t avail
	echo "Checking prerequisites:"

	if tool "${ZIG:-zig}" "Zig 0.17 from https://ziglang.org/download/ (or set ZIG=)"; then
		v="$("$bin" version)"
		case "$v" in 0.17.*) note zig "$v"; zig="$bin" ;; *) fail zig "need 0.17.x, have $v" ;; esac
	fi

	if tool node "Node.js >= 24 from https://nodejs.org/"; then
		v="$("$bin" --version)"
		t="${v#v}"
		if [ "${t%%.*}" -lt 24 ] 2>/dev/null; then
			fail node "need >= 24, have $v"
		elif ! "$bin" -e 'process.exit(typeof WebAssembly.Suspending === "function" ? 0 : 1)'; then
			fail node "$v has no JSPI (WebAssembly.Suspending); need Node >= 24"
		else
			note node "$v (JSPI ok)"
		fi
	fi

	if tool clang "clang >= 21 with the WebAssembly target (22 tested)"; then
		v="$("$bin" --version | sed -n 's/.*clang version \([0-9][0-9.]*\).*/\1/p' | head -1)"
		if [ -z "$v" ] || [ "${v%%.*}" -lt 21 ]; then
			fail clang "need >= 21, have ${v:-unknown}"
		elif ! "$bin" --target=wasm64-unknown-unknown -c -x c /dev/null -o /dev/null 2>/dev/null; then
			fail clang "$v cannot target wasm64 (no WebAssembly backend)"
		else
			note clang "$v (wasm64 ok)"
		fi
	fi
	# clang++ and ld.lld build the patched wasm-ld; the llvm-* tools are used
	# by the kernel build (ideally from the same LLVM as clang).
	for t in clang++ ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-ranlib llvm-readelf llvm-strip; do
		tool "$t" "part of LLVM (clang, lld, llvm packages)" && note "$t" ok
	done
	for t in cmake ninja gcc make flex bison bc m4 python3 git curl tar gzip bzip2 sha256sum; do
		tool "$t" && note "$t" ok
	done
	for t in mke2fs debugfs e2fsck; do
		tool "$t" "e2fsprogs >= 1.43" && note "$t" ok
	done
	# kernel/guest/alpine-opt.sh, the guest packages rebuilt for kwemu (run by
	# alpine.sh): meson for apk-tools (a Python program: only looked up),
	# lua for apk's help text, perl modules for openssl's Configure.
	for t in patch perl; do
		tool "$t" && note "$t" ok
	done
	# Fedora's pkg-config is a shell script around the pkgconf binary.
	t="$(real_bin pkgconf)"; [ -n "$t" ] || t="$(real_bin pkg-config)"
	if [ -n "$t" ] && [ "$(head -c 4 "$t" | od -An -tx1 | tr -d ' \n')" = 7f454c46 ]; then
		note pkg-config ok
	else
		fail pkg-config "install pkg-config or pkgconf"
	fi
	if [ -n "$(type -P meson)" ]; then
		note meson ok
	else
		fail meson "install meson (alpine-opt.sh builds apk-tools with it)"
	fi
	if [ "$(uname -m)" != x86_64 ]; then
		note alpine-opt "WARNING: its gcc toolchain is for x86_64 hosts; build with KW_ALPINE_OPT=0 (Alpine's builds)"
	fi
	t="$(real_bin lua5.4)"; [ -n "$t" ] || t="$(real_bin lua)"
	if [ -n "$t" ] && [ "$(head -c 4 "$t" | od -An -tx1 | tr -d ' \n')" = 7f454c46 ]; then
		note lua ok
	else
		fail lua "install lua 5.x (apk's help text)"
	fi
	if [ -n "$(real_bin perl)" ] && "$(real_bin perl)" -MFindBin -MIPC::Cmd -MFile::Compare -e 1 2>/dev/null; then
		note perl-modules ok
	else
		fail perl-modules "perl with FindBin, IPC::Cmd and File::Compare (openssl's Configure)"
	fi

	avail="$(df -Pk "$root" | awk 'NR == 2 {print int($4 / 1048576)}')"
	if [ ! -d "$vendor/src/llvm22" ] && [ "${avail:-0}" -lt 10 ]; then
		note disk "WARNING: ${avail} GiB free; a full setup needs about 5 GiB"
	fi

	# Optional: pnpm for the SDK build and the browser page (web/).
	if [ -n "$(real_bin pnpm)" ] || [ -n "$(command -v pnpm || true)" ]; then
		note pnpm "found (pnpm install, then pnpm dev for the browser page)"
	else
		note pnpm "not found (optional, for the SDK build and the browser page: https://pnpm.io/installation)"
	fi
	# Optional: the browser tests (web/test/*.mjs) need Chromium.
	if [ -n "${CHROME:-}" ] || [ -n "$(real_bin chromium)" ] ||
		ls "$HOME"/.cache/ms-playwright/chromium*/chrome*-linux64/chrome* >/dev/null 2>&1; then
		note chromium "found (browser tests can run)"
	else
		note chromium "not found (optional, for browser tests: npx playwright install chromium-headless-shell, or set CHROME=)"
	fi

	if [ ${#missing[@]} -gt 0 ]; then
		echo
		echo "Missing or unusable: ${missing[*]}"
		echo "Install them with your package manager, then re-run ./setup.sh."
		return 1
	fi
	echo "All prerequisites found."
}

check || exit 1
[ "${1:-}" = --check ] && exit 0

start=$SECONDS
export ZIG="$zig"
echo
echo "== zig build (kwemu library with the JIT tier, test harness, test guests)"
# The same option kernel/build.sh passes, so it does not rebuild libkwemu.a.
"$zig" build -Dkwemu-jit="$([ "${KWEMU_JIT:-1}" = 0 ] && echo false || echo true)"
echo
echo "== kernel/build.sh all"
"$root/kernel/build.sh" all

echo
echo "Done in $(( (SECONDS - start) / 60 )) min $(( (SECONDS - start) % 60 )) s. Try:"
echo "  node js/cli.ts                                                       # Alpine shell, Ctrl-] quits"
echo '  node js/cli.ts --append "console=hvc0 rdinit=/usr/bin/kwtest"         # smoke test (kwtest as /init)'
echo "  node js/cli.ts --disk vendor/build/disk/alpine.ext4                   # Alpine on ext4 (persistent)"
echo "  pnpm install && pnpm dev                                             # browser: http://localhost:8080/"

# AGENTS.md

unkernel runs Linux 7.3, compiled to a single wasm module (`arch/wasm` with an
MMU), in Bun 1.4.5+ or a browser with JSPI. User space is unmodified riscv64
Linux ELF (rv64gc plus Zba, Zbb, Zbs, Zicond, Zkne, Zknd, Zbc, Zbkb, Zbkc,
Zbkx), run by kwemu: a Zig interpreter with a wasm JIT tier, linked into the
kernel. README.md is the overview, and kernel/README.md covers the kernel
side, the devices and the guest image.

`.agents/` has one file per area. Read the one for the area you change:

| File | Covers |
| --- | --- |
| [.agents/kernel.md](.agents/kernel.md) | kernel tree and patch workflow, `kw_emu.h` contract, memory model, JSPI, host imports, IRQs, riscv user ABI, config |
| [.agents/kwemu.md](.agents/kwemu.md) | emulator and JIT design, invariants, tests, measured numbers, rejected designs |
| [.agents/js.md](.agents/js.md) | the SDK (`js/`): rules, build checks, disks, network stack and Wisp |
| [.agents/web.md](.agents/web.md) | the browser page, releasing its kernel, engine quirks |
| [.agents/data-disk.md](.agents/data-disk.md) | the persistent data disk, overlay root, safe mode, apk handling |
| [.agents/guest-packages.md](.agents/guest-packages.md) | busybox, zlib, openssl, apk-tools rebuilt for kwemu (`alpine-opt.sh`): build, numbers, traps |
| [.agents/toolchain.md](.agents/toolchain.md) | patched wasm-ld, Binaryen, Zig 0.17, host tools, pinned downloads |
| [.agents/testing.md](.agents/testing.md) | the full test matrix, for releases or when asked |
| [.agents/status.md](.agents/status.md) | roadmap, open issues, work not yet in the image |

## Host safety rules (read first)

A binfmt_misc handler with a truncated magic can match every 64-bit ELF
and stop exec on the whole host until a reboot. So:

- Never register binfmt_misc handlers. Never write under `/proc` or `/sys`.
  Do not use `mount`, `chroot`, `unshare` or `sysctl`, and do not change
  services.
- No `sudo` and no package installs.
- Run riscv64 binaries on the host only through an explicit emulator
  (`qemu-riscv64-static ./bin`). Never run the guest's `/etc/kw-binfmt.sh`,
  or any part of it, on the host.
- Do not start anything on port 8080: that is `bun run dev`'s port.
- Repeat these rules in every subagent brief.

## Layout

The parts that `ls` does not make obvious:

- `src/` is kwemu, with its contract in `include/kw_emu.h`. `guest/` holds
  its test guests.
- `kernel/build.sh` runs every kernel-side step (`toolchain binaryen kernel
  smp lower alpine disk datadisk bundle all`, plus `ubuntu` and the
  profiling variant `stats`). One tree gives two kernels, UP (`kernel`)
  and SMP (`smp`); the bundle carries the UP kernel and a patch to the SMP
  one (kernel.md, Two kernels). `KSRC`, `KOUT`, `KOUT_SMP` and `KW_BUILD`
  point it at another tree and output root. Linux patches are in
  `kernel/patches/linux/`, wasm-ld patches in `kernel/patches/llvm/`.
- `vendor/` (gitignored) holds the kernel tree
  `vendor/src/linux-wasm-kernel` (branch `kw-riscv-user`), `vendor/src/llvm22`,
  the toolchain and all build outputs. Those branches exist only there, so
  `kernel/patches/` is their only durable record.
- The page's kernel is the gitignored `web/kernel/unkernel-alpine.wasm`.
  `kernel/build.sh bundle` copies its output there, and `bun run dev` runs
  that file as it is (its copy in `web/kernel/page/`, without an SMP
  patch section). A page build (`bun run build:web`, a deploy) replaces it
  with the newest GitHub release's bundle (`web/scripts/kernel.ts`, web.md).

## Building

```sh
./setup.sh                  # check prerequisites, then zig build + kernel/build.sh all
zig build test              # emulator tests, native and wasm64, with and without the JIT
kernel/build.sh kernel      # the UP kernel: kwemu with the JIT, vmlinux, lower, refresh the bundle
kernel/build.sh smp         # the SMP kernel (kwemu with atomics); the bundle then gets the SMP patch
bun install                 # SDK and page dev dependencies
bun js/cli.ts               # boot Alpine from the bundle; --help lists options
```

CLI exit codes: 0 = power off, 1 = halt or boot failure, 2 = restart,
124 = `--timeout`, 253 = panic, 254 = wasm trap, 255 = fatal.

## Easy to break

Details are in the area files.

- `include/kw_emu.h` is copied into the kernel by build.sh. Bump
  `KW_ABI_VERSION` on any layout or semantic change (kernel.md).
- Only `wasm_switch_to`, `poll_oneoff`, `sched_yield` and `proc_exit` may
  suspend under JSPI (kernel.md).
- Every kernel thread needs a `kw_park_point()` in its loop, or parking
  (and so snapshots) fails with EBUSY naming it (kernel.md, Parking).
- JIT output must match the interpreter exactly (kwemu.md).
- SMP kernels: a task moves to another CPU only where its JSPI stack
  (that CPU thread's) can be dropped and it can start on a fresh one: a
  user task on its way to user mode, a kernel thread at a restart point.
  Host imports other than clocks, randomness, console output and task
  switching answer on CPU 0 alone, and a kernel thread that is bound to
  another CPU after it ran needs a restart point (kernel.md, SMP).
- `kw_defconfig` is maintained by hand. Kconfig drops options silently, so
  check `$KOUT/.config` after a change.
- `js/core` stays universal: no `node:` imports, no unguarded DOM APIs
  (js.md).
- The image's busybox, zlib, openssl and apk-tools are rebuilt from
  pinned aports commits (`kernel/guest/alpine-opt.sh`). An Alpine update
  needs new pins there; `alpine.sh` stops until they match
  (guest-packages.md).
- Overlay root and data disk rules are in data-disk.md. Never use
  `switch_root`, and never clear the IndexedDB store `kwdisk:kwdata-v1`.

## Changing things

- **Kernel**: commit on `kw-riscv-user` in `vendor/src/linux-wasm-kernel`,
  then export so that `kernel/patches/linux/` equals
  `format-patch -N 7595a62d45e..kw-riscv-user` (kernel.md).
- **wasm-ld**: commit in `vendor/src/llvm22`, run `kernel/build.sh
  toolchain`, and re-export (toolchain.md).
- **Guest image**: `kernel/build.sh alpine` or `kernel/build.sh disk`.
- **Page**: a kernel or guest change reaches the deployed page with the
  next release (`.github/workflows/release.yml`, run by hand). `bun run dev`
  runs it as soon as `kernel/build.sh` has rebuilt the bundle.

## Tests

Run the quick check for what you changed. The full matrix in
.agents/testing.md is for releases, or when the user asks for it.

| Change | Quick check |
| --- | --- |
| Emulator (`src/`, `guest/`, `include/`) | `zig build test` |
| Kernel, `kw_emu.h`, JIT | `kernel/build.sh kernel`; `bun js/cli.ts --append "console=hvc0 rdinit=/usr/bin/kwtest"` (`kwtest: 0 failure(s)`, exit 0); for JIT changes, again with `--no-jit` |
| Guest image, anything user space sees | `bun run test:api`; optional: `bun js/cli.ts --timeout 120 --input '{8}uname -a; apk --version\n{2}poweroff\n'` |
| Display, input, sound (kwfb, kwinput, kwsnd) | `bun run test:api`; optional: `bun test/glimmer-check.mjs --run` |
| Block, ext4, data disk | `bun run test:block` |
| SDK (`js/`) | `bun run typecheck`; `bun run test:api` |
| Host file systems (9p, `kw9p`) | `bun run test:9p`; `bun run test:api` (after a kw9p change, `kernel/build.sh alpine` first) |
| Inbound to the guest (`vm.connect`, `vm.fetch`, kwtty CONNECT, `--forward`) | `bun run test:http`; `bun run test:tty`; `bun run test:api` (after a kwtty change, `kernel/build.sh alpine` first) |
| Network | `bun run test:net` |
| SMP (`CONFIG_SMP`, `js/core/cpu.ts`; kernel.md, SMP), or any kernel change that SMP code sees | `kernel/build.sh smp` (after `kernel`, so that the bundle carries the patch); kwtest with `--smp 2` (the SMP kernel from the bundle) and once with `--kernel vendor/build/kernel-smp/vmlinux32.wasm --initrd alpine-test` (one CPU); `zig build test -Dkwemu-atomics=true` after a kwemu change |
| Bundle and kernel patch (`bundle.mjs`, `kwdiff.mjs`, `kpatch.ts`, `kremap.ts`) | `KPATCH_UP=vendor/build/kernel/vmlinux32.wasm KPATCH_SMP=vendor/build/kernel-smp/vmlinux32.wasm bun run test:kpatch` |
| Page (`web/`) | `bun run typecheck:web`; `bun run build:web` |

The optional checks boot the same bundle as `bun run test:api`, which already
runs shell commands and `glimmer --test` inline and in worker mode. Run them
when the change touches what only they cover. The Alpine boot adds `apk` and
the CLI's `--input`. `glimmer-check` compares the whole frame pixel for
pixel and the sound sample for sample, and checks the mouse and tablet
events and the CLI's `--display`, `--sound-wav` and `--worker`. Both are
still part of the full matrix.

Do not run the browser tests (`web/test/`) unless asked. The page is
tested by hand with `bun run dev`.

To add a test: for the emulator, a guest in `build.zig` plus an entry in
`test/kwemu-test.mjs`; for the kernel, a `CHECK(...)` in
`kernel/guest/kwtest.c`.

## Conventions

- Commit messages are imperative sentences, optionally prefixed with an
  area (`web: `, `CLI: `). Kernel patches use kernel style (`wasm: ...`);
  a fix is folded into the patch it belongs to, a new piece is a new patch
  (kernel.md). Do not add
  `Signed-off-by` lines; only a human author can certify one.
- Every new file gets an SPDX header and a copyright line. Project code is
  GPL-2.0-or-later, the JavaScript (`js/`, `web/`, SDK tests) is MIT, and
  kernel patches are GPL-2.0-only. Never copy code from linux-wasm's GPL
  runtime into `js/`.
- When a change makes something here or in `.agents/` wrong, fix it in the
  same commit. The docs describe the current state: no change history and
  no commit hashes. Date measurements (absolute dates).

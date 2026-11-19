# kernel/: Linux on wasm64 with emulated riscv64 user mode

This directory holds the Linux kernel built as a single wasm64 module (Joel
Severin's `arch/wasm`, reworked). User space is unmodified riscv64 Linux ELF,
run by the kwemu software CPU (`src/`, contract in `include/kw_emu.h`). The
CPU walks real Sv39 page tables, so fork, mmap and copy-on-write behave like
real Linux. A stock Alpine riscv64 minirootfs boots to a shell under Node, in
Chromium, and in WebKit (Safari 27+, whose JSPI it needs), and Ubuntu Base
24.04 LTS (glibc, apt) boots from a disk image under Node. The browser page
and the single-file bundle use a 32-bit-memory build of the same kernel, which
needs no memory64.

Paths in this file are relative to `kernel/`, except those starting with
`src/`, `include/`, `vendor/` or `zig-out/`, which are relative to the
repository root. Commands are run from the repository root.

## Build and run

`./setup.sh` (repository root) checks the prerequisites and runs `zig build`
and `kernel/build.sh all`. By hand:

```sh
kernel/build.sh all          # wasm-ld 22, Binaryen, UP and SMP kernels + vmlinux32.wasm, Alpine initramfs + bundle, disk
kernel/build.sh kernel       # the UP kernel only (the quick loop), then the bundle
kernel/build.sh smp          # the SMP kernel (vendor/build/kernel-smp), then the bundle with the SMP patch
node js/cli.ts --smp 2 --append "console=hvc0 rdinit=/usr/bin/kwtest"   # kwtest on the SMP kernel from the bundle, 2 CPUs
node js/cli.ts                                                  # Alpine (the bundle), interactive; Ctrl-] quits
node js/cli.ts --append "console=hvc0 rdinit=/usr/bin/kwtest"   # kwtest smoke test as /init (the bundle)
node js/cli.ts --kernel vendor/build/kernel/vmlinux --append "console=hvc0 rdinit=/usr/bin/kwtest"   # same tests on the wasm64 build
node js/cli.ts --append "console=hvc0 rdinit=/usr/bin/kwbench"   # rough guest speed
node test/wasi-node.ts       # the kernel with Node's node:wasi for every WASI import
kernel/build.sh lower        # vmlinux32.wasm (32-bit memory) from the existing vmlinux (fetches wasm-opt if needed)
kernel/build.sh bundle       # vendor/build/bundle/unkernel-alpine.wasm: vmlinux32.wasm + Alpine in one file (also copied to web/kernel/ for pnpm dev)
pnpm install && pnpm dev    # the page (web/): Vite dev server on http://localhost:8080/ (prints LAN URLs for phones too)
pnpm build:web               # web/.output: the built page and its Nitro server (pnpm start:web runs it)
node web/test/headless.mjs --shots /tmp/shots   # desktop + phone + failure checks in headless Chromium (built output)
node --test test/net.test.ts  # network stack unit tests (synthetic frames)
node web/test/net.mjs        # apk/wget through Wisp in headless Chromium
kernel/build.sh disk                                         # vendor/build/disk/alpine.ext4 (needs e2fsprogs)
node js/cli.ts --disk vendor/build/disk/alpine.ext4   # Alpine on ext4, root=/dev/wda rw, persistent
kernel/build.sh ubuntu                                       # vendor/build/disk/ubuntu.ext4: Ubuntu Base 24.04 (needs e2fsprogs)
node js/cli.ts --disk vendor/build/disk/ubuntu.ext4 --snapshot   # Ubuntu on ext4, a root shell (see Ubuntu)
kernel/build.sh datadisk     # vendor/build/disk/kwdata.kwsparse.gz, the data disk template (needs mke2fs)
node js/cli.ts --data /tmp/kwdata.img   # Alpine plus the data disk at /data (created from the template if missing)
kernel/build.sh stats        # vendor/build/bundle/unkernel-alpine-stats.wasm: kwemu with -Dkwemu-stats (own kernel output dir)
node js/cli.ts --kernel vendor/build/bundle/unkernel-alpine-stats.wasm --stats   # kwemu's exit counters at exit
node --test test/block.test.ts   # CowDisk/store logic, kwsparse, FileDisk, requestSync (fake store)
node web/test/data.mjs       # data disk in headless Chromium: persistence, overlay root, safe mode and recovery, second tab, export/reset/import
node test/overlay-node.mjs   # the overlay root under Node: persistence, kw.root=initramfs, safe mode for broken changes (--apk, --image2 need the network)
```

`build.sh` steps, each also available on its own (`toolchain`, `binaryen`,
`kernel`, `smp`, `lower`, `alpine`, `disk`, `datadisk`, `bundle`; `ubuntu`
and `stats` are separate and not part of `all`):

* **toolchain**: sparse-clones `llvmorg-22.1.8` (commit checked), applies
  `patches/llvm/`, and builds `wasm-ld` only. The patches are Joel's GNU-ld linker-script support
  and weak-signature fix, forward-ported from LLVM 18, plus two fixes for
  non-shared memory. clang 22 and the other LLVM tools come from the system.
  LLVM 22 is required, not 18: clang >= 20 and Zig emit table64
  `call_indirect` for wasm64, and an LLVM 18 linker produces an invalid
  module from those objects.
* **kernel**: fetches Linux v7.3.4 from kernel.org (commit `7595a62d45e`,
  shallow), applies `patches/linux/` as branch `kw-riscv-user` (`arch/wasm`
  is based on Joel Severin's linux-wasm port),
  and builds `vmlinux` with `kw_defconfig`. Kbuild drives the toolchain
  through `tools/fake-llvm/llvm-wrapper.py`. The emulator comes from
  `zig-out/lib/libkwemu.a` (`zig build -Dkwemu-jit=true`, run first, so
  with kwemu's JIT tier; `KWEMU_JIT=0` builds it without, `KWEMU=path`
  takes a prebuilt library as is); with `KWEMU=none` a stub is linked
  instead. `include/kw_emu.h` is copied over the kernel's
  `arch/wasm/include/asm/kw_emu.h` (with a warning) if the two differ. It
  then runs `lower`. After a reconfigure it checks that `.config` has
  every option `kw_defconfig` sets. The banner has fixed stamps, so two
  builds of the same tree are identical: `(unkernel@unkernel)`, a build
  id (`#` and 12 hex digits, a hash of the tree, the kwemu sources and
  the toolchain inputs) and the date of the newest commit on the tree
  (`.agents/kernel.md`, Two kernels).
* **smp**: the SMP kernel from the same tree (`kw_defconfig` plus
  `arch/wasm/configs/kw_smp.config`, kwemu built with
  `-Dkwemu-atomics=true` in `vendor/build/kwemu-smp`) into
  `vendor/build/kernel-smp`, lowered like the UP one. `all` builds it
  (`KW_SMP=0`: not); `kernel` never does.
* **binaryen**: downloads the Binaryen release `version_133` (pinned
  checksum) into `vendor/toolchain/binaryen`. `lower` does this if no
  suitable `wasm-opt` is found.
* **lower**: `vendor/build/kernel/vmlinux32.wasm`, the kernel with its memory
  and table lowered to 32 bits, which the browser page and the bundle use
  (see Browser page). It uses `wasm-opt -g --memory64-lowering --table64-lowering`, which
  takes about 1 s. The `wasm-opt` is `$WASM_OPT`, then
  `vendor/toolchain/binaryen`, then `PATH`. It must know `--table64-lowering`.
  If there is none and the download fails, the step fails and a stale
  `vmlinux32.wasm` is removed.
* **bundle**: `vendor/build/bundle/unkernel-alpine.wasm`, `vmlinux32.wasm`
  with `alpine.cpio` (gzipped), its command line and, if it exists, the data
  disk template in custom sections (`tools/bundle.mjs`; `unkernel.initrd`,
  `unkernel.cmdline`, `unkernel.datadisk`). There is no wasm64 bundle.
  With an SMP kernel built from the same tree it also has
  `unkernel.kernel.smp.kwpatch` (`tools/bundle.mjs --smp`), a patch from
  the UP kernel to the SMP one (`tools/kwdiff.mjs`, 1.3 MiB), which the
  runtime applies when it is asked for more than one CPU. bundle.mjs
  refuses an SMP kernel of another build (banners that differ in more
  than `SMP`, another `KW_ABI_VERSION`); build.sh then warns and bundles
  without the patch, or fails with `KW_SMP=1` (as in `all`). The patch
  is cached in `vendor/build/kernel-smp/up.kwpatch` while both kernels
  stay the same. `kernel`, `smp`, `lower`, `alpine` and `datadisk`
  refresh the bundle when both inputs exist; without a template it warns
  and bundles none.
* **datadisk**: `vendor/build/disk/kwdata.kwsparse.gz`, the template of the
  data disk (see Block devices): an empty ext4 file system labelled
  `kwdata`, 4 GiB, 4 KiB blocks, made with `mke2fs -t ext4 -b 4096 -L
  kwdata -m 0 -J size=8 -E lazy_itable_init=0,lazy_journal_init=0,root_owner=0:0,orphan_file_size=32K`
  and the ext4 features of `alpine-disk.sh`'s image (pinned in a generated
  `mke2fs.conf`), checked with `e2fsck -fn`, then encoded by
  `tools/kwsparse.mjs` (554 non-zero blocks, 17 KiB gzipped). The orphan
  file is 8 blocks instead of the default 256, because the kernel reads it
  one block at a time at every mount. Give `orphan_file_size` a unit: a
  bare number is taken as blocks. The output is
  reproducible: fixed `-U` and `hash_seed`, and `E2FSPROGS_FAKE_TIME` /
  `SOURCE_DATE_EPOCH` for the timestamps. `all` runs it before `bundle`, and
  without mke2fs warns and goes on.
* **alpine** (`guest/alpine.sh`), the only initramfs, `vendor/build/initramfs/alpine.cpio`, and `alpine-test.cpio`, which always has kwtest and kwbench:
  * The Alpine minirootfs 3.24.4 (version and checksum pinned in `tools/env.sh`, `ALPINE_TARBALL=file` overrides). It gets a small `/init` and an inittab with `hvc0::respawn:-/bin/sh` and `::respawn:/usr/bin/kwtty serve` (see vsock).
  * busybox, zlib, libcrypto, libssl, libapk and apk are the same Alpine packages rebuilt for kwemu's CPU (`guest/alpine-opt.sh`: gcc 16 `-O2` with Zba/Zbb/Zbs/Zicond, linked with lld), which made shell scripts about 20% faster and apk about 11% (2026-11-16). The disk image gets them too. Details in `.agents/guest-packages.md`.
  * `/usr/bin/kwtest` and `/usr/bin/kwbench` (`guest/kwtest.c`, `guest/kwbench.c`), built static with `zig cc -target riscv64-linux-musl`, so they run as `/init` (`rdinit=/usr/bin/kwtest`; it powers off, or halts on a failure) or from the shell. They come as a second cpio archive after the image's, which the kernel unpacks after the first. With `KW_RELEASE=1` (set by the release workflow) `alpine.sh` leaves them out of `alpine.cpio`, so release bundles, the npm package and the deployed page have no kwtest; boot a release bundle with `--initrd alpine-test` to run it. The choice is in `alpine.sh`, not `build.sh`, because `build.sh` is part of CI's kernel cache key. Both archives have the same image id (`/usr/lib/kw-image`), which leaves the test programs out.
  * `/usr/bin/glimmer`, built the same way (see Display, input and sound), and so are `/usr/bin/kwvsock`, `/usr/bin/kwshm`, `/usr/bin/kwtty` and `/usr/bin/kw9p` (see vsock, Host file systems and Shared memory).
  * The cpio archive is written by `tools/mkcpio.py`; no root is needed.
* **disk** (`guest/alpine-disk.sh`, `DISK_SIZE`, default 512M; `all` keeps
  an existing image that is newer than its inputs, `disk` always rebuilds): the same
  minirootfs as a sparse ext4 image, without root: `mke2fs -d` from the
  extracted tree, then `tools/ext4-owners.py` emits debugfs `sif` commands
  that make every inode root-owned and restore the tarball's exact modes
  and owners (setuid, `/etc/shadow` root:shadow). Inode tables and journal
  are zeroed at mkfs time (no lazyinit writes on first boot); `e2fsck -fn`
  checks the result. Boot uses the real `/sbin/init` (busybox) with an
  inittab running `/etc/kw-rc` (mount -a, hostname), `/etc/kw-net.sh` and a
  shell on hvc0; `::shutdown:/etc/kw-shutdown` kills everything and
  remounts `/` read-only, so `poweroff` leaves the fs clean.
* **ubuntu** (`guest/ubuntu-disk.sh`, `DISK_SIZE`, default 2G sparse;
  `UBUNTU_TARBALL=file` overrides the download): Ubuntu Base 24.04.5 riscv64
  (`ubuntu-base-24.04.5-base-riscv64.tar.gz` from
  `cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/`, SHA-256 pinned
  in `tools/env.sh`) as `vendor/build/disk/ubuntu.ext4`, built like the
  Alpine disk. See Ubuntu below.

The CLI (`js/cli.ts`, run by Node directly; `node dist/cli.mjs` after `pnpm
build`, `npx unkernel` once installed) has the page's defaults: Alpine from
the bundle (`js/unkernel-alpine.wasm` is a symlink to
`vendor/build/bundle/unkernel-alpine.wasm`; `dist/` has a copy), and
`vendor/build/kernel/vmlinux32.wasm` for anything else. `--help` lists the
options and exit codes. Options: `--kernel` (or a positional path; either build or
a bundle), `--initrd alpine|none` or a cpio path (a bare name is
`vendor/build/initramfs/<name>.cpio`), `--disk image|URL` (repeatable:
wda, wdb, ...; a file is written in place, an http(s) URL is range-fetched
with an in-memory overlay; with a disk and no `--initrd`/`--append` it boots
`root=/dev/wda rw`), `--snapshot` (file writes go to a memory overlay), `--mem MiB` (512),
`--append`, `--timeout s`, `--data FILE` (the data disk, after the `--disk` disks: a file used in place,
created sparse from the template if missing: `--data-template`, else the
bundle's, else `vendor/build/disk/kwdata.kwsparse.gz`), `--stats` (also prints the JIT counters), `--no-jit` (kwemu interprets only), `--size COLSxROWS`, and `--input` for scripted typing
(`\n`, `^C`, `{N}` = pause N s, `{sync}` = raise the sync IRQ and log
when the next block flush arrives), `--display[=WxH]`, `--sound` and
`--sound-wav FILE` (see Display, input and sound; `--help` lists the
`--input` tokens that dump a frame and inject keys and mouse events). Networking is on by default; `--no-net`
removes the device, `--net-mtu N` sets the MTU handed out by DHCP, and
`--net-wisp URL` sends the guest's TCP through a Wisp server instead of host
sockets.

`build.sh` also takes `KSRC=dir` (a kernel git worktree), `KOUT=dir` and
`KOUT_SMP=dir` (the two kernels' build outputs) and `KW_BUILD=dir` (the
root of every build output, default `vendor/build`), so a branch can be
built without touching the main tree or its outputs; the header of
`build.sh` lists the rest (`KW_SMP`, `KWEMU`, `KWEMU_SMP`, ...).

Downloads are pinned: the kernel base commit and the LLVM tag/commit in
`build.sh`; Binaryen, Alpine and Ubuntu Base by SHA-256 (`build.sh`,
`tools/env.sh`); the page's npm dependencies (wterm, React, Tailwind) through
`pnpm-lock.yaml`. Host tools are taken from real binaries on `PATH`, skipping
wrapper scripts (`tools/env.sh`, `use_real_host_tools`).

## Networking

* **Kernel:** `kwnet` (`drivers/net/kwnet.c`) is an Ethernet device whose
  frames are copied to and from the host (`wasm_driver_net_init`/`send`/
  `rx_len`/`recv`). Received frames raise IRQ 2 in `wasm_host_irqs`, polled
  like the console, and are drained by NAPI into GRO. The device claims
  checksum offload and TSO and marks RX `CHECKSUM_UNNECESSARY`, so the guest
  computes no checksums and sends 64 KiB TCP segments. Networking is
  optional: when `wasm_driver_net_init` returns < 0 (the runtime does that
  without `opts.net`; a host without networking can stub it so) no device
  is registered.
* **Host:** `js/core/net.ts` (`NetStack`) is a user-mode stack ("slirp-lite") that
  terminates the guest's frames. Guest 10.0.2.15/24, gateway 10.0.2.2, DNS
  10.0.2.3. It answers ARP, runs a DHCP server, answers DNS A queries through
  the backend (AAAA and other types get an empty answer), answers pings to
  the gateway and DNS addresses, and terminates TCP. TCP handling covers the
  handshake, MSS and window scaling, flow control both ways, go-back-N
  retransmit after 1 s, FIN half-close and RST. Each connection is bridged
  to a backend:
  * Node (`js/node/net.ts`, `directBackend()`, the CLI's default): real
    sockets and `dns.lookup`. With `hostLoopback` (the CLI sets it), TCP to
    10.0.2.2 goes to the host's 127.0.0.1.
  * Browser page (`web/src/net.ts`, outside the SDK): Wisp (below);
    `?net=0` or `?wisp=0` removes the device. (A WebSocket-to-TCP relay
    the page used to offer is in git history.)
  * Wisp (`js/core/net-wisp.ts`, `wispBackend()`, Wisp v1; Node and
    browsers): the guest's TCP connections
    multiplexed over one WebSocket to a Wisp server (wisp-js, epoxy-server,
    ...). The default list is `DEFAULT_WISP_SERVERS` (the project's server,
    `wss://wisp.pi0.io:6680/`), exported by the SDK; on the page
    `?wisp=URL[,URL...]` replaces it. The CLI uses it with `--net-wisp URL`.
    That server has an allow list of expected Origins (`http://localhost`
    is on it); anything else, including no Origin, gets 404. On Node, whose
    WebSocket sends no Origin, the Node entry's `wispBackend()` and the CLI
    send `Origin: http://localhost` (`NODE_WISP_HEADERS`, overridable with
    the `headers` option, which browsers ignore). A page served from an
    origin outside the list needs its own Wisp server. With several URLs
    all are opened at once and the first to finish the handshake wins.
    Wisp is weaker than direct sockets, and the guest can tell:
    * no DNS: lookups get stable fake addresses from 198.18.0.0/15 and the
      server resolves the name, so every name "resolves" and a bad one
      fails at connect time;
    * no connect acknowledgement: the guest's connect succeeds at once, and
      a refused or unreachable host becomes a reset;
    * no half-close: the guest's FIN is not forwarded;
    * flow control covers only guest-to-server data (credits counted in
      packets); server data is buffered in the page without a limit.

    `?wisp=0` disables the fallback: DHCP still works, DNS gets SERVFAIL
    (musl gives up after its 5 s timeout), and TCP gets a reset. A `ws://`
    Wisp server cannot be used from an `https://` page (mixed content).
* **Guest:** the Alpine inittab runs `/etc/kw-net.sh`, which brings up `lo`
  and, if eth0 exists, runs `udhcpc` (it writes `/etc/resolv.conf`). The
  guest clock is host wall time, so TLS works. apk uses the minirootfs's
  https repositories, but starts with `main` only: every apk command that
  loads the indexes parses all enabled ones, ~0.65 s for main and ~2.7 s
  with community (2026-11-15). The community line is in `/etc/kw-apk-lazy`,
  and `/etc/kw-apk-enable` appends it to `/etc/apk/repositories` when
  something needs it; it stays there. By hand: `/etc/kw-apk-enable`, or
  append the line yourself. Packages installed with `apk add -X URL` are
  not upgraded later (apk no longer has their repository), so the
  repository is enabled for good instead.

  In an interactive root shell with a default route, a
  command that is not found (`htop`, `node`) is installed with
  `apk add cmd:NAME` and then run (`/etc/profile.d/kw-apk.sh`, a busybox ash
  `command_not_found_handle`, and `/etc/kw-apk-install`). ash passes the hook
  only the command name, so the arguments come from the history line, and only
  for a simple line: after `htop; ls` it asks you to run the command again.
  `$?` is 127 either way. `KW_AUTO_APK=0` turns the hook off.
  kw-apk-install does not ask apk: it looks the command up in a list of the
  `cmd:` names each cached index provides, built from the index when first
  needed and again when the index changes (`/var/cache/kw-apk/*.cmds`).
  Building takes ~1.2 s for main and ~3.1 s for community, a lookup ~0.1 s
  (2026-11-15). A command in none of the
  enabled repositories is looked up in the lazy ones: their index is fetched
  with wget to the file name apk uses for its cache
  (`APKINDEX.<8 hex digits of sha1(index URL)>.tar.gz`, unless the page has
  pushed it there), and on a hit the repository is enabled and apk reuses
  that file rather than downloading it again. kw-qemu enables community too
  (for `qemu-ARCH`).
* **bwrap** is a shim too (`/usr/local/bin/bwrap`,
  `kernel/guest/bwrap-shim.sh`): the kernel has no seccomp, so it drops
  `--seccomp FD` and runs bubblewrap's `/usr/bin/bwrap` with the rest. GTK
  programs need it to load images (Xfce).
* **curl** is a shim (`/usr/local/bin/curl`, `kernel/guest/curl-shim.sh`)
  over busybox wget, because the real one costs about 2.4 MB of download and
  5 MB of RAM. It handles only GET requests with `-L` whose result it can
  reproduce exactly (`curl -fsSL URL | sh`, `curl -fLo FILE URL`; options
  `-f -s -S -L -k -g -o -O -H -A -e -m`). Everything else (other options,
  a body, no `-L`, credentials, an HTTP error without `-f`, a TLS failure)
  runs the real curl, installed on first use by `/etc/kw-apk-install curl`;
  after that, the shim execs `/usr/bin/curl` directly. Output is written only
  after a complete transfer, so `curl | sh` does not stream.
* **x86_64, aarch64, i386 and arm binaries** run through qemu-user. i386
  also covers i486-i686 (Alpine's `x86`), and arm covers armv5-armv7
  (`armhf`, `armv7`), little-endian only. The kernel has
  `CONFIG_BINFMT_MISC`, and the inittab runs
  `/etc/kw-binfmt.sh`, which registers the four ELF types (flag P) with the
  interpreter `/etc/kw-qemu`, which runs the binary under `qemu-ARCH` (ARCH
  is `x86_64`, `aarch64`, `i386` or `arm`). The first time an ARCH is needed
  (as root, with a network, under a lock so parallel execs do not race apk)
  it installs `qemu-ARCH` and a library root for dynamic binaries at qemu's
  default prefix `/usr/gnemul/qemu-ARCH`: musl, libgcc, libstdc++ and
  gcompat (glibc's loader names and sonames on top of musl, so simple glibc
  binaries run too), about 4 MB, verified with that architecture's keys from
  `alpine-keys`. Add more with `apk add --root /usr/gnemul/qemu-ARCH --arch
  APKARCH --keys-dir /usr/share/apk/keys/APKARCH PKG` (APKARCH is `x86` for
  i386 and `armv7` for arm). Expect about 7x slower than riscv64 code: qemu's
  TCG output is interpreted by kwemu like any other code.
* **`kw-arch ARCH [command...]`** runs a command (default: a shell) with
  `uname` and `arch` reporting x86_64, aarch64, i686 or armv7l instead of
  riscv64, for installers that refuse riscv64:
  `curl -fsSL https://opencode.ai/install | kw-arch x86_64 bash`. Only the
  commands are faked (shims in `/usr/lib/kw-arch` first on PATH), not the
  `uname()` syscall.
* **Not implemented:**
  * IPv6 (off in the kernel) and IP fragments.
  * UDP other than DHCP and DNS; other datagrams get ICMP port unreachable.
  * ICMP to anything except 10.0.2.2/3. There is no ping to the internet.
  * TCP SACK and timestamps, and inbound connections (no port forwarding).

## Block devices (kwblk)

* **Kernel:** `drivers/block/kwblk.c`, blk-mq, one hw queue (depth 32),
  disks `wda`, `wdb`, ... probed at boot from the host
  (`wasm_driver_block_info`). `->queue_rq()` writes the request (op, sector,
  direct-mapped segment addresses) into its PDU and calls
  `wasm_driver_block_submit`, which never suspends, so it is fine in
  blk-mq's atomic dispatch context (no `BLK_MQ_F_BLOCKING`, no kthread).
  The host either completes it synchronously (return <= 0 = status) or
  returns 1, later writes the status into the PDU, queues it and raises
  IRQ 3; the handler drains `wasm_driver_block_reap()`. Like the console
  IRQ it is polled on user-mode exits and in idle, which the host wakes,
  so other tasks keep running while a range fetch is in flight. Read,
  write, flush (volatile write cache), discard and write-zeroes (if the
  backend has them).
* **Host:** `js/core/block.ts` (`BlockHost`, hooked into the `Kernel` via
  `opts.disks`), backends:
  * `FileDisk` (`js/node/disk.ts`, `openDisk()`): an image file, `readSync`/
    `writeSync` straight into kernel memory, flush = `fdatasync`.
  * `HttpBase`: read-only base fetched with HTTP Range requests in 256 KiB
    chunks (adjacent misses coalesced up to 4 MiB, in-flight dedupe), kept
    in memory.
  * `CowDisk`: copy-on-write overlay in 4 KiB blocks over a base (ext4's
    4 KiB writes never need the base). Without a store the overlay is in
    memory. With an `IdbStore` (`js/web/disk.ts`, `openHttpDisk()`, `openDataDisk()`) it is loaded lazily: memory holds only the
    blocks written since their last committed save, plus the set of block
    numbers that have a record. Reads take memory, then IndexedDB (one
    `getAll` over the request's key range), then the base. A read that goes
    to IndexedDB also fetches the stored blocks after it (8, doubling to 128
    while the misses stay sequential) into a readahead buffer of at most
    4 MiB, which a read consumes and a write drops. A partial write
    of a block that is not in memory is a read-modify-write; writes to a
    block wait for an earlier pending one, so they apply in submission
    order and a stale fetch never overwrites a newer write. Discard and
    write-zeroes store an empty (zeros) record, or, over an all-zero base,
    delete the record.
  * `ZeroBase` / `SparseBase`: an all-zero base (the data disk) and one made
    of a few blocks (a kwsparse image; a snapshot copy).
* **Persistence semantics.** The disk has a volatile write cache (the
  driver advertises flush): a completed write is only in the page's memory.
  Each flush saves every block written before it in one IndexedDB
  transaction (durability `strict`) and completes when that commits; a
  flush issued while a save is in flight waits for it. So the saved state
  is always the state at some completed flush, which ext4's journal handles
  like a power cut. What is lost when a tab dies is what was written after
  the last flush (ext4 commits every 5 s; `sync` or fsync flush at once). If
  a save fails (quota, disk error) its blocks stay dirty for the next
  flush and the flush returns EIO; the page reports it (a full quota as
  `QuotaExceededError`). The IndexedDB connection is reopened if the
  browser closes it or another tab needs a version change, and a failed
  transaction is retried once. `strict` rather than the default or
  `relaxed`: a flush is where the guest asks for durability, and only
  strict also survives an OS crash or power loss; it costs one device
  flush per guest flush.
* **requestSync.** `Kernel.requestSync({timeout = 3000})` (in the SDK: `KernelInstance.sync()`) sets IRQ 4
  (`WASM_IRQ_SYNC`) in `wasm_host_irqs` and wakes the kernel, which clears
  it and runs `ksys_sync()`. It resolves true once every persistent disk
  (a `CowDisk` with an attached store, a writable `FileDisk`) has completed
  a flush issued after the call, or false on the timeout; then it clears
  the bit itself, because a kernel without IRQ 4 never does.
* **Page:** the page attaches no root disk (it boots the bundled initramfs
  only); `openHttpDisk()` is for SDK users.
* **Page, data disk** (`web/src/data.ts`, on by default where IndexedDB exists,
  `?data=0` turns it off): an ext4 file system labelled `kwdata`, 4 GiB,
  that the guest finds by label and mounts at `/data`. It is the page's only
  kwblk disk, `wda`.
  * Template: the bundle's `unkernel.datadisk` section; without one the
    page runs without a data disk and logs why. On first use its blocks are copied into the store in
    one transaction, which then marks the store initialized; after that the
    disk is the store over a `ZeroBase`, and a new template never touches it.
  * The store is `kwdisk:kwdata-v1`, keyed by the format version, not by the
    template or an ETag. It is never cleared implicitly: if its identity
    (format, size) does not match, the page does not attach it, runs a fresh
    in-memory disk and says why (other `kwdisk:kwdata-*` versions are only
    logged).
  * One tab at a time: `navigator.locks.request('kwdisk:kwdata',
    {ifAvailable: true})`, held for the page's lifetime; where Web Locks are
    missing (plain-http LAN pages are not a secure context) a
    BroadcastChannel probe, which two tabs opened in the same instant can
    both pass. A tab without the lock gets an in-memory snapshot, a copy of
    the saved disk if it is at most 64 MiB (one read transaction, so
    consistent), else the template, and a WARN line, toast and panel note.
  * `navigator.storage.persist()` is requested; the Environment tab's *Storage* line
    shows whether it was granted and the usage (`storage.estimate()`).
  * The page calls `requestSync()` when it is hidden (`visibilitychange`)
    and on `pagehide`, and Reboot waits for it (up to 3 s).
  * `KW.exportData()` (panel: *Export*) syncs, then downloads the disk as
    `kwdata-<time>.kwsparse.gz`. `KW.importData(file)` (*Import…*) replaces
    the saved disk with such a file and reloads; `KW.resetData()` (*Reset*)
    forgets it and reloads (the next boot starts from the template). Both
    first stop the running disk's saves and refuse while another tab holds
    the lock.
* **kwsparse** (`js/core/kwsparse.ts`, CLI `tools/kwsparse.mjs encode|decode|info`),
  usually gzipped: magic `KWSPARS1`, u64 LE disk size, u32 LE block size
  (4096), u32 LE count N, N u64 LE block indices (ascending), then N blocks
  of data. Only non-zero blocks are stored.
* **Sync request, kernel side:** the host sets IRQ 4 (`WASM_IRQ_SYNC`) and
  wakes the kernel when it may lose the session; the handler queues a
  work item that calls `ksys_sync()` (writeback of every filesystem,
  journal commits, device flushes), so the host can wait for the flush.
  Requests made before the work runs coalesce into one sync.
* **Data disk (`/data`):** a disk holding an ext4 file system labelled
  `kwdata` (wda without a root disk, else the one after it) is found by
  label (`findfs`) and mounted at `/data` by `/etc/kw-data.sh`
  (`kernel/guest/kw-data.sh`; from `/init`, or from inittab sysinit on a
  disk root), with `noatime,commit=1`, `discard` if the device supports
  it, and `vm.dirty_expire_centisecs`/`dirty_writeback_centisecs` = 100,
  so writes reach the disk within about 2 s. With it the initramfs root
  becomes the overlay root below; on a disk root `/data` is only mounted.
  Without a `kwdata` disk nothing changes. `/etc/kw-shutdown` (poweroff,
  reboot) stops all processes, then unmounts `/data` (or, under the
  overlay root, remounts `/` and `/data` read-only, which leaves ext4
  clean). After an unclean stop the journal is replayed on the next mount
  (there is no e2fsck in the initramfs). A test image:
  `mke2fs -t ext4 -b 4096 -L kwdata -m 0 -J size=8 -E lazy_itable_init=0,lazy_journal_init=0 data.ext4 4G`,
  then `node js/cli.ts --data data.ext4` (or `--data new.img`, created
  from the template).
* **Overlay root** (`kernel/guest/overlay/`): with a data disk the whole
  root is writable and persistent through overlayfs
  (`CONFIG_OVERLAY_FS`, no optional features). Lower layer: the initramfs
  root, read-only; upper and work dirs: `/data/overlay/{upper,work}`. So
  `apk add`, edits under `/etc`, `/root`, `/home`, users and so on survive
  a reload, and nothing is reinstalled at boot.
  * **Switch:** `/init` runs `kw-data.sh root`, which mounts `/data` and
    runs `/usr/lib/kw-overlay/root` (`root.sh`): it mounts the overlay at
    `/mnt` with `lowerdir=/`, checks it (below), remounts rootfs read-only
    (a lower layer must not change while in use), moves `/data`, `/dev`,
    `/proc`, `/sys` and `/run` into it, mounts a tmpfs on `/tmp` (it stays
    in memory, as on the plain root) and calls `pivot_root`; the old root
    stays at `/run/kw-lower`. busybox `switch_root` is not usable: it
    deletes everything on the old root before the switch, and the old root
    is the lower layer. `pivot_root` from the initramfs works because
    Linux mounts rootfs on an immutable nullfs.
  * **Escape hatch:** `kw.root=initramfs` on the kernel command line boots
    the plain image for one boot, with `/data` mounted and the changes
    unmounted in `/data/overlay/upper`, where they can be inspected or
    fixed (changing the upper layer while the overlay is mounted is
    undefined in overlayfs). It is the only `kw.root=` value. Under Node:
    `--append "console=hvc0 rdinit=/init kw.root=initramfs"`; in the page:
    `?root=initramfs`, or the panel's *Safe mode* button.
  * **Boot health and safe mode.** Changes can break the boot (a bad
    `/etc/inittab` or `/etc/profile`, a deleted `/bin/sh`, a broken
    busybox or C library). The decision is made by code in the lower
    layer only, so the changes cannot break it, and a broken boot falls
    back to *safe mode*: that boot stays on the plain image with `/data`
    mounted, and the changes are left in place, untouched. Leaving them
    rather than moving them aside means nothing diverges (there is no
    second upper layer to merge later), a false alarm costs one command,
    and the evidence stays as it was. The triggers:
    * *Checks after mounting* (`root.sh`): the merged root's `/bin/sh` is
      run with `chroot` (so a broken shell, busybox or C library fails
      here), `/sbin/init` must be executable, and `/etc/inittab` must
      have a `respawn` or `askfirst` entry other than kwtty's. A failure
      falls back for this boot only, and every boot checks again, so a fix
      made from safe mode takes effect at the next boot. So does a failed
      mount or `pivot_root`.
    * *Attempt count:* right before the switch, `/data/overlay/attempts`
      is incremented and synced. `bootwatch` (`bootwatch.sh`, started
      from `/run/kw-lower` after the switch) removes it once a console
      shell waits at its prompt: a session leader with a tty that is a
      shell (or getty or login), sleeping, with the terminal in its own
      foreground process group and no children, the same process in two
      samples 0.25 s apart (the shell of a kwtty session counts too). A
      clean shutdown on request removes it too.
      When a boot starts with 2 or more, two boots in a row never got
      that far (a hang, a kernel panic, a reload in the middle of each):
      it writes `/data/overlay/safe` and falls back. One reload in the
      middle of a 0.3 s boot does not trip it.
    * *bootwatch, at once:* while a boot works some process besides init
      and bootwatch always runs (a sysinit script, then the shell; kwtty,
      which is always there, does not count). If the system stays empty
      for 3 s before a prompt (a console shell that exits right away,
      which busybox init respawns once a second, or none at all),
      bootwatch writes `/data/overlay/safe`, so the next boot is safe
      mode; if a prompt appears later after all, it takes that back. After 20 s without a prompt it prints how to get out.
    * `/data/overlay/safe` (one line: the reason and the time) keeps safe
      mode on until `kw-overlay restore` (or a boot that reaches a prompt
      with the changes, which only bootwatch's own false alarm can give).
      Sticky because its evidence is not deterministic, and flapping
      between a broken and a plain root helps nobody.

    Safe mode prints, in yellow after the `/data:` line:
    `kw-overlay: SAFE MODE: <reason>`, then where the changes are and the
    commands below; the page shows the reason and how to restore in its
    panel (Data disk) and a toast. Tested cases (`test/overlay-node.mjs`,
    `web/test/data.mjs` step 2b, and one case under WebKit): garbage
    `/etc/inittab`, a deleted `/bin/sh` and a truncated
    `/lib/ld-musl-riscv64.so.1` fall back at the next boot; `/etc/profile`
    ending in `exit` is detected by bootwatch within about 3 s, and the
    next boot is safe mode; a `profile.d` script that hangs or spins
    gives two boots without a prompt, then safe mode; a broken
    `/sbin/init` gives two kernel panics, then safe mode. A boot killed
    once before its prompt does not.
  * **`kw-overlay`:** `status` (root, image, safe mode and why, this
    boot's messages, the attempt count, image updates, set-aside
    directories), `restore` (leave safe mode from the next boot),
    `discard` (alias `reset`: move the changes to
    `/data/overlay/discarded-TIME` and start over from the image; at once
    on a plain root, at the next boot on the overlay root).
  * **Image updates:** `alpine.sh` stamps `/usr/lib/kw-image`
    (`alpine-<version>-<hash of the tree>`, unchanged by an identical
    rebuild); `/data/overlay/lower` records the image the changes were
    last used with, and `/data/overlay/image/{pkgs,world}` its package
    list and world. On a change, `/usr/lib/kw-overlay/rebase` runs on the
    new plain root before the mount, because the first `apk add` or `del`
    copied apk's database into the upper layer, and that copy would hide
    the new image's. It writes what apk would have if the user's commands
    had been run on the new image: the new image's database entries,
    minus image packages the user removed, plus the user's own packages
    (dependencies included); the upper copies of new-image packages'
    files outside `/etc` (older or upgraded versions, whiteouts) move to
    `/data/overlay/rebase-TIME`, so the image's version shows, while
    `/etc` stays as the user left it; the world is the new image's minus
    the user's removals plus the user's additions; `scripts.tar.gz` and
    `triggers` follow the packages. Nothing is deleted, a rerun gives the
    same result, and boot prints what was kept, replaced and moved, then
    appends to `/data/overlay/history`. Tested with two images whose
    package sets differ (the second adds nano, libncursesw and
    ncurses-terminfo-base, and zlib goes from 1.3.2-r1 to 1.4-r0), after
    `apk add htop tree`, `apk upgrade zlib` and `apk del musl-utils` on the
    first: `apk info -v` is exactly the new set minus musl-utils and
    scanelf plus htop, lsof and tree, `apk audit` matches the new image
    without changes, htop, tree and nano run, `apk del` and `apk add`
    work and `apk fix --simulate` has nothing to do; without the zlib
    upgrade the image's zlib 1.4 replaces the stale 1.3.2 entry. Kept
    redirect_dir, index, xino and metacopy off: overlayfs defines offline
    lower changes only then.
  * **Cut-off apk runs:** apk 3 unpacks each file as a `.apk.<hash>`
    temporary, renames a package's files once it is unpacked, and writes
    its database only at the end, so a reload during `apk add` left
    temporaries and unregistered packages in the upper layer.
    `/etc/apk/commit_hooks.d/kw-overlay.hook` creates
    `lib/apk/db/kw-commit` before each commit and removes it after (apk
    runs the post-commit hook even when a package fails). If it survives,
    `/usr/lib/kw-overlay/apk-cleanup` runs before the next mount and
    removes every `.apk.<hash>` file and every unowned file or symlink
    whose ctime is after the marker (outside `/root`, `/home`, `/tmp`,
    `/var/tmp`, `/run`, `/data`), then empty unowned directories made
    since; the list goes to `/data/overlay/apk-cleanup.log`. A normal boot
    pays one file test; after a cut-off `apk add python3` the boot took
    1.98 s instead of 0.30 s (494 files, 17.5 MiB removed). `apk
    --no-scripts` skips the hooks.
  * **Differences from the plain root:** renaming a directory that comes
    from the image fails with EXDEV (no redirect_dir), and `mv` falls
    back to copying; hard links to image files work (copy-up first); a
    full data disk is a full root; the shell history (`/root/.ash_history`)
    persists. `/data/overlay/upper` is visible under `/data`, but change it
    only after a `kw.root=initramfs` or safe-mode boot.
  * **Measured** (run-node, the CLI's predecessor, 2026-11): boot to a shell 0.34-0.35 s on a fresh
    data disk and with python3, htop and nano installed (0.23 s without a
    data disk), 479 MiB of 499 available with python3 installed (the old
    bind-mount mode reinstalled packages into RAM at each boot: 12.9 s and
    394 MiB available with python3). The first boot after an image update
    with python3 installed took 3.6 s (the rebase), the next 0.29 s.
    `apk add` takes as long as on the plain root (the index parse
    dominates). The kernel grows by 116 KiB (43 KiB gzipped) for
    overlayfs.

## Display, input and sound

Three small drivers give graphical programs what they need, and cost
nothing until one runs: each registers its device only when the host offers
it, and allocates only while a program has it open. The CLI offers none by
default; the page offers all three.

* **Display** (`drivers/video/fbdev/kwfb.c`): `/dev/fb0`, fbdev, 32 bpp
  XRGB8888, `write()` and `mmap()`. The mode is chosen when the first
  program opens the device: the CLI's `--display` gives 640x480 and
  `--display=WxH` any size; the page offers its viewport in CSS pixels. A
  mode above 1M pixels is divided by a whole number (1920x1032 becomes
  960x516), because the buffer is one allocation of at most 4 MiB. A
  program may set its own size with `FBIOPUT_VSCREENINFO` while it is the
  only opener and has nothing mapped. The physical size of the picture (the
  `width` and `height` of `FBIOGET_VSCREENINFO`, in mm) comes from the
  host: the page counts 96 CSS pixels to the inch, and the CLI takes
  `--display=WxH@DPI`. One program has the display at a time: while one
  holds `/dev/fb0` open (or mapped, even after closing it), another's
  `open()` fails with EBUSY, so `glimmer` started in a second terminal
  says the display is busy instead of drawing over `fbdoom`. The host
  reads the pixels whenever the kernel yields, at most about 50 times a
  second while a program is busy; there is no vsync, so draw whole
  frames.
* **Input** (`drivers/input/kwinput.c`): `/dev/input/event0`, a keyboard,
  `event1`, a relative mouse with a wheel and three buttons, and `event2`,
  an absolute pointer (a tablet, like QEMU's usb-tablet: ABS_X/ABS_Y over
  the whole picture, the same buttons and wheel), which X uses so that the
  page's mouse moves in and out of the picture without pointer lock. They
  exist whenever the display does. The host delivers events only while a program
  has the device open.
* **Sound** (`sound/drivers/kwsnd.c`): an ALSA card, `hw:0,0`, playback
  only (U8 and S16_LE, mono or stereo, 8000 to 48000 Hz), and OSS
  `/dev/dsp`. `apk add alsa-utils` and `aplay` or `speaker-test` work.
  There is no mixer and no capture. `--sound-wav FILE` records what the
  guest plays; `--sound` gives the card and drops the output.
* **vsock** (`net/vmw_vsock/kwvsock.c`, 2026-11-14): an AF_VSOCK
  transport to the host, built on `virtio_transport_common` like
  `vsock_loopback`, with the packets crossing through host imports instead
  of virtqueues. The guest is CID 3 and the host CID 2; stream sockets only
  (no SEQPACKET, no datagrams), with virtio-vsock's credit flow control.
  The host runs the other end of the protocol (`js/core/vsock.ts`): the
  SDK's `vsock` option and the CLI, both on by default (nothing listens on
  the host in the CLI; `--no-vsock` leaves the device out). Without a host device no transport is registered and `connect()`
  fails with ENODEV. `kwvsock connect PORT [CID]` and `kwvsock listen PORT`
  (`guest/kwvsock.c`) pipe stdin and stdout over a connection.
  `kwtty serve [PORT]` (`guest/kwtty.c`, from inittab) serves terminal
  sessions to the host on vsock port 1022 (privileged, so no unprivileged
  guest program can take it): each connection gets its own pty, with its
  own size and resizes, and root's login shell or the program the host
  names on it (argv, working directory, environment), and a hangup when
  the host closes. With the PIPES option the program gets stdin, stdout
  and stderr pipes instead, in a session of its own (a hangup goes to its
  process group), and EOF closes its stdin. With the CONNECT option there
  is no program: kwtty connects to a TCP port on 127.0.0.1 and then
  relays raw bytes between that socket and the vsock connection, passing
  half-closes on (the SDK's `vm.connect()` and `vm.fetch()`, the CLI's
  `--forward`). Only CID 2 may connect, since
  there is no authentication. The protocol (frames: OPEN with the size,
  TERM, environment, argv, directory, PIPES and CONNECT, DATA, RESIZE, SIGNAL, EOF;
  OPENED with the program's pid and pts number, EXIT with the status,
  ERROR, STDERR) is described
  at the top of `kwtty.c`; the
  host side is `js/core/tty.ts`. `socket(AF_VSOCK)` works without a
  transport, so kwtty asks `/dev/vsock` for the local CID
  (`IOCTL_VM_SOCKETS_GET_LOCAL_CID`, `VMADDR_CID_ANY` without one) and,
  without a device, sleeps in `pause()` instead of exiting, so that init
  does not respawn it once a second. hvc0 stays the system console.
* **Host file systems** (9p, 2026-11-15): the host serves file systems
  over 9P2000.L on vsock port 564 (`js/core/9p.ts`; the SDK's `mounts`
  and `vm.mount()`, the CLI's `--mount`), and `kw9p NAME DIR [ro]`
  (`guest/kw9p.c`) mounts one by the name the SDK gives it with the
  kernel's own 9p client on the socket (`trans=fd`, `cache=readahead`), no
  driver of ours; `mount` and `df` show `kw9p:NAME`. The SDK runs kw9p
  through kwtty. kw9p also passes `metatimeout=1000` (patch
  `9p: add metatimeout`): the guest reuses names and attributes it has
  looked up for up to 1 s, then revalidates them with one getattr, so host
  changes show within 1 s and a repeated stat costs no round trip; each
  write(2) still goes to the host at once, so nothing waits to be written
  back. .agents/js.md has the measurements and the limits.
  kw_defconfig: NET_9P, NET_9P_FD, 9P_FS.
* **Shared memory** (`drivers/misc/kwshm.c`, 2026-11-14): the
  host reads and writes the pages of guest shmem files (memfds, files in
  `/dev/shm`) in place, since they already lie in the kernel's memory; the
  driver only tells it which pages a file occupies and pins them while the
  host may look. The host opens or creates files in `/dev/shm` by name,
  and guest programs export a shmem fd through `/dev/kwshm` (ioctl
  `KWSHM_IOC_EXPORT`, `include/uapi/linux/kwshm.h` in the kernel tree),
  getting an id to send to the host over any channel. Holes are allocated
  on export. The SDK's `shm` option and the CLI's `--shm` (which opens
  nothing itself) offer it; without them there is no `/dev/kwshm`.
  `kwshm memfd SIZE [SEED]` and `kwshm export FILE` (`guest/kwshm.c`)
  export a patterned memfd or a file and print its id.
* **In the image:** `glimmer` (`guest/glimmer.c`) is a small game that uses
  the display, the keyboard and the mouse at any screen size, and plays
  synthesised sound effects when there is a sound card (22050 Hz stereo
  through the raw ALSA ioctls, about 46 ms queued; M or Tab mutes,
  `--no-sound` turns it off). `glimmer --test` draws a fixed pattern,
  plays a fixed test signal (1 s each of 440 Hz on both channels, 660 Hz
  on the left, 880 Hz on the right) and prints every input event, and
  `node test/glimmer-check.mjs --run` checks all three from the host
  (`--no-sound`: without a sound card).
* **Size**, lowered 32-bit kernel, 2026-11-14: display +37 KiB, input
  +49 KiB, sound +142 KiB (30 KiB of it the OSS emulation), vsock
  (VSOCKETS, VSOCKETS_DIAG, KWVSOCK) +45 KiB (+15 KiB gzipped), kwshm
  +6 KiB (+2 KiB gzipped); 2026-11-15: 9p (NET_9P, NET_9P_FD, 9P_FS)
  +141 KiB (+52 KB gzipped, 28 KiB of RAM). `INPUT` turns
  HID on by default; kw_defconfig turns it off again.

## Ubuntu (disk root)

`kernel/build.sh ubuntu` (`guest/ubuntu-disk.sh`) turns Ubuntu Base 24.04.5
LTS riscv64 (glibc 2.39, dpkg, apt 2.8, perl-base; no init system, no
python) into `vendor/build/disk/ubuntu.ext4`, 2 GiB sparse (`DISK_SIZE`),
about 143 MiB allocated. Nothing runs as root on the host: the tarball has
no device nodes and no xattrs or file capabilities, its two hard links
survive `mke2fs -d`, and `tools/ext4-owners.py` restores the owners and the
setuid/setgid bits (`su`, `passwd`, `mount`, `unix_chkpwd` root:shadow,
`/var/cache/apt/archives/partial` owned by `_apt`). The script adds:

* `/sbin/init` -> `/usr/local/sbin/kw-init`, a bash script as PID 1: it
  mounts `/proc`, `/sys`, `/dev/pts`, `/dev/shm` and `/run` (fstab), runs
  `kw-net`, and starts `bash -l` on the console in its own session (job
  control, ^C). When that shell exits, or on `poweroff`/`reboot`/`halt`
  (wrappers in `/usr/local/sbin` that signal PID 1, and defer to the
  system's own commands once an init system is installed), it kills
  everything, remounts `/` read-only (`kw-shutdown: / is clean`) and calls
  reboot(2) through perl, since there is no reboot binary.
* `/usr/local/sbin/kw-net`: Ubuntu Base has neither iproute2 nor a DHCP
  client, so this perl script sets lo up and eth0 to the fixed addresses of
  the host's user-mode network (10.0.2.15/24, gateway 10.0.2.2) with the
  classic ioctls; `/etc/resolv.conf` points at 10.0.2.3.
* hostname, hosts, fstab and a `TERM` fix, as on Alpine, and a drop-in
  that logs root in on hvc0 once systemd's `serial-getty@hvc0` exists.

```sh
kernel/build.sh ubuntu
node js/cli.ts --disk vendor/build/disk/ubuntu.ext4 --snapshot          # root shell; poweroff
node js/cli.ts --disk vendor/build/disk/ubuntu.ext4 --snapshot --append "console=hvc0 root=/dev/wda rw init=/bin/bash"
node js/cli.ts --disk vendor/build/disk/ubuntu.ext4 --mem 1024          # persistent: apt-get update && apt-get install ...
```

Measured on 2026-11-13 (x86-64 host, Node 24, JIT on): `apt-get update`
(28.6 MB of indexes) takes about 4 minutes, mostly at about 130 kB/s from
ports.ubuntu.com through the CLI's network; `apt-get install
--no-install-recommends python3 procps iproute2 file xz-utils curl
ca-certificates` (42 packages, already downloaded) 2 min 38 s. Then
python3 3.12 (ssl, sqlite3, multiprocessing), `curl https://...`, `ip` over
netlink and `ps` work. Booting it, the update, the install and those
programs made no syscall that returned ENOSYS and hit no illegal
instruction (checked with a kernel that logged both). glibc 2.39 on riscv64
never calls rseq (the kernel has none) and runs without a vDSO.

The apt install was what found the slice bug fixed by charging kernel entries (see
Interrupts are polled under Design).

**systemd.** systemd 255 runs as PID 1. Install
it from the kw-init shell (persistent disk, network):

```sh
node js/cli.ts --disk vendor/build/disk/ubuntu.ext4 --mem 1024 --input '{5}apt-get update && apt-get install -y --no-install-recommends systemd systemd-sysv udev dbus && poweroff\n'
node js/cli.ts --disk vendor/build/disk/ubuntu.ext4 --snapshot --mem 1024   # systemd, root logged in on hvc0
```

`systemd-sysv` replaces `/sbin/init`; `init=/usr/local/sbin/kw-init`
still boots the plain shell (with the network, which nothing configures
under systemd yet). udev is needed: without it `dev-hvc0.device` never
appears and the console getty times out after 90 s. On 2026-11-13 (same
host): `Startup finished in 132ms (kernel) + 7.417s (userspace)`, 8.7 s
with `--no-jit`; `systemctl is-system-running` says `running`, no failed
units, 33 processes, and `poweroff` goes through systemd's shutdown and
leaves `/` clean. What the kernel lacks, and systemd copes with:

* `bpf` (BPF_SYSCALL off) and `keyctl` (KEYS off) return ENOSYS: no BPF
  firewalling or device control, no session keyrings. These two are the
  only ENOSYS of the boot.
* No seccomp (`SystemCallFilter=` is skipped), no IPv6 (`::1` is not
  added to lo), no `SO_PASSSEC`, only the `pids` cgroup controller
  (`cpu`, `memory`, `io` and the rest are unsupported),
  no modules (the `modprobe@` units run and find nothing).

It needs irq_work to run from the timer tick: Tiny SRCU starts grace
periods with irq_work, and when the arch claimed an irq_work interrupt it
does not have, any `synchronize_srcu()` hung, for one in `close()` of an
inotify descriptor with a watch (systemd early in boot, and a python3
one-liner under kw-init). The config it needs: CGROUPS,
NAMESPACES (UTS, IPC, PID, NET), KCMP, FANOTIFY, AUTOFS_FS and
EXT4_FS_SECURITY, about 180 KiB more kernel.

Patch 0040 (2026-11-14) adds small options that tools and services probe
for: the `pids` controller, user namespaces (`unshare -r`, bubblewrap),
CHECKPOINT_RESTORE (`/proc/PID/task/TID/children`), PSI
(`/proc/pressure`), task I/O accounting (`/proc/PID/io`), userfaultfd,
IP multicast, `ss` for unix, packet and netlink sockets, loop devices
(created on demand through `/dev/loop-control`), `/dev/net/tun` and
`/proc/sysrq-trigger`. Together they add about 200 KB to the lowered
kernel (70 KB gzipped, 54 KB with brotli) and 25 KiB of RAM. Alpine's
`/init` and the Alpine disk's fstab mount cgroup2 at `/sys/fs/cgroup`
(24 KiB, about 10 ms).

For VPNs and containers the kernel also has policy routing (`ip rule` and
more than one routing table), veth pairs and dummy links (64 KB, 24 KB
gzipped, 20 KiB of RAM; 2026-11-17). Tailscale's `tailscaled` runs on
`/dev/net/tun` with its usual rules and table 52; start it with
`tailscale up --netfilter-mode=off`, since there is no netfilter, and
expect relayed (DERP) connections, since the host network stack carries no
UDP. A `dummy0` link exists from boot.

## Browser page

The page (`web/`, repository root) is a full-screen terminal (wterm) with
a tmux-style status line and terminal-style dialogs (Ctrl-A is the
shortcut prefix, ⌘A too on Apple devices; then ? lists the keys) and a demo
launcher, built to work on phones as well
as desktops: React and Tailwind, Vite builds the client, Nitro the server, and the kernel side is the SDK (`js/web.ts`,
from source). Everything is self-hosted except the Wisp fallback.

* **Query parameters:** `?mem=MiB`, `?append=<cmdline>`, `?net=0`,
  `?wisp=<url>[,<url>...]|0`, `?jit=0` (no JIT; counters in `KW.jitStats()`), `?data=0`,
  `?display=0`, `?sound=0`,
  `?root=initramfs` (safe mode: `kw.root=initramfs`), `?verbose=1`, `?worker=1`
  (experimental: the kernel, the data disk, the network, the display, input and sound
  in a Web Worker; input and frames through shared memory when the page is
  cross-origin isolated, `?shared=0` for messages), `?smp=N` (experimental: the SMP
  kernel on N CPUs, each in a Web Worker; offered only when the page's bundle carries
  the SMP kernel and the page is cross-origin isolated, else one CPU; no Suspend), and, for tests,
  `?simulate=nojspi|oom|lowmem` (documented in `web/src/config.ts`).
* **Launcher:** ❯ at the left of the status line (or ⌘K on Apple devices,
  Ctrl-Shift-O, Ctrl-A o) opens a full-page grid of demos: glimmer, tmux,
  htop, Midnight Commander, Neovim, sshfs over FUSE, nginx, Node.js, Python,
  PostgreSQL, SQLite, Valkey, internet radio, asciiquarium and Doom. Each
  runs in a new terminal window: the page writes its files into the guest,
  installs its Alpine packages with apk and runs its commands
  (`web/src/demos/`, one file each); web servers open in the preview. The
  page ships nothing for them, so most need the network.
* **What it downloads.** One file: `web/kernel/unkernel-alpine.wasm`, the
  `bundle` output attached to the newest GitHub release (10.6 MiB, without
  an SMP patch section if the release has one;
  `web/scripts/kernel.ts` fetches it when the page is built; `pnpm dev`
  runs the local build's copy), a Vite asset (`/assets/unkernel-alpine-<hash>.wasm` in the
  build; the runtime takes the initramfs and command line from its custom
  sections). The page has no other kernel, root fs or disk.
* **Updates.** The page and its kernel always load from the network (the
  kernel through the HTTP cache, revalidated), so a reload runs the newest
  deploy. The service worker (`web/public/vm-sw.js`, scope `/vm/`)
  serves only the guest preview; .agents/web.md (Service worker and updates).
* **Memory.** The default is auto (the SDK's `autoMemoryMiB()`): 512 MiB on desktops and 256 MiB on
  phones, or less if `navigator.deviceMemory` is low. If the browser refuses
  the allocation, the runtime retries with 384, 256, 192, 128, 96 and then
  64 MiB. Alpine boots in 48 MiB.
* **Load order.** An inline script in `index.html` installs
  `error`/`unhandledrejection` handlers first, and reports the page module
  if it has not run after 8 s. The entry module (`src/main.tsx`) runs the
  feature preflight with the SDK's `checkSupport()` (a real JSPI test
  module, BigInt, memory64 for information). Only after the preflight
  passes does it import the boot module (`src/boot.ts`: wterm and the
  kernel runtime, a separate chunk). A missing feature, a module that fails
  to load or parse, a 404, a failed allocation, or a kernel panic or trap
  turns the status dot red and opens the dialog with the error and a hint.
  The page never stays blank. There is no support for browsers without ES
  modules or JSPI beyond that message.
* **Status dialog** (the status line's windows, or the prefix, then k, i, l, e): boot timeline with timings, environment
  checks, the kernel log (dmesg-style console lines, plus user-space output
  until the shell is up), and an error list. It also has options (root fs,
  memory, font size), *Copy diagnostics*, and *Reboot*. Copying falls back to
  a selectable textarea where the Clipboard API is missing (plain-http LAN
  origins).
* **Terminal windows.** Window 0 is the console (hvc0). Ctrl-A n (⌘K n),
  or `+` on the status line, opens a terminal window (`1:sh` to `9:sh`): a
  kwtty session over vsock (the page's kernel always has the vsock device)
  with its own pty, size and login shell. Ctrl-A or Ctrl-Shift with a
  digit, or a click on its name, switches; the shell exiting closes its
  window, Ctrl-A x closes the current one. `web/src/windows.ts`;
  .agents/web.md has the details.
* **Suspend.** Ctrl-A s (or *Suspend* in the dialog) saves the running
  system in the browser and stops it; the next visit offers to resume it,
  with the console as it was and `/data` as saved. Terminal windows 1-9
  and network connections do not survive. The session is offered only on
  the same kernel release and options, and is dropped once `/data`
  changes. `web/src/session.ts`; .agents/web.md (Suspend and resume).
* **Mobile.** Tapping the terminal raises the keyboard. The key bar has
  Esc, Tab, sticky Ctrl, ^C, arrows, `|` `/` `-` `~` and Paste, and its
  buttons never take focus. Layout uses `100dvh`,
  `interactive-widget=resizes-content`, `visualViewport` and safe-area insets.
  The terminal is refitted (cols × rows) on every resize.
* **LAN / insecure origins.** Plain `http://<lan-ip>:8080` is not a secure
  context. The page does not need one: memory is not shared. Every response
  carries COOP/COEP (route rules in `web/vite.config.ts`), so a secure
  context is cross-origin isolated, but the kernel does not use
  SharedArrayBuffer. Only `navigator.clipboard` and `navigator.deviceMemory` disappear.
* **Browser support:** JSPI (`WebAssembly.Suspending`/`promising`) is
  required. It is on by default in Chrome/Edge 137+ (desktop and Android) and
  Safari 27+ (macOS, iOS/iPadOS 27; every iOS browser uses the system
  WebKit). Firefox 153+ also works. memory64 is not required, because the
  page loads the 32-bit-memory kernel (see below) everywhere. Chrome 133+ and
  Firefox 134+ have it; for Safari, sources disagree (some say 27.3, but no
  stable release had it as of 2026-11; iOS 27.0-27.2 and Playwright WebKit
  build 2336 do not).
* **Two kernel builds.** `vmlinux` is wasm64 (memory64 + table64), the
  build output and the reference (`js/cli.ts --kernel
  vendor/build/kernel/vmlinux`). `vmlinux32.wasm`, which the bundle, the page and
  the CLI use, is the same
  module after Binaryen's
  `wasm-opt --memory64-lowering --table64-lowering`. Pointers stay i64 in
  the code and at the JS boundary, so imports, exports and JSPI are
  unchanged. Every load, store, memory op and table op wraps its address to
  i32, which is exact because guest RAM is below 4 GiB. Data and element
  segment offsets become i32, and the memory and table types become 32-bit.
  The runtime reads the memory type from the module's `target_features`
  section (`moduleIsMemory64`) and creates a matching `WebAssembly.Memory`.
  In V8 both builds run at the same speed; in JavaScriptCore the lowered one
  is ~20% faster on a shell loop, so it is the page's only build.

## Design

* **One instance, one thread, JSPI.** Each kernel task has its own Wasm
  stack. `__switch_to` calls the suspending import `wasm_switch_to`, which
  parks the current stack on a promise. It then resumes the next task's
  promise, or starts a fresh stack through the `ret_from_fork` export (a
  promising export). The kernel C stack (`__stack_pointer`) and `current`
  are Wasm globals, saved in Wasm locals across the switch (`entry.S`).
  * The kernel is uniprocessor with `ARCH_NO_PREEMPT`.
  * Memory is non-shared, so the kernel needs neither SharedArrayBuffer nor
    COOP/COEP (the page sends COOP/COEP anyway).
* **Interrupts are polled.** The timer is a one-shot expiry compared against
  the host monotonic clock. Console input arrives as a host-set bit in
  `wasm_host_irqs` (IRQ 1, which kicks hvc). Both are checked:
  * whenever a slice of 200k user instructions ends. The slice belongs to
    the CPU: it runs on across kernel entries and task switches, and every
    syscall and page fault is charged 1000 instructions, so a
    loop that keeps entering the kernel still ends a slice at least every
    200 entries (apt busy-polls with `pselect()` while dpkg finishes, which
    used to livelock the UP kernel);
  * in `arch_cpu_idle`, which suspends in `wasm_idle(timeout)`, a WASI
    `poll_oneoff` on stdin and a monotonic clock, until the timer expires
    or a host event (input, a frame, a block completion) wakes it.

  While user code is busy, the kernel yields to the host event loop every
  20 ms (`wasm_yield`: `sched_yield`). After idle and yield the kernel also
  raises IRQ 1 itself when `poll_oneoff` reports stdin readable, so a plain
  WASI host that never writes `wasm_host_irqs` still delivers input.
* **MMU=y without hardware.**
  * The kernel runs only in the direct map: virtual address = physical
    address = linear address, and `phys_base` is 0.
  * User page tables use the Sv39 layout. The PTE bits are riscv's, with
    `_PAGE_PROT_NONE` = G and the riscv swap format, in a 3-level table with
    the PUD folded.
  * kwemu walks the tables and raises `KW_EV_FAULT`. The kernel either
    fixes the A/D bits directly (Svadu-like fast path) or calls
    `handle_mm_fault` through `lock_mm_and_find_vma`.
  * `update_mmu_cache` and `flush_tlb_*` map to `kw_flush_tlb_*`, and
    `switch_mm` maps to `kw_set_pgd`.
* **uaccess.** `copy_{to,from}_user`, `clear_user` and the futex ops walk the
  page tables in software (`arch/wasm/mm/fault.c`) and fault pages in.
  `get_user`/`put_user` and `strn*_user` use the generic implementations on
  top of these.
* **vmalloc** returns direct-mapped memory (`mm/vmalloc-flat.c`, behind
  `CONFIG_VMALLOC_FLAT`). `vmap()` of non-contiguous pages fails, there is no
  `VMAP_STACK`, and per-cpu memory uses `percpu-km`.
* **riscv64 user ABI.**
  * Syscalls come from `scripts/syscall.tbl` with abis
    `riscv rlimit memfd_secret`. pt_regs-wrapped entry points give every
    syscall one Wasm type.
  * Signal frames use riscv's `rt_sigframe`/`ucontext` (FP state, END ext
    header).
  * ELF loading uses binfmt_elf with `EM_RISCV`, `AT_HWCAP` = IMAFDC, and
    `AT_MINSIGSTKSZ`.
  * `uname -m` reports `riscv64`. The ISA that user space sees comes from
    one set (`arch/wasm/kernel/cpu.c`): RV64GC plus the extensions that
    every kwemu has (Zicbop, Ziccamoa, Ziccif, Zicclsm, Ziccrse, Zicntr,
    Zihintntl, Zihintpause, Za64rs, Zaamo, Zalrsc, Zca, Zcd) plus the optional ones kwemu implements (`kw_isa_supported()`:
    Zba, Zbb, Zbc and Zbs, the B extension and carry-less multiplication;
    Zbkb, Zbkc and Zbkx, the bit manipulation for cryptography; Zknd and
    Zkne, the scalar AES instructions; Zicond, conditional zeroing; and of
    the RVA23U64 profile Zcb, more compressed instructions, Zimop and Zcmop,
    the may-be-operations, Zicbom and Zicboz, the cache-block operations
    with 64-byte blocks, Zawrs, wait on reservation set, Zfa, more
    floating-point instructions, Zfhmin, half-precision conversions, and
    Zihpm, whose counters read 0), minus
    `kw.isa=`. The `isa` line of `/proc/cpuinfo` lists it in upstream's
    canonical order
    (`rv64imafdc_zicbom_zicbop_zicboz_ziccamoa_ziccif_zicclsm_ziccrse_zicntr_zicond_zicsr_zifencei_zihintntl_zihintpause_zihpm_zimop_za64rs_zaamo_zalrsc_zawrs_zfa_zfhmin_zca_zcb_zcd_zcmop_zba_zbb_zbc_zbkb_zbkc_zbkx_zbs_zknd_zkne`),
    and `riscv_hwprobe` reports the same set in `IMA_EXT_0` (FD, C and the
    `RISCV_HWPROBE_EXT_*` bits) and `IMA_EXT_1` (the platform properties),
    Zicbop, Zicboz and Zicbom block sizes of 64, fast misaligned scalar
    access and no vector, the end of user space (1 << 38) and no vendor
    extensions; `TIME_CSR_FREQ` is unknown. `AT_HWCAP` stays IMAFDC. The cycle, time and
    instret CSRs all count retired instructions. `riscv_flush_icache`
    flushes the emulator's translations.
  * **`kw.isa=`** masks extensions, for A/B measurements and bisecting: a
    comma list applied from left to right, where `rv64gc` turns off
    everything beyond RV64GC, `-ext` turns one off and `+ext` turns one
    back on (if kwemu implements it). Examples: `kw.isa=rv64gc`,
    `kw.isa=-zkne,-zknd`, `kw.isa=-zba,-zbb,-zbs,-zicond`,
    `kw.isa=rv64gc,+zkne`. A
    masked optional extension raises SIGILL like an unimplemented one.
    Masking one that every kwemu has (Zicntr, Zca, ...) only stops
    advertising it. The boot log shows the result (`kwemu: isa ...`).
    Under Node: `--append "console=hvc0 rdinit=/init kw.isa=rv64gc"`.
  * There is no vDSO. Handlers return through a `[sigpage]` special mapping
    that holds `li a7,139; ecall`.
* **Console.** `hvc_wasm` on WASI fds 1 (output) and 0 (input, read only
  after a zero-timeout `poll_oneoff`, so it never blocks), `console=hvc0`.
* **Network.** `kwnet`, IRQ 2; see Networking.
* **Block.** `kwblk`, IRQ 3; see Block devices.
* **Sync.** IRQ 4, a host request to write everything back (`ksys_sync()`
  from a work item); see Block devices.
* **Input.** `kwinput`, IRQ 5. **vsock.** `kwvsock`, IRQ 6: packets queued
  for the guest, or room again after the host refused one. **Shared
  memory.** `kwshm`, IRQ 7: host requests queued. **Snapshot.** IRQ 8: park
  every task and save the machine (`/proc/kwpark` runs the same cycle
  without saving). Host bits without a handler are cleared and ignored.

### Host imports

The runtime lives in `js/core/kernel.ts` (`Kernel`, with `js/core/wasi.ts`)
and is shared by Node and the browser (the SDK, see the top-level README).
Imports marked * are JSPI suspending; they
suspend only when the host returns a promise.

* `env.memory`: the kernel's linear memory (fixed size, chosen by the host).
* `wasi_snapshot_preview1` (WASI preview 1 subset, kernel side
  `arch/wasm/kernel/wasi.c`, host side `js/core/wasi.ts`):
  * `clock_time_get` (monotonic for the clocksource, sched_clock and timer;
    realtime for the boot wall clock), `random_get` (boot entropy).
  * `fd_write` (fd 1 console, fd 2 panic text), `fd_read` (fd 0 console
    input; files), `poll_oneoff`* (idle, and zero-timeout stdin checks;
    uvwasi answers those with the clock event alone, so the kernel also
    reads once whenever an earlier poll reported stdin readable),
    `sched_yield`*, `proc_exit`* (0 power off, 1 halt, 2 restart, 253
    panic).
  * `args_sizes_get`/`args_get`: the command line is argv[1..] joined with
    spaces. The runtime passes `["vmlinux", cmdline]`.
  * `fd_prestat_get`/`fd_prestat_dir_name`, `path_open`, `fd_filestat_get`,
    `fd_read`, `fd_close`: the initrd is the file `initrd` in the first
    preopened directory (fd 3 and up) that has one. The kernel reads it into
    memory that memblock allocates below 4 GiB. The runtime preopens `/`
    with the bundled or given initramfs as `initrd`.

  The preview 1 ABI is wasm32: pointer and size arguments are i32 in both
  kernel builds. The kernel passes only addresses below 4 GiB (static
  buffers in the kernel image, a bounce buffer for console data) and
  `wasi_ptr()` panics rather than truncate one.
* `unkernel` (only the unkernel runtime provides these): `wasm_switch_to`*
  (task switching), `wasm_snapshot_point` (the end of a snapshot the host
  asked for with IRQ 8; see .agents/kernel.md, Parking),
  `wasm_driver_block_info`/`submit`/`reap` (kwblk),
  `wasm_driver_net_init`/`send`/`rx_len`/`recv` (kwnet, optional),
  `wasm_driver_vsock_init`/`send`/`rx_len`/`recv`/`keep` (kwvsock, optional; see
  .agents/kernel.md), `wasm_driver_shm_init`/`request`/`attach`/`detach`/`reply`
  (kwshm, optional; see .agents/kernel.md), the display, input and sound
  imports (optional),
  `wasm_driver_console_size` (console rows << 16 | cols, 0 = unknown) and `wasm_dump_stacktrace`. kwemu, when built with its JIT tier
  (the default), adds `kw_host_jit_caps`, `kw_host_jit_compile` and
  `kw_host_jit_free` (contract in `include/kw_emu.h`; host
  `js/core/jit.ts`): the host compiles a hot block's module synchronously
  against the kernel's memory and `table.set`s it into one of 1024 kwemu
  stub slots of the exported `__indirect_function_table`. The kernel itself
  never calls them; a host that returns 0 from `kw_host_jit_caps` gets the
  interpreter only.

The console follows the host terminal's size: `hvc_wasm` sets it on the tty
when the tty is opened and re-reads it on each input poll, and the host
raises the console IRQ after a resize (`Kernel.setConsoleSize()`, called by
the page's fit, by the CLI from its stdout TTY or `--size COLSxROWS`, and by
`KernelInstance.resize()` in the SDK).
Programs get SIGWINCH. The images set `TERM=xterm-256color` for the console
shell (`/etc/profile.d/kw-term.sh`), replacing the `vt102` that busybox init
picks for a serial-like console, which has no colors.

Besides a restored snapshot, which replaces all of it before the kernel
enters `kw_resume`, the host writes kernel memory only for `wasm_host_irqs` (IRQ bits),
kwblk/kwnet data, kwinput events, kwvsock packets, kwshm requests, the
pages of shmem files exported to it (kwshm) and WASI results; it no longer writes `boot_command_line`
or `initrd_start`/`initrd_end`. A standalone WASI runtime still cannot run
the kernel: it needs the `unkernel` imports, above all a JSPI-like
`wasm_switch_to`, and a module that defines its memory instead of importing
it.
`test/wasi-node.ts` checks the WASI side against a third-party
implementation: Node's `node:wasi` provides every `wasi_snapshot_preview1`
import and the script provides only the `unkernel` ones (JSPI task
switching, no block or net device, no JIT).

## Not done / stubbed

* ptrace has no regsets (`PTRACE_GETREGSET` fails), so strace and gdb do
  not work. There are no core dumps, seccomp, modules, swap, or kallsyms.
  COREDUMP needs arch work first: the ELF core writer calls
  `elf_core_copy_task_fpregs`, which arch/wasm lacks, and the notes would
  have to carry the riscv64 registers from kwemu.
* Without a kwblk disk the root file system is the initramfs (tmpfs/rootfs),
  so packages installed with `apk add` must fit in RAM; with a data disk
  they go to its overlay root, with a root disk to that disk.
* kwblk: no partitions in the shipped image (the driver allows 15), no
  hot-plug or resize, no FUA (the block layer emulates it with flushes).
  `FileDisk` ignores discard (Node has no hole punching). The browser keeps
  every fetched `HttpBase` chunk in memory (the overlay is loaded lazily),
  and saves only on flush (ext4 commits every 5 s), so a tab closed mid-way
  loses at most the unflushed tail. An export or import of the data disk is
  held in memory as a whole.
* SMP is experimental: a second build (`arch/wasm/configs/kw_smp.config`,
  `kernel/build.sh smp`, `.agents/kernel.md`, SMP) runs one kernel instance per
  CPU in worker threads on a shared memory (CLI `--smp N`; the page's
  `?smp=N`, in Web Workers, once its bundle carries the SMP kernel),
  each CPU with its own JIT. It has every device, all served by CPU 0
  (disk I/O from other CPUs is handed to it), but no snapshots yet. A task moves to another CPU only on its way back to
  user mode (the load balancer, `taskset`); one asleep in a system call
  stays where it is until it returns. The released kernel is UP. linux-wasm's NOMMU mode (programs as Wasm
  modules), its Wasm binfmt and its wasm32 build are not part of this
  port.
* Kernel stack overflow is not detected (16 KiB shadow stacks). A wasm
  trap in kernel code ends the session.
* `vmap()` of scattered pages returns NULL. No current user in this config
  hits it.

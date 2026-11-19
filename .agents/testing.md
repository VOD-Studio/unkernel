# Testing: the full matrix

AGENTS.md lists a quick check per area. Run these longer checks before a
release, or when asked for. The browser tests (`web/test/`, see web.md)
are run only when asked; the page is tested by hand with `bun run dev`.

| Change | Run |
| --- | --- |
| Emulator (`src/`, `guest/`, `include/`) | `zig build test`, then the kernel row |
| Kernel or `kw_emu.h` | `kernel/build.sh kernel` and `kernel/build.sh smp`; `bun js/cli.ts --append "console=hvc0 rdinit=/usr/bin/kwtest"`, the same with `BUN_JSC_useWasmMemory64=1` and `--kernel vendor/build/kernel/vmlinux`, and both again with `--no-jit` (expect `kwtest: 0 failure(s)`, exit 0); the SMP kernel as below the table; `node test/wasi-node.ts` (`PASS`) |
| Bundle, kernel patch, `build.sh` | `KPATCH_UP=vendor/build/kernel/vmlinux32.wasm KPATCH_SMP=vendor/build/kernel-smp/vmlinux32.wasm bun run test:kpatch`; after a change to the stamps or the build, two clean builds into different `KW_BUILD` roots give the same `vmlinux32.wasm` files and bundle (`sha256sum`) |
| JIT (`src/emu/jit.zig`, `js/core/jit.ts`) | the two rows above; `zig build test -Dkwemu-fp-fuzz=1000000` after FP changes; `zig build fuzz -- 20000` after control-flow changes; Alpine with real work under JIT and `--no-jit`, comparing outputs (`seq 30000 \| sort -rn \| md5sum`, `tar cf - /lib \| gzip \| md5sum`, `sha256sum`); `bun test --expose-gc --timeout 120000 ./test/api.test.ts` |
| Anything a real userland sees | `bun js/cli.ts --timeout 120 --input '{8}uname -a; apk --version\n{2}poweroff\n'` |
| Block, ext4, disk script | `bun js/cli.ts --disk vendor/build/disk/alpine.ext4 --snapshot --timeout 120 --input '{6}df -h /\n{2}poweroff\n'` (`/dev/root` mounted, `kw-shutdown: / is clean`) |
| Ubuntu disk (`ubuntu-disk.sh`), or anything glibc sees | `kernel/build.sh ubuntu`; `bun js/cli.ts --disk vendor/build/disk/ubuntu.ext4 --snapshot --timeout 180 --input '{8}getconf GNU_LIBC_VERSION; apt --version; dpkg -l \| wc -l\n{4}poweroff\n'` (`glibc 2.39`, `apt 2.8.3`, `kw-shutdown: / is clean`, exit 0); with a network, also `apt-get update` and an `apt-get install`; after a kernel change, a systemd boot of a disk with systemd installed (`running`, no failed units; kernel/README.md, Ubuntu) |
| Data disk (`block.ts`, `kwsparse.ts`, `web/src/data.ts`, `kw-data.sh`) | `bun run test:block`; `bun js/cli.ts --data /tmp/d.img --timeout 120 --input '{8}ls /data\n{2}{sync}{2}poweroff\n'` (`sync: block flush after`, `kw-shutdown: /data is clean`; delete the image afterwards) |
| Overlay root (`kernel/guest/overlay/`, `kw-data.sh`) | `kernel/build.sh alpine`; `bun test/overlay-node.mjs` (`PASS`; with a network also `--only apk --apk`); after a `rebase.sh` change, `--only update --image2 BUNDLE` (see the script's header) |
| Network (SDK or kwnet) | `bun run test:net`; `UNKERNEL_TEST_WISP=1 bun run test:api` |
| SDK (`js/`, `package.json`, `build.config.ts`) | `bun run typecheck`; `bun run test:tty`; `bun run test:http`; `bun run test:9p`; `bun run test:api`; `bun run build`, then the kwtest, Alpine and disk rows with `bun dist/cli.mjs`, `UNKERNEL_DIST=1 bun run test:api`, and `bun pm pack --dry-run` |
| Host file systems (`fs.ts`, `9p.ts`, `memfs.ts`, `mounts.ts`, `nodefs.ts`, `kw9p.c`) | after a kw9p change `kernel/build.sh alpine`; `bun run test:9p`; `bun run test:api`; `bun test/9p-bench.ts` and with `--worker`, against js.md's table |
| Page (`web/`) | `bun run typecheck:web`; `bun run build:web` |

A separate static guest program goes into the `glimmer kwvsock ...` loop at
the end of `kernel/guest/alpine.sh`, or into the `kwtest kwbench` loop
after it if it is only for tests (those stay out of release bundles). `bun test/glimmer-check.mjs --run`
boots with `--display --sound-wav`, runs `glimmer --test` and checks the
dumped frame pixel for pixel, the injected input events and the recorded
test signal sample for sample (`--no-sound`: without a sound card; `--worker`:
the same through the CLI's `--worker`, with input and frames in shared
memory; run it also with `--worker=messages` after a worker-mode change).
The SMP kernel (kernel.md, SMP; `kernel/build.sh smp` puts it in the
bundle) runs the same checks: kwtest with `--smp 2`, `--smp 4` and
`--smp 2 --no-jit` (add `--display --shm` for its kwfb and kwshm checks)
and once on one CPU (`--kernel vendor/build/kernel-smp/vmlinux32.wasm
--initrd alpine-test`), `UNKERNEL_TEST_CPUS=2 bun run test:api` (the
snapshot tests skip), and `bun
test/glimmer-check.mjs --run --kernel <it> --initrd <an image> --smp 2`.
Emulator guests print
`name: N checks, 0 failures`.

When you measure something, follow the rules in kwemu.md (machine, date,
command, interleaved medians).

## Release workflow (CI)

`.github/workflows/release.yml` runs by hand from main as a release of
the generated version `<package.json version>-<YYMMDD>-<commit>` (commit
date, UTC), which it tags `v<version>` once the build passes. Its
`release` input (on by default) unchecked makes it a smoke run. A pushed
`v<version>` tag on main is a release of that version. It refuses any
other ref before building, and stamps the version into package.json
before `bun run build`. It builds everything from source with `KW_RELEASE=1`, so `alpine.sh`
leaves kwtest and kwbench out of `alpine.cpio` and the bundle
(`kernel/build.sh toolchain kernel smp alpine datadisk`, the last two
with `KW_SMP=1`, so the bundle must carry the SMP patch; clang 22 from
apt.llvm.org; both kwemu libraries with `zig build -Dcpu=baseline`
handed over as `KWEMU=` and `KWEMU_SMP=`, so the zig cache survives
runners with other CPU models), runs
kwtest with and without the JIT (the bundle's kernel with `--initrd
alpine-test`) and on 2 CPUs with the JIT (`--display --shm`) and without
(the SMP kernel from the bundle; a hosted
runner has 4 vCPUs, so not more), `bun run typecheck`, `bun run test:kpatch`
on the two kernels, the tty, http and 9p
tests, `bun run build`, kwtest and the api tests on the built package both
UP and on 2 CPUs (`UNKERNEL_DIST=1 UNKERNEL_TEST_CPUS=2`), then
uploads `bun pm pack`'s tarball (`unkernel.tgz`) and the bundle. A release
publishes the tarball as `@vod-studio/unkernel` through npm trusted publishing
with the `latest` dist-tag. It publishes a GitHub release marked latest with
both files attached. CI builds and tests with the Bun version pinned in
`packageManager`. The npm publishing job uses Node 26 for npm provenance, and
`test:wasi` uses Node 24+ to check the kernel against uvwasi. The workflow's
header lists the caches. The kernel tree is restored only by an exact
patch-series key, and the kernel builds (UP and SMP, one cache) only for that
same tree.

To create the npm package, run the workflow on `main` with `release`
unchecked. Download the `release` artifact and publish its `unkernel.tgz`
with `npm publish ./unkernel.tgz --access public --tag latest` from an npm
account with publish access to `@vod-studio`. In the package's npm settings,
add a GitHub Actions trusted publisher for organization `VOD-Studio`, repository
`unkernel`, and workflow `release.yml`. Leave the environment field empty and
enable `npm publish`. Run a release of a fresh version within two days to
validate the publisher. The publish job uses OIDC on a GitHub-hosted runner.

The SMP checks passed on a GitHub-hosted runner under Node on 2026-11-19.
The Bun commands have been verified locally and await a hosted run.

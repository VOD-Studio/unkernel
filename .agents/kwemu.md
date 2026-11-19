# kwemu and its JIT tier

kwemu is the RV64GC user-mode CPU (plus optional extensions, below) that the
kernel links (`zig-out/lib/libkwemu.a`, contract `include/kw_emu.h`; the
kernel side is in kernel.md). This file has the design, the invariants that
tests guard, the numbers that drive decisions, and the designs that were
tried and rejected.

## Sources and outputs

| Path | What |
| --- | --- |
| `src/libkwemu.zig`, `src/emu/kwemu.zig` | C ABI, Sv39 walker and TLBs, block cache (lookup, validation, SMC tracking), `kw_run` |
| `src/emu/exec.zig` | decoder (RV64GC to ops), op semantics, dispatch |
| `src/emu/jit.zig` | JIT tier: block and region emitter, slot pool, compile policy, host imports |
| `src/cpu/core.zig` | reference interpreter; kwemu runs its `generic` ops through it |
| `src/cpu/fpu.zig` | exact softfloat for all rounding modes and flags, host-float fast paths for RNE |
| `src/emu/kwemu_test.zig` | unit tests; roots `src/tests.zig` (native) and `src/tests_wasm.zig` (wasm64 with the JIT) |
| `src/emu/harness*.zig` | test "kernel" using only the C ABI (native and wasm64) |
| `guest/` | test guests: `isatest`, `fptest`, `atomics`, `kbench`, `aestest` (+zkne,+zknd), `bktest` (+zbc,+zbkb,+zbkc,+zbkx), `zbtest` (+zba,+zbb,+zbs,+zicond), `rvatest` (+zcb,+zimop,+zcmop,+zicbom,+zicboz,+zawrs), `zfatest` (+zfa), `zfhtest` (+zfhmin), `jalrtest` (C, static musl); `hello`, `bench` (Zig, `rt.zig`) |
| `test/kwemu-test.mjs`, `kwemu-unit-wasm.mjs` | run by `zig build test` |
| `test/kwemu-jit-host.mjs` | JS host of the JIT imports, for tests and benchmarks |
| `test/kwemu-bench.mjs` | benchmark table (`--jit`, `--median --reps N`, `--wasm-only`) |
| `test/jit-proto.mjs` | the standalone feasibility prototype of the JIT |

`zig build` writes `zig-out/lib/{kwemu.o,libkwemu.a}` (wasm64, cpu `mvp` +
memory64 only, undefined `__stack_pointer`), `zig-out/lib/native/libkwemu.a`,
and `zig-out/bin/kwemu-harness{,-jit}.wasm`.

Build options: `-Dkwemu-jit` (off for plain `zig build`; kernel/build.sh
turns it on), `-Dkwemu-jit-threshold` (2^17), `-Dkwemu-jit-grow` (8192
exits per KiB of module, 0 = never; see Regions), `-Dkwemu-stats`
(counters, the `kw_debug_stats` export, harness and CLI `--stats`;
`kernel/build.sh stats` builds a kernel and bundle with it),
`-Dkwemu-fp-fuzz=N`, `-Dkwemu-tail-call` (off, see Rejected designs),
`-Dlib-optimize` (ReleaseFast) and `-Doptimize` (native library and
harness).

## Interpreter

- **Ops.** Each guest instruction becomes one 16-byte op (`h, rd, rs1,
  rs2, raw, imm`). Immediates are pre-extended, `auipc`/`lui`/`c.li` fold
  into `li`, branch targets are absolute, compressed instructions expand to
  the same ops, and `x0` destinations go to a scratch slot. 136 op kinds
  cover RV64IMC, FP loads/stores, common F/D arithmetic and, while they
  are enabled, every instruction of Zkne/Zknd, Zba, Zbb, Zbc/Zbkc, Zbs,
  Zbkb, Zbkx and Zicond. Zcb, Zimop, Zcmop, Zawrs and Zfa decode to
  existing kinds (below). `Stats.op_hist` and `JitStats.hb` have room for
  `kwemu.max_ops` (192; harness.zig reads that layout). Every kind costs
  dispatch code, so variants of one operation share a kind, with the
  variant in `imm` where that needs no branch. Everything else (CSRs,
  AMOs, LR/SC, `fsqrt`, `fcvt`, `fclass`, `ecall`, illegal encodings) is a
  `generic` op that runs `core.exec` on the raw bits.
- **Superblocks.** A block holds up to 64 instructions inside one page.
  Conditional branches are side exits, and direct `jal`/`j` inside the page
  are followed. A branch back to the block's own start ends it, and such a
  self-loop re-enters without a lookup. A 32-bit instruction that
  straddles the page end is a block of its own, so a block never depends
  on a second page.
- **Lookup.** A 2-way table of 32K blocks keyed by virtual pc, set
  `((pc >> 1) ^ (pc >> 15)) & 16383`. The fast path is two compares: pc,
  and `tgen` against the generation of either entry of pc's exec-TLB set.
  The exec TLB is 2-way (256 sets), and every fill gets a fresh 64-bit
  generation. Both the 2-way exec TLB and that set hash are needed: a
  1-way exec TLB (busybox and musl pages under ASLR) or a `pc >> 16` hash
  (pc and `pc ^ 0x8000` collide) made the ash loop vary between 3 and 5 s.
- **Coherence.** A block is trusted only under the generation it was
  validated with. Flushes, `kw_set_pgd` and FENCE.I retire generations. A
  stale block is revalidated (same pc, same host address, same raw bits)
  or re-decoded. Guest stores are tracked exactly: pages holding code sit
  in a hashed filter with a 64-byte-chunk bitmap, and their write-TLB
  entries carry `code_flag`, which sends stores to the slow path. A store
  into a marked chunk retires the page's generations and ends the current
  block, so SMC takes effect at the next instruction.
- **Several harts** (an SMP kernel, kernel.md, SMP; ABI 7): each CPU has
  its own `struct kw_cpu` on one shared memory, and code tracking is per
  `kw_cpu`, so another hart's store into code is seen after a flush here
  (riscv's `flush_icache` syscall flushes every CPU), as on hardware.
  Built with `-Dkwemu-atomics` (`core.smp`), AMOs are wasm atomic
  read-modify-writes (min/max as compare-and-swap loops), LR is an atomic
  load whose value SC compare-and-swaps against (an ABA store in between
  goes unnoticed, as in QEMU), everything is seq_cst (so aq/rl hold), and
  FENCE (also FENCE.TSO and PAUSE) is a generic op that does a seq_cst
  read-modify-write, a locked instruction on x86-64 V8 (about 4.3 ns
  over the plain op, against 8.9 ns for `atomic.fence`, an mfence; an
  atomic load costs nothing extra. Node 24, i7-10700K, 2026-11-16, a
  loop of each on a shared memory). Without the
  option all of them stay single-hart (a plain read-modify-write; FENCE a
  no-op op). The JIT runs on every hart (JIT on several harts, below).
- **Precise state.** Ops update `kw_regs` directly. On a fault mid-block,
  pc is recomputed from the raw instruction lengths and the budget is
  refunded. `icount` and the budget are exact, because a block that does
  not fit the remaining budget is single-stepped. `*irq_pending` is polled
  at every block end. An interpreted self-loop that an interrupt ends
  still counts its passes towards the compile threshold (`loopDone`):
  under a stream of IPIs (a thread flushing TLBs on another CPU) a hot
  loop otherwise never got compiled.
- **Memory fast path.** One compare per access: the TLB entry holds
  `tag = vpn` and `add = host - va`, and the tag is compared against the
  vpn of the access's last byte, so page-straddling accesses fall into the
  slow path for free. This is still about 15 wasm instructions per access.
  The read and write TLBs are direct-mapped with 1024 entries each
  (32 KiB together). Against 256 entries (2026-11-15, Node 24.22.1,
  16-core host, medians of 15 runs over 5 interleaved boots): `apk
  --no-network info tree` 2.76 vs 2.85 s, `seq 100000 | sort -r` 2.89 vs
  2.98 s, `seq 250000 | gzip | gunzip` 2.96 vs 3.03 s, an ash counting
  loop 2.97 vs 3.01 s.
- **Cache.** 32K block slots, 384K ops (6 MiB of the 8 MiB `KW_CPU_SIZE`),
  a 4096-entry code-page filter. When the op arena fills, the whole cache
  (and every compiled block) is reset. A 16 or 32 MiB `KW_CPU_SIZE` was no
  faster, and 32 MiB does not boot with 48 or 64 MiB of guest memory. The
  block table cannot grow past 64K entries: region members are u16 block
  indexes.
- **FP.** All five rounding modes and flags are exact. RNE uses host-float
  fast paths with exact inexact detection. f64 FMA uses Boldo & Melquiond's
  emulated FMA (Dekker product, TwoSum, round to odd), checked against the
  integer path on more than 2M random and near-cancellation cases.
- **Dispatch** is one central `while (true) switch` in `exec.runOps`, a
  loop over a single `br_table`. Keep it that way: a threaded `switch`
  (`continue :sw`) makes LLVM give every handler its own `br_table` over
  all kinds, `kwemu.run` about 7x larger, and node's cold startup code
  much slower (Rejected designs). V8 pays most for mispredicts and code
  size on code that does not repeat: 16 hot functions run at 3.3 ns per
  instruction, 256 to 4K distinct functions in random order at 6.7-8.7 ns.
  Op-cache misses are not the cause: 4K functions sharing one op sequence
  run at hot speed.

## ISA and optional extensions

The base is RV64GC: RV64IMAFDC, Zicsr, Zifencei. Also always there, with
no gate: Zicntr (cycle, time and instret all return `icount`), and the
hints that run as no-ops because they are plain RV64GC encodings with
`rd = x0`: PAUSE (Zihintpause, a FENCE that decodes to `nop`), the NTL
hints `add x0, x0, x2..x5` and `c.add x0, x2..x5` (Zihintntl) and
`prefetch.{i,r,w}` = `ori x0` (Zicbop). The kernel advertises these,
Zaamo, Zalrsc, Zca and Zcd (parts of A and C) and the platform
properties Ziccamoa, Ziccif, Zicclsm, Ziccrse and Za64rs (below), in
cpuinfo and hwprobe (kernel.md).

**Why extensions** (goals: a faster Alpine first, a bootable Ubuntu
second). Emulator cost scales with retired instructions, so only
extensions that collapse many of them pay. Alpine 3.24's binaries (node
and its libraries too) are pure RV64GC, so only code that picks a path at
run time gains: OpenSSL 3.5 reads hwprobe and `AT_HWCAP`, and uses
Zkne/Zknd for all AES (the DRBG too, so nearly every process using RAND)
and Zbc (+ Zbkb) for GHASH; Zknh, Zksed, Zksh or Zbb alone get no scalar
use. V8 on musl ignores hwprobe and only accepts a cpuinfo `isa` exactly
`rv64imafdc`/`rv64imafdcv`, B only with `--riscv-b-extension` (newer V8
uses hwprobe). Ubuntu 24.04 is RV64GC, 25.10 and later need RVA23 with V.
Every new op needs JIT support: left to the interpreter, it can be slower
than no extension (Rejected designs).

Optional extensions have one bit each: `KW_ISA_*` in `include/kw_emu.h`,
`core.Ext` in `src/cpu/core.zig` (checked against each other at compile
time in kwemu.zig): Zba, Zbb, Zbc, Zbs, Zbkb, Zbkc, Zbkx, Zknd, Zkne,
Zicond, Zcb, Zimop, Zcmop, Zicbom, Zicboz, Zawrs, Zfa, Zfhmin, Zihpm (the
scalar part of RVA23U64), bits 0-18, with 19-63 free. `core.implemented`
is the set this build implements (`kw_isa_supported()`): all nineteen.
`kw_set_isa()` stores `isa & implemented` in `Hart.isa` and drops every
decoded block and compiled module; `kw_cpu_init` enables everything
implemented. Instructions of a disabled or unimplemented extension raise
`KW_EV_ILLEGAL` like any unknown encoding.

**Adding an extension X** (the pattern is also in the comment above
`core.Ext`):

1. `core.exec`: decode X's encodings behind `has(h, .x)` and fall through
   to `ill(h, inst)` when it is false. `enabled()` folds to `false` at
   compile time while X is not in `implemented`.
2. `exec.decode(inst, pc, isa)`: give X's hot encodings a dedicated op
   only under `core.enabled(isa, .x)`, else return `generic` (which runs
   `core.exec`, so step 1's gate applies). Blocks are decoded under one
   `isa`, which is why `kw_set_isa` resets the cache.
3. `jit.zig`: translate only X's dedicated ops. They exist only while X is
   enabled, so the JIT needs no gate of its own. Never translate X's
   encodings inside `generic` ops (as `fpGeneric` does for F/D).
4. Add `.x` to `core.implemented`. That alone makes the kernel advertise
   X (cpu.c lists every `KW_ISA_*` extension), so do it only when X is
   complete (interpreter, JIT, tests). Test it: `isa_probes` in
   kwemu_test.zig and `isa_exts` in kwtest.c hold one probe instruction
   per extension and check that it traps exactly when X is not enabled;
   add result checks of your own, and JIT-vs-interpreter cases if X has
   dedicated ops.

**Instructions in more than one extension** are legal when any of them is
enabled, and are gated on all of them: an unimplemented one folds to
`false`, so the gate is right before and after it is implemented.
Examples: `aes64ks1i`/`aes64ks2` (Zkne or Zknd), `clmul`/`clmulh` (Zbc or
Zbkc), and the ten instructions Zbkb shares with Zbb
(`core.bitmanip.kbOrB`: andn, orn, xnor, rol, ror, rori, rolw, rorw,
roriw, rev8, plus zext.h, which on RV64 is `packw rd, rs1, x0`; packw with
another rs2 is Zbkb only).

### Zkne / Zknd (scalar AES)

The RV64 instructions of the scalar cryptography spec v1.0.1: `aes64es`,
`aes64esm` (Zkne), `aes64ds`, `aes64dsm`, `aes64im` (Zknd), and
`aes64ks1i`, `aes64ks2` (either one). `aes64ks1i` with rnum 0xB-0xF,
`aes64im` with a nonzero rs2 field, any funct3 other than the spec's and
the RV32-only `aes32*` encodings are illegal.

- **Reference** (`core.aes`): ShiftRows picks bytes of rs1:rs2, SubBytes
  is a lookup in the S-box (computed at compile time from the GF(2^8)
  inverse and the affine map), (Inv)MixColumns is computed with a
  branch-free `xtime`. No data-dependent branches or early exits, but the
  S-box lookup is indexed by data, so this is not constant-time against
  cache timing, and kwemu does not advertise Zkt.
- **Interpreter**: the seven instructions get dedicated ops
  (`aes64es` ... `aes64ks1i`, imm = rnum) that call `core.aes`; `core.exec`
  gates the same encodings (`aes.op`/`aes.opImm`) for `generic`.
- **JIT**: compiled code may only address cpu-relative data, so
  `jit.init` fills `State.aes` (`AesTab`, 3.5 KiB inside `struct kw_cpu`)
  from `core.aes`: `te`/`td` (MixColumns / InvMixColumns of the column
  (S[x], 0, 0, 0) resp. (S^-1[x], 0, 0, 0); a byte in row r contributes
  `rotl(t[x], 8r)`), `im` (InvMixColumns of (x, 0, 0, 0)), and the two
  S-boxes. `aes64esm`/`dsm`/`im` are 8 word loads, 6 rotates and XORs per
  64 bits, `aes64es`/`ds` 8 byte loads; `aes64ks1i` and `aes64ks2` are
  always inline. Like FMAs, a block with at most 4 table ops
  (`aes_inline_max`) gets them inline, more call one helper function per
  kind (type 1, `(rs1, rs2, cpu) -> rd`) shared by the module. The tables
  are derived from the interpreter's functions but the code paths differ
  (tables vs arithmetic MixColumns), and the tests compare the two.

### Zbc / Zbkb / Zbkc / Zbkx (bit manipulation for cryptography)

RV64 only, as the bit-manipulation spec v1.0.0 (Zbc) and the scalar
cryptography spec v1.0.1 (Zbkb, Zbkc, Zbkx) define them: Zbc is clmul,
clmulh, clmulr; Zbkc clmul, clmulh; Zbkx xperm4, xperm8; Zbkb pack, packh,
packw, brev8 and the instructions shared with Zbb (above). zip and unzip
are RV32-only and stay illegal, as do RV32's rev8 encoding (0x698) and the
Zbb-only neighbours (orc.b, min, ...) without Zbb. OpenSSL uses
clmul/clmulh for GHASH when hwprobe reports Zbc, in its Zbkb variant
(brev8) when Zbkb is there too.

- **Reference** (`core.bitmanip`): every instruction is on the Zkt list,
  so none branches on or indexes by data. clmul is BearSSL's `bmul64`: the
  operands masked to every fourth bit, 16 integer multiplications, the
  products XORed per bit class and masked; a column of one product has at
  most 16 terms, so its sum never carries into the next column of its
  class below bit 64. clmulr is `rev(clmul(rev a, rev b))` and clmulh is
  clmulr >> 1. No loop and no early exit, so it is constant-time wherever
  integer multiplication is (x86-64 and AArch64). The spec's bit loop (in
  the tests) would be about 640 wasm instructions per clmul, bmul64 is
  about 100.
- **Interpreter**: each instruction has a dedicated op while enabled
  (`andn` ... `brev8` in `exec.H`); `core.exec` gates the same encodings
  (`bitmanip.op`, `op32`, `opImm`, roriw) for `generic`.
- **JIT**: rotates are wasm rotates (counts wrap like RISC-V's), andn/orn/
  xnor/pack* are a few ALU ops, rev8 is a rotate by 32 plus two mask
  swaps, brev8 three mask swaps. clmul is bmul64 inline (about 100
  instructions, 8 scratch locals), clmulh/clmulr add three bit reversals
  (about 290); xperm8 is a shift and a `select` per byte, xperm4 a shift
  per nibble. A block with at most 12 clmul*/xperm* (`bk_inline_max`) gets
  them inline, more call one helper per kind (type 1, the third parameter
  unused). 12 covers OpenSSL's GHASH loop (6 clmul + 6 clmulh, about
  6.5 KB of module). Inline bodies use the inline FMA body's scratch
  locals (`l_bk`), which hold nothing across ops.

### Zba / Zbb / Zbs / Zicond (the B extension, conditional zeroing)

RV64 only, as the bit-manipulation spec v1.0.0 (Zba, Zbb, Zbs) and Zicond
v1.0 define them: sh1add, sh2add, sh3add, add.uw, sh1add.uw, sh2add.uw,
sh3add.uw, slli.uw (Zba); clz, clzw, ctz, ctzw, cpop, cpopw, max, maxu,
min, minu, sext.b, sext.h, orc.b and the ten shared with Zbkb (Zbb); bclr,
bclri, bext, bexti, binv, binvi, bset, bseti (Zbs); czero.eqz, czero.nez
(Zicond). Immediate shifts and bit indexes are 6 bits; RV32's encodings,
`slli.uw` under OP-IMM and W forms that do not exist (bclriw, sext.b in
OP-IMM-32, czero in OP-32, ...) stay illegal.

- **Reference**: `core.bitmanip` (`op`, `op32`, `opImm`, `opImm1`,
  `opImm32`) and `core.czero`, plain Zig (`@clz`, `@popCount`, ...).
  `orcb` is branch-free: bit 7 of `((a & 0x7f..) + 0x7f..) | a` is set
  per nonzero byte.
- **Interpreter**: 30 instructions on 10 op kinds, the variant in `imm`
  (see `exec.H`): `shadd` (all eight Zba ones; `(rs1 & mask) << s + rs2`,
  slli.uw with rs2 = x0), `clz`/`ctz`/`cpop` (W forms through a shift or a
  mask in imm), `minmax` (signed compare of operands XORed with a bias, so
  minu/maxu are the same code), `sext` (shift pair), `orc_b`, `bitop`
  (bclr/bset/binv as `(a & ~(m & k1)) ^ (m & k2)`), `bext` (bexti is bext
  with rs2 = x0 and the index in imm), `czero`. bseti/bclri/binvi decode
  to `ori`/`andi`/`xori` with the mask as immediate. None of the shared
  kinds branch on the variant.
- **JIT**: every one, specialised on imm: wasm `i64/i32.clz`, `ctz`,
  `popcnt` (i32 forms plus `extend_i32_u` for the W ones), compare and
  `select` for min/max and czero, `shl`/`shr_s` for sext.b/h (the
  sign-extension opcodes are not MVP), shift-and-mask for the Zbs ops and
  orc.b, `extend_i32_u` for .uw. All are a handful of instructions and
  always inline.

### Zcb / Zimop / Zcmop / Zicbom / Zicboz / Zawrs (RVA23 decode-level)

As the Zc spec v1.0 (Zcb, Zcmop), Zimop v1.0, the CMO spec v1.0.1
(Zicbom, Zicboz) and Zawrs v1.01 define them; none adds an op kind.

- **Zcb**: c.lbu, c.lhu, c.lh, c.sb, c.sh (quadrant 0, funct3 100; uimm[0]
  is bit 6, uimm[1] bit 5) decode to `lbu`/`lhu`/`lh`/`sb`/`sh`; c.mul to
  `mul`; c.zext.b, c.zext.h, c.zext.w to `andi` with 0xff / 0xffff /
  0xffffffff; c.sext.b, c.sext.h to `sext`; c.not to `xori -1`. So the JIT
  covers them with no change. c.sext.b/h and c.zext.h also need Zbb,
  c.zext.w needs Zba (`core.zcbUnary`), c.mul needs M. c.sh with bit 6
  set, funct6 100100-100111 and the unary sub-opcodes 6 and 7 stay
  illegal.
- **Zimop / Zcmop**: mop.r.N and mop.rr.N (`core.isMop`: SYSTEM funct3 4,
  bits 31, 29:28 = 1, 00, then 25:22 = 0111 or 25 = 1) decode to `li rd,
  0`; c.mop.N (c.lui x1, x3, ..., x15 with a zero immediate,
  `core.isCMop`) to `nop`. Zicfiss lives in these encodings; kwemu does
  not implement it, so they stay MOPs (as on hardware with shadow stacks
  off).
- **Zawrs**: wrs.nto and wrs.sto decode to `nop`. The spec lets them
  complete at any time; a single hart has nobody else to wait for, and a
  polling loop around them is preempted by the kernel's slices like any
  loop. Yielding to the kernel scheduler from here would need a new event
  kind (an ABI change).
- **Zicbom / Zicboz** (64-byte blocks, `generic`, so the JIT hands them
  back; nothing makes them hot): `core.Interp.cbo`. cbo.clean and
  cbo.flush do nothing but check that a load (else a store) to the
  address would be permitted, and report a store page fault (`access` =
  write) when neither is, as the spec says; so on a page the kernel has
  not populated, Linux treats it as a write fault (as on hardware). cbo.zero
  zeroes the aligned block through `rmwPtr([64]u8)`, the write path:
  permission, A/D faults and decoded-code tracking (a cbo.zero over code
  ends the block, like a store). cbo.inval is illegal (Linux sets
  `senvcfg.CBIE` = 0 for user mode, arch/riscv/kernel/cpufeature.c), as
  are rd != x0 and the reserved immediates.

### Zfa (additional floating-point instructions)

As Zfa v1.0 defines them for F and D: fli.s/d, fminm/fmaxm.s/d,
fround/froundnx.s/d, fcvtmod.w.d, fleq/fltq.s/d. The .h forms need Zfh
(kwemu has only Zfhmin) and fmvh.x.d / fmvp.d.x are RV32-only, so they
stay illegal, as do fcvtmod.w.d with a mode other than RTZ and fli with
funct3 != 0. No new op kind:

- **fli** decodes to `fmv_w_x` / `fmv_d_x` with rs1 = x0 and the constant
  in imm: those ops compute `f[rd] = x[rs1] | imm` (imm = 0 for fmv.w.x /
  fmv.d.x). The table (`core.fli_s`/`fli_d`) is computed at compile time
  from the spec's list.
- **fminm / fmaxm**, and the base **fmin / fmax**, decode to the
  `fsgnj_s/d` kind with imm = 4 | funct3; **fround / froundnx** to the
  same kind with imm = 16 | rm (24 | rm for froundnx). The kind's handler
  branches on imm (sign injection, min/max with flags, rounding through
  `F.roundInt`), which keeps the kind count down.
- **fleq / fltq** are `fcmp_s/d` with imm = funct3 (4, 5).
- **fcvtmod.w.d** stays `generic` (`fpu.fcvtmodWD`): NaN and infinity
  give 0 with NV, a value whose integer part does not fit in 32 bits sets
  NV and not NX (QEMU agrees), else NX when it was not integral.
- **JIT**: fli is a constant (`fmv_*_x` with rs1 = x0); min/max/minm/maxm
  are `fMinMax` (integer selects on the operand bits, compares on host
  floats, so no NaN bits from wasm); fround(nx) (`fRound`) is wasm's
  `nearest`/`trunc`/`floor`/`ceil` (exact, sign of zero kept; singles
  through f64, exact both ways), NX for froundnx when the value changed, a
  NaN operand handed back, RMM not translated, a dynamic mode only while
  frm is RNE (`frmCheck`); fleq/fltq are `fCmp` with the quiet NaN test.
  Clang inlines floor, ceil, trunc, round and rint as fround with Zfa, so a
  hand-back there would make libm-style code slower than without Zfa.

### Zfhmin (half-precision loads, stores, moves and conversions)

As Zfh v1.0 defines Zfhmin: flh, fsh, fmv.x.h, fmv.h.x, fcvt.s.h,
fcvt.h.s, fcvt.d.h, fcvt.h.d. Everything else with fmt = H (arithmetic,
compares, fclass, integer conversions, fcvt.h.h) is Zfh and stays
illegal, as do fcvt.q.h and flq/fsq. Interpreter only (`generic`; the JIT
hands them back): conversion to and from half is rare in the code this
runs, and has no plain wasm operation.

- Halves are NaN-boxed in the 64-bit registers (`core.boxH`): flh,
  fmv.h.x and fcvt.h.* write `0xffff_ffff_ffff_xxxx`; a source that is not
  boxed that way reads as the canonical NaN 0x7e00 (`unboxH`). fmv.x.h and
  fsh move the low 16 bits as they are, fmv.x.h sign-extends.
- Conversions are `fpu.Fmt(u16)` (`F16`): the generic `unpack` /
  `roundPack` / `fromOther` code with a 10-bit significand, so narrowing
  rounds in every mode with exact NV/OF/UF/NX (tininess after rounding)
  and widening is exact (NV for a signalling NaN, NaN results canonical).

### Zihpm, Zkt and the platform properties (the rest of RVA23U64)

- **Zihpm**: hpmcounter3..hpmcounter31 (CSRs 0xc03-0xc1f) read 0, as
  counters with no event selected do; writes (also csrrs/csrrc with a
  source other than x0) and the RV32 `h` halves stay illegal (`csrOp`). On
  hardware Linux grants user reads of these only through perf
  (`scounteren`); kwemu lets them read like cycle/time/instret. Linux
  lists `zihpm` in cpuinfo and hwprobe whenever the hart has it, so the
  kernel does too. CSR ops are `generic`, so the JIT hands them back.
- **Zkt** (data-independent execution latency) is **not advertised**.
  The integer ALU, shift, multiply and compressed forms on the list run
  without data-dependent branches or memory accesses in the JIT
  (mulh/mulhsu correct the high word with shift-and-mask, `mulCorr`), and
  in the interpreter apart from `fpu.mulh`/`mulhsu`, whose sign
  corrections are `if`s that LLVM may or may not turn into selects.
  clmul*, xperm*, rev8, brev8, pack* and the rotates were written for Zkt
  (above). The blocker is AES: aes64es/esm/ds/dsm/ks1i look the S-box up
  by data in the interpreter (`core.aes.subBytes`) and the JIT (`AesTab`).
  Below all of it, no wasm engine promises data-independent timing for any
  instruction. Fixing AES would need a bitsliced S-box (Boyar-Peralta,
  roughly 120 boolean ops per byte), several times slower than the table.
- **Platform properties**: Za64rs (the reservation is a single address,
  so within 64 bytes), Zic64b (cbo blocks are 64 bytes), Ziccif (fetches
  are single aligned loads, and stores into code are seen at the next
  instruction), Ziccrse (a constrained LR/SC loop succeeds: the
  reservation is only lost to a context switch, a signal or sigreturn,
  `kw_clear_reservation`), Ziccamoa (all AMOs and LR/SC on all memory)
  and Zicclsm (misaligned loads and stores work, also across pages) all
  hold, in the interpreter and the JIT, and so does Za128rs. Zicclsm
  covers loads and stores only: scalar and FP loads and stores never trap
  on alignment (in the page, one unaligned host access, and the JIT emits
  wasm accesses with alignment 0; across pages, `loadSlow`/`storeSlow`,
  to which the JIT hands them back), while a misaligned AMO, LR or SC
  raises `KW_EV_MISALIGNED` (`amo` in core.zig; AMOs are `generic` ops,
  so the JIT hands them back too), which the kernel turns into SIGBUS
  (`BUS_ADRALN`). Neither Ziccamoa nor Zicclsm asks for misaligned
  atomics (that would be Zam). The kernel lists the five that Linux has
  names for (not Zic64b or Za128rs) in cpuinfo and `IMA_EXT_1` (kwemu
  bit 0), and answers `MISALIGNED_SCALAR_PERF` with
  FAST: misaligned ld/sd copy as fast as aligned ones and several times
  faster than lbu/sb.

## JIT tier

**Scope.** A decoded block (not raw instructions) is translated into one
wasm function. Hot blocks that branch to each other share one module (a
region, below), also across pages. Supported: integer ALU, immediates,
shifts, W ops, `li`, the M extension (with RISC-V's division-by-zero and
overflow results), all loads and stores, side exits, followed `jal`, all
terminators, F/D (below), Zkne/Zknd, Zba/Zbb/Zbs/Zicond,
Zbc/Zbkb/Zbkc/Zbkx, Zcb, Zimop, Zcmop, Zawrs and Zfa except fcvtmod.w.d.
Anything else (CSRs, AMOs, LR/SC, `ecall`, static non-RNE FP rounding,
page-straddling instructions) ends the compiled prefix: the code hands
that op back and the interpreter finishes the pass. A block whose first op
is not supported is never compiled.

**Generated code.** `f(x, cpu, irqp, jl: i64) -> i64`. Guest registers live
in wasm locals, loaded on entry and written back at a single exit. Loads and
stores inline the data-TLB fast path on the same `tlb_r`/`tlb_w` arrays. A
miss hands the op back before it executes, which covers faults, straddles
and stores into code pages (`code_flag`), so SMC detection is unchanged. A
self-loop becomes a wasm `loop` that polls `*irqp` and checks `jl` at each
back edge. The result is `(jl_left << 8) | code`: 0..63 = handed back
before op k, 64 = terminator retired, 128+k = side exit at op k. The code
depends only on pc, the raw bits, cpu-relative offsets and block-table
positions, never on host addresses or generations. So a revalidated block
keeps its code, and a re-decoded one (new bytes, a COW copy at a new host
address, a cache reset) frees it. Emitted modules use only MVP
instructions (plus memory64 for a 64-bit memory), so they load on every
engine the page supports.

**When.** A block is compiled after it has retired 2^17 interpreted
instructions, counted per entry and per self-loop pass. The countdown
lives in the block's state word, so a block that is never compiled costs
one load per entry. Eager mode (caps bit 2) compiles on first entry, for
tests. Compiling everything eagerly is much slower for short programs
(`atomics`: 13 vs 110 MIPS), which is why there is a threshold.

**Slots.** kwemu owns 1024 stub functions in the function table: no table
growth and no allocator. A stub returns "handed back at op 0", so an empty
slot is harmless. When all slots are in use, a clock (second chance) evicts
one. Slots are freed only from `run` between entries (`lookupSlow`,
`decodeBlock`, `resetCache`, `compile`), never from inside compiled code.
`kw_cpu_init` forgets slots without freeing them, so a host must accept a
compile into a slot that is already installed. `kw_host_reset` (a restored
snapshot, where the table is a new instance's and holds the stubs again)
forgets them the same way, sets every block's `jx` back to `never`
(re-decoding a block that still named a slot would free that slot on a
host that never compiled it), asks `kw_host_jit_caps` again and resets the
cache.

**Emit buffer.** Modules are emitted into a 16 KiB buffer inside
`struct kw_cpu`. A module that does not fit is emitted again with less in
it: fewer region members (the ones found last are dropped and the region
is closed), then a shorter prefix of the hot block (3/4 of the ops each
time). Every retry is strictly smaller, and a module that overflowed is
never handed to the host. `struct kw_cpu` has only about 53 KiB left
below `KW_CPU_SIZE` with the JIT (`members` and `member_op` take 64 KiB
at 16 members), so check the headroom before growing JIT tables.

### F/D rule

The emitted code computes exactly what `exec.doOp`/`core.exec` compute
(result bits and accrued flags), or hands the op back before it executes.

- FP registers are i64 locals holding the raw register bits. Singles are
  unboxed like `core.unbox` (a value that is not NaN-boxed reads as the
  canonical NaN), and single results are NaN-boxed. `fcsr` is a local,
  loaded when needed and written back at the exit, so `frm` is kept.
- Arithmetic mirrors `fpu.zig`'s RNE fast paths: the same host operation,
  the same result-range guard (biased exponent in [2, emax - 2], so no NaN,
  infinity, zero, subnormal or overflow, and wasm's nondeterministic NaN
  bits never reach a register), and the same exact inexact test. Outside
  the guard the op is handed back.
- FMA: f64 mirrors `fma64Fast`, including the zero-product and zero-addend
  cases, and takes Dekker's exact-product shortcut (`r = sh`, inexact iff
  `sl != 0`). f32 mirrors `fma32Fast`. A block with up to 4 FMAs gets them
  inline. Blocks with more call one helper per format, shared by the
  module. Decide this per block or member, not per module.
- Conversions and `fsqrt` use wasm's correctly rounded operations, with
  range checks before any trapping `trunc`. NaN sources, out-of-range
  values and RMM are handed back.
- Static non-RNE arithmetic is not compiled. Dynamic rounding tests
  `frm == RNE` once per pass of each block or region member (a region can
  be entered at any member) and hands back otherwise, which includes an
  illegal `frm`.
- The inexact test is skipped while NX is already set.

### Regions

A module holds up to 16 decoded blocks (members), on any pages. The body
is a `loop` over a `br_table` with two entries per member: its checked
entry (below), which falls through into the member, and the member itself
(only for the member `run` entered). A member that leaves towards a member
(terminator, side exit, or `jalr` whose target pc matches a member's; a
jalr compares against every member) sets the index and branches to the
loop. Other exits return to `run`. `cpu.jit.cur` names the member a region
left from.

- **Home and guest members.** A block's state word names one region, its
  home (`compiled | member << 16 | pool entry`), and `run` enters the block
  only through that module, at that member. A region may also hold copies
  of blocks whose home is another region (guests). A member's code depends
  only on its decoded ops, so a copy is exact as long as the block holds
  the same decode. `State.members` lists both kinds, `member_op` the low
  16 bits of each member's op index when it was compiled.
- **Membership.** When a block gets hot, `compile` takes it, the members
  (home and guest) of an open region of the same virtual page that has
  room (that region is replaced), then breadth-first the decoded, valid,
  not-yet-compiled blocks reachable through side exits, branch and jal
  targets and call return sites, on any page. A self-loop keeps a module
  of its own, and that module is closed: as a plain wasm loop it is much
  faster than as a member, and loops over big arrays hand back on every
  data-TLB miss, which is cheap only for a small module. A region cut to
  fit the buffer is closed too, so dropped members do not rejoin and push
  others out, and so is a full one.
- **Growth along exits** (`noteExit`/`noteHot`). After compiled code
  leaves a region (terminator or side exit, not a hand-back), `run` checks
  the block it looks up next. If that block is compiled in another region
  and lies on another page than the region's own, it counts the exit on
  the block (`hits`). After `grow_threshold` such exits per KiB of the
  leaving region's module (`-Dkwemu-jit-grow`, 8192), the block joins that
  region as a guest: the region is emitted again with it and replaces the
  old module. A grown region that does not fit the buffer is not cut: the
  old one stays, closed. Calls into libc and PLT stubs, the returns, and
  functions that span pages then stay in one module. Closed and full
  regions and self-loops are not grown, and targets on the region's own
  page are left to the merge above (Rejected designs).
- **Why the grow threshold is that high.** An exit through `run` costs
  only about 11 ns more than a branch between members, while a grow
  compiles the whole region again (a few hundred µs for up to 16 KiB). A
  grow pays only for an edge that will be taken tens of thousands of times
  more. Counting per KiB makes a big region, which costs more to
  recompile, wait longer.
- **Entering a member** (`checkedEntry`). Every branch into another member
  m, from any page, goes through m's checked entry, which tests that m's
  `op` is still the op index it was compiled from (a re-decode takes new
  ops until a cache reset, which frees every module), that m is valid
  under the current exec-TLB fill of its own page (`tgen` equals l_g, the
  `tgen` of the member being run, or else the generation of one of the two
  exec-TLB entries of m's page's set, which is what `lookup` checks; l_g
  then becomes m's `tgen`), that `jl` covers all of m, and that `*irqp` is
  0. Then it charges m. A jalr to the start of the member being run tests
  only `jl` and `*irqp` and stays in that member's own `loop`. If a check
  fails, it returns "done" with pc = m's start, and `run` looks m up
  (revalidates or re-decodes it). The checks
  exist once per member, and a branch site is 6 bytes (a jalr target 18).
  Inline checks per branch site and target (each jalr one per member)
  would be 40% of all module bytes in apk and close regions early (cut to
  fit the buffer).
- **Register file.** The prologue loads the union of the registers (and
  FP registers and `fcsr`) that any member uses, and the single epilogue
  writes back the union of the ones written. Flags accrued in one member
  stay in the `fcsr` local across member branches and reach `regs.fcsr` at
  every exit.
- **Invalidation.** A re-decoded member loses only its own home state
  (`dropMember`); its copies in other regions fail the op check from then
  on. A region is freed when its last home member goes, when the clock
  evicts it, when it is grown (replaced), or on `resetCache`.

### Invariants (what the tests check)

- Budget and `icount` are exact: `run` charges the entered member in full,
  every further member is charged before it runs and only if `jl` covers
  it, and a side exit refunds the rest of the member it leaves. A budget
  that ends inside a member stops at its start, and `run` single-steps from
  there. `instret` reads are handed back.
- IRQ latency: every member branch and self-loop pass reads `*irqp`, so it
  is read at most 64 instructions apart, as in `run`.
- Precise state on fault, trap and hand-back: registers are written back at
  the single exit, and `run` continues from op k of the named member (a
  guest member is named like any other).
- A member runs only while it is the decode it was compiled from and valid
  under the current fill of its own page, checked at every branch into it.
  Nothing in compiled code changes the exec TLB, so the check holds until
  the module returns. Flushes, `kw_set_pgd`, FENCE.I, SMC, remaps and
  unmaps of either page of a two-page region stop exactly the branches
  into that page.
- SMC: compiled stores into code pages miss the write TLB and hand back.
  The interpreter's store retires the generations, and any later member
  branch fails its check.
- Flushes, `kw_set_pgd` and FENCE.I only retire generations. Revalidated
  members keep their code, and the tests check that nothing is recompiled.

### JIT on several harts (SMP)

An SMP kernel (kernel.md, SMP) runs one instance of the module per CPU, in
its own thread, on one shared memory. The JIT is per CPU:

- **Per-CPU code.** Each CPU has its own `struct kw_cpu` (block cache,
  TLBs, slot pool, emit buffer) and its own instance with its own
  `__indirect_function_table`; `kw_cpu_init` on that CPU asks that CPU's
  host for the caps, and `kw_host_jit_compile`/`free` act on that table.
  A `kw_cpu` is used only by its own CPU (the kernel's `wasm_kw_cpu` is the
  running CPU's, and a task that moves starts afresh on the new CPU), so
  a slot or module of one CPU is never reachable from another. A task
  that moves finds a cold cache there and compiles again what is hot.
  Sharing modules between CPUs is not built: it would need a module to
  be instantiated in every CPU's thread (a `WebAssembly.Module` can be
  posted, an instance cannot), a slot installed in every table before
  any CPU enters it, and a free that waits until no CPU runs the module,
  for a gain only where several CPUs run the same hot code.
- **Interrupts.** Compiled code polls the `irqp` it is called with, which
  `enter` takes from the CPU's own `irq_pending` at every call (nothing
  is baked into a module), at every self-loop back edge and member
  entry, as on one hart. With a shared memory (caps bit 3) the load is
  `i32.atomic.load`: a plain load in a loop that stores nothing may be
  hoisted, and another CPU's IPI (a TLB shootdown waits for the answer)
  would then never be seen. Nothing in compiled code waits for another
  CPU.
- **Compiles do not hold up TLB flushes.** A compile (gathering the
  region, emitting the module, the host's `new WebAssembly.Module`,
  `new Instance`, V8's first-call compile and `table.set`) takes 0.1 to
  0.4 ms of host time, up to a few ms, and the CPU polls no interrupt in
  it. kwemu marks it (ABI 8, kw_emu.h "Flushes during a JIT compile"):
  `jit_busy` in `struct kw_cpu` is 1 from before the region is gathered
  (`windowOpen`) until after the host returns (`windowClose`), and
  nothing in between runs guest code, reads guest memory or walks a page
  table (only `kw_cpu`: decoded ops, exec-TLB generations, the emit
  buffer, the slot tables). A flush (tlb.c `kw_flush_later()`) that
  finds a target busy sets its `flush_all`, `smp_mb()`, and skips it if
  it still reads `jit_busy` (acquire; kwemu's `jit_busy = 1` is a
  seq_cst store, so the user stores made before are visible to the
  flusher, as `csd_unlock()` would make them). kwemu stores 0, then takes
  `flush_all` with an atomic exchange: either the flusher sees the window
  closed and waits as before, or kwemu sees the mark, flushes everything
  (a range flush becomes a full one there) and `run` looks the block up
  again before it runs anything (`Go.again`, also after a grow): the
  flusher may have returned and unmapped or remapped it. V8 compiles a
  wasm function at its first call, which would otherwise come from `run`
  after the window: every module starts with `if (cpu == 0) return 0`,
  and the host calls `f(0, 0, 0, 0)` inside the import (`flags` bit 0),
  so that compile is in the window too. Before it gathers, kwemu looks at
  its irq word: an interrupt already pending (an IPI sent just before the
  window, whose sender now waits) is taken first, and the block compiles
  at its next pass. The 20 ms yield to the host (below) is skipped by
  flushes the same way (kernel.md, SMP, MM). Still waited for: an IPI
  raised in the ~1-2 µs between a flusher's read of `jit_busy` (0) and
  its IPI, if the window opens in between (most of the 50-500 µs waits
  left under constant compiling); IPIs that are not TLB flushes
  (`membarrier()`, other `smp_call_function()` users); a reschedule IPI
  (a wakeup onto the compiling CPU starts after the compile); frees
  (`table.set`, a few µs, outside the window). Measured: Numbers, Compile
  stalls.
- **Flushes** retire generations on each CPU, as on one hart: the kernel
  sends `flush_tlb_*()` to every CPU that has the mm loaded and waits,
  marks a CPU in lazy TLB mode (or yielding to its host) stale (it
  flushes everything when it takes the mm again, before any user code),
  does the same for a CPU that is compiling (below), and
  `riscv_flush_icache` (with any flags) flushes every CPU and waits for
  all but those. A flushed CPU revalidates
  each block before it runs it again (same pc, host address and raw
  bits), and a block that was rewritten or moved to another page is
  decoded again and its code freed (`drop`).
- **Code changed by another hart** (its stores or `cbo.zero`) is seen by
  a hart after that hart's FENCE.I, after
  `riscv_flush_icache()` (any flags: it flushes every CPU and returns
  only when each has flushed or will before it runs user code), and after any unmap, remap or permission change
  of the page (the shootdown completes before the call returns), as on
  RISC-V hardware with Linux; until then the hart may keep running the
  old instructions, decoded or compiled. That is what Linux on hardware
  promises, so cross-modifying guests already call it: musl's and
  glibc's `__riscv_flush_icache()` and the compilers'
  `__builtin___clear_cache()` are that system call (JITs in the guest
  were not checked one by one; kwtest's `jit:` rewrite check is the
  test). `SYS_RISCV_FLUSH_ICACHE_LOCAL` is treated as a global flush,
  which is stronger than Linux. Stores into decoded code on the same
  hart are still seen at the next instruction. Safety holds regardless of timing: decoded blocks
  and compiled code hold no host addresses (compiled code reaches guest
  memory only through this CPU's data TLB, filled from the current page
  table), so stale code only runs old guest instructions with current
  translations. Each instruction is decoded from one load of its bits
  (a 32-bit instruction in a page is one aligned load), so a rewrite of
  an aligned instruction is seen whole (Ziccif) and a block may mix old
  and new instructions only at instruction boundaries.
- **Atomics.** AMOs, LR/SC, FENCE, FENCE.TSO and PAUSE (all `generic` in
  an atomics build) and `cbo.*` are handed back to the interpreter, which
  does them atomically (above); no fusion, region or helper emits any of
  them, and the reservation lives in the CPU's `Hart` (cleared at every
  switch by the kernel), never in compiled code. wrs.nto/wrs.sto stay
  no-ops (the spec lets them return at once). Every guest load or store
  is one wasm load or store of its width (`i32.store8`, `i64.store`,
  ...); a misaligned one inside a page is one unaligned access (RVWMO
  does not make misaligned accesses atomic), and one that straddles a
  page is handed back. No `memory.copy` or `memory.fill` is emitted.
- **Task switches.** Compiled code writes registers, FP registers and
  `fcsr` back at its single exit and returns to `run` before the kernel
  can run, so a task's state is in `kw_regs` whenever it can be switched
  out or moved; `jit.cur` is scratch for one call.
- **Host.** Each CPU's thread has its own `JitHost` (js.md, CPU
  threads), whose counters CPU 0's host reads; it yields to its event
  loop every 20 ms of user code, without which V8 never finished
  collecting freed modules there.

### Host contract

These imports exist only with `-Dkwemu-jit`. The kernel host is
`js/core/jit.ts`, and the test host is `test/kwemu-jit-host.mjs`.

| Import | |
| --- | --- |
| `kw_host_jit_caps() -> u32` | bit 0 = JIT available (0: never compile), bit 1 = 32-bit memory (lowered kernel: the code imports a 32-bit `env.memory` and wraps addresses), bit 2 = eager, bit 3 = shared memory (the code declares its `env.memory` import shared, with a maximum of 65536 pages for memory32 and 262144 for memory64, and reads `*irqp` with `i32.atomic.load`; the host sets it when the kernel's memory is a SharedArrayBuffer). Called once, from `kw_cpu_init`, by each CPU on its own host. |
| `kw_host_jit_compile(ptr, len, slot, flags) -> i32` | Compile the module at `ptr` (it imports `env.memory` and exports `f`) synchronously with `new WebAssembly.Module` and `table.set` its `f` into `slot` (a BigInt index for table64). 0 = installed, < 0 = failed (slot untouched, and that block is never compiled). `flags` bit 0 (ABI 8; older kwemu passes no `flags`): `f` called with `cpu` = 0 returns 0 at once (every module starts with that test), and `jit.ts` calls `f(0, 0, 0, 0)` once so that V8 compiles it there, inside kwemu's compile window (JIT on several harts). |
| `kw_host_jit_free(slot)` | Put back the stub that was there before the first compile, and drop the module. |

kwemu's 1024 stubs are the last 1024 entries of the kernel's exported
`__indirect_function_table`, distinct in `vmlinux` and after the Binaryen
lowering. Check that again if you change link flags or Binaryen passes.
`jit.ts` installs only into existing non-null slots, restores only slots it
installed, never throws into the kernel, and counts compiles, frees,
failures, bytes and time (`stats().jit`, CLI `--stats`, page
`KW.jitStats()`).

**Collecting freed modules.** Engines collect a freed module only when
their GC runs, and a module costs more memory than the GC is told about.
JavaScriptCore counts the kernel's wasm memory in its heap size, so with
512 MiB of RAM it waits for about 3 GB of further allocation before
collecting. V8 in Chromium collects for an allocation only about as large
as the external memory it already holds (which includes the kernel's
memory); Node collects for 64 MiB at any memory size. So `jit.ts` tracks
modules with a FinalizationRegistry. While 256 or more freed modules are
uncollected (`RETAINED_NUDGE`), it allocates and detaches an ArrayBuffer
on every compile (not on a free: a free is outside kwemu's compile window,
and an allocation there can start a collection that delays the CPU's
answer to an IPI). The nudge starts at 64 MiB, doubles up to
4 GiB whenever nudges have seen no collection for 250 ms, and halves when
an allocation fails. At 2048 uncollected (`RETAINED_LIMIT`) it refuses
compiles, and kwemu interprets those blocks. Measured 2026-11-13: a
14,000-module WebKit session stays at most ~620 uncollected with no
refusals but grows by about 50 MiB (unexplained); a Chromium page that
only compiles and frees stays below 700. With a 2 GiB memory Chromium
refuses a large enough nudge, so such a page can still refuse compiles
for a few seconds until V8 collects on its own. Counters: `collected`,
`retained`, `maxRetained`, `gcNudges`, `refused`.

**Compile cost, and why it stays on the kernel's thread** (2026-11-14,
1644 real modules from an Alpine boot and two `npx --version`, 6.5 KiB on
average, mean µs per module):

| engine | `new Module` | `new Instance` | `table.set` | first call | later calls |
| --- | ---: | ---: | ---: | ---: | ---: |
| Node 24.22.1 | 60 | 12 | 0.7 | 167 | 0.6 |
| Chromium 151 (headless shell 1234) | 80 | 12 | 1 | 261 | 0.8 |
| WebKit 2388 (Safari 27.2) | 145 | 9 | 0.6 | 2 | 0.6 |

V8 compiles lazily: `new Module` only decodes and validates (about 55 µs
fixed + 6 µs/KiB), and the first call compiles with Liftoff on the
calling thread (16 µs + 30 µs/KiB). `WebAssembly.compile` or a worker that
posts the Module leaves that first-call compile where it was; only a
worker that also instantiates on a dummy memory and calls `f` once moves
it. `jit.ts` makes that first call itself, inside `kw_host_jit_compile`
(`f(0, 0, 0, 0)` returns at once), so it is in kwemu's compile window
(JIT on several harts) and counted in `compileMs`; the table's first-call
column is from before that. JavaScriptCore compiles in the constructor
(there the extra call costs only the call). TurboFan tier-up already
runs on background threads. Even if compiling were free and instant, the
shell rows of Numbers would gain 2.4% in sum and `npx --version` 4.5%, and
lower thresholds still would not win; an asynchronous install could also
happen only at the browser's 20 ms yields, leaving a hot block interpreted
that long instead of the ~0.25 ms compiling takes (Rejected designs).

## Tests

- `zig build test`: unit tests natively (interpreter) and as wasm64 with an
  eager JIT host under Bun (`BUN_JSC_useWasmMemory64=1`, set by `build.zig`)
  that checks every compile goes into a free slot and
  nothing stays installed. Then every guest in five modes: native, wasm64,
  wasm64 + JIT (eager and at the default threshold), and the JIT harness
  lowered to memory32. Each JIT mode must retire exactly as many
  instructions as the interpreter.
- F/D tests run each translated FP form (303 forms, both precisions, every
  rounding mode) over edge-case operands and compare result bits and flags
  per operation, interpreter vs JIT. A randomized differential test runs
  4096 operand sets per form. `zig build test -Dkwemu-fp-fuzz=1000000`
  runs a million per form (about 1:15 min). Run it after any change to the
  FP translation.
- `kwemu jit fuzz`: random control-flow graphs over two code pages
  (branches, cross-page jal, jalr through jump tables, calls, loops,
  ecalls, IRQs, lazily mapped pages, guest and kernel code rewrites on
  either page, F/D and every extension's ops mixed in, `fcsr` changes), run
  on an interpreter machine and a JIT machine with the same random budgets,
  flushes, thresholds, region sizes and growth thresholds, comparing every
  slice (event, pc, `icount`, budget, x and f registers, `fcsr`). Between
  slices the "kernel" also flushes the second page alone, moves either
  page to a copy (sometimes with the rewrite: COW), or unmaps it until the
  next fault on it, so a region whose members span both pages sees one
  page change while the other stays valid. 24 seeds run in `zig build
  test`. `zig build fuzz -- N [SEED]` runs more: `-- 20000 100000` takes
  about 5 minutes. Run a long one after any change to regions, budget, IRQ
  polling, invalidation, or how FP state crosses block boundaries.
- `kwemu jit regions: jalr into members`: an indirect call whose target
  alternates, a leaf returning to two sites, all as members of one module
  (grown) or of separate ones; a guest store into a member, a kernel
  rewrite of another, unmapping their page, each against the interpreter.
  The `jalrtest` guest does the same in C (tables, a rebound "GOT" slot, a
  jump table, recursion, code in an mmap'ed page rewritten in place,
  through W^X mprotect, after munmap + mmap, and by its caller), with a
  digest checked against `qemu-riscv64-static`.
- `kwemu jit regions across pages`: a call from one page into another and
  the return, as home members and as guests (grown along exits); then
  flushing either page or `kw_set_pgd` (nothing recompiled), a kernel
  rewrite of the second page, a COW copy of it with a change, and
  unmapping it (exact fault), each against the interpreter.
- Mutation checks: charging one instruction too few, skipping the IRQ poll
  or the member checks (op identity, generation on the same or another
  page), not naming the hand-back member, dropping the `fcsr` write-back,
  testing `frm` per module, making guests home members and most FP
  emission mutations are caught. Two FP mutations survive (both relax a
  guard stricter than needed). Dropping the checked entry's op or
  generation test is caught (also by `jalrtest`). Not updating l_g after
  a branch into another page is caught by nothing (it only sends more
  checks to the exec-TLB set, costing speed).
- Per extension, in `kwemu_test.zig` (`kwemu isa`, `aes`, `bitmanip`,
  `zb`, `rva23`, `zfa`, `zfhmin`, `zihpm`, and `kwemu jit: ... on random
  operands`): known vectors (FIPS-197, SP 800-38D GHASH, AES-GCM test
  case 2), spec-loop references (`refClmul`, `refClz`, ...) on random and
  edge operands, the encodings and gates under every relevant enable mask
  with the neighbours that stay illegal, inline and helper paths with x0
  and rd = rs operands, JIT against interpreter against reference with
  exact instret. `kwemu isa` checks that every probe traps with the exact
  pc, `insn` and `icount` when its extension is off and that `kw_set_isa`
  drops decoded code; the hints leave registers unchanged.
- Per extension, a guest built with the extension (`aestest`, `bktest`,
  `zbtest`, `rvatest`, `zfatest`, `zfhtest`): each instruction against a
  portable C model over tens of thousands of random operands in loops
  that compile, plus what clang emits for plain C with the extension
  (musl is built with it too). Each prints a digest that
  `test/kwemu-test.mjs` checks against the value `qemu-riscv64-static -cpu
  rv64,<ext>=true,...` prints.
- `kwemu jit: a flush asked for during a compile`: the test host
  (`kwemu-jit-host.mjs`) calls the unit tests' `kwemu_test_compile_hook`
  export inside every compile; there "another CPU" checks `jit_busy`,
  maps another page at the block's address and sets `flush_all`, and the
  new code must run, not the old; an interrupt raised there is taken
  where the interpreter takes it. The fuzz asks for such a flush in every
  other compile (results must not change). The host also checks that
  every module's `f(0, 0, 0, 0)` returns 0 and that `flags` bit 0 is set.
- `kwemu jit: compile threshold counts self-loop passes that an interrupt
  ends`: a self-loop that rings its own doorbell every 64 passes must be
  compiled after the threshold's worth of passes (dropping `loopDone` on
  the interrupt path is caught).
- In the kernel: kwtest's JIT and ISA checks (kernel.md), on an SMP
  kernel its `jit:` checks (compiled loops on every CPU, stores beside
  atomics, moves, code changed by another CPU), kwbench `--stats`, and
  Alpine outputs compared with `--no-jit`. With a `-Dkwemu-stats` SMP
  kernel the CLI's `--stats` prints kwemu's counters per CPU.

## Numbers

i7-10700K, Node 24.22. Single runs on a busy machine vary by up to 20%,
and the first command after boot varies most (V8 is still optimising the
kernel), so compare interleaved medians only and give machine, date and
command with any number.

**Harness and kwbench** (2026-11-13, before central dispatch, which moved
the interpreted wasm64 columns by -7% to +16% and native by 5-18%; the
JIT column did not change). `node test/kwemu-bench.mjs zig-out --jit
--median --reps 5`, guest MIPS:

| benchmark | native interp | wasm64 interp | wasm64 + JIT |
| --- | ---: | ---: | ---: |
| sieve+fib (`guest/bench.zig`) | 775 | 379 | 1830-1925 |
| mem (RMW + memcpy, 8 MiB) | 851 | 364 | 1704 |
| fib (recursive) | 657 | 346 | 1405-1485 |
| fp (dgemm + nbody) | 267 | 181 | 506-533 |
| sha (sha256) | 1148 | 456 | 4026 |
| interp (bytecode VM) | 566 | 316 | 1651 |

The memory32-lowered JIT harness runs about as fast as the wasm64 one.
Building the tier in costs the interpreter 1-10% when nothing is compiled,
and about 5-7% on kernel syscall round trips. In the kernel (lowered,
kwbench, median of 5): int loop 3902 MIPS (about 274 with `--no-jit`),
mem loop 1917 MB/s (about 427), fp loop 54.8 Miter/s (about 15), getppid
0.12 µs, clock_gettime 311 ns, fork+exit+wait 0.12 ms.

**Alpine, timed in the guest** (2026-11-13, lowered kernel, medians of 5
interleaved boots, before central dispatch; outputs identical with and
without the JIT and on both builds; the `--no-jit` column is from an
earlier run of 3):

| command | JIT | wasm64 JIT | `--no-jit` |
| --- | ---: | ---: | ---: |
| ash loop, 30000 iterations | 2.60 s | 2.76 s | 4.64 s |
| `seq 30000 \| sort -rn \| md5sum` | 3.17 s | 3.81 s | 11.77 s |
| `md5sum` busybox × 8 | 0.17 s | 0.16 s | 0.33 s |
| 200 × fork + exec `/bin/true` | 0.35 s | 0.38 s | 0.38 s |
| `tar cf - /lib \| gzip -6 \| md5sum` | 0.41 s | 0.47 s | 0.71 s |
| `sha256sum` × 2 + `sha512sum` | 0.08 s | 0.09 s | 0.46 s |
| `awk` sqrt loop, 200000 iterations | 2.62 s | 3.47 s | 10.72 s |
| `seq 100000 \| awk` (sum of sqrt) | 3.51 s | 4.27 s | 9.77 s |
| `yes \| head -c 20000000 \| md5sum` | 3.64 s | 4.51 s | 9.91 s |

The ash loop is noisy from boot to boot (2.3-4.6 s; the share of compiled
instructions varies between 66% and 88% with the addresses ASLR picks).
Exits from compiled code to `run` (`-Dkwemu-stats`, one boot each):
`yes | md5sum` 79M (331M branches between members, 228M of them into
another page), `awk` loop 50M, `sort` 51M, ash 33M, `tar | gzip` 11M.

**`sort -rn` scales as n log n** (2026-11-13): 3000 / 30000 lines take
0.88 / 11.06 s with `--no-jit`, 0.28 / 2.71 s with the JIT (12.6x, n log
n predicts 12.9x). The cost is busybox's numeric comparison of both keys
at every compare (plain `sort` is 4-7x faster), nothing on the kernel or
emulator side.

**Where the time goes.** Of the exits that remain, most leave regions
that are full (16 members) or closed (cut to fit the 16 KiB buffer):
ash 17M of 21M, `md5sum`'s rounds (big straight-line blocks) nearly all of
them. Self-loop modules are the other big group (`sort` 22M exits into
one). The emulated f64 FMA is the most expensive compiled op (about 40
f64 operations, much less when the product is exact). AMOs and LR/SC
still go through `generic`.

**apk startup and jalr** (2026-11-15, Node 24.22.1, 16-core host;
`apk --no-network info tree` after `apk update`, apk-tools 3.0.9; counts
from one stats boot with ASLR off, times medians of 15 runs over 5
interleaved boots). 967M guest instructions, ~90% compiled, 2.84 s. Per
run: 42.9M entries into compiled code. Dynamic jalr (QEMU trace): 12.7M
returns, 8.1M PLT `jalr t1`, 2.6M indirect calls; 13.1M of them leave
compiled code (ret 7.2M, PLT 4.7M, indirect calls and jumps 1.2M). The
other exits: region side exits 13.7M (8.2M of them into a self-loop
module, e.g. `apk_blob_cspn`'s byte loop and zlib's inflate loop, each
left and re-entered once per outer iteration), side exits of self-loops
6.2M, direct 5.3M, hand-backs 4.5M. jalr exits are
concentrated: 185 return sites, 84% of a site's exits to one target, PLT
exits all monomorphic. 11M of the jalr exits leave full (16-member)
regions; the targets are almost all compiled in another region, so only
growth could bring them in. Against inline checks per branch site,
checked entries need 286 instead of 862 KiB of module bytes for the
checks per run (member code is 26% bigger), cut 26 instead of 54 regions
to fit the buffer, and have 42.9M instead of 46.9M entries and 13.1M
instead of 15.6M jalr exits, in the same time (2.84 vs 2.84 s,
`main`-only 0.68 vs 0.67 s; ash loop 2.26 vs 2.52 s, `md5sum` × 8 0.14 vs
0.15 s, `sort` 2.76 vs 2.74 s; harness table within 2%). An exit costs
only ~11 ns more than a branch between members
(harness micro-benchmark of a call and an indirect call across pages,
regions off vs on), so 2.5M fewer exits are worth ~30 ms, below the noise.

**Node startup** (2026-11-14). `npx --version` (Alpine node 24.22.3,
npm 11.12.1) is interpreter-bound: ~640M guest instructions, `run` +
`decodeBlock` ~83% of host CPU, kernel C <2%. It takes ~3.7-3.9 s, and the
JIT does not beat `--no-jit`.
- Arena: 34-40 resets per npx run; ~55% of hot compiles recompile a pc
  compiled before a reset (690K block decodes, 116K distinct blocks:
  node's working set is ~6x the arena). Block-table conflict evictions
  are ~24% of decodes but hit cold blocks (widening the table: ≤3%).
- Per-module host cost: 70 µs fixed + 30.5 µs/KiB. Merging 16 modules
  saves 13%; trimming the unused locals (114 declared, ~21 used) would
  save 17%. Compiled code runs ~6 ns/insn (mostly Liftoff) against ~12 ns
  interpreted on cold code (~4 ns on a tight loop).
- Threshold: a fixed 2^19 gives npx parity with `--no-jit` but hurts
  everything else (Rejected designs). An adaptive scheme (double the
  threshold up to 2^19 while resets come less than 2^25 instructions
  apart, back to 2^17 after a quiet epoch) gave npx parity and kept 2^17
  elsewhere in a prototype. A self-loop threshold changed nothing.
- Host V8 tiering is not the cause: `run` is in TurboFan normally
  (`--liftoff-only` makes npx 5.96 to 9.22 s); dynamic-tiering flags
  change nothing (`--no-wasm-tier-up` is a no-op without `--liftoff`).
- Guest side: Alpine's node has no builtin code cache
  (`node_use_node_code_cache: false`; `compileForInternalLoader` is 16% of
  npx), and `NODE_COMPILE_CACHE` gave nothing. `--jitless
  --single-threaded` makes npx 16% faster but a CPU-bound loop 35% slower,
  so it is no NODE_OPTIONS default. `--max-lazy` and `--no-maglev` are
  slower.
- Method: strace and gdb hang (no regsets) and there are no perf events.
  `kernel/build.sh stats` builds a `-Dkwemu-stats` bundle; the CLI's
  `--stats` prints its counters for the whole run at exit
  (`JitHost.kwemuStats()`, `stats().kwemu`). For a window inside a run, a
  host driver calls the exported `kw_debug_stats` at markers the guest
  prints. Either finds the cpu through the stats-only export
  `kw_debug_cpu_of_jit_buf(ptr)`, where `ptr` is what
  `kw_host_jit_compile` receives; `icount` is at offset 32.

**Guest HTTPS** (2026-11-14). curl from a local server gets 30-32 MB/s
(AES-GCM; ChaCha20 25.6), plain HTTP into the guest 220-290 MB/s: TLS
crypto in user space is the limit (guest CPU 98% busy). Host `node
--cpu-prof` of 3 × 100 MiB TLS 1.3 AES-256-GCM downloads, guest PCs
mapped to libraries: ~35% OpenSSL `rv64i_zkne_encrypt` (its round
self-loop is its own 818-byte module: 16 table loads and 12 `i32.rotl`
per round, 2 round-key loads with TLB checks; the generic GCM code calls
it once per 16-byte block); 13% `kwemu.run` + 2.5% `jit.enter`/`noteHot`;
17.6% Zbc GHASH (192 inlined `i64.mul` per module); 8.4% musl
`memmove`'s forward byte loop; 4.5% NetStack JS; under 1% kernel C. kTLS
does not help (kernel.md).

Follow-up (2026-11-14, same machine, medians of 5 interleaved boots):
- `memmove` caller (LD_PRELOAD shim in the guest): libssl's
  `tls_default_read_n` (`memmove(pkt, rl->packet, len + left)`), which
  moves the bytes read ahead to the buffer start after each record batch.
  The distance is one TLS record (16406 bytes, 6 mod 8), so it always takes
  the byte loop: 116 of 120 MB moved per 100 MiB download. curl hard-codes
  `SSL_CTX_set_read_ahead(1)` and a 64 KiB read buffer, and neither curl
  options nor openssl.cnf turn that off, so only a faster byte-copy loop
  in the JIT can help.
- Per AES block (stats build): curl (GCM) 2.3-2.4 entries into compiled
  code, about 1 of them into the round self-loop, 93.6-97.5% of
  instructions compiled; `openssl speed` aes-256-gcm 2.7 entries, 98.8%;
  aes-256-ctr 4.0-4.1 entries (2 self-loops per block: the AES rounds and
  `ctr128_inc`), 98.7-99.5%. Hand-backs are negligible. The interpreted
  rest of curl is mostly blocks counting down again after an arena reset.
- `TLS_AES_128_GCM_SHA256` instead of the default AES-256-GCM: curl 34.3
  vs 31.7 MB/s (+8%), `openssl speed` 52.9 vs 46.6 MB/s; ChaCha20-Poly1305
  29.5 MB/s. Not changed in the image (a policy decision).

**OpenSSL with the crypto extensions** (2026-11-13, Node 24.22.1, Alpine's
`openssl` 3.5.9, `openssl speed -evp ALG -bytes 8192 -seconds 3`, MB/s,
medians of 5 interleaved boots; "masked" = the same kernel with the
extensions turned off by `kw.isa=`):

| ALG | default | masked | masked set |
| --- | ---: | ---: | --- |
| aes-128-ctr | 63.6 | 33.4 | `-zkne,-zknd` |
| aes-256-cbc | 77.0 | 34.9 | `-zkne,-zknd` |
| aes-128-gcm | 51.7 | 35.7 | `-zbc,-zbkb,-zbkc,-zbkx` |
| aes-256-gcm | 46.6 | 31.8 | `-zbc,-zbkb,-zbkc,-zbkx` |

Zkn is 1.9-2.2x OpenSSL's generic C AES on 8 KiB; Zbc took GHASH from
about 80 to about 280 MB/s, so AES-CTR is now the larger part of GCM.
16-byte calls barely move (OpenSSL's per-call EVP work dominates).
SHA-256 and ChaCha20 do not change, and B (Zba/Zbb/Zbs/Zicond) does not
slow OpenSSL down. Outputs of `openssl enc`, `dgst`, GMAC and 720 AES-GCM
EVP cases matched with and without the masks, with `--no-jit` and against
the host.

**B extension** (2026-11-13, JIT harness, medians of 7, guests built for
rv64gc and rv64gc+zba+zbb+zbs+zicond): kbench sha -23% instructions /
-13% time, interp -22% / -5%, an LZ77/CRC/sieve/sort program -10% / -19%,
mem and fp flat. Interpreted, `shadd` costs more than `add`, so
dispatch-bound loops can get slightly slower with fewer instructions.
Alpine's node with `--riscv-b-extension`: an integer JS benchmark -6.5%
(clz/popcount/min/max loop -26%).

**SMP with the JIT** (2026-11-16, Node 24.22.1, 16-core host, lowered
kernels; kernel.md, SMP). kwbench and an Alpine shell per config in a
random order per round, 12 rounds, medians [IQR]; "UP" is the UP build,
"SMP 1" the SMP build on one CPU:

| metric | UP | SMP 1 | SMP 2 | SMP 4 |
| --- | ---: | ---: | ---: | ---: |
| int loop, MIPS | 4087 [4020-4120] | 4002 [3980-4030] | 4006 [3950-4020] | 4016 [3980-4060] |
| mem loop, MB/s | 2382 [2300-2430] | 2204 [2120-2220] | 2135 [2090-2170] | 2185 [2130-2210] |
| fp loop, Miter/s | 55.4 [55.1-55.6] | 55.3 [53.9-55.4] | 55.0 [54.6-55.2] | 55.2 [55.0-55.3] |
| getppid, µs | 0.13 | 0.13 | 0.13 | 0.13 |
| clock_gettime, ns | 349 [338-374] | 416 [403-425] | 436 [429-451] | 439 [423-449] |
| fork+exit+wait, ms | 0.13 | 0.19 | 0.23 | 0.25 |
| spin loop, 1 thread, s | 1.097 | 1.159 | 1.157 | 1.151 |
| spin loop, N threads (N = CPUs), s | | | 1.161 | 1.173 |
| `kwjob 1`, s | 13.42 | 13.84 | 13.96 | 13.47 |
| `kwjob N` (N = CPUs), s | | | 14.38 | 14.15 |

Compiled code costs the same on every CPU count (int and fp within the
IQRs; mem -7% on the SMP build, from its atomics). The kernel-side costs
(clock, fork) are the SMP build's, as with the interpreter (kernel.md,
Costs). Parallel compiled loops scale linearly: N threads of the spin loop
(`kwpar`, 400M iterations each) take as long as one, 1.99x on 2 CPUs and
3.93x on 4. `kwjob N` (N parallel copies of gzip -6, bzip2 -1 and an awk
sqrt loop over an 8 MiB tar, digests identical in every run and with
`--no-jit`) is 1.94x on 2 CPUs and 3.81x on 4. kwtest's compiled parts
on CPU 1 (a `-Dkwemu-stats` kernel): 1.05 G instructions, 84% compiled
(CPU 0 88%).

- **IPI answers** (`kwipi`, scratch tool in `vendor/smp-deferred/tools`:
  CPU 0 mprotects a touched page of the mm back and forth for 15 s, each
  call a shootdown that waits for CPU 1): with CPU 1 in a compiled
  self-loop the call takes p50 1.8 µs, p99 3.3, p99.99 74 (interpreted
  2.0 / 3.8 / 210; CPU 1 making getppid calls 1.9 / 3.8 / 64; CPU 1 idle
  and not waited for, lazy TLB, 1.3 / 2.4 / 60). Single calls of about
  1 ms in every mode are the host's scheduling.
- **Compile stalls** (2026-11-17, Node 24.22.1, 16-core host shared with
  other builds, load average 4-7 unless said; lowered kernels; "before"
  is the tree without the compile window, kernel and host; JIT on several
  harts describes the design). Where the time goes, from a host trace of
  CPU 1 compiling all the time (kwipi `churn`: 8192 generated functions
  called in turn, each just past the threshold): `new Module` 0.10 ms,
  `new Instance` 0.02, V8's first-call compile 0.27 (p99 0.7), `table.set`
  3 µs, a free 1.4 µs (up to 0.4 ms when it nudged the collector), and
  kwemu's own gathering and emitting about as much again before the host
  call. The 20 ms yield took a median 32 µs but up to 19 ms (V8's
  finalizers and collections of freed modules); every shootdown that
  waited over 1 ms overlapped such a yield. kwipi `churn` on 2 CPUs,
  20 s, 4 interleaved boots each, medians (time of one `mprotect()` that
  shoots down CPU 1's TLB):

  | | before | after | after, no first call in the host | window, but flushes still wait |
  | --- | ---: | ---: | ---: | ---: |
  | mprotects in 20 s | 5.53 M | 7.07 M | 6.29 M | 5.04 M |
  | p50 / p99, µs | 2.0 / 5.1 | 2.0 / 4.1 | 2.2 / 5.4 | 2.3 / 6.4 |
  | p99.9 / p99.99, µs | 130 / 350 | 13 / 230 | 47 / 220 | 120 / 330 |
  | max, ms | 20.0 | 3.9 | 16.5 | 20.5 |
  | calls over 1 ms | 194 | 3 | 5 | 193 |

  (the last two columns come from a kernel with a switch for the skip and
  counters; in the third, 9.5% of the CPUs to answer were skipped as
  compiling and 4.5% as yielding). Beside 16 host spinners (load 15-17, 2 boots
  each): p99.9 310 to 130 µs, max 52 to 22 ms, calls over 1 ms 1561 to
  970, 2.47 M to 3.51 M mprotects. Kwipi's `spin` mode (no compiles)
  is unchanged (p99.9 11 µs, max 0.5-0.7 ms). Real workloads compile far
  less: the node set below (3 × `node -e`, `npx --version`, a CPU loop and
  4 worker threads; Alpine's node 24.22.3) compiles about 3600 modules
  and makes about 12,800 shootdowns on 2 CPUs (10,500 CPUs to answer, of
  which 1-2% were compiling); the time flushes spent waiting fell from
  145 to 18 ms on 2 CPUs and from 206 to 46 ms on 4, and the longest wait
  from 14.7 to 0.8 ms (2 CPUs).
- **Cost of the window** (same dates and host, interleaved medians).
  Compile counts are unchanged; `compileMs` rises about 2.6x because it
  now holds V8's first-call compile, which was spent in the first call
  before. kwbench (5 boots): within its noise on UP and 2 CPUs (int loop
  3897 vs 3588 MIPS UP, 3845 vs 3798 on 2 CPUs; mem and fp within 2%).
  JIT harness (`kwemu-bench.mjs --jit`, 2 alternating runs of median-of-5):
  sieve+fib 2127-2149 vs 2076-2123 MIPS, fib 1451-1474 vs 1407-1431,
  interp 1649-1677 vs 1671-1697, the rest within 1%: the `cpu == 0` test
  at every entry costs nothing measurable. Shell set (5 boots, seconds,
  before → after): UP ash 1.96 → 1.94, sort 3.01 → 2.88, md5 0.102 →
  0.106, awk 2.10 → 2.10, `yes` 4.50 → 4.61; 2 CPUs ash 1.95 → 2.17
  (noisy, as on one hart), sort 2.98 → 2.84, awk 2.48 → 2.30. Node set
  (4 boots): the sum of the six medians 22.28 → 22.39 s on UP, 17.04 →
  17.17 s on 2 CPUs, 14.23 → 14.10 s on 4 (`npx --version` 4.19 → 4.14 s
  on 2 CPUs). kwpar on 2 and 4 CPUs (400M iterations per thread): 1.15
  → 1.16 s for one thread, 1.18 → 1.17 s (2) and 1.19 → 1.20 s (4) for one
  per CPU. kwstorm + kwmmstress (120 s) and kwtlb (60 s) on 4 CPUs with
  the JIT: no errors, and each secondary still collects what it frees
  (about 1500-1750 compiles per CPU, at most 2 uncollected at the end).
- **Host memory** (peak RSS of the CLI process after `kwjob N` on N CPUs,
  JIT vs `--no-jit`): 1 CPU 244 vs 193 MiB, 2 CPUs 365 vs 300, 4 CPUs 457
  vs 394. A CPU's thread costs about 100 MiB with or without the JIT;
  per-CPU modules add little, since each CPU keeps at most 1024.

**Sizes** (2026-11-14). `kwemu.o` is about 363 KB with the JIT. Every op
kind adds dispatch code, extension helpers are inlined into the op
handlers and `core.exec`, so share kinds where a variant in `imm` needs
no branch. The largest test module is 15,227 bytes (an FP region cut to
fit).

## Rejected designs

Measured under V8 (Node 24). Do not retry these without a new reason.

| Idea | Result |
| --- | --- |
| Threaded dispatch (`continue :sw` per handler) | a `br_table` per handler, `kwemu.run` 7x larger, `kwemu.o` 528 vs 363 KB; `npx --version` 6.14 vs 3.66 s with `--no-jit` |
| Tail-call dispatch (`-Dkwemu-tail-call`, `return_call_indirect` chain) | about 2x slower (138 vs 252 MIPS) |
| Fusing common op pairs (top 32 of `npx`) | no gain (3.65 vs 3.66 s) |
| Multiplicative block-set hash | fixes collisions, but costs the interpreter 3-7% |
| ReleaseSmall for libkwemu | about 5% slower than ReleaseFast |
| Calling the next compiled block from compiled code (`call_indirect`) | almost no gain: each hop still writes back and reloads registers |
| Re-entering the next compiled block straight from `run` | no gain on top of regions |
| Region "light entry" (load only the entered member's registers) | slower everywhere (ash 2.55 to 3.51 s) |
| Self-loops as region members | much slower (sieve+fib 1150 vs 1880 MIPS) |
| FMA helpers decided per module | every FMA of an FP region became a call (kbench fp 457 vs ~500 MIPS) |
| Caching modules by content | only 4% of modules repeat |
| Growing regions with a fixed threshold (64-1024 exits per target) | `yes` 30-35% faster, ash 4-9% slower, `md5sum` × 8 +40% (each grow recompiles the whole region) |
| Growing towards targets on the region's own page | ash 2.81 vs 2.65 s |
| Cutting a grown region to fit the buffer | dropped members ran interpreted again: ash compiled 50% instead of 88% |
| Growing only regions of up to 8 members | `yes` 4.45 vs 3.51 s, ash no better |
| Growing only towards a target with a quarter of the region's exits | ash no better |
| Cross-page members only from the breadth-first search, no growth | `yes` 5.90 vs 5.49 s (hot libc callees are already compiled elsewhere) |
| Not translating an extension's ops (hand back) | slower than no extension: aes-256-cbc 24.7 vs 34.9 MB/s (77.0 compiled) |
| AES ops always through helpers | 5-11% slower than inline at 8 KiB; inline up to 4 per block |
| clmul/clmulh through helpers in GHASH (12 per block) | 3-4% slower GCM; inline up to 12 per block |
| One op kind per Zba/Zbb/Zbs/Zicond mnemonic group (13 kinds) | more code than 10 kinds with branch-free variants in imm |
| Compiling JIT modules off the kernel's thread | at most 2.4% (shell) / 4.5% (npx) even if free; see Host contract |
| Tenured op arena (compiled blocks survive young resets) | recompiles 55% to 0-6%, but npx still +1% vs `--no-jit`, and keeping marks exact across resets needs a bounded eviction rule |
| A fixed JIT threshold of 2^19 | npx at parity with `--no-jit`, but kwbench mem -18%, `md5sum` × 8 +60% |
| `riscv_flush_icache` as a range flush | no change (~300 calls per npx run) |
| Per-site data-TLB page cache in self-loop modules (tag + addend in locals, up to 8 sites) | slower (2026-11-14, kwbench mem loop 2623 vs 3054 MB/s, aes-256-cbc 71.9 vs 74.9 MB/s): the TLB loads are L1 hits, and the extra loop-carried locals cost more |
| 32-member regions and a 32 KiB emit buffer, with checked entries (2026-11-15) | apk entries 42.3M to 40.2M, jalr exits -13%, but apk 3.05 vs 2.88 s: bigger modules cost more per entry (prologue and epilogue over the union of registers) and per recompile |
| Grow threshold 1024 per KiB, with checked entries (2026-11-15) | apk entries -7%, PLT exits 4.9M to 3.5M, a quarter to a third more compiles per run; time 2.85 vs 2.88 s (noise). With 32 members too: entries -14%, jalr exits 9.4M, slower |
| Four AES T-tables instead of one table plus `i32.rotl` (AesTab +6 KiB) | aes-256-cbc 8 KiB +3.6% (78.8 vs 76.1 MB/s), aes-256-gcm and curl unchanged (2026-11-14); below the 4% bar for an AesTab change |
| SMP compile stalls: taking a pending interrupt right after the compile, before the block runs (2026-11-17) | the JIT then takes an interrupt that a guest store raised earlier than the interpreter does (fuzz seed 100675: 7 instructions earlier), so the two diverge; kwemu looks at the irq word before the compile instead |
| SMP compile stalls: the host's first call of a new module made to trap (out-of-bounds `x`, `cpu` and `irqp`) instead of a `cpu == 0` test in every module (2026-11-17) | a wasm trap costs 33-43 µs in a CPU's thread (5-6 µs in a small test process, also on a JSPI stack; cause not found), against one compare per entry |
| SMP compile stalls: compiling asynchronously (`WebAssembly.compile`, or a helper worker posting the Module, which could also be shared between CPUs) | a finished Module reaches a CPU's thread only through its event loop, which it runs at the 20 ms yields: a hot block would stay interpreted that long instead of ~0.3 ms; V8's first-call compile stays on the CPU unless the helper also calls `f` on a memory of the same type |
| SMP compile stalls: returning to the kernel between `new Module`, `new Instance` and the first call, to take interrupts there | 0.1, 0.02 and 0.25 ms on average: the first-call compile alone is most of it and cannot be split; for TLB flushes the window covers all of it anyway |

## Next steps

AMOs and LR/SC in the JIT. Bigger regions: most exits that remain leave
full or closed regions (ash, `md5sum`), but more members need a smaller
`members`/`member_op` encoding (or a bigger `KW_CPU_SIZE`, an ABI change)
and a bigger emit buffer; measure the compile cost (module bytes) with
it, since that is what limits growth. Exits into self-loop modules
(`sort`, `tar | gzip`) are the other large group. For FP, directed
rounding and results outside the fast-path range are still handed back.

Node startup: fix the arena reset policy first (compact or partial resets
that keep compiled pcs), then retune the threshold (the adaptive scheme
above); cheaper modules (unused locals), cheaper enter and transitions,
and a faster interpreter on cold code are what is left.

Guest HTTPS: the self-loop, TLB-cache and T-table ideas were measured
and dropped (Rejected designs), and clmul/clmulh fusion shares no work.
What is left: a byte-copy fast path for misaligned overlapping copies
(libssl's read-ahead `memmove`, 8% of HTTPS time), cheaper `run`
entries, and AES codegen with i32 index math.

apk (and other call-heavy C): the largest exit group left is a self-loop
module and the code it leaves to, which returns into it (8.2M + 6.2M per
apk run); a self-loop that could also run as a guest member of the region
it is left to would remove both. The jalr exits that remain leave full
regions; more members alone did not pay (Rejected designs), so it would
take cheaper region entries (a smaller register prologue) first.

Measure with the `-Dkwemu-stats` exit counters (`[kwemu-exits]` and
`[kwemu-jx]`, indices in `jit.Jx`), the long fuzz, and the Alpine rows
above. Every entry ends as a hand-back, a side exit (`exit_side`, of which
`exit_side_region` are side exits of region members), a direct or jalr
terminator, or a stop (`exit_stop`: budget, interrupt or a failed checked
entry, at a block's start); compiled code tells `run` which through the
done codes (`code_done_side`, `code_done_stop`), at no cost to other
builds. `next_by` crosses that reason with the class of the block run
next (`jit.Nx`: the same block, never compiled, not compiled yet, the
same region, a self-loop module, another region that could still grow or
one that is full). The rest: same page vs other page, branches into
another page, region hops and stops. The kernel cannot print them; the
CLI's `--stats` or a host driver reads them (Node startup, Method).

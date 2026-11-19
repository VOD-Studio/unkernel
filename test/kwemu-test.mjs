// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
// End-to-end tests of the kwemu library through the test harness, which
// plays "kernel" against the C ABI only (src/emu/harness.zig):
//   * native:  zig-out/bin/kwemu-harness (links zig-out/lib/native/libkwemu.a)
//   * wasm64:  zig-out/bin/kwemu-harness.wasm (links zig-out/lib/libkwemu.a)
//   * wasm64+jit (eager / threshold): zig-out/bin/kwemu-harness-jit.wasm, the
//     JIT tier with the JS host of test/kwemu-jit-host.mjs; each must retire
//     exactly as many instructions (instret) as the wasm64 interpreter
//   * wasm32+jit: the JIT harness lowered with Binaryen
//     (wasm-opt --memory64-lowering --table64-lowering, as the kernel is;
//     --enable-memory64 because Zig emits no target_features section, and
//     bulk memory and threads for a -Dkwemu-atomics build);
//     skipped with a note if vendor/toolchain/binaryen is missing ($WASM_OPT
//     overrides the path)
// usage: BUN_JSC_useWasmMemory64=1 bun test/kwemu-test.mjs <zig-out prefix> [--bench-only]
import { readFile, mkdtemp, rm } from "node:fs/promises";
import { existsSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { createJitHost } from "./kwemu-jit-host.mjs";

const prefix = resolve(process.argv[2] ?? "zig-out");
const benchOnly = process.argv.includes("--bench-only");
const guestDir = join(prefix, "guest");
const dec = new TextDecoder();

const wasmModule = await WebAssembly.compile(await readFile(join(prefix, "bin", "kwemu-harness.wasm")));
const jitPath = join(prefix, "bin", "kwemu-harness-jit.wasm");
const jitModule = await WebAssembly.compile(await readFile(jitPath));

// memory32 variant of the JIT harness (lowered like vmlinux32.wasm)
let jit32Module = null, jit32Note = "";
{
  const wasmOpt = process.env.WASM_OPT ?? fileURLToPath(new URL("../vendor/toolchain/binaryen/bin/wasm-opt", import.meta.url));
  if (!existsSync(wasmOpt)) jit32Note = `skipped wasm32+jit: ${wasmOpt} not found (kernel/build.sh binaryen)`;
  else {
    const dir = await mkdtemp(join(tmpdir(), "kwemu-jit32-"));
    const out = join(dir, "kwemu-harness-jit32.wasm");
    const p = spawnSync(wasmOpt, ["-g", "--enable-memory64", "--enable-bulk-memory", "--enable-threads", "--memory64-lowering", "--table64-lowering", jitPath, "-o", out], { encoding: "utf8" });
    if (p.status !== 0) jit32Note = `FAIL wasm-opt lowering: ${p.stderr}`;
    else jit32Module = await WebAssembly.compile(await readFile(out));
    await rm(dir, { recursive: true, force: true });
  }
}

async function runWasm(module, elf, args, jit = null) {
  let out = "", err = "", mem;
  const imports = {
    env: {
      host_write: (fd, ptr, len) => {
        const s = dec.decode(new Uint8Array(mem.buffer, Number(ptr), Number(len)));
        if (fd === 2) err += s; else out += s;
      },
      host_now_ns: () => Number(process.hrtime.bigint()),
    },
  };
  // a library built with -Dkwemu-jit=true: its plain harness imports them too
  if (!jit && WebAssembly.Module.imports(module).some((i) => i.module === "unkernel")) jit = createJitHost({ available: false });
  if (jit) imports.unkernel = jit.imports;
  const inst = await WebAssembly.instantiate(module, imports);
  const ex = inst.exports;
  mem = ex.memory;
  jit?.attach(ex);
  const image = await readFile(elf);
  const argBytes = new TextEncoder().encode(args.join("\0") + "\0");
  const total = image.length + argBytes.length;
  const ptr = Number(ex.kwh_buf(BigInt(total)));
  if (!ptr) throw new Error("image too large");
  new Uint8Array(mem.buffer, ptr, total).set(image);
  new Uint8Array(mem.buffer, ptr + image.length, argBytes.length).set(argBytes);
  const status = ex.kwh_run(BigInt(image.length), BigInt(argBytes.length), 1);
  if (jit) {
    const s = jit.stats;
    if (s.errors.length) {
      err += s.errors.map((e) => `jit host: ${e}\n`).join("");
      return { status: -1, out, err };
    }
    return { status, out, err, jit: `${s.compiles} compiled, ${s.frees} freed, ${(Number(s.compileNs) / 1e6).toFixed(0)} ms` };
  }
  return { status, out, err };
}

function runNative(elf, args) {
  const p = spawnSync(join(prefix, "bin", "kwemu-harness"), ["--stats", elf, ...args.slice(1)], { encoding: "utf8" });
  return { status: p.status, out: p.stdout, err: p.stderr };
}

let failed = 0;
function mips(r) {
  const m = /MIPS=([\d.]+)/.exec(r.err);
  const n = /instret=(\d+)/.exec(r.err);
  return (m ? `${(Number(n[1]) / 1e6).toFixed(1)}M insns, ${m[1]} MIPS` : "") + (r.jit ? `; jit: ${r.jit}` : "");
}

const cases = [
  { guest: "isatest", expect: /isatest: \d+ checks, 0 failures/ },
  { guest: "fptest", expect: /fptest: \d+ checks, 0 failures/ },
  { guest: "atomics", expect: /atomics: \d+ checks, 0 failures/ },
  // the digest is what qemu-riscv64-static -cpu rv64,zkne=true,zknd=true prints
  { guest: "aestest", expect: /aestest digest: e5a7e06c95795ca0\naestest: \d+ checks, 0 failures/ },
  // what qemu-riscv64-static -cpu rv64,zbc=true,zbkb=true,zbkc=true,zbkx=true prints
  { guest: "bktest", expect: /bktest digest: df49b8c72c57ddff\nbktest: \d+ checks, 0 failures/ },
  // what qemu-riscv64-static -cpu rv64,zba=true,zbb=true,zbs=true,zicond=true prints
  { guest: "zbtest", expect: /zbtest digest: 79fd08f9c2e26f6d\nzbtest: \d+ checks, 0 failures/ },
  // what qemu-riscv64-static -cpu rv64,zba=true,zbb=true,zcb=true,zimop=true,zcmop=true,zicbom=true,zicboz=true,zawrs=true prints
  { guest: "rvatest", expect: /rvatest digest: 82d53e6ff7f1c585\nrvatest: \d+ checks, 0 failures/ },
  // what qemu-riscv64-static -cpu rv64,zfa=true prints
  { guest: "zfatest", expect: /zfatest digest: 7336769a0d94f11c\nzfatest: \d+ checks, 0 failures/ },
  // what qemu-riscv64-static -cpu rv64,zfhmin=true prints
  { guest: "zfhtest", expect: /zfhtest digest: b88af7c766514775\nzfhtest: \d+ checks, 0 failures/ },
  // what qemu-riscv64-static prints
  { guest: "jalrtest", expect: /jalrtest digest: fe7c1240f830ff1c\njalrtest: \d+ checks, 0 failures/ },
  { guest: "hello", args: ["x", "y z"], expect: /argv\[2\] = y z\n/ },
  { guest: "bench", args: ["2000000", "3", "27"], expect: /primes below 2000000: 148933[\s\S]*fib: 196418/ },
].filter((c) => !benchOnly || c.guest === "bench");

const modes = [
  ["native", runNative],
  ["wasm64", (elf, args) => runWasm(wasmModule, elf, args)],
  ["wasm64+jit", (elf, args) => runWasm(jitModule, elf, args, createJitHost({ eager: true }))],
  ["wasm64+jit/thr", (elf, args) => runWasm(jitModule, elf, args, createJitHost())],
];
if (jit32Module) modes.push(["wasm32+jit", (elf, args) => runWasm(jit32Module, elf, args, createJitHost({ eager: true, mem32: true }))]);
const width = Math.max(...modes.map(([m]) => m.length));

for (const c of cases) {
  const elf = join(guestDir, `${c.guest}.elf`);
  const args = [c.guest, ...(c.args ?? [])];
  let instret = null; // the wasm64 interpreter's: the JIT modes must retire exactly as many
  for (const [mode, run] of modes) {
    const r = await run(elf, args);
    const n = /instret=(\d+)/.exec(r.err)?.[1];
    if (mode === "wasm64") instret = n;
    const ok = r.status === 0 && c.expect.test(r.out);
    if (!ok) {
      failed++;
      console.log(`FAIL kwemu ${mode} ${c.guest}: status ${r.status}\n--- stdout ---\n${r.out}--- stderr ---\n${r.err}`);
    } else if (mode.includes("jit") && n !== instret) {
      failed++;
      console.log(`FAIL kwemu ${mode} ${c.guest}: instret ${n}, the interpreter retired ${instret}`);
    } else console.log(`ok   kwemu ${mode.padEnd(width)} ${c.guest.padEnd(8)} (${mips(r)})`);
  }
}
if (jit32Note) {
  console.log(jit32Note);
  if (jit32Note.startsWith("FAIL")) failed++;
}

if (failed) {
  console.log(`${failed} kwemu test(s) failed`);
  process.exit(1);
}

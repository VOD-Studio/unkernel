// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
// Runs the kwemu unit tests built as wasm64 with the JIT tier
// (src/tests_wasm.zig + src/test_runner_wasm.zig, run by `zig build test`)
// against an eager JS JIT host, and checks the host's slot bookkeeping:
// every compile goes into a free slot, every free into an installed one,
// no module fails to compile, and nothing is left installed at the end
// (each test's Machine.deinit resets the block cache).
// usage: BUN_JSC_useWasmMemory64=1 bun test/kwemu-unit-wasm.mjs <kwemu-unit-jit.wasm> [--fuzz N] [--seed S]
//   --fuzz N: the randomized interpreter-vs-JIT test ("kwemu jit fuzz") runs
//   N seeds from S (default 0) instead of its default count (`zig build fuzz -- N [S]`)
import { readFile } from "node:fs/promises";
import { createJitHost } from "./kwemu-jit-host.mjs";

const dec = new TextDecoder();
const jit = createJitHost({ eager: true, strict: true });
const arg = (name) => {
  const i = process.argv.indexOf(name);
  return i > 0 ? BigInt(process.argv[i + 1]) : null;
};
const rest = process.argv.slice(3);
const pos = rest.length && !rest[0].startsWith("-") ? rest : [];
const fuzz = [arg("--fuzz") ?? (pos[0] ? BigInt(pos[0]) : 0n), arg("--seed") ?? (pos[1] ? BigInt(pos[1]) : 0n)];
let mem, out = "";
const { instance } = await WebAssembly.instantiate(await readFile(process.argv[2]), {
  env: {
    host_write: (fd, ptr, len) => {
      const s = dec.decode(new Uint8Array(mem.buffer, Number(ptr), Number(len)));
      if (fd === 2) process.stderr.write(s);
      else out += s;
    },
    kwemu_fuzz_config: (which) => fuzz[which] ?? 0n,
  },
  unkernel: jit.imports,
});
mem = instance.exports.memory;
jit.attach(instance.exports);
let failed;
try {
  failed = instance.exports.run_tests();
} catch (e) {
  const last = out.split("\n").pop().split("\t")[0];
  console.log(`FAIL kwemu unit (wasm64+jit): trapped in "${last}": ${e.message}`);
  process.exit(1);
}
const lines = out.trim().split("\n").map((l) => l.split("\t"));
for (const [name, st] of lines) console.log(`${(st.startsWith("FAIL") ? st : st.padEnd(4))} wasm64+jit ${name}`);
const n = (p) => lines.filter(([, st]) => st?.startsWith(p)).length;
const s = jit.stats;
console.log(`kwemu unit (wasm64+jit): ${n("ok")} passed, ${n("skip")} skipped, ${failed} failed; ` +
  `host: ${s.compiles} compiles, ${s.frees} frees, ${s.failures} compile failures, ${jit.installed()} left installed, ` +
  `${(Number(s.compileNs) / 1e6).toFixed(0)} ms compiling ${(s.bytes / 1024).toFixed(0)} KiB`);
for (const e of s.errors) console.log(`FAIL jit host: ${e}`);
if (jit.installed()) console.log("FAIL jit host: slots left installed");
if (failed || s.errors.length || jit.installed() || s.compiles === 0) process.exit(1);

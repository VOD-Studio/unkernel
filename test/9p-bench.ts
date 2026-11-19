// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
// Benchmark of host file systems in the guest (core/9p.ts, core/mounts.ts):
// one kernel, one mount (the SDK's, cache=readahead with metatimeout=1000),
// tmpfs as the baseline. Prints a markdown table row; .agents/js.md has dated
// results.
//
//   bun test/9p-bench.ts [--worker] [--no-jit] [--node] [--quick]
//
// --node serves a temp directory through nodeFs() instead of a MemoryFs.
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { createKernel, MemoryFs, nodeFs, type Fs } from "../js/node.ts";

const argv = process.argv.slice(2);
const flag = (f: string) => argv.includes(f);
const worker = flag("--worker");
const jit = !flag("--no-jit");
const quick = flag("--quick");
const BIG = 16 << 20;
const TREE_DIRS = 30, TREE_FILES = 100; // the metadata workload: 3000 small files

const big = new Uint8Array(BIG);
for (let i = 0; i < big.length; i++) big[i] = (i * 2654435761) >>> 24;
const want = Buffer.from(await crypto.subtle.digest("SHA-256", big)).toString("hex");
const tmpDirs: string[] = [];

/** A fresh file system with the benchmark's files. */
function makeFs(): Fs {
	const files: Array<[string, string | Uint8Array]> = [["small.txt", "hello\n"], ["big.bin", big], ["a/b/c/deep.txt", "deep\n"]];
	for (let i = 0; i < 1000; i++) files.push([`many/f${i}`, `${i}\n`]);
	for (let d = 0; d < TREE_DIRS; d++) for (let f = 0; f < TREE_FILES; f++) files.push([`tree/d${d}/f${f}.txt`, `file ${d}/${f}\n`.repeat(4)]);
	if (flag("--node")) {
		const dir = mkdtempSync(path.join(tmpdir(), "unkernel-9p-bench-"));
		tmpDirs.push(dir);
		for (const [p, c] of files) {
			mkdirSync(path.dirname(path.join(dir, p)), { recursive: true });
			writeFileSync(path.join(dir, p), c);
		}
		return nodeFs(dir);
	}
	const fs = new MemoryFs();
	for (const [p, c] of files) fs.writeFile(`/${p}`, c);
	return fs;
}

const t0 = performance.now();
const vm = await createKernel({ worker, jit, log: () => {} });
const sh = async (cmd: string) => {
	const t = performance.now();
	const r = await vm.exec("sh", ["-c", cmd]);
	if (r.exitCode !== 0) throw new Error(`${cmd}: exit ${r.exitCode}: ${r.stderr}`);
	return { out: r.stdout.trim(), ms: performance.now() - t };
};
const N = quick ? 200 : 1000;
const loop = (body: string, n = N) => `i=0; while [ $i -lt ${n} ]; do ${body}; i=$((i+1)); done`;
const us = (ms: number, base: number, n: number) => (((ms - base) / n) * 1000).toFixed(0);
const rows: Array<Record<string, string>> = [];

try {
	await sh("true");
	const boot = performance.now() - t0;
	// tmpfs baselines (the same files)
	await sh(`mkdir -p /tmp/b/a/b/c /tmp/b/many && echo hello > /tmp/b/small.txt && echo deep > /tmp/b/a/b/c/deep.txt && cd /tmp/b/many && ${loop("echo $i > f$i", 1000)}`);
	await sh(`cd /tmp/b && for d in $(seq 0 ${TREE_DIRS - 1}); do mkdir -p tree/d$d; for f in $(seq 0 ${TREE_FILES - 1}); do printf 'file %s\\n%.0s' $d/$f 1 2 3 4 > tree/d$d/f$f.txt; done; done`);
	const work = (dir: string) => `cd ${dir} && find tree -type f | wc -l && tar cf - tree | wc -c && ls -lR tree | wc -l`;
	await sh(work("/tmp/b"));
	const base = {
		stat: (await sh(loop("[ -e /tmp/b/small.txt ]"))).ms,
		open: (await sh(loop("exec 3</tmp/b/small.txt; exec 3<&-"))).ms,
		cat: (await sh(loop("cat /tmp/b/small.txt >/dev/null", N / 4))).ms,
		create: (await sh("mkdir -p /tmp/b/c && cd /tmp/b/c && " + loop("echo $i > n$i", 200))).ms,
		work: (await sh(work("/tmp/b"))).ms,
	};
	console.log(`booted in ${boot.toFixed(0)} ms; ${worker ? "worker" : "inline"}, jit ${jit}, ${flag("--node") ? "nodeFs" : "MemoryFs"}; ${new Date().toISOString().slice(0, 10)}; tmpfs workload ${base.work.toFixed(0)} ms`);
	// The first pass pays for JIT compiling the shell loops, dd, find and tar: run it once unreported.
	for (const i of [0, 1]) {
		const dir = `/mnt/bench${i}`;
		const m = await vm.mount(dir, makeFs());
		const s = () => m.stats.requests;
		const row: Record<string, string> = { run: `${worker ? "worker" : "inline"}${flag("--node") ? ", nodeFs" : ""}` };
		await sh(`[ -e ${dir}/small.txt ] && [ -e ${dir}/a/b/c/deep.txt ]`);
		let q = s();
		const st = await sh(loop(`[ -e ${dir}/small.txt ]`));
		row["stat µs"] = us(st.ms, base.stat, N);
		row["RT/stat"] = ((s() - q) / N).toFixed(1);
		q = s();
		const op = await sh(loop(`exec 3<${dir}/small.txt; exec 3<&-`));
		row["open+close µs"] = us(op.ms, base.open, N);
		row["RT/open"] = ((s() - q) / N).toFixed(1);
		q = s();
		const cat = await sh(loop(`cat ${dir}/small.txt >/dev/null`, N / 4));
		row["cat µs"] = us(cat.ms, base.cat, N / 4);
		row["RT/cat"] = ((s() - q) / (N / 4)).toFixed(1);
		const ls = await sh(`ls -l ${dir}/many | wc -l`);
		const ls2 = await sh(`ls -l ${dir}/many | wc -l`);
		row["ls -l 1000 ms"] = `${ls.ms.toFixed(0)}/${ls2.ms.toFixed(0)}`;
		const rd = await sh(`dd if=${dir}/big.bin of=/dev/null bs=128k 2>&1 | tail -1`);
		row["read 128k MB/s"] = (BIG / 1e6 / (rd.ms / 1000)).toFixed(0);
		const rd4 = await sh(`dd if=${dir}/big.bin of=/dev/null bs=4k 2>&1 | tail -1`);
		row["read 4k MB/s"] = (BIG / 1e6 / (rd4.ms / 1000)).toFixed(0);
		const sum = await sh(`sha256sum ${dir}/big.bin`);
		if (!sum.out.startsWith(want)) throw new Error(`sha256 mismatch: ${sum.out}`);
		const wr = await sh(`dd if=/dev/zero of=${dir}/w.bin bs=1M count=${BIG >> 20} 2>/dev/null`);
		row["write 1M MB/s"] = (BIG / 1e6 / (wr.ms / 1000)).toFixed(0);
		const cr = await sh(`mkdir -p ${dir}/c && cd ${dir}/c && ` + loop("echo $i > n$i", 200));
		row["create µs"] = us(cr.ms, base.create, 200);
		q = s();
		const wk = await sh(work(dir));
		row["find+tar+ls -lR 3000 ms"] = `${wk.ms.toFixed(0)} (${((s() - q) / 1000).toFixed(1)}k RT)`;
		await m.unmount();
		if (i) rows.push(row);
	}
	const cols = Object.keys(rows[0]!);
	console.log(`| ${cols.join(" | ")} |\n| ${cols.map(() => "---").join(" | ")} |`);
	for (const r of rows) console.log(`| ${cols.map((c) => r[c]).join(" | ")} |`);
	console.log("stat, open+close, cat and create are per operation over tmpfs; ls -l is cold/warm wall time incl. exec; the workload (find | wc, tar | wc, ls -lR over 30 x 100 small files) is wall time; sizes 16 MiB.");
} finally {
	await vm.stop();
	for (const d of tmpDirs) rmSync(d, { recursive: true, force: true });
}

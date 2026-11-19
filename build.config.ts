// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
// obuild config for the `@vod-studio/unkernel` npm package (bun run build).
//
//   js/node.ts -> dist/node.mjs   Node entry (@vod-studio/unkernel/node)
//   js/web.ts  -> dist/web.mjs    web entry (@vod-studio/unkernel/web)
//   js/cli.ts  -> dist/cli.mjs    `bunx --package @vod-studio/unkernel unkernel`
//   vendor/build/bundle/unkernel-alpine.wasm -> dist/unkernel-alpine.wasm
//                                 (kernel/build.sh bundle; both entries find it
//                                 with new URL("./unkernel-alpine.wasm", import.meta.url))
//   js/node/worker-entry.ts       the kernel worker (createKernel({ worker: true })) on
//   js/web/web-worker-entry.ts    Node and in browsers, each bundled into one minified ES
//                                 module and inlined as a string where js/node/worker.ts
//                                 and js/web/worker.ts start it (WORKERS)
//   js/node/cpu-entry.ts          a secondary CPU of an SMP kernel on Node, inlined the
//                                 same way where js/node/cpu.ts starts it: in the Node
//                                 entries and inside the Node kernel worker (WORKERS)
//   js/web/web-cpu-entry.ts       the same in browsers, inlined as a Blob URL where
//                                 js/web/cpu.ts starts it: in the web entry and inside
//                                 the web kernel worker (WORKERS)

import { realpathSync } from "node:fs";
import { copyFile, readFile, readdir, stat } from "node:fs/promises";
import { builtinModules, createRequire } from "node:module";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { defineBuildConfig } from "obuild/config";

const WASM = "vendor/build/bundle/unkernel-alpine.wasm";

/**
 * Worker entries and the module that starts each one with
 * `new URL("./<entry>", import.meta.url)`. The build bundles the entry
 * into a standalone chunk and replaces that expression with `wrap` of the
 * chunk's code as a string literal: on Node the string itself
 * (new Worker(code, { eval: true })), in browsers a Blob URL made from it
 * (js/web/worker.ts). `entries` are the dist entries that must carry it;
 * every other entry must not.
 */
interface WorkerSpec {
	name: string;
	starter: string;
	entry: string;
	platform: "node" | "browser";
	wrap: (s: string) => string;
	entries: string[];
	/** Workers this worker starts itself: inlined into its own bundle first. */
	nested?: string[];
}
const WORKERS: WorkerSpec[] = [
	{ name: "cpu", starter: "js/node/cpu.ts", entry: "js/node/cpu-entry.ts", platform: "node", wrap: (s: string) => s, entries: ["node.mjs", "cli.mjs"] },
	{ name: "node", starter: "js/node/worker.ts", entry: "js/node/worker-entry.ts", platform: "node", wrap: (s: string) => s, entries: ["node.mjs", "cli.mjs"], nested: ["cpu"] },
	{ name: "webcpu", starter: "js/web/cpu.ts", entry: "js/web/web-cpu-entry.ts", platform: "browser", wrap: (s: string) => `inlineCpuUrl(${s})`, entries: ["web.mjs"] },
	{ name: "web", starter: "js/web/worker.ts", entry: "js/web/web-worker-entry.ts", platform: "browser", wrap: (s: string) => `inlineWorkerUrl(${s})`, entries: ["web.mjs"], nested: ["webcpu"] },
];
/** Starts every inlined worker string (WORKER_MARK + name + "*" + "/"); the end hook looks for it. */
const WORKER_MARK = "/*unkernel-worker:";
const workerMark = (name: string) => `${WORKER_MARK}${name}*/`;

// rolldown comes with obuild (not a direct dependency): resolve it from there.
type RolldownChunk = { type: string; fileName: string; code?: string; imports?: string[]; dynamicImports?: string[] };
type Rolldown = (opts: Record<string, unknown>) => Promise<{
	generate(o: Record<string, unknown>): Promise<{ output: RolldownChunk[] }>;
	close(): Promise<void>;
}>;
async function loadRolldown(pkgDir: string): Promise<Rolldown> {
	const obuild = realpathSync(path.join(pkgDir, "node_modules/obuild/package.json"));
	const mod = await import(pathToFileURL(createRequire(obuild).resolve("rolldown")).href) as { rolldown: Rolldown };
	return mod.rolldown;
}

/** `code` without the string literals that hold an inlined worker. */
function withoutWorkerStrings(code: string): string {
	for (let at = code.indexOf(WORKER_MARK); at >= 0; at = code.indexOf(WORKER_MARK)) {
		const start = at - 1, q = code[start]!;
		if (q !== '"' && q !== "'" && q !== "`") throw new Error("an inlined worker is not at the start of a string literal");
		let end = at;
		while (end < code.length && code[end] !== q) end += code[end] === "\\" ? 2 : 1;
		code = code.slice(0, start) + code.slice(end + 1);
	}
	return code;
}

/**
 * A rolldown plugin that replaces `new URL("./<entry>", import.meta.url)`
 * in each worker's starter with the worker's code (`codes`: name -> the
 * string from bundleWorker()). `strict`: every starter must be bundled.
 */
function inlinePlugin(pkgDir: string, workers: WorkerSpec[], codes: Map<string, string>, strict: boolean) {
	const inline = new Map<string, { pattern: string; code: string; done: boolean }>();
	for (const w of workers) {
		inline.set(path.join(pkgDir, w.starter), {
			pattern: `new URL("./${path.basename(w.entry)}", import.meta.url)`,
			code: w.wrap(JSON.stringify(codes.get(w.name)!)),
			done: false,
		});
	}
	return {
		name: "unkernel:inline-worker",
		transform(code: string, id: string) {
			const w = inline.get(path.normalize(id.split("?")[0]!));
			if (!w) return null;
			if (code.split(w.pattern).length !== 2) throw new Error(`${id} must contain ${w.pattern} exactly once (build.config.ts WORKERS)`);
			w.done = true;
			return { code: code.replace(w.pattern, () => w.code), map: null };
		},
		buildEnd() {
			if (!strict) return;
			for (const [id, w] of inline) if (!w.done) throw new Error(`${id} was not bundled, so its worker was not inlined`);
		},
	};
}

/**
 * One worker entry as a standalone minified ES module that imports nothing
 * but Node built-ins (node), or nothing at all (browser), with the workers
 * it starts (`nested`, already in `codes`) inlined.
 */
async function bundleWorker(pkgDir: string, w: WorkerSpec, codes: Map<string, string>): Promise<string> {
	const { entry } = w;
	const node = w.platform === "node";
	const rolldown = await loadRolldown(pkgDir);
	const nested = WORKERS.filter((n) => w.nested?.includes(n.name));
	const bundle = await rolldown({
		input: path.join(pkgDir, entry),
		cwd: pkgDir,
		platform: w.platform,
		external: node ? [/^node:/, ...builtinModules] : [],
		treeshake: true,
		plugins: nested.length ? [inlinePlugin(pkgDir, nested, codes, true)] : [],
	});
	const { output } = await bundle.generate({ format: "esm", minify: true, codeSplitting: false });
	await bundle.close();
	const chunk = output[0]!;
	if (output.length !== 1 || chunk.type !== "chunk" || chunk.code === undefined)
		throw new Error(`${entry}: expected one chunk, got ${output.map((o) => o.fileName).join(", ")}`);
	const bad = [...chunk.imports ?? [], ...chunk.dynamicImports ?? []].filter((i) => !node || (!i.startsWith("node:") && !builtinModules.includes(i)));
	if (bad.length) throw new Error(`${entry}: the worker bundle imports ${bad.join(", ")}; it may import ${node ? "only Node built-ins" : "nothing"}`);
	if (chunk.code.includes("import.meta")) throw new Error(`${entry}: the worker bundle uses import.meta, which means nothing when it runs from a string`);
	return workerMark(w.name) + chunk.code;
}

export default defineBuildConfig({
	entries: [
		{
			type: "bundle",
			input: ["./js/node.ts", "./js/web.ts", "./js/cli.ts"],
			license: false, // no bundled dependencies
		},
	],
	hooks: {
		async start(ctx) {
			const wasm = path.join(ctx.pkgDir, WASM);
			const st = await stat(wasm).catch(() => null);
			if (!st?.isFile())
				throw new Error(`${WASM} is missing: build it first (kernel/build.sh all, or kernel/build.sh bundle once vmlinux32.wasm and the Alpine initramfs exist)`);
		},
		async rolldownConfig(config, ctx) {
			// dist/node.mjs, not dist/js/node.mjs.
			const input = config.input as Record<string, string>;
			config.input = Object.fromEntries(Object.entries(input).map(([name, src]) => [name.replace(/^js[/\\]/, ""), src]));
			// Inline each worker entry as a string where it is started (WORKERS),
			// nested ones first (WORKERS lists them before the workers that start them).
			const codes = new Map<string, string>();
			for (const w of WORKERS) codes.set(w.name, await bundleWorker(ctx.pkgDir, w, codes));
			const plugins = Array.isArray(config.plugins) ? config.plugins : config.plugins ? [config.plugins] : [];
			config.plugins = [inlinePlugin(ctx.pkgDir, WORKERS, codes, true), ...plugins];
		},
		rolldownOutput(output) {
			// Name the shared chunks after what they hold: dist/_chunks/core.mjs
			// (universal) and node.mjs (Node-only code shared by node.mjs and cli.mjs).
			const split = output.codeSplitting as { groups?: Array<{ name: string; test: RegExp }> } | undefined;
			split?.groups?.unshift(
				// Sources only: rolldown-plugin-dts runs .d.ts modules through the same graph.
				{ name: "core", test: /[\\/]js[\\/]core[\\/][\w-]+\.ts$/ },
				{ name: "node", test: /[\\/]js[\\/]node[\\/][\w-]+\.ts$/ },
			);
		},
		async end(ctx) {
			const dist = path.join(ctx.pkgDir, "dist");
			await copyFile(path.join(ctx.pkgDir, WASM), path.join(dist, "unkernel-alpine.wasm"));
			// The files an entry loads (itself and its chunks) and its bare imports.
			const reach = async (entry: string) => {
				const files = new Map<string, string>(), bare: Array<[string, string]> = [];
				const visit = async (file: string): Promise<void> => {
					if (files.has(file)) return;
					const code = await readFile(path.join(dist, file), "utf8");
					files.set(file, code);
					// The inlined worker is a string literal: its imports are not the chunk's.
					const outside = withoutWorkerStrings(code);
					for (const m of outside.matchAll(/\b(?:import|export)\b[^;]*?\bfrom\s*["']([^"']+)["']|\bimport\s*\(?\s*["']([^"']+)["']/g)) {
						const spec = m[1] ?? m[2]!;
						if (spec.startsWith(".")) await visit(path.join(path.dirname(file), spec));
						else bare.push([spec, file]);
					}
				};
				await visit(entry);
				return { files, bare };
			};
			// The web entry must not pull in Node built-ins, directly or through a shared chunk.
			const web = await reach("web.mjs");
			for (const [spec, file] of web.bare)
				throw new Error(`dist/web.mjs imports "${spec}" (via ${file}); the web entry must stay free of Node built-ins and dependencies`);
			// Each entry carries its own platform's kernel worker inlined as a string and not the
			// other's, and nothing refers to a worker's source file.
			for (const entry of ["node.mjs", "web.mjs", "cli.mjs"]) {
				const { files } = await reach(entry);
				for (const w of WORKERS) {
					const has = [...files.values()].some((code) => code.includes(workerMark(w.name)));
					if (has !== w.entries.includes(entry))
						throw new Error(`dist/${entry} ${has ? "carries" : "does not carry"} the inlined ${w.name} kernel worker (build.config.ts WORKERS)`);
				}
			}
			for (const f of [...(await readdir(dist)), ...(await readdir(path.join(dist, "_chunks")).catch(() => [])).map((c) => `_chunks/${c}`)]) {
				const code = f.endsWith(".mjs") ? await readFile(path.join(dist, f), "utf8") : "";
				for (const name of ["worker-entry", "cpu-entry"])
					if (code.includes(name)) throw new Error(`dist/${f} refers to ${name}: a worker was not inlined`);
			}
			// The bundled-kernel URL must be resolved relative to the entry itself, not a shared chunk.
			for (const entry of ["node.mjs", "web.mjs", "cli.mjs"]) {
				if (!(await readFile(path.join(dist, entry), "utf8")).includes(`new URL("./unkernel-alpine.wasm", import.meta.url)`))
					throw new Error(`dist/${entry} does not locate unkernel-alpine.wasm next to itself`);
			}
			const chunks = await readdir(path.join(dist, "_chunks")).catch(() => []);
			for (const c of chunks.filter((f) => f.endsWith(".mjs"))) {
				if ((await readFile(path.join(dist, "_chunks", c), "utf8")).includes("unkernel-alpine.wasm"))
					throw new Error(`dist/_chunks/${c} refers to unkernel-alpine.wasm (would resolve inside _chunks/)`);
			}
			// Every entry links (a broken chunk split shows up as a missing export).
			for (const entry of ["node.mjs", "web.mjs"]) {
				const mod = await import(`${pathToFileURL(path.join(dist, entry)).href}?check=${Date.now()}`);
				if (typeof mod.createKernel !== "function") throw new Error(`dist/${entry} has no createKernel export`);
			}
			console.log(`unkernel: dist/unkernel-alpine.wasm copied; web entry is free of Node imports; kernel and CPU workers inlined; entries link; ${chunks.length} shared chunk(s)`);
		},
	},
});

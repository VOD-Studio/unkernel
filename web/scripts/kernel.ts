// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
// The page's kernel: web/kernel/unkernel-alpine.wasm (gitignored).
// vite.config.ts calls fetchKernel() when the dev server starts and when
// the page is built.
//   - The dev server runs the file that is there, whatever wrote it (the
//     local pipeline: kernel/build.sh bundle copies its output there), and
//     fetches only when there is none.
//   - A page build always takes the bundle attached to the newest GitHub
//     release of this repository, so a deploy never ships a local kernel.
//     It downloads unless the file is that release's, by sha256.
// The download happens here, at build time, because GitHub sends release
// assets without CORS, so a browser cannot fetch them. The file is a Vite
// asset (src/sdk.ts), so it gets a hashed /assets/ name. web/kernel/release.json records the release
// that was downloaded last; a file that does not match it is "local".
//
// Environment:
//   KW_KERNEL=<path>          use this bundle instead (copied in), in a build too, e.g.
//                             KW_KERNEL=../vendor/build/bundle/unkernel-alpine.wasm bun run build:web
//   KW_KERNEL_RELEASE=<tag>   this release instead of the newest (v0.1.0-261115-75add72);
//                             the dev server then fetches it too
//   GITHUB_TOKEN, GH_TOKEN    for the GitHub API (60 requests an hour without
//                             one; past that, the release feed is used)
// If GitHub cannot be reached and the file is a release's (the tag asked
// for, if one was), a build keeps it.
//
// splitKernel() then makes what the page serves, in web/kernel/page/: the
// UP bundle unkernel-alpine.wasm, which is the file above without its SMP
// patch section (kernel/tools/bundle.mjs --smp; byte for byte the file when
// it has none), and, only when the file has that section,
// unkernel-alpine-smp.wasm: the SMP kernel the patch makes with the same
// root file system, command line and data disk template
// (js/core/kpatch.ts). So UP visitors download what they would without the
// patch, and an SMP page would download one SMP bundle without patching in
// the browser. vite.config.ts serves the second file as its own hashed
// asset (virtual:unkernel-smp-kernel).
import { createHash } from "node:crypto";
import { mkdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { smpKernelFromBundle, withoutSmpPatch } from "../../js/core/kpatch.ts";

const REPO = "pithings/unkernel";
const ASSET = "unkernel-alpine.wasm";
const DIR = fileURLToPath(new URL("../kernel/", import.meta.url));
/** Where the kernel goes; src/sdk.ts imports it from here. */
export const KERNEL_FILE = `${DIR}${ASSET}`;
const META_FILE = `${DIR}release.json`;
const PAGE_DIR = `${DIR}page/`;
/** The UP bundle the page serves (src/sdk.ts kernelUrl). */
export const PAGE_KERNEL_FILE = `${PAGE_DIR}${ASSET}`;
/** The SMP bundle the page serves, present only when KERNEL_FILE carries an SMP patch. */
export const PAGE_SMP_FILE = `${PAGE_DIR}unkernel-alpine-smp.wasm`;

export interface KernelRelease {
	/** The release's tag, or "local" for KW_KERNEL. */
	tag: string;
	/** When it was published (ISO 8601), or the local file's time; "" if unknown. */
	date: string;
	sha256: string;
}

interface Resolved { tag: string; date: string; url: string; sha256?: string }

const UA = { "user-agent": "unkernel-web-build" };
const sha256 = (b: Uint8Array) => createHash("sha256").update(b).digest("hex");
const log = (msg: string) => console.log(`[kernel] ${msg}`);

/** The release to use: from the API (with the asset's digest), else from the feed. */
async function resolve(want?: string): Promise<Resolved> {
	const token = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
	const res = await fetch(`https://api.github.com/repos/${REPO}/releases${want ? `/tags/${want}` : "?per_page=20"}`, {
		headers: { ...UA, accept: "application/vnd.github+json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
	});
	if (res.ok) {
		type R = { tag_name: string; draft: boolean; published_at: string; assets: { name: string; browser_download_url: string; digest?: string | null }[] };
		for (const r of ([] as R[]).concat(await res.json())) {
			const a = r.draft ? undefined : r.assets.find((a) => a.name === ASSET);
			if (a) return { tag: r.tag_name, date: r.published_at, url: a.browser_download_url, sha256: a.digest?.replace(/^sha256:/, "") };
		}
		throw new Error(`no release of ${REPO}${want ? ` tagged ${want}` : ""} has ${ASSET}`);
	}
	if (res.status === 404 && want) throw new Error(`${REPO} has no release ${want}`);
	// Rate limited (or the API is down): the release feed has no limit, but no digests.
	log(`GitHub API: ${res.status} ${res.statusText}; using the release feed`);
	let tag = want, date = "";
	if (!tag) {
		const feed = await fetch(`https://github.com/${REPO}/releases.atom`, { headers: UA });
		if (!feed.ok) throw new Error(`release feed: ${feed.status} ${feed.statusText}`);
		const entry = /<entry>([\s\S]*?)<\/entry>/.exec(await feed.text())?.[1] ?? "";
		tag = /\/releases\/tag\/([^"]+)"/.exec(entry)?.[1];
		date = /<updated>([^<]+)<\/updated>/.exec(entry)?.[1] ?? "";
		if (!tag) throw new Error(`${REPO} has no releases`);
	}
	return { tag, date, url: `https://github.com/${REPO}/releases/download/${tag}/${ASSET}` };
}

/** The file there now: its release if it is the one release.json names, else "local"; undefined if none. */
async function current(): Promise<KernelRelease | undefined> {
	let bytes: Uint8Array;
	try { bytes = await readFile(KERNEL_FILE); }
	catch { return undefined; }
	const sum = sha256(bytes);
	try {
		const meta = JSON.parse(await readFile(META_FILE, "utf8")) as KernelRelease;
		if (meta.sha256 === sum) return meta;
	} catch {}
	return { tag: "local", date: (await stat(KERNEL_FILE)).mtime.toISOString(), sha256: sum };
}

async function store(bytes: Uint8Array, rel: KernelRelease): Promise<KernelRelease> {
	if (bytes[0] !== 0 || bytes[1] !== 0x61 || bytes[2] !== 0x73 || bytes[3] !== 0x6d) throw new Error(`${rel.tag}: ${ASSET} is not a wasm module`);
	await mkdir(DIR, { recursive: true });
	await writeFile(`${KERNEL_FILE}.tmp`, bytes);
	await rename(`${KERNEL_FILE}.tmp`, KERNEL_FILE);
	await writeFile(META_FILE, `${JSON.stringify(rel, null, "\t")}\n`);
	return rel;
}

async function fetchOnce(dev: boolean): Promise<KernelRelease> {
	const local = process.env.KW_KERNEL;
	if (local) {
		const bytes = await readFile(local);
		log(`${local} (KW_KERNEL), ${(bytes.length / 1048576).toFixed(1)} MiB`);
		await mkdir(DIR, { recursive: true });
		await writeFile(KERNEL_FILE, bytes);
		return { tag: "local", date: (await stat(local)).mtime.toISOString(), sha256: sha256(bytes) };
	}
	const want = process.env.KW_KERNEL_RELEASE || undefined;
	const now = await current();
	if (dev && now && (!want || now.tag === want)) {
		log(`${now.tag === "local" ? "a local build" : now.tag} (web/kernel/unkernel-alpine.wasm)`);
		return now;
	}
	const have = now?.tag === "local" ? undefined : now;
	let rel: Resolved;
	try {
		rel = await resolve(want);
	} catch (e) {
		if (!have || (want && have.tag !== want)) throw new Error(`cannot fetch the page's kernel from ${REPO}'s GitHub releases: ${(e as Error).message}`);
		log(`${(e as Error).message}; keeping ${have.tag}`);
		return have;
	}
	if (have?.tag === rel.tag && (!rel.sha256 || rel.sha256 === have.sha256)) return have;
	log(`downloading ${rel.tag} (was ${now?.tag ?? "none"})`);
	const res = await fetch(rel.url, { headers: UA });
	if (!res.ok) throw new Error(`${rel.url}: ${res.status} ${res.statusText}`);
	const bytes = new Uint8Array(await res.arrayBuffer());
	const sum = sha256(bytes);
	if (rel.sha256 && sum !== rel.sha256) throw new Error(`${rel.url}: sha256 ${sum}, the release says ${rel.sha256}`);
	log(`${rel.tag}: ${(bytes.length / 1048576).toFixed(1)} MiB, sha256 ${sum.slice(0, 16)}`);
	return store(bytes, { tag: rel.tag, date: rel.date, sha256: sum });
}

let once: Promise<KernelRelease> | undefined;

/**
 * Puts the kernel at KERNEL_FILE (once per process) and says which it is.
 * `dev`: the dev server, which keeps a file that is there.
 */
export function fetchKernel(dev = false): Promise<KernelRelease> {
	return (once ??= fetchOnce(dev));
}

/** Write `bytes` to `file` unless it holds them already (atomically). */
async function writeIfChanged(file: string, bytes: Uint8Array): Promise<void> {
	try {
		if (Buffer.compare(await readFile(file), bytes) === 0) return;
	} catch {}
	await writeFile(`${file}.tmp`, bytes);
	await rename(`${file}.tmp`, file);
}

let split: Promise<{ smp: boolean }> | undefined;

/**
 * Make web/kernel/page/ from KERNEL_FILE (once per process unless `again`,
 * which the dev server passes when the file changes; after fetchKernel()):
 * the UP bundle without the SMP patch section and, if there is a patch,
 * the SMP bundle. A bundle without the section (every release so far)
 * gives the same UP file and no SMP file.
 */
export function splitKernel(again = false): Promise<{ smp: boolean }> {
	if (again) split = undefined;
	return (split ??= (async () => {
		const bytes = new Uint8Array(await readFile(KERNEL_FILE));
		await mkdir(PAGE_DIR, { recursive: true });
		const up = withoutSmpPatch(bytes);
		await writeIfChanged(PAGE_KERNEL_FILE, up);
		if (up === bytes) {
			await rm(PAGE_SMP_FILE, { force: true });
			return { smp: false };
		}
		const smp = await smpKernelFromBundle(bytes);
		if (!smp) throw new Error(`${ASSET}: an SMP patch section that makes no kernel`);
		await writeIfChanged(PAGE_SMP_FILE, smp);
		log(`SMP patch: UP ${(up.length / 1048576).toFixed(1)} MiB and SMP ${(smp.length / 1048576).toFixed(1)} MiB bundles in web/kernel/page/`);
		return { smp: true };
	})());
}

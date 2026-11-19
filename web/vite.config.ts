// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
// The unkernel page: Vite for the client (index.html, src/: React and
// Tailwind), Nitro for the build output (.output/ with the Node preset,
// `node .output/server/index.mjs`; .vercel/output/ on Vercel) and the
// response headers. The page is static: the kernel
// (kernel/unkernel-alpine.wasm, the newest GitHub release's, which
// scripts/kernel.ts fetches before anything else) is a Vite asset. The page's service worker
// (the guest preview's relay) is public/vm-sw.js, the preview's server
// fallback server/vm.ts.
//
// Build settings (environment variables): KW_KERNEL, KW_KERNEL_RELEASE,
// GITHUB_TOKEN pick the kernel (scripts/kernel.ts; the dev server runs
// web/kernel/'s file as it is).
//
// Runtime settings (environment variables of the built Node server):
//   PORT, HOST (NITRO_PORT, NITRO_HOST)  where it listens (default: port 3000, all interfaces)
import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";
import { nitro } from "nitro/vite";
import { fetchKernel, KERNEL_FILE, PAGE_SMP_FILE, splitKernel } from "./scripts/kernel.ts";

const git = (...args: string[]) => {
	try { return execFileSync("git", args, { cwd: import.meta.dirname, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim(); }
	catch { return ""; }
};

/**
 * __KW_BUILD__ (src/env.d.ts), shown in the About dialog: the Linux release
 * from the kernel's banner, the kernel's release tag and the page's commit.
 * Empty where unknown (no git).
 */
async function buildInfo(dev: boolean) {
	const kernel = await fetchKernel(dev);
	await splitKernel();
	const linux = /Linux version (\S+)/.exec(await readFile(KERNEL_FILE, "latin1"))?.[1] ?? "";
	const [commit = "", date = ""] = git("log", "-1", "--format=%H %cI").split(" ");
	return {
		linux,
		kernel: kernel.tag,
		commit: commit || process.env.VERCEL_GIT_COMMIT_SHA || "",
		date,
	};
}

export default defineConfig({
	// Every interface, so a phone on the LAN can open http://<this-machine>:8080/.
	server: {
		host: true,
		port: 8080,
		// The dev server's own responses (modules, /@fs/) do not go through
		// Nitro's route rules below. A worker script must carry COEP itself,
		// or a cross-origin isolated page refuses to start it (?worker=1).
		headers: { "cross-origin-opener-policy": "same-origin", "cross-origin-embedder-policy": "require-corp" },
	},
	build: { target: "esnext" },
	// The SDK's worker mode (?worker=1): js/web/worker.ts starts a module worker.
	worker: { format: "es" },
	plugins: [
		{
			// The kernel first: fetched before the build resolves it, and
			// __KW_BUILD__ reads its banner.
			name: "unkernel:kernel",
			// The dev server keeps the file that is there (a local build).
			async config(_, { command }) {
				return { define: { __KW_BUILD__: JSON.stringify(await buildInfo(command === "serve")) } };
			},
		},
		{
			// The SMP bundle (scripts/kernel.ts splitKernel()) as an asset of its
			// own, hashed like the UP one, and its URL for src/sdk.ts; null when
			// the kernel has no SMP patch. Emitted whether or not code uses it.
			name: "unkernel:kernel-smp",
			// The dev server serves web/kernel/page/: split again when a local
			// build replaces the kernel (kernel/build.sh bundle), as it was
			// served fresh before there was a split.
			configureServer(server) {
				server.watcher.add(KERNEL_FILE);
				server.watcher.on("change", (file) => {
					if (file === KERNEL_FILE) splitKernel(true).catch((e: unknown) => console.error(`[kernel] ${(e as Error).message}`));
				});
			},
			resolveId(id) {
				return id === "virtual:unkernel-smp-kernel" ? "\0virtual:unkernel-smp-kernel" : null;
			},
			async load(id) {
				if (id !== "\0virtual:unkernel-smp-kernel") return null;
				const { smp } = await splitKernel();
				if (!smp) return "export const kernelSmpUrl = null;";
				if (this.environment.mode === "dev") return `export const kernelSmpUrl = new URL(${JSON.stringify(`/@fs${PAGE_SMP_FILE}`)}, import.meta.url);`;
				const ref = this.emitFile({ type: "asset", name: "unkernel-alpine-smp.wasm", source: await readFile(PAGE_SMP_FILE) });
				return `export const kernelSmpUrl = new URL(import.meta.ROLLUP_FILE_URL_${ref}, import.meta.url);`;
			},
		},
		{
			// Files in public/ are answered by Nitro's dev handler, with neither
			// server.headers above nor the route rules below. Set the isolation
			// headers first, so a document there is
			// cross-origin isolated like the page.
			name: "unkernel:isolate-public",
			configureServer(server) {
				server.middlewares.use((_req, res, next) => {
					res.setHeader("cross-origin-opener-policy", "same-origin");
					res.setHeader("cross-origin-embedder-policy", "require-corp");
					next();
				});
			},
		},
		react(),
		tailwindcss(),
		nitro({
			// The kernel (9 MiB) is sent br/zstd/gzip-encoded by the Node server.
			compressPublicAssets: true,
			// The guest preview (src/preview.ts): /vm/** reaches the server only when the
			// service worker (public/vm-sw.js, served at /vm-sw.js) did not answer.
			handlers: [{ route: "/vm/**", handler: "./server/vm.ts" }],
			routeRules: {
				// Cross-origin isolation (secure contexts only), so SharedArrayBuffer
				// is available. The kernel does not need it yet (its memory is not shared).
				"/**": {
					headers: {
						"cross-origin-opener-policy": "same-origin",
						"cross-origin-embedder-policy": "require-corp",
					},
				},
				// Checked for updates on every load (src/sw.ts); not cached by the CDN.
				"/vm-sw.js": { headers: { "cache-control": "no-cache" } },
			},
		}),
	],
});

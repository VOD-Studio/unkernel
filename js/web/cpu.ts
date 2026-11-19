// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
// Start a secondary CPU of an SMP kernel (web-cpu-entry.ts, core/cpu.ts)
// on a module Web Worker: Platform.spawnCpu in browsers, the counterpart of
// js/node/cpu.ts. Called from the kernel's own thread, which must be a
// worker (worker mode's kernel worker, or a worker the caller runs the
// kernel in): CPU 0 blocks in memory.atomic.wait32 while it waits for
// another CPU, which traps on a browser's main thread (webCpuBlocker()).
// The CPU workers are nested workers of that thread, and each gets the
// compiled module and the shared memory in its first message.
//
// From source (the page's Vite build, Vite's dev server) the worker is
// `new Worker(new URL(...), { type: "module" })` on the entry file, which
// Vite bundles as a worker (nested in the kernel worker's bundle). `bun run
// build` (build.config.ts, WORKERS) replaces the URL below (the expression
// must appear exactly once in this file) with inlineCpuUrl(code): a Blob
// URL, revoked once the worker has started, in the web entry and inside
// the inlined kernel worker, which starts the CPUs in worker mode.

import type { CpuEndpoint, CpuInit, CpuMessage } from "../core/cpu.ts";

let blobUrl: string | undefined;

/** @internal The dist's CPU worker: its code (inlined by the build) as a Blob URL. */
export function inlineCpuUrl(code: string): URL {
	blobUrl = URL.createObjectURL(new Blob([code], { type: "text/javascript" }));
	return new URL(blobUrl);
}

/**
 * Why this thread cannot run CPU threads, or undefined if it can: shared
 * memory (a cross-origin isolated page), Web Workers here (nested ones in
 * a worker), Atomics.waitAsync (CPU 0's idle wait for another CPU's IPI)
 * and a thread that may block (not a browser's main thread). With
 * `worker: true`, for a kernel in a worker that this thread starts
 * (createKernel({ worker: true })): the page's view, without the
 * main-thread check; the worker checks again before it starts CPUs.
 */
export function webCpuBlocker(opts: { worker?: boolean } = {}): string | undefined {
	if (typeof SharedArrayBuffer !== "function" || (typeof crossOriginIsolated === "boolean" && !crossOriginIsolated))
		return "shared memory needs a cross-origin isolated page (COOP same-origin and COEP require-corp, served over https or from localhost)";
	if (typeof Worker !== "function") return "this thread cannot start Web Workers";
	if (typeof (Atomics as { waitAsync?: unknown }).waitAsync !== "function") return "this engine has no Atomics.waitAsync (CPU 0's idle wait for the other CPUs)";
	if (opts.worker) return undefined;
	try {
		Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 1, 0);
	} catch {
		return "a CPU blocks while it waits for another (memory.atomic.wait32), which a browser's main thread may not: run the kernel in a worker (worker: true)";
	}
	return undefined;
}

export function spawnWebCpu(init: CpuInit): CpuEndpoint {
	blobUrl = undefined;
	const w = new Worker(new URL("./web-cpu-entry.ts", import.meta.url), { type: "module", name: `unkernel-cpu${init.cpu}` });
	const url = blobUrl as string | undefined;
	const revoke = () => {
		if (url) URL.revokeObjectURL(url);
	};
	w.addEventListener("message", revoke, { once: true });
	w.addEventListener("error", revoke, { once: true });
	w.postMessage(init);
	return {
		listen(h) {
			w.addEventListener("message", (e: MessageEvent<CpuMessage>) => h.message(e.data));
			w.addEventListener("messageerror", () => h.error(new Error(`a message from CPU ${init.cpu}'s worker could not be read (structured clone failed)`)));
			// A script that fails to load or throws at top level: an ErrorEvent, often without a message.
			w.addEventListener("error", (e) => {
				e.preventDefault();
				h.error(new Error(e.message || `CPU ${init.cpu}'s worker failed to start (its script did not load, or threw before it ran)`));
			});
		},
		terminate: () => w.terminate(),
	};
}

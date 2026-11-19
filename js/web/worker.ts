// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
// Start the kernel worker (web-worker-entry.ts) on a module Web Worker, for
// createKernel({ worker: true }) (core/worker-host.ts).
//
// From source (the page's Vite build, Vite's dev server) the worker is
// `new Worker(new URL(...), { type: "module" })` on the entry file, which
// Vite bundles as a worker. `bun run build` (build.config.ts) bundles the entry
// into one minified ES module that imports nothing and replaces the URL
// below (the expression must appear exactly once in this file) with
// inlineWorkerUrl(code): a Blob URL, revoked once the worker has started.
// So the published package has no worker file and needs nothing from a
// downstream bundler.

import type { WorkerEndpoint } from "../core/worker-protocol.ts";

let blobUrl: string | undefined;

/** @internal The dist's worker: its code (inlined by the build) as a Blob URL. */
export function inlineWorkerUrl(code: string): URL {
	blobUrl = URL.createObjectURL(new Blob([code], { type: "text/javascript" }));
	return new URL(blobUrl);
}

export function spawnWebWorker(): WorkerEndpoint {
	blobUrl = undefined;
	const w = new Worker(new URL("./web-worker-entry.ts", import.meta.url), { type: "module", name: "unkernel" });
	const url = blobUrl as string | undefined;
	const revoke = () => {
		if (url) URL.revokeObjectURL(url);
	};
	w.addEventListener("message", revoke, { once: true });
	w.addEventListener("error", revoke, { once: true });
	return {
		post: (msg, transfer) => w.postMessage(msg, transfer ?? []),
		listen(h) {
			w.addEventListener("message", (e) => h.message(e.data));
			w.addEventListener("messageerror", () => h.error(new Error("a message from the kernel worker could not be read (structured clone failed)")));
			// A script that fails to load or throws at top level: an ErrorEvent, often without a message.
			w.addEventListener("error", (e) => {
				e.preventDefault();
				h.error(new Error(e.message || "the kernel worker failed to start (its script did not load, or threw before it ran)"));
			});
		},
		terminate: () => w.terminate(),
	};
}

// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
// unkernel for Node (>= 24): the universal SDK plus file disks, direct
// networking over host sockets, host directories as guest mounts
// (nodeFs), and the bundled kernel read from disk.
//
//   import { createKernel } from "@vod-studio/unkernel";
//   const vm = await createKernel();            // bundled Alpine, no network
//   vm.onOutput((b) => process.stdout.write(b));
//   vm.write("uname -a; poweroff\n");
//   const { code } = await vm.exited;
//
//   const vm = await createKernel({ worker: true }); // same, in a worker thread
//
// Nothing else imports this module (the CLI uses node/platform.ts), so the
// bundled kernel's URL below stays relative to dist/node.mjs.

import { createKernelOn, type CreateKernelOptions, type KernelHandle, type KernelInstance, type WorkerOption } from "./core/instance.ts";
import type { WorkerKernel } from "./core/worker-host.ts";
import { nodePlatform } from "./node/platform.ts";

export * from "./core/index.ts";
export { FileBase, FileDisk, createImageFromKwsparse, openDisk } from "./node/disk.ts";
export type { OpenDiskOptions } from "./node/disk.ts";
export { nodeFs } from "./node/nodefs.ts";
// wispBackend here sends Origin: http://localhost by default (it shadows the core export).
export { NODE_WISP_HEADERS, directBackend, wispBackend } from "./node/net.ts";

/**
 * The bundled kernel: vmlinux32.wasm with the Alpine root file system and
 * its command line in custom sections. In a source checkout this resolves
 * (through a symlink) to vendor/build/bundle/unkernel-alpine.wasm.
 */
export const bundledKernelUrl: URL = new URL("./unkernel-alpine.wasm", import.meta.url);

const platform = nodePlatform(bundledKernelUrl);

/**
 * Load, compile and boot a kernel (default: the bundled Alpine) and return
 * the running instance. Rejects with a BootError if it cannot start. With
 * `worker: true` the kernel is loaded, compiled and run in a worker thread
 * and the result is a WorkerKernel (no low-level `kernel`; see
 * WorkerOption for what it does not support yet).
 */
export function createKernel(opts: CreateKernelOptions & { worker: true }): Promise<WorkerKernel>;
export function createKernel(opts?: CreateKernelOptions & { worker?: false }): Promise<KernelInstance>;
export function createKernel(opts?: CreateKernelOptions & WorkerOption): Promise<KernelHandle>;
export function createKernel(opts: CreateKernelOptions & WorkerOption = {}): Promise<KernelHandle> {
	return createKernelOn(platform, opts);
}

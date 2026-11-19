// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
// The page's configuration, from its URL. The kernel is always the page's
// own unkernel-alpine.wasm (sdk.ts), with Alpine bundled. Each parameter
// except ?simulate, ?demo and ?showcase has a control under Options in the status panel
// (ui.ts), which rebuilds the URL on Reboot (keeping the others).
//
//   ?mem=MiB                           kernel memory (default: auto, from the SDK's autoMemoryMiB():
//                                      256 on phones, 512 otherwise, less on low-memory devices)
//   ?append=<cmdline>                  kernel command line
//   ?net=0                             no network device (else: the Wisp server(s), default:
//                                      the project's)
//   ?wisp=<url>[,<url>...] | ?wisp=0   Wisp servers to race (0 = no network device)
//   ?jit=0                             kwemu interprets only (default: its JIT tier compiles hot
//                                      guest code to WebAssembly; counters in KW.jitStats())
//   ?verbose=1                         write every kernel message to the terminal, in gray
//                                      (default: kernel messages go to the Kernel log tab, and
//                                      during boot the newest one shows on the transient line)
//   ?data=0                            no data disk. By default (when IndexedDB exists) the data
//                                      disk, an ext4 fs labelled kwdata, is attached as /dev/wda
//                                      and kept in IndexedDB (data.ts); the guest's root is an
//                                      overlay whose changes live on it. Its template is the
//                                      kernel bundle's section unkernel.datadisk. One tab at a
//                                      time: another tab gets an unsaved in-memory copy.
//                                      KW.exportData(), KW.importData(file), KW.resetData() (also
//                                      buttons in the panel). Hiding or leaving the page and
//                                      Reboot ask the guest to sync first (KW.sync(), the SDK's
//                                      sync()).
//   ?display=0                         no display. By default the guest gets /dev/fb0 (kwfb,
//                                      640x480), and a canvas over the terminal shows it while a
//                                      program has it open (try `glimmer`). Nothing is
//                                      allocated until then.
//   ?sound=0                           no sound card. By default the guest gets ALSA hw:0,0 and
//                                      /dev/dsp (kwsnd, playback), played with Web Audio
//                                      (audio.ts; try `glimmer`). Nothing runs until a program
//                                      plays; the first tap or key press after that unmutes.
//   ?root=initramfs                   safe mode for this boot (kw.root=initramfs): the plain
//                                      image root instead of the overlay root; /data stays
//                                      mounted (the panel's Safe mode button; kernel/README.md)
//   ?worker=1                          experimental: run the kernel in a Web Worker (the SDK's
//                                      createKernel({ worker: true })), so it never blocks the
//                                      page. The data disk and the Wisp network are built in the
//                                      worker from specs; the display, input devices and sound
//                                      work as on the page's thread. Console and evdev input and
//                                      frames go through shared memory when the page is
//                                      cross-origin isolated (https or localhost; a plain-http
//                                      LAN page has no SharedArrayBuffer), else as messages,
//                                      which wait up to 20 ms while the guest is busy. Default:
//                                      on the page's thread.
//   ?shared=0                          with ?worker=1: messages even where shared memory works
//                                      (to compare the two)
//   ?smp=N                             experimental: boot the SMP kernel on N CPUs (2 to 8, at most
//                                      navigator.hardwareConcurrency), each CPU in a Web Worker
//                                      of its own on one shared memory; implies ?worker=1 (CPU 0
//                                      blocks while it waits for another CPU, which a page's main
//                                      thread may not). Needs the page's SMP kernel (sdk.ts
//                                      kernelSmpUrl: a release bundle with an SMP patch) and
//                                      cross-origin isolation (https or localhost); otherwise, or
//                                      when the SMP kernel fails to load or start, the page boots
//                                      on one CPU as usual (smpBlocker(), boot.ts). No Suspend.
//                                      Default (and ?smp=1): one CPU, the UP kernel.
//   ?demo=<id>                         launch that demo once the guest is up (launcher.ts). The
//                                      launcher sets it on each launch, so a reload reopens the
//                                      last demo, and closing its window removes it; read
//                                      there, not here. ?demo=- runs the showcase.
//   ?showcase[=warm,<step>,...]        a fast scripted tour of the demos with captions; warm
//                                      pre-installs them, step ids pick a subset (showcase.ts);
//                                      read in launcher.ts
//   ?simulate=nojspi,oom,lowmem        fake a failure (for tests)
import { DEFAULT_MEMORY_FALLBACK_MIB, autoMemoryMiB, kernelSmpUrl, kernelUrl, webCpuBlocker } from "./sdk.ts";

/** The project's source, linked from About and the boot notes. */
export const REPO = "https://github.com/pithings/unkernel";

/** The command line without ?append=. */
export const DEFAULT_CMDLINE = "console=hvc0 rdinit=/init";

export interface Config {
	kernelUrl: string;
	memMiB: number;
	memWhy: string;
	/** What auto would pick on this device, even when ?mem= is given. */
	memAutoMiB: number;
	/** ?mem= as given, or null for auto. */
	memParam: string | null;
	memFallbackMiB: number[];
	cmdline: string;
	/** The command line as ?append= sets it (cmdline without kw.root=). */
	baseCmdline: string;
	/** ?append= or ?root= was given (the command line is shown only then). */
	cmdlineGiven: boolean;
	/** The guest network device (?net=0 or ?wisp=0 removes it). */
	net: boolean;
	/** ?wisp= servers, or null for the SDK's DEFAULT_WISP_SERVERS. */
	wisp: string[] | null;
	/** kwemu's JIT tier (?jit=0 turns it off). */
	jit: boolean;
	/** A display, /dev/fb0 (on unless ?display=0). */
	display: boolean;
	/** A sound card, played with Web Audio (on unless ?sound=0). */
	sound: boolean;
	/** Attach the data disk (?data=0 turns it off). */
	data: boolean;
	/** ?root=initramfs: safe mode (kw.root=initramfs) for this boot, else null. */
	root: "initramfs" | null;
	/** The kernel runs in a Web Worker (with the data disk, network, display, input and sound): ?worker=1, or more than one CPU. */
	worker: boolean;
	/** ?worker=1 as given (the Worker thread option). */
	workerParam: boolean;
	/** The SMP kernel's URL (sdk.ts kernelSmpUrl), or null when the page has none. */
	kernelSmpUrl: string | null;
	/** ?smp= as given (1 to 8; 1 when absent): the CPUs option. */
	smpParam: number;
	/** CPUs this load boots with: smpParam where possible (capped at cpuMax), else 1. */
	cpus: number;
	/** Why this page cannot boot more than one CPU (smpBlocker()), or null. */
	smpBlocked: string | null;
	/** Why this load boots on one CPU although ?smp= asks for more, or null. */
	smpWhy: string | null;
	/** The most CPUs offered: navigator.hardwareConcurrency, at most 8 (the kernel's limit). */
	cpuMax: number;
	/** The count the CPUs option suggests, or 0 when this device has too few threads to suggest one. */
	cpuSuggested: number;
	/** Worker mode: shared memory for input and frames where it works (?shared=0: messages). */
	shared: boolean;
	verbose: boolean;
	simulate: string[];
	/** A touch device or a mobile user agent. */
	mobile: boolean;
	coarse: boolean;
	mobileUA: boolean;
	fontSize: number;
}

/** The kernel's limit (NR_CPUS in kw_smp.config). */
export const MAX_CPUS = 8;

/**
 * Why this page cannot boot the SMP kernel, or null: no SMP kernel in the
 * page's bundle, no cross-origin isolation (shared memory), no Web
 * Workers or no Atomics.waitAsync (webCpuBlocker()), or one CPU thread.
 * JSPI and nested workers in the kernel worker are checked there: a worker
 * that cannot start CPUs boots the SMP kernel on one CPU (boot.ts says so).
 */
export function smpBlocker(): string | null {
	if (!kernelSmpUrl) return "this page's kernel has no SMP build (its release bundle carries no SMP patch)";
	const why = webCpuBlocker({ worker: true });
	if (why) return why;
	if ((navigator.hardwareConcurrency || 1) < 2) return "this device reports a single CPU thread";
	return null;
}

/** sessionStorage: boot this tab's next load on one CPU (boot.ts bootUpOnce()), with why. */
export const UP_ONCE_KEY = "kw-up-once";
function takeUpOnce(): string | null {
	try {
		const v = sessionStorage.getItem(UP_ONCE_KEY);
		sessionStorage.removeItem(UP_ONCE_KEY);
		return v;
	} catch {
		return null;
	}
}

export function readConfig(search: string = location.search): Config {
	const params = new URLSearchParams(search);
	const coarse = typeof matchMedia === "function" && matchMedia("(pointer: coarse)").matches;
	const mobileUA = /Android|iPhone|iPad|Mobi/i.test(navigator.userAgent);
	const mobile = coarse || mobileUA;
	const memParam = params.get("mem");
	const auto = autoMemoryMiB({ mobile });
	const fixed = memParam !== null && Number(memParam) > 0;
	const append = params.get("append");
	const root = params.get("root") === "initramfs" ? "initramfs" : null;
	const wispParam = params.get("wisp");
	const wisp = wispParam && wispParam !== "0" ? wispParam.split(",").map((s) => s.trim()).filter(Boolean) : null;
	// CPUs: as many as asked where the page can, never more than the host's
	// threads. The suggestion leaves half of them to the host (the page, the
	// browser, other tabs): a guest CPU whose thread the host deschedules
	// stalls the others when they wait for it (.agents/status.md, SMP).
	const hc = navigator.hardwareConcurrency || 1;
	const cpuMax = Math.max(1, Math.min(MAX_CPUS, hc));
	const half = Math.min(4, Math.floor(hc / 2));
	const smpParam = Math.max(1, Math.min(MAX_CPUS, Math.floor(Number(params.get("smp"))) || 1));
	const smpBlocked = smpBlocker();
	const upOnce = smpParam > 1 ? takeUpOnce() : null;
	const smpWhy = smpParam < 2 ? null : smpBlocked ?? upOnce;
	const cpus = smpWhy ? 1 : Math.min(smpParam, cpuMax);
	const workerParam = params.get("worker") === "1";
	return {
		kernelUrl: kernelUrl.pathname,
		memMiB: fixed ? Number(memParam) : auto.mib,
		memWhy: fixed ? `?mem=${memParam}` : auto.why,
		memAutoMiB: auto.mib,
		memParam: fixed ? memParam : null,
		memFallbackMiB: [...DEFAULT_MEMORY_FALLBACK_MIB],
		cmdline: root ? `${append || DEFAULT_CMDLINE} kw.root=${root}` : append || DEFAULT_CMDLINE,
		baseCmdline: append || DEFAULT_CMDLINE,
		cmdlineGiven: !!append || !!root,
		net: params.get("net") !== "0" && wispParam !== "0",
		wisp: wisp?.length ? wisp : null,
		jit: params.get("jit") !== "0",
		display: params.get("display") !== "0",
		sound: params.get("sound") !== "0",
		data: params.get("data") !== "0",
		root,
		worker: workerParam || cpus > 1,
		workerParam,
		kernelSmpUrl: kernelSmpUrl?.pathname ?? null,
		smpParam,
		cpus,
		smpBlocked,
		smpWhy,
		cpuMax,
		cpuSuggested: half >= 2 ? Math.min(half, cpuMax) : 0,
		shared: params.get("shared") !== "0",
		verbose: params.get("verbose") === "1",
		simulate: (params.get("simulate") || "").split(",").filter(Boolean),
		mobile,
		coarse,
		mobileUA,
		fontSize: 14,
	};
}

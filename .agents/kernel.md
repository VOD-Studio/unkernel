# Kernel

The kernel-side reference for agents. kernel/README.md describes the same
system for users (build steps, CLI options, devices, the guest image). This
file covers how to change the kernel and what must not break.

## Tree and patch workflow

`vendor/src/linux-wasm-kernel` is a git tree on branch `kw-riscv-user`:
base `7595a62d45e` (Linux v7.3.4 from kernel.org) plus one commit per file in
`kernel/patches/linux/`. `arch/wasm` grew from Joel Severin's linux-wasm
series (`joelseverin/linux`, branch `wasm-7.0`); the first two patches
(the arch panic hook, modpost on Wasm) are his as they were, and the arch
patch, which keeps about a quarter of its lines from his port, names him
in a `Co-developed-by` trailer (keep it when rewording that patch). Nothing
is fetched from that fork.
On a fresh clone, build.sh (`prepare_kernel_tree`) creates the branch with
`git am` on a shallow fetch (`git fetch --deepen=100` for more history).

```sh
cd vendor/src/linux-wasm-kernel
git commit -a          # a new patch, or `git commit --fixup X` and then
                       # GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash 7595a62d45e
cd ../../..
kernel/build.sh kernel
rm kernel/patches/linux/*.patch
git -C vendor/src/linux-wasm-kernel format-patch -N -o "$PWD/kernel/patches/linux" 7595a62d45e..kw-riscv-user
```

- The series has one patch per piece: generic changes first (Joel's two,
  stock LLVM, `VMALLOC_FLAT`, 9p `metatimeout`, the kthread park points,
  the random vmfork reseed),
  then the arch, the ISA and hwprobe, each driver (kwblk, kwnet, kwfb,
  kwinput, sysrq, kwsnd, kwvsock, kwshm), parking, kwvsock's reset after
  a snapshot restore (it needs both), and `kw_defconfig` last. A fix or an extension of one of
  them is a `git commit --fixup` of that patch, autosquashed; a new piece
  (a driver, a generic change) is a new patch, placed with its kind, with a
  kernel-style subject (`wasm: ...`). Its config options go in the
  `kw_defconfig` patch. Each patch need not build on its own; the whole
  series must.
- Keep `-N` (no `n/m` counter) on export.
- The SMP work (status.md item 8) is on the `smp` branch with its kernel
  tree in the worktree `vendor/src/linux-smp` (branch `kw-smp`), whose
  new patches follow `kw_defconfig`: the shared-memory build, the atomic
  tweaks, then percpu-km, `ARCH_TASKS_STAY_ON_CPU` (sched with the
  exit-to-user hook, kthread and workqueue), the csd wait hooks
  (kernel/smp.c), the arch and driver SMP patches, the waits that
  block and the spinlocks taken out of turn (below, SMP, Waiting for
  another CPU). There
  `kernel/patches/linux/` equals `format-patch -N 7595a62d45e..kw-smp`.
- To check that the series applies to a clean base:
  `git -C vendor/src/linux-wasm-kernel worktree add /path/x 7595a62d45e && git -C /path/x am "$PWD"/kernel/patches/linux/*.patch`,
  built with `KSRC=/path/x KOUT=vendor/build/kernel-x kernel/build.sh kernel`.
- **Config**: `arch/wasm/configs/kw_defconfig` is a hand-written list of
  explicit choices. Never replace it with `savedefconfig` output. build.sh
  reruns `make kw_defconfig` whenever the file is newer than
  `$KOUT/.config`, which overwrites any menuconfig change. Put every change
  in kw_defconfig, rebuild, then check `$KOUT/.config`: Kconfig drops
  options whose dependencies are not met without saying so.
- Kbuild runs the toolchain through
  `kernel/tools/fake-llvm/llvm-wrapper.py` (`LLVM=` is the wrapper and
  `REAL_LLVM=` the real tools). See toolchain.md.
- The kernel builds without warnings; keep it that way. kw_defconfig sets
  `FRAME_WARN=3072` because clang's wasm backend gives each variadic call
  its own 16-byte stack slot (`snmp_seq_show`: 2304 bytes, all others
  under 1024).

## Where things are in the kernel tree

| What | Where |
| --- | --- |
| entry, task switch | `arch/wasm/kernel/entry.S`, `process.c` |
| parking (all tasks to a resumable point), `/proc/kwpark` | `arch/wasm/kernel/park.c`, `asm/park.h`, `include/linux/kw_park.h` (park points in kernel threads) |
| user-mode loop (`kw_run` slices, IRQ and timer checks, yield) | `arch/wasm/kernel/traps.c` (`KW_SLICE` 200000, `KW_ENTRY_COST` 1000, `KW_YIELD_NS` 20 ms) |
| WASI wrappers, `wasi_ptr()` | `arch/wasm/kernel/wasi.c` |
| sync IRQ | `arch/wasm/kernel/sync.c` |
| kwemu glue, ABI check, `kw_cpu_storage` | `arch/wasm/mm/tlb.c` |
| software uaccess and the fault path | `arch/wasm/mm/fault.c` |
| flat vmalloc | `mm/vmalloc-flat.c` (`CONFIG_VMALLOC_FLAT`) |
| riscv syscall table | `arch/wasm/kernel/Makefile.syscalls`, `syscall_table.c` (from `scripts/syscall.tbl`, abis `riscv rlimit memfd_secret`) |
| riscv signal frames | `arch/wasm/kernel/signal.c`, `arch/wasm/mm/sigpage.c` |
| riscv uapi | `arch/wasm/include/uapi/asm/` (ptrace, sigcontext, ucontext, hwcap, hwprobe), `include/asm/elf.h` |
| `riscv_hwprobe`, `riscv_flush_icache` | `arch/wasm/kernel/sys_riscv.c` |
| ISA extensions: the table, `kw.isa=`, the cpuinfo `isa` line, the hwprobe bits | `arch/wasm/kernel/cpu.c`, `kw_isa_init()` from `tlb.c` |
| IRQ numbers | `arch/wasm/include/asm/irq.h` |
| devices | `drivers/tty/hvc/hvc_wasm.c`, `drivers/block/kwblk.c`, `drivers/net/kwnet.c`, `drivers/video/fbdev/kwfb.c`, `drivers/input/kwinput.c`, `sound/drivers/kwsnd.c`, `net/vmw_vsock/kwvsock.c`, `drivers/misc/kwshm.c` with `include/uapi/linux/kwshm.h` |

## The kwemu contract (`include/kw_emu.h`)

`include/kw_emu.h` is the source of truth. The kernel's copy is
`arch/wasm/include/asm/kw_emu.h`. build.sh copies the header over it and
warns if they differed, so a header change also needs a kernel commit and a
patch re-export.

- `KW_ABI_VERSION` is 8. `tlb.c` compares it with `kw_abi_version()` at
  boot and panics on a mismatch. Bump it, in both copies, on any change to
  the layout or the semantics. A new `KW_ISA_*` bit is an ABI change;
  implementing an extension that already has a bit is not. Host imports
  (below) are not part of it.
- Optional ISA extensions: `kw_cpu_init` enables every one kwemu
  implements, and `tlb.c` then calls `kw_isa_init()` (cpu.c), which calls
  `kw_set_isa()` once with what `kw.isa=` leaves on and advertises exactly
  the set it returns. `kw_set_isa()` drops all decoded code, so it is
  meant for boot only.
- `kw_host_reset()` is for a restored snapshot (park.c, `__kw_resume`):
  the memory now belongs to a new module instance, so kwemu forgets its
  JIT slots without `kw_host_jit_free`, asks `kw_host_jit_caps` again and
  drops all decoded code.
- `KW_CPU_SIZE` is 8 MiB, reserved statically (`kw_cpu_storage`), so it
  comes out of guest RAM. Zig checks its layouts against the header at
  compile time through translate-c. About 53 KiB of it is spare
  (kwemu.md, Sizes).
- kwemu has no allocator and no globals. All state lives in `struct kw_cpu`
  and `struct kw_regs`, which the kernel owns.
- Sv39 tables are read at `phys_base + pa`, and kwemu never writes a PTE.
  If A is 0, or D is 0 on a store, it raises `KW_EV_FAULT`. The kernel then
  sets the bits directly (a fast path, like Svadu) or goes through
  `handle_mm_fault`.
- Flushes: the kernel calls `kw_flush_tlb_range`/`kw_flush_tlb_all` from
  `flush_tlb_*` and `update_mmu_cache`, and `kw_set_pgd` from `switch_mm`.
  Code the kernel or the host writes (COW copies, page reuse, file data,
  kwshm) becomes visible only after one of these calls or a guest FENCE.I.
  kwemu tracks guest stores into code exactly by itself.
- `kw_clear_reservation` must be called on every context switch, signal
  delivery and sigreturn (process.c, signal.c), or LR/SC breaks.
- kwemu polls `*irq_pending` (`&wasm_host_irqs`) on entry and at every
  block end, so at least every 64 instructions, and returns
  `KW_EV_INTERRUPT`.
- The `cycle`, `time` and `instret` CSRs return `icount`, not wall time.
  That is why there is no vDSO and `clock_gettime` is a real syscall.
  Signal handlers return through the `[sigpage]` mapping
  (`li a7,139; ecall`).
- The JIT imports (`unkernel.kw_host_jit_caps`/`compile`/`free`) are not
  part of the ABI version (a host takes a missing `flags` argument of
  `compile`, from a kwemu before ABI 8, as 0), and the kernel never calls
  them. kwemu imports
  them itself and owns 1024 stub functions in the kernel's exported
  `__indirect_function_table`. Details are in kwemu.md.

## Memory model

- The kernel runs only in the direct map: virtual = physical = linear
  address, and `phys_base` is 0.
- User page tables use the Sv39 layout with riscv's PTE bits
  (`_PAGE_PROT_NONE` = G, the riscv swap format), in 3 levels with the PUD
  folded.
- vmalloc returns direct-mapped memory, so `vmap()` of scattered pages
  fails (nothing in this config hits that). There is no `VMAP_STACK` and no
  stack guard, and per-cpu memory uses `percpu-km`.
- uaccess (`copy_{to,from}_user`, `clear_user`, futex ops) walks the user
  page tables in software and faults pages in. `get_user`/`put_user` do a
  single scalar load or store for aligned 1-, 2-, 4- and 8-byte addresses
  (single-copy atomic on a shared memory, unlike `memcpy`'s `memory.copy`)
  and fall back to `raw_copy_{from,to}_user` when unaligned; `strn*_user`
  are the generic ones on top of that. As a hardware MMU
  retries the access, `kw_user_addr()` walks again for as long as the
  fault succeeds (another thread may take the page away in between: a
  zap, a fork's COW write-protect); a real fault error, a fatal signal
  or `pagefault_disable()` ends it, and after 10000 rounds it gives up
  with a one-time warning (a fault handler that never maps the page;
  on UP nothing else would end the loop; beside host load other threads
  took the page away up to 17 times in a row, 2026-11-17). A kernel access is ended by a
  fatal signal only, so its faults wait killable, not interruptible
  (without `FAULT_FLAG_INTERRUPTIBLE`, as GUP): an interruptible wait
  that a pending signal ends at once would spin, and the kernel does not
  poll the tick in such a loop. The futex ops on user words are wasm
  atomics (plain accesses without the atomics feature).
- Kernel memory is not shared (no SharedArrayBuffer) by default. The
  arch Makefile's experimental `KW_ATOMICS=1` (wasm atomics, so the
  `__atomic_*` builtins become atomic instructions) and
  `KW_SHARED_MEMORY=1` (also `--shared-memory`: passive data segments,
  initialised by the start function `__wasm_init_memory`) make variables
  build a UP kernel that boots on a shared memory; kwemu must then be
  built with `zig build -Dkwemu-atomics=true`, and the host detects the
  shared import (status.md, SMP). An SMP kernel (SMP below) always links
  that way. Guest RAM is below
  4 GiB, which makes the lowering exact.

## Tasks: JSPI on one thread

- Every kernel task runs on its own wasm stack. `__switch_to` calls the
  suspending import `wasm_switch_to`, which parks the current stack on a
  promise and resumes the next one, or starts a fresh stack through the
  promising export `ret_from_fork`. `__stack_pointer` and `current` are
  wasm globals, saved in locals across the switch (`entry.S`).
- The kernel is UP with `ARCH_NO_PREEMPT` (the SMP build, SMP below, has
  one such thread per CPU).
- Suspending imports: `unkernel.wasm_switch_to` and the WASI
  `poll_oneoff`, `sched_yield` and `proc_exit`. They suspend only when the
  host returns a promise. The console read path uses a zero-timeout
  `poll_oneoff`, which must return synchronously.
- Every other import must return synchronously. In particular
  `wasm_driver_block_submit` is called by blk-mq in atomic context.
- `Kernel.stop()` and every exit make the suspending imports return a
  never-settling promise (a fresh one each time, so a dropped instance can
  be collected), and the kernel parks at its next suspension point.
- Keep task switching behind `wasm_switch_to`/`ret_from_fork`, so that
  wasm stack switching can replace JSPI later (status.md).

## Parking: every task's state in memory

A suspended task's continuation is on its wasm stack in the engine, which
cannot be saved. Parking (`arch/wasm/kernel/park.c`, `asm/park.h`,
`linux/kw_park.h`) brings every task to a point where its whole state is
in guest memory, then resumes each one on a fresh stack. Snapshots are
built on it (below; the console and disks are saved so far, status.md).
Every cycle resumes every task through the fresh-stack path, so kwtest's
`park:` check covers it.

- **Trigger**: a write to `/proc/kwpark` (asynchronous: the writer parks
  too) wakes `kwparkd`. Reading it gives `requests N done N result R users
  U kthreads K us T blocker comm[pid]:state` (the last cycle's counts,
  request-to-resume time and the task that blocked it, `-` if none).
- **Phases**: user tasks first (`kw_park_users`), while kernel threads
  still run, so a user task in a D-state wait for a journal commit or
  writeback finishes it; then kernel threads (`kw_park_kthreads`); then
  kwparkd parks itself and sets `kw_park_final`. A task that has not
  parked after 2 s (stopped or traced, in a D-state sleep, a kernel thread
  without a park point, created but never woken) ends the cycle: every
  parked task is resumed and the result is -EBUSY with that task named.
- **User tasks**: kwparkd sets `TIF_NOTIFY_SIGNAL` (repeated every tick
  until the task parks), which ends interruptible sleeps. The task parks
  at the top of `user_mode_loop()`, after the exit work, where its state
  is `pt_regs` plus task_struct (restart block, signal state). Syscalls
  restart (-ERESTARTSYS, -ERESTARTNOHAND, the restart block for nanosleep,
  poll and futex timeouts); the few that do not restart after SIGSTOP and
  SIGCONT either (epoll_wait, sigtimedwait, sockets with a timeout) return
  EINTR once per cycle. Parked tasks sleep in `TASK_IDLE`, so signals
  (even SIGKILL) and tty wakeups wait for the resume.
- **Kernel threads**: kwparkd wakes those sleeping in `TASK_INTERRUPTIBLE`
  or `TASK_IDLE` (never plain D-state sleeps: `kthread()`'s wait for its
  first wakeup has no loop). Each loop has a `kw_park_point(fn, arg)` where
  it holds no locks and has no wait queue entry or timer on its stack;
  `fn(arg)` re-enters the loop without its one-time setup. The set:
  kthreadd (`kthreadd_loop`), `kthread_worker_fn`, `worker_thread` (at
  `woke_up`, idle), `rescuer_thread`, `smpboot_thread_fn`, devtmpfsd
  (`devtmpfs_work_fn`), oom_reaper, kcompactd (`kcompactd_loop`), kswapd
  (`kswapd_loop`), khvcd, kjournald2 (`kjournald2_loop`) and
  ext4lazyinit (`ext4_lazyinit_thread`, at its loop top). Waits that a
  wakeup does not end (`wait_event*()`) also end on `kw_park_pending()`,
  and the loop then skips its work. A new kernel thread (a driver, a
  config option) needs a park point too, or every cycle fails with EBUSY
  naming it; `cat /proc/kwpark` after a cycle shows which.
- **Consistent point**: `arch_cpu_idle()` sees `kw_park_final` and, inside
  `irqentry_enter()` with interrupts off and nothing runnable, checks that
  every task is `KW_PARK_PARKED` (and not on a runqueue), a zombie, or
  `TIF_NEVER_RUN`. A snapshot would be taken there.
- **Resume**: `kw_unpark_all()` marks each parked task `KW_PARK_RESUMING`
  and `TIF_NEVER_RUN` and wakes it. The next switch to it starts a fresh
  stack (the host drops the old one from `resumers`), and `__ret_from_fork`
  calls `kw_park_resume()`: `schedule_tail()` with `set_child_tid` cleared
  (the TID was stored at the first run), then `fn(arg)` (its return value
  goes to `kthread_exit()`), or for a user task `irqentry_exit_to_user_mode()`
  (delivers signals that arrived while parked, no syscall-exit work, so no
  duplicate ptrace stop) and `user_mode_loop()`.
- **Snapshots**: `Kernel.snapshot()` raises IRQ 8, which marks the next
  cycle a snapshot. At its end park.c calls the import
  `wasm_snapshot_point(result, blocker, free_map, free_bits)`: with
  result 0 from the consistent point (after the counts, before anything
  is resumed), where the host copies the memory during the call, leaving
  out the free pages; otherwise with the error and the task that did not
  park. The host answers 0, or -EBUSY if
  its own block, net, vsock or shm queues are not empty or a disk cannot be
  sealed (js.md, Disks in snapshots). A disk's seal happens during this
  call, while nothing runs. A restore instantiates
  the same build (`linux_banner` must match), copies the memory over the
  fresh instance's, clears `wasm_host_irqs` and calls the export
  `kw_resume` (entry.S) instead of `_start`: the idle task on a fresh
  stack, `__kw_resume()`, which calls `kw_host_reset()` and resumes only
  kwparkd. kwparkd steps the realtime clock to the host's
  (`do_settimeofday64`), reseeds the RNG (`add_vmfork_randomness()`,
  built for KW_PARK by the generic random patch, so that two restores of
  one snapshot differ), runs the park restore notifiers and then resumes
  everything else. A driver whose host side did not survive registers one
  (`kw_park_register_restore_notifier()`, linux/kw_park.h; it runs while
  every other task is parked, so it must not wait for one): kwvsock resets
  every connected socket (ECONNRESET, as virtio-vsock does on
  TRANSPORT_RESET after a live migration) except the established ones the
  host keeps (`wasm_driver_vsock_keep(guest_port, host_port)` > 0: the 9p
  sessions of host file systems, whose state the host saved, js.md), and
  listeners stay. The other
  devices need no kernel help: their host side restores what the kernel
  told it (js.md, Devices in snapshots). On SMP the other CPUs would have
  to stay idle until the notifiers return.
  Free pages: just before that call, `kw_park_mark_free()` drains this
  CPU's per-cpu lists (`drain_local_pages()`, as hibernation's
  `swsusp_save()` does) and sets a bit for every page on the buddy free
  lists in a bitmap of `max_pfn` bits (`kvcalloc` on the first snapshot,
  then kept: 16 KiB for 512 MiB), passed as `free_map`. The host leaves
  those pages out (`copySnapshotMemory()`, js.md) and a restore gives them
  zeros. Nothing reads a free page's contents (no PAGE_POISONING;
  `init_on_free` expects zeros), and the free lists link through
  `struct page`, which is saved. `/proc/kwpark` shows the last count
  (`free`, in pages). Dropping clean page cache first gains nothing with
  the initramfs root, whose files are tmpfs (28.6 MiB with
  `drop_caches` against 28.4 MiB without, 2026-11-15), so there is no such
  option; an overlay root on a data disk has cache that could be dropped. The host offsets
  its monotonic clock so that the guest's continues from the saved value
  (CLOCK_MONOTONIC and CLOCK_BOOTTIME do not count the time between save
  and restore). Restarting the idle task at `cpu_startup_entry()` is fine
  with TINY_RCU and no CPU_IDLE or CONTEXT_TRACKING_IDLE; TREE_RCU (SMP)
  would need care there.
- **Cost** (2026-11-15, Node, Alpine at a shell with 3 to 7 user tasks and
  22 to 25 kernel threads): 180-500 µs per cycle. The check in
  `user_mode_loop()` (one load per kernel exit) did not move kwbench:
  0.13 µs per `getppid`, 0.14 ms per fork+exit+wait, with and without it.
  The lowered kernel grew by 1.5 KB raw, 2.3 KB gzip (parking alone). A
  snapshot of a 512 MiB machine (2026-11-15, the CLI's `{suspend}`): at
  a shell 28.4 MiB, after writing and removing 200 MiB in /tmp and a
  `sort` 28.9 MiB (32.0 and 232.1 MiB with the free pages saved too, zero
  64 KiB chunks left out by `encodeSnapshot` either way); parked and
  copied in 10-16 ms (80-90 ms when the whole memory was copied); reading
  and decoding the file 15 ms (122 ms for the 232 MiB one). A restore
  answered its first shell command 215 ms after reading the file, about
  what a cold boot to the prompt takes (210 ms): the gain is the state,
  not the time.
- **SMP**: `KW_PARK` depends on `!SMP`, so an SMP kernel has no
  `/proc/kwpark`, no `kw_resume` export (the host's `snapshot()` rejects:
  "cannot resume one") and no handler for IRQ 8; kwtest's `park:` check
  is skipped when `uname -v` says SMP. Parking there would need (UP is
  assumed in three places): `kw_park_final` must
  become a count of CPUs that reached `arch_cpu_idle()` with interrupts
  off (the last one runs the check); `kw_unpark_all()` must not mark a
  task whose old stack still runs on another CPU (a spurious wakeup into
  the park loop; `wait_task_inactive()`); and the check runs inside
  `irqentry_enter()` so that RCU watches, which matters with TREE_RCU.
  The free-page walk then needs every CPU's per-cpu lists drained (each
  CPU drains its own before it counts itself, or the last one drains all
  of them, since the others are idle). The SMP device paths (SMP below,
  Devices) add little: their state is in memory, and the work items they
  queue on CPU 0 (kwsnd's start/stop, `kw_host_call()`) run before a
  kworker parks at idle; but the consistent point must also find kwblk's
  `kwblk_pending` empty (another CPU's request raises IRQ 3, which CPU 0
  takes before it idles, so the check belongs after that), and the host's
  block queue check stays as it is.
  Moving a user task to another CPU (SMP below) uses the same kind of
  fresh entry as `kw_park_resume()`'s user path, from the reschedule in
  the exit loop instead of the top of `user_mode_loop()`; a resumed
  parked task would also have to set `thread.stack_cpu`.

## Host interface

Module `wasi_snapshot_preview1` (kernel `wasi.c`, host `js/core/wasi.ts`):

- `clock_time_get` (monotonic for clocksource, sched_clock and timer;
  realtime for the boot wall clock) and `random_get`.
- `fd_write` (1 = console, 2 = panic text), `fd_read` (0 = console input),
  `poll_oneoff`, `sched_yield`, and `proc_exit` (0 = power off, 1 = halt,
  2 = restart, 253 = panic).
- `args_*`: the command line is argv[1..] joined with spaces (the runtime
  passes `["vmlinux", cmdline]`).
- `fd_prestat_*`, `path_open`, `fd_filestat_get`, `fd_close`: the initrd is
  the file `initrd` in the first preopened directory that has one.
- Preview 1 is a wasm32 ABI. Declare pointer and size parameters `u32` and
  pass them through `wasi_ptr()`, which panics above 4 GiB. Anything that
  may live in high RAM goes through a static buffer in the kernel image or
  the bounce buffer.

Module `unkernel`: `wasm_switch_to`, `wasm_snapshot_point` (park.c),
`wasm_init_flag`, `wasm_cpu_count`, `wasm_cpu_start` and
`wasm_stack_drop` (SMP kernels only; SMP below),
`wasm_driver_block_info`/`submit`/`reap`
(kwblk), `wasm_driver_net_init`/`send`/`rx_len`/`recv` (kwnet; `net_init`
< 0 means no device), `wasm_driver_console_size` (`rows << 16 | cols`, 0 =
unknown), `wasm_dump_stacktrace`, kwemu's `kw_host_jit_caps`/`compile`/
`free`, and the display, input, sound, vsock and shm imports below. Module
`env` holds only `memory`. A host must provide every import, or
instantiation fails.

Display, input, sound, vsock and shm are lazy: each `_init` import returns
< 0 when the host has no such device, and then nothing is registered.
Display, input and sound allocate nothing until a program opens the
device, and the host is told on open and close. None of these imports
suspends. Each new device must add only its own imports (diff the
module's imports against a build without it).

- **kwfb** (`/dev/fb0`, 32 bpp XRGB8888, write and mmap):
  `wasm_driver_fb_init()`; `wasm_driver_fb_mode()` (`width << 16 | height`,
  0 = 640x480), asked at the first open; `wasm_driver_fb_attach(pixels,
  width, height, stride, format)` at the first open and on every mode
  change, with NULL at the last close. It returns the size at which the
  host shows the picture, in mm (`width << 16 | height`, 0 = unknown),
  which becomes `fb_var_screeninfo` `width` and `height` (X.Org's fbdev
  driver ignores those and assumes 96 dpi; Qt's linuxfb uses them). The
  host reads the pixels in place whenever it runs; there is no vsync. The
  buffer is one contiguous allocation, and the buddy allocator gives at
  most 4 MiB, so each side is clamped to 64..4096 and a mode above 1M
  pixels is divided by the smallest integer that fits; if the allocation
  still fails, the size is halved. `FBIOPUT_VSCREENINFO` changes the size
  only while the caller's file is the only one open and nothing is mapped
  (EBUSY otherwise); `line_length` is always 4 * xres. One program has
  the display at a time: a user open fails with EBUSY while another user
  open file exists (kernel opens, `user == 0`, are not refused; there is
  no fbcon). The claim is the file's, so it lasts through fork and through
  a mapping that outlives `close()`, and ends at the file's release, which
  exit always reaches. mmap inserts the pages directly: `vm_insert_page`
  rejects large kmalloc pages here.
- **kwinput** (evdev, present only with the display): event0 "kwinput
  keyboard" (keys 1..255, no autorepeat), event1 "kwinput mouse"
  (REL_X, REL_Y, REL_WHEEL, three buttons) and event2 "kwinput tablet",
  an absolute pointer like QEMU's usb-tablet (ABS_X/ABS_Y 0..32767 for the
  whole picture, REL_WHEEL, three buttons; no BTN_TOUCH, tool bits or
  INPUT_PROP_DIRECT, so udev and libinput call it a mouse with absolute
  motion and X's evdev an absolute pointer; device numbers 0, 1, 2 in the
  events and the open mask). `wasm_driver_input_init()`;
  `wasm_driver_input_state(mask)` from the open and close callbacks;
  `wasm_driver_input_read(buf, max)` pulls 12-byte events (device, type,
  code, value) after the host raises IRQ bit 5. kw_defconfig switches HID
  and the hardware input drivers off. Only user space may open these
  devices: the host routes keys to evdev instead of the console while the
  keyboard is open, so an in-kernel input handler that opens what it
  matches breaks the console. sysrq's handler is a passive observer on
  wasm (the `wasm: sysrq` patch, `passive_observer`: it sees events while evdev has the
  device open, so Alt-SysRq works then, but never calls `open`). A lower
  `MAGIC_SYSRQ_DEFAULT_ENABLE` would not do: writing a non-zero
  `kernel.sysrq` registers the handler again, and systemd sets 16. Any new
  handler (VT kbd, leds, mousedev, joydev) needs the same care; kwtest's
  `input handlers` check fails on handlers other than evdev and sysrq, and
  `test/api.test.ts` asserts that nothing is open before glimmer opens the
  devices.
- **kwsnd** (ALSA card 0, `hw:0,0`, playback only, U8 and S16_LE, mono or
  stereo, 8000-48000 Hz, plus OSS `/dev/dsp` through SND_PCM_OSS; no
  mixer, no PCM timer, no `/proc/asound`): `wasm_driver_sound_init()`
  (the host's preferred rate, or 0); `wasm_driver_sound_event(event, rate,
  channels, format)` (0 close, 1 open, 2 prepare, 3 start, 4 stop);
  `wasm_driver_sound_write(buf, bytes)`, which the host copies during the
  call and answers with the frames it has queued. A kernel timer on the
  host's monotonic clock hands over the frames that the elapsed time is
  worth every 5-10 ms; it uses no IRQ bit. A late tick hands over at most
  three ticks' worth, and an underrun stops the stream, so nothing spins.
- **kwvsock** (host `js/core/vsock.ts`): an AF_VSOCK transport on
  `virtio_transport_common`, registered as the G2H transport the way
  `vsock_loopback` registers its local one (KWVSOCK selects
  VIRTIO_VSOCKETS_COMMON and needs no VIRTIO; `virtio_transport_stream_allow`
  lives in virtio_transport.c, so kwvsock has its own). Guest CID 3
  (`KWVSOCK_GUEST_CID`), host CID 2; streams only (no seqpacket, no
  datagrams). Packets are virtio-vsock's (`struct virtio_vsock_hdr`, then
  the payload); the host runs the other end of the protocol. Without the
  device AF_VSOCK `connect()` fails with ENODEV. Sends keep their order: a
  packet the host refuses (-EAGAIN) goes back to the head of the queue and
  is retried after IRQ 6 (the SDK refuses only through its `refuse` test
  hook, since credit bounds the data). RX takes packets into linear skbs
  of at most `rx_max` (32 KiB less the shared info, which the host keeps
  every packet within) and calls `virtio_transport_recv_pkt(..., NULL)`
  (global mode, like virtio-vsock); a failed skb allocation leaves the
  packet with the host and retries 10 ms later. kw_defconfig: VSOCKETS,
  VSOCKETS_DIAG (`ss --vsock`), KWVSOCK, not VSOCKETS_LOOPBACK. Cost:
  +45 KiB lowered kernel (+15.7 KB gzipped).
- **kwshm** (UAPI `include/uapi/linux/kwshm.h`; host `js/core/shm.ts`):
  the host reads and writes the pages of guest shmem files (memfds,
  `/dev/shm` files) in place. An export is a file or a page-aligned range
  of one, with an id (IDR, cyclic from 1, shared by host and guest
  exports; at most 4096, and at most half of RAM pinned). Its folios are
  pinned with `memfd_pin_folios()` (FOLL_PIN with FOLL_LONGTERM semantics,
  udmabuf's interface), which also allocates holes, so every page the host
  sees is the file's. A pin rather than a plain reference: both make
  migration fail, but a pin is the documented way to give something
  outside the kernel's mappings long-lived access, lets compaction skip
  the folio early (`folio_maybe_dma_pinned()`), and moves pages out of
  ZONE_MOVABLE/CMA first (none here). `F_SEAL_WRITE` uses the same
  refcount test, so it fails with EBUSY while exported. No swap and no THP
  here. A truncation or hole punch removes pinned folios from the page
  cache (`folio->mapping` becomes NULL) but cannot free them, so the host
  never touches freed or reused memory; its view may go stale. Stale means
  another size (`i_size` against the export's; range exports are clamped
  to their range) or a held folio whose mapping or index no longer
  matches. Unpinning marks a writable export's folios dirty
  (`folio_mark_dirty_lock()`). Host writes bypass kwemu: code the host
  writes into a page a guest program executes is not seen until a FENCE.I
  or a flush.
  Ordering: every export is announced (attach) when it is made, refreshed
  and released, so a guest export's page list is already at the host when
  the guest sends its id, and an attach comes before the reply to the
  request that caused it. A refresh unpins the old pages only after the
  new list's attach, a release only after the detach returned. Host opens
  look the name up in PID 1's fs (`scoped_with_init_fs()`: a kworker's own
  root is nullfs) without following a final symlink. The guest side is
  the misc device `/dev/kwshm` (ioctl magic 0xBB, listed in
  ioctl-number.rst; the UAPI header documents it); closing the file
  releases its exports, and an export is writable for the host only if
  the fd is writable and not sealed against writes. One mutex covers
  everything. There is no change notification: the host learns staleness
  with a check, a round trip. At power-off the kernel releases nothing;
  the host forgets every export. The request layout and the imports are
  in the driver and `js/core/shm.ts`. kw_defconfig: KWSHM (depends on
  SHMEM and MEMFD_CREATE). Cost: +6 KiB lowered kernel (+1.8 KB gzipped).
- **9p** (host `js/core/9p.ts`, guest `kernel/guest/kw9p.c`): host file
  systems use the stock 9p client with the fd transport, no driver and no
  host import. kw9p connects an AF_VSOCK socket to the host (CID 2, port
  564) and mounts 9p with `trans=fd,rfdno=S,wfdno=S`,
  `cache=readahead` and `metatimeout=1000` on it; the client takes its
  own references to the socket, so kw9p exits after mount(2) and
  unmounting closes the connection. What the guest caches and for how
  long is in js.md (Host file systems). Stock fs/9p has no attribute
  timeout and no way for the server to invalidate a guest cache; the
  patch `9p: add metatimeout` adds `metatimeout=MS`: CACHE_META with an
  expiry per inode (`v9fs_inode.attr_expire`, set in
  `v9fs_stat2inode_dotl`), checked in `__v9fs_lookup_revalidate` and
  `v9fs_vfs_getattr_dotl`; `v9fs_refresh_inode_dotl` then drops the pages
  of a file whose qid.version, size or mtime changed and leaves a name
  that now holds another qid.path invalid. Negative dentries default to
  the same expiry. The option is meant for 9P2000.L: only there does it
  set the expiry and refresh a stat (with the legacy protocols lookups
  always revalidate, but a stat of a cached inode is not refreshed);
  without the option nothing changes. `v9fs_get_tree` refuses it with
  EINVAL in any cache mode with CACHE_WRITEBACK (mmap, loose, fscache, or
  a bitmask with that bit), because the CACHE_META getattr path skips the
  flush of dirty pages and a refresh rewrites the inode from the server,
  which could truncate pending writes; kw9p uses cache=readahead.
  kw_defconfig: NETWORK_FILESYSTEMS (the menu that holds 9P_FS; nothing
  else in it is on), NET_9P (selects NETFS_SUPPORT), NET_9P_FD, 9P_FS; not
  9P_FS_POSIX_ACL, 9P_FSCACHE or the virtio, Xen, RDMA and USB
  transports. Cost, measured 2026-11-15 against the build before it:
  +141 KiB lowered kernel (+52 KB gzipped), 28 KiB of RAM (the boot
  "Memory:" line); metatimeout adds under 1 KiB to the bundle. kwtest
  checks that the type is registered.

The host writes kernel memory only for `wasm_host_irqs`, kwblk/kwnet data,
kwinput events, kwvsock packets, kwshm requests, the pages of shmem files
exported to it (kwshm, ShmFile.write) and WASI results. It does not write
`boot_command_line` or the initrd bounds. `test/wasi-node.ts` boots with
Node's `node:wasi` for every WASI import and checks this side against a
third-party implementation.

## IRQs and time

- IRQs are bits in `wasm_host_irqs`, written by the host and polled
  (`asm/irq.h`): console = 1 (input or a window resize), net = 2, block =
  3 (completions; on SMP also another CPU's requests for CPU 0), sync = 4 (`ksys_sync()` from a work item; requests coalesce; host
  `Kernel.requestSync()`), input = 5 (kwinput events queued), vsock = 6
  (kwvsock packets queued, or room again after a refused send), shm = 7
  (kwshm requests queued), snapshot = 8 (a park cycle that ends in
  `wasm_snapshot_point`; host `Kernel.snapshot()`). Bits without a handler
  are cleared and ignored.
- The timer is a one-shot deadline, checked against the host monotonic
  clock.
- Everything is checked when a slice ends and in `arch_cpu_idle`
  (`wasm_idle(timeout)`: a `poll_oneoff` on stdin and the deadline). A
  slice is 200k user instructions of the CPU, not of one `kw_run` call:
  `cpu->budget` is refilled only after `KW_EV_BUDGET`/`KW_EV_INTERRUPT`,
  and each syscall and page fault costs `KW_ENTRY_COST` (1000) of it.
  Otherwise a loop of cheap syscalls never sees a timer tick and is never
  preempted (apt busy-polls dpkg's status pipe with `pselect()` after EOF,
  and dpkg never runs again).
- While user code is busy, the kernel yields to the host every 20 ms.
  After idle and after a yield, it sets the console bit itself when stdin
  is readable, for hosts that never write `wasm_host_irqs`.
- The host relies on this: every slice end reads the monotonic clock
  (`clock_time_get`) before `wasm_poll_irqs`. Worker mode's shared
  transport (js.md) drains its input rings in that import and sets the IRQ
  bits there, so the kernel takes them in the same slice end (in a guest
  busy loop the clock ran every 0.6 ms p90 with the JIT, 1.3 ms without;
  2026-11-14). Keep a clock read at the slice end if `do_user_interrupt`
  changes.
- SMP: each CPU has a word of pending bits. CPU 0's is `wasm_host_irqs`
  (the host's device bits arrive there only, so device interrupts run on
  CPU 0; the host sets them with `Atomics.or`), the others are
  `kw_irq_words[]`; IPIs are bits 24-27 (`KW_IPI_*`, irq.h; 27, the
  kick, has no handler: it only ends a blocked wait). The timer is
  a per-CPU clockevent (IRQ 0 is a percpu-devid interrupt) with a per-CPU
  expiry. Polling widens: a CPU also takes what is pending when it
  enables interrupts (`arch_local_irq_restore()` checks the word) and in
  `cpu_relax()` with interrupts on, so a CPU spinning on a lock still
  answers the holder's TLB shootdown.
- irq_work runs from the timer tick: `arch_irq_work_has_interrupt()` is
  false, since nothing could raise the interrupt (otherwise irq_work never
  runs and every Tiny SRCU `synchronize_srcu()` hangs: inotify `close()`,
  systemd).
- A single long stay in the kernel (one big syscall) still delays these
  checks until it returns. See status.md.

## SMP (`CONFIG_SMP`, `arch/wasm/configs/kw_smp.config`)

A second build of the same tree: `make kw_defconfig kw_smp.config` (SMP,
`NR_CPUS` 8), which also links with `--shared-memory` (arch Makefile),
with kwemu built by `zig build -Dkwemu-jit=true -Dkwemu-atomics=true`.
`kernel/build.sh smp` does that into `vendor/build/kernel-smp` (Two
kernels, below). The UP build does not change
(every SMP piece is `#ifdef CONFIG_SMP` or compiles away). Status,
numbers and open issues: status.md item 8.

- **Model.** One instance of the module per CPU, each in its own host
  thread, all on one shared memory. `current`, `__stack_pointer`,
  `kw_irq_flags` (the interrupt flag) and `kw_irq_word` (the address of
  the CPU's pending word) are wasm globals, so per CPU;
  `raw_smp_processor_id()` is `current_thread_info()->cpu`. The host
  offers `wasm_cpu_count()` CPUs; `kw_smp_init_cpus()` (setup_arch)
  makes them possible and present, capped by `nr_cpus=`, and takes
  kwemu's 8 MiB state for each from memblock (CPU 0's stays static).
  `__cpu_up()` calls `wasm_cpu_start(cpu, idle)`: the host starts a
  thread with a new instance, which enters the export
  `kw_secondary_entry(idle)` (entry.S), then `kw_secondary_start()`
  (smp.c); `__cpu_up()` waits up to 30 s for it to come online.
- **The data-segment flag.** With a shared memory every instance's start
  function initialises the passive data segments unless the word
  `__wasm_init_memory_flag` is 2. wasm-ld places it after all data, past
  `_end`, in memory the kernel would hand out, and C cannot name it
  (wasm-ld asserts on a reference). The module exports its address, so
  the host answers `wasm_init_flag()` from that export and setup_arch
  memblock-reserves the word; a secondary's host checks that it reads 2
  before it instantiates.
- **Tasks move only where their stack can be dropped** (a JSPI stack
  belongs to the thread that created it): `ARCH_TASKS_STAY_ON_CPU`
  (init/Kconfig; process.c has the arch side). `thread.stack_cpu` is the
  CPU whose host holds the task's stack. `__ret_from_fork()` holds the
  task there with `migrate_disable()` from its first run, which the
  scheduler honours everywhere (`cpus_ptr` becomes that CPU once it
  switches out; `sched_getaffinity()` shows the user's mask). A fork
  child starts unheld (`copy_thread()` resets the copied hold), so new
  tasks spread at fork. A held task is let go (`sched_stay_release()`,
  kernel/sched/core.c: `migrate_enable()` plus a move to an allowed CPU
  if its affinity excludes this one) at two kinds of point:
  - **A user task at the reschedule on its way to user mode.** The
    generic exit loop calls `arch_exit_to_user_mode_schedule()` instead
    of `schedule()` (irq-entry-common.h; the default is `schedule()`),
    which is `kw_exit_to_user_schedule()`: after a system call, a fault
    or an interrupt (a slice end), once the system call's exit work
    (tracing, a ptrace stop, audit) is done. The task's state is then
    all in `pt_regs` and task_struct. Switched in on its stack's CPU,
    it returns from `schedule()` (the usual resume) and is held again.
    Switched in elsewhere (the balancer pulled it, an affinity change
    sent it), `__switch_to()` starts it on a fresh stack, and
    `kw_user_resume()` finishes the switch (`sched_stay_switch_tail()`:
    `schedule_tail()` without the child TID store and without
    recalculating TIF_SIGPENDING, so a system call that returned
    -ERESTARTSYS still restarts) and runs `irqentry_exit_to_user_mode()`
    from the top. What the old pass had still to do (a signal,
    notify-resume, another reschedule) is in the TIF flags, which only
    the task clears; `regs->cause` and a0 are as it left them; the LR/SC
    reservation is cleared at every switch anyway. Equivalent to the old
    stack's path with rseq off (this config) and no CONTEXT_TRACKING_USER;
    with rseq on, the syscall and interrupt exits differ in
    `rseq_*_exit_to_user_mode()` and would need a look. Tasks preempted
    or asleep in the kernel (a system call, `cond_resched()`, a signal
    stop) stay held: their stack is live.
  - **A kthread at a restart point.** New kthreads first run only to
    report that they exist and are bound afterwards (per-CPU threads of
    a CPU not yet online, a per-CPU workqueue pool's first worker), so
    kernel/kthread.c and kernel/workqueue.c call
    `arch_kthread_restart_point(fn, arg)` before such a sleep (the
    creation wait, the park before the thread function, an idle worker)
    and `arch_kthread_restart_cancel()` after it. Woken on another CPU,
    the thread starts there in `kthread_exit(fn(arg))`. A workqueue
    rescuer that must serve another CPU's per-CPU pool leaves the
    request queued and calls `arch_kthread_move(cpu, rescuer_thread,
    rescuer)`: its affinity becomes that CPU, it releases itself and
    starts again there (otherwise it would run that CPU's work items on
    its own: `process_one_work()` warns).

  The CPU that holds a moved task's old stack learns it from a per-CPU
  list (`kw_stack_drop()`, 32 entries) and, at its next switch or idle,
  before it could switch to that task (or a new task at the same
  address) again, calls `wasm_stack_drop(task)`; its host forgets the
  stack. A full list only leaks that stack until the task next starts
  fresh on that CPU. A task picked again on its own CPU resumes its
  stack rather than starting fresh: preemptions are frequent and moves
  rare (`/proc/kwmove`, below), and a fresh start costs a new JSPI stack
  while the old one waits for garbage collection.

  Affinity: `sched_setaffinity()` that excludes the CPU of a held task
  records the mask and returns at once (no waiting for a move that may
  come only after a long sleep in a system call). For a user task
  `arch_stay_move()` sets TIF_KW_MOVE (`ARCH_EXIT_TO_USER_MODE_WORK`,
  asm/entry-common.h) and kicks it: it moves on its next way to user
  mode, at once if it runs in user mode, at the end of the call for
  itself (`taskset -c 1 cmd`, `pthread_setaffinity_np()` on itself), at
  the wakeup if it sleeps in a system call. A task let go meanwhile moves
  the upstream way (stopper or `move_queued_task()`). A held kthread gets
  EBUSY, unless it is moving itself (`arch_kthread_move()`).

  Placement: where the scheduler would have moved a held task itself,
  it names the CPU to the arch instead (`arch_stay_move_to()`, which
  sets TIF_KW_MOVE and `thread.move_to`): `sched_exec()`, whose stopper
  cannot move a held task (it now asks with the task's own mask:
  `cpus_ptr` has been its CPU's since it last switched out), and the
  wakeup of a held user task whose CPU is busy (`stay_wake_target()` in
  `select_task_rq()`): the waker's CPU for a WF_SYNC wakeup from
  another CPU, else the first idle CPU; a WF_SYNC wakeup on the task's
  own CPU keeps the pair together. The task finishes its system call
  where it slept, and `kw_exit_to_user_move()` takes the hint on its
  way to user mode only if that CPU is idle then and its own CPU has
  other work (`sched_stay_release(dest)` queues the move as for an
  affinity change); otherwise it goes on without a reschedule. A
  sleeper woken behind a busy task thus leaves once and then wakes on
  its new CPU, and nothing is cut short: interrupting interruptible
  sleepers the way parking does was not done, since calls that do not
  restart would return EINTR at the scheduler's whim. Tasks preempted
  in the kernel (`cond_resched()`) stay where they are (status.md, SMP,
  Placement, has what that costs).
  `/proc/kwmove` (SMP only) counts user tasks switched out where they may
  move (`released`), resumed on their CPU (`resumed`) or started on
  another (`moved`), kthreads started again elsewhere (`restarted`),
  stacks dropped (`dropped`, `lost`), and exits that found a CPU named
  by exec or a wakeup (`hinted`) and moved there (`followed`). An Alpine boot to a shell
  (2026-11-16) released 10-18 times, all resumed in place, and
  restarted 6 kthreads on 2 CPUs, 21 on 4. Held tasks never call
  `migrate_enable()` before they exit, so `rq->nr_pinned` (used only by
  CPU hot-unplug, which this arch lacks) only grows.
- **IPIs and idle.** `kw_irq_raise(cpu, bits)` (irq.c) ORs the bits into
  the target's word and does `memory.atomic.notify`. A secondary idles in
  `memory.atomic.wait32` on its word with the timer's timeout (it blocks
  its thread; no JSPI); CPU 0 idles in `poll_oneoff` as on UP, and its
  host also ends that wait on `Atomics.waitAsync` of `wasm_host_irqs`.
  `kw_irq_enable_pending()` runs the handlers with interrupts still off,
  then sets the flag; `user_mode_loop()` enables without delivering,
  since `kw_run()` returns `KW_EV_INTERRUPT` at once and the exit path
  then honours a reschedule. Every CPU yields to its own host
  (`wasm_yield`, every 20 ms of user code, traps.c): CPU 0's serves the
  devices, and a secondary's event loop runs the engine's housekeeping,
  without which V8 never finishes collecting the JIT modules freed
  there (finalizers and the collector's last pass are tasks; js.md, CPU
  threads). That can take milliseconds, so on SMP the yield comes after
  the pending interrupts are taken, and TLB flushes do not wait for a
  yielding CPU (MM, below). Only CPU 0 also checks stdin there.
  `smp_send_stop()` parks the others (CPU 0 in `wasm_idle(-1)`, so its
  host can still take a secondary's exit; it clears its pending word
  before each such wait, since the host's idle ends at once while that
  word is not 0, and a stop bit left there kept CPU 0 resuming in a loop
  of microtasks that starved the host's event loop, so the exit was never
  taken). A CPU takes the stop IPI in
  `cpu_relax()` even with interrupts off, and a secondary's host raises
  it on CPU 0 when the session ends there (exit, trap, fatal; js.md):
  CPU 0's host takes that CPU's message only once CPU 0 suspends, and
  CPU 0 may be spinning for the CPU that ended (a lock it held, a
  cross-CPU call).
- **MM.** `switch_mm()` adds the CPU to `mm_cpumask(next)` before
  `kw_set_pgd()` and removes it from the previous mm (still referenced:
  lazy TLB refcount). `flush_tlb_*()` runs `kw_flush_tlb_*` here and,
  through `smp_call_function_many()` with wait, on every other CPU in the
  mask that uses the mm; `riscv_flush_icache` flushes every CPU
  (`kw_flush_icache_all()`). A CPU in lazy TLB mode (`enter_lazy_tlb()`:
  idle, a kthread, a task past `exit_mm()`) keeps the mm loaded and its
  mask bit, but a flush does not wait for it (its host thread may be
  asleep): it sets that CPU's `kw_tlb_stale` instead, and `switch_mm()`
  back to that mm flushes everything first (Dekker pairing of
  `kw_tlb_lazy` and `kw_tlb_stale` with `smp_mb()` on both sides; a
  switch to another mm drops everything anyway). The same holds, and the
  same flag is used, while a CPU yields to its host from user mode
  (`kw_yield_to_host()`: no user code and no uaccess until it is back, and
  then it flushes everything if marked). A CPU whose kwemu is compiling
  (kw_emu.h, `jit_busy`: no user code, no guest memory and no page table
  in it, a few hundred µs of host time without interrupts) is not waited
  for either: the flusher sets its `flush_all`, `smp_mb()`, and skips it
  if it still reads `jit_busy` (acquire, pairing with kwemu's release
  store, so the user stores made before the compile are visible); kwemu
  clears `jit_busy`, then takes `flush_all` and flushes everything before
  it runs user code (`kw_flush_later()`, tlb.c; kwemu.md, JIT on several
  harts). `flush_tlb_all()` (so `riscv_flush_icache`) skips both kinds
  too. Unlike on x86 this
  holds when page tables are freed too: a lazy CPU runs no user code and
  no uaccess walk for the mm, and kwemu walks the table only while it
  runs user code and caches no table entries. `update_mmu_cache_range()`
  and the flush after `ptep_set_access_flags()`
  (`flush_tlb_fix_spurious_fault()`) flush only this CPU: they follow a
  PTE that gained access with the same page, and kwemu fills a TLB entry
  only from a PTE that allows the access (separate read, write and exec
  TLBs, no negative entries, a miss walks), so another CPU at worst
  walks again; every change that takes access away or moves the page
  flushes every CPU first (`ptep_clear_flush()`, `flush_tlb_*()`).
  The software A/D update in fault.c is a `cmpxchg` (as a hardware
  walker's, without the PTE lock), so pgtable.h makes every
  read-modify-write of a present PTE atomic on SMP
  (`ptep_get_and_clear`, `ptep_set_wrprotect`,
  `ptep_test_and_clear_young`, `ptep_set_access_flags` keeping D), except
  `ptep_get_and_clear_full()` in the teardown of a whole mm
  (`exit_mmap()`: mm_users is 0, so nothing sets A or D), a plain read
  and clear as on x86. The uaccess walk and copy (`kw_user_addr()`) have
  no poll point between them, and pages and page tables are freed only
  after the mmu_gather flush, which waits for every CPU that uses the mm,
  so a CPU never copies into a freed page (gup-fast's argument; the
  default mmu_gather, without `MMU_GATHER_RCU_TABLE_FREE`, frees page
  tables in the same batch). The walk takes no lock (munmap frees page
  tables under the mmap read lock), so it reads each level once and
  finds the next table from that value, as gup-fast does. User code on
  other CPUs updates futex words with AMOs and LR/SC, so the kernel's
  futex ops on them (`FUTEX_WAKE_OP`, PI, robust futex death) are
  atomic RMWs (asm/futex.h).
- **Per-CPU memory** is percpu-km (mm/Kconfig allows `NEED_PER_CPU_KM`
  on SMP with `VMALLOC_FLAT`) with the generic `setup_per_cpu_areas()`.
  Spinlocks are asm-generic's ticket locks with the wait out of line
  and, by default, taken out of turn while no ticket is outstanding
  (asm/spinlock.h, below), rwlocks queued (`ARCH_USE_QUEUED_RWLOCKS`),
  RCU is TREE_RCU.
- **Waiting for another CPU** (wait.c). A CPU's host thread may be
  descheduled by the host at any time, so a CPU that spins for another
  (a lock holder, a cross-CPU call's answer, a task leaving another CPU)
  burns host time while that CPU is not running and looks busy to the
  host, which then deschedules it more often, also while it holds a
  lock: under host load that convoy made cross-CPU work 10-50x slower
  than the guest's lost share of the host explains (study and numbers
  in `vendor/smp-deferred/load/README.md`). So every such wait spins
  for `kw_spin_us=` (20 µs, counted from its 256th spin; the clock is
  not read before) and then blocks the thread in
  `memory.atomic.wait32` on the CPU's own pending word until the word
  changes, for at most `kw_spin_sleep_us=` (100 µs) at a time; both are
  boot parameters and writable in `/sys/module/kernel/parameters/`,
  and `kw_spin_us=0` spins as before. The waits: the ticket lock's slow
  path (`kw_ticket_wait()`), csd waits (`arch_csd_lock_wait()`, a hook
  in kernel/smp.c) and `smp_cond_load_relaxed()` (asm/barrier.h; so
  qrwlock and `try_to_wake_up()`'s wait for `p->on_cpu`). A spinlock
  unlock (one atomic 16-bit add on the owner half, then a read of
  `kw_lock_sleepers`) and `csd_unlock()` (`arch_csd_unlocked()`) kick
  the CPUs blocked on that lock or csd with `KW_IPI_KICK`: the waiter
  publishes its key (per-CPU) and the sleeper count, both seq_cst,
  before it reads the lock again, and the releaser reads the count and
  the keys after its release, so either the waiter sees the release or
  the releaser kicks it, and `memory.atomic.wait32` compares the word
  first. `smp_cond_load_relaxed()` waits have no kick: the timeout or
  any interrupt ends their block. Any IPI ends a block (the sender
  notifies the word), so a blocked CPU still answers shootdowns. With
  interrupts on, a waiter never blocks over something already pending
  (`cpu_relax()` takes it); with them off it blocks until something new
  arrives (a reschedule IPI it cannot take yet does not keep it
  spinning), never over a kick or the stop IPI. A kick that comes after
  its waiter stopped waiting is cleared before the CPU waits again. The
  block is not a JSPI suspension (CPU 0 blocks too: every CPU of an
  SMP kernel runs in a worker; an SMP kernel on one CPU never waits for
  another). Every 256 spins a waiter with interrupts on also takes its
  timer if it expired: otherwise a spinning CPU sees only its pending
  word and its tick starves (an RCU stall was seen that way). Bare
  `cpu_relax()` loops (seqcount retries) still spin
  without the timer check.
  Ticket locks are FIFO, so a waiter whose thread the host has
  descheduled holds up every waiter behind it even once the lock is
  free; blocking does not help there. So with `kw_spin_unfair=1` (the
  default; a boot parameter, writable in
  `/sys/module/kernel/parameters/`) a CPU takes no ticket: it takes the
  lock as `arch_spin_trylock()` does (cmpxchg of the ticket word while
  owner == next) and otherwise waits for that in `kw_steal_wait()`,
  which spins, blocks and is kicked as a ticket waiter (the same key
  and sleeper count; only an unlock frees the lock, and it kicks every
  CPU blocked on it). Waiters are then served in no particular order,
  as on x86 guests without PV spinlocks (`virt_spin_lock()`); there is
  no starvation bound. Both kinds share the word, the unlock and the
  kick, so the parameter may change at any time: a ticket holder is
  served in turn, a CPU without one never overtakes a ticket, and one
  still waiting when the parameter turns 0 takes a ticket.
  `kw_spin_unfair=0` gives plain ticket locks (cost when 0: one read of
  a flag per lock). `arch_spin_is_contended()` counts only tickets
  (its users, `spin_needbreak()` and `rwlock_needbreak()`, return 0
  without preemption anyway). qrwlock's `wait_lock` is an
  `arch_spinlock_t`, so it is unfair too; a waiting writer holds it,
  so readers still cannot starve a writer. Measurements: status.md,
  SMP, step 7.
- **Devices** stay on CPU 0 (their imports answer only there; another
  CPU's host ends the session when one is called there, js.md). hvc_wasm:
  CPU 0's console interrupt pulls the input into a FIFO and records the
  window size, and khvcd reads those on any CPU; output works on every
  CPU (each CPU's `fd_write` puts it into one ring shared by every
  CPU and the host, in the order the kernel made the calls; js.md, CPU
  threads). kwnet: NAPI runs on CPU 0
  (its interrupt); another CPU's frames wait in a queue that a work item
  on CPU 0 sends, and `ndo_open` raises IRQ 2 on CPU 0 instead of
  looking itself. kwvsock: its work items run on CPU 0, and another CPU's
  packets wait in `tx_queue`. kwblk: blk-mq calls `->queue_rq()` on the
  submitting CPU in atomic context; a request started on another CPU
  waits in `kwblk_pending` and raises IRQ 3 on CPU 0, whose handler
  submits the waiting ones in order before it reaps, and CPU 0 submits
  its own directly behind them. So every request is submitted and ended
  on CPU 0 (`blk_mq_end_request()` there wakes the submitter where it
  sleeps): all disk I/O is serialised on CPU 0, as it is on the host's
  thread anyway (cost in status.md, SMP). The other devices' imports are
  called from process context through `kw_host_call(fn, arg)` (smp.c): at
  once on CPU 0, else `work_on_cpu(0, ...)` while the caller sleeps (a
  task in the kernel stays on its CPU, so the check holds). kwshm: its
  request work item is queued on CPU 0; attach and detach go through
  `kw_host_call()` with `kwshm_lock` held, which the call does not take
  (the work item that does take it sleeps on it in another kworker of
  CPU 0's pool). kwfb: the mode and attach calls (open, release, mode
  change, under `info->lock`). kwinput: the open/close callbacks update
  the open mask inside the call, which serialises them (CPU 0 runs each
  to its end). kwsnd: open, prepare and close send their event through
  it; the timer is pinned to CPU 0 (`HRTIMER_MODE_REL_PINNED`), and a
  trigger (atomic) on another CPU leaves its start or stop in the stream
  and queues a work item on CPU 0 (`system_highpri_wq`), which sends it
  and starts the timer. Whatever sends an event first sends those left
  (between two prepares a stream starts and stops at most once), and
  the tick sends a start before its frames, so the host sees them in
  order. The host reads and writes these devices' memory (block data,
  pixels, shm pages, PCM, input events) while other CPUs run, as a DMA
  engine would: block data belongs to its request until it ends, and
  framebuffer tearing is as on UP. WASI's scratch buffers for the clock
  and writes are per CPU; the rest is CPU 0's.
- **kwemu** gets a `struct kw_cpu` per CPU, with the ISA CPU 0 enabled,
  and a JIT tier per CPU: each CPU's kwemu compiles into its own
  instance's function table through its own host (kwemu.md, JIT on
  several harts). A `kw_cpu` is only ever used by its CPU's instance
  (`wasm_kw_cpu` is `kw_cpus[smp_processor_id()]`, and a task that moves
  starts afresh on the new CPU), so nothing compiled on one CPU is
  reachable from another. Its atomics build makes AMOs, LR/SC and FENCE
  atomic (kwemu.md).
- **Costs** (2026-11-16, i7-10700K, Node 24, interpreter only). Each
  atomic RMW, cmpxchg or seq_cst store is a locked instruction in V8 on
  x86-64, about 4.3 ns more than the plain op, and `atomic.fence`
  (`smp_mb()`, `smp_rmb()`, `smp_wmb()`, and acquire and release, which
  asm-generic builds from a fence) about 8.9 ns. A fork and its exit take
  about 4 locked ops per mapped page that no barrier change removes
  (folio refcount and mapcount, raised at fork, dropped at exit). A
  wakeup that has to wake a sleeping host thread costs about 12 µs more
  than one on the same CPU when the target is a secondary
  (`memory.atomic.wait32`) and 20 µs more for CPU 0 (its host's
  `poll_oneoff`): kwwake, a pipe ping-pong with 200 µs gaps, woke a
  task on its own CPU in 7.3 µs, on CPU 1 in 19 µs, on CPU 0 in 28 µs
  (medians of 500). A fork whose child starts on the other CPU pays two
  of those (the child's start, the parent's wakeup at its exit). Lazy
  TLB, the local flush for a PTE that gained access and the plain
  teardown clear (MM above) measured with kwfork (11 alternating rounds,
  medians): a process moved to CPU 1 while CPU 0 idles with its mm
  loaded faults in 536 ns (3,321 when every fault waited for CPU 0's
  flush) and forks and reaps a child in 80 µs (118); exit costs 4.3 ns
  less per mapped page; one-CPU and same-CPU numbers did not move.
  With the JIT on every CPU: kwemu.md, Numbers, SMP with the JIT.

## riscv64 user ABI

- Syscall numbers come from `scripts/syscall.tbl` through pt_regs wrappers,
  so every syscall has one wasm type.
- Generic code takes ABI choices from arch `Kconfig` selects. Riscv's
  clone argument order is `CLONE_BACKWARDS` (otherwise `tls` and
  `child_tid` swap and every pthread program breaks). Compare with
  `arch/riscv/Kconfig` before adding a syscall-ABI select.
- ELF: `EM_RISCV`, `AT_HWCAP` = IMAFDC (single letters only, never more),
  `AT_MINSIGSTKSZ`. `riscv_flush_icache` flushes kwemu's translations.
- ISA advertising (cpu.c): one table of multi-letter extensions in the
  canonical order of riscv's `riscv_isa_ext[]`, each with its kwemu bit (0
  for ones every kwemu has: Zicbop, Ziccamoa, Ziccif, Zicclsm, Ziccrse,
  Zicntr, Zihintntl, Zihintpause, Za64rs, Zaamo, Zalrsc, Zca, Zcd) and its
  hwprobe bit, in `IMA_EXT_0` or, for the platform properties Ziccamoa,
  Ziccif, Zicclsm, Ziccrse and Za64rs (kwemu.md), in `IMA_EXT_1`. The
  effective set (implemented, minus `kw.isa=`) gives the `/proc/cpuinfo`
  `isa` line and `riscv_hwprobe` `IMA_EXT_0` and `IMA_EXT_1`;
  `ZICBOP_BLOCK_SIZE`, `ZICBOZ_BLOCK_SIZE` and `ZICBOM_BLOCK_SIZE` are 64
  while that extension is listed. User space picks code paths from these
  (OpenSSL reads `IMA_EXT_0`, V8 on musl only the cpuinfo line), so an
  extension is listed only once kwemu implements it. Optional ones listed
  by default: Zicbom, Zicboz, Zicond, Zihpm, Zimop, Zawrs, Zfa, Zfhmin,
  Zcb, Zcmop, Zba, Zbb, Zbc, Zbkb, Zbkc, Zbkx, Zbs, Zknd, Zkne: all of
  RVA23U64 but V and its sub-extensions, Supm and Zkt. Not listed: Zkt
  (kwemu's AES is not constant-time, kwemu.md), Supm (pointer masking:
  dropped), Zmmul (M implies it and upstream has no name for it).
  `MISALIGNED_SCALAR_PERF` (and `CPUPERF_0`) is FAST: a misaligned access
  costs what an aligned one does, several times less than its bytes one by
  one. `MISALIGNED_VECTOR_PERF` is UNSUPPORTED (no V). `riscv_hwprobe`
  ignores `RISCV_HWPROBE_WHICH_CPUS` and answers as for a plain query.
  `HIGHEST_VIRT_ADDRESS` is 1 << 38 (`STACK_TOP_MAX`, as riscv Sv39), the
  THEAD, SIFIVE and MIPS vendor keys are 0, and `TIME_CSR_FREQ` is
  unknown (key -1), because the time CSR counts instructions.
- ptrace has no regsets, so strace and gdb do not work. There are no core
  dumps, seccomp, modules, swap or kallsyms. Kernel stack overflow (16 KiB
  shadow stacks) is not detected, and a wasm trap in the kernel ends the
  session.

## Two builds: wasm64 and lowered

`vmlinux` uses memory64 and table64. `kernel/build.sh lower` runs it
through Binaryen (`wasm-opt -g --memory64-lowering --table64-lowering`) to
make `vmlinux32.wasm`. Pointers stay i64 in the code and at the JS
boundary. Only memory and table accesses are wrapped to i32, which is exact
because RAM is below 4 GiB. The runtime picks the memory type with
`moduleIsMemory64()`, which reads the module's `target_features` section.

The lowered build runs at the same speed in V8, is about 20% faster in
JavaScriptCore, and needs no memory64. The bundle, the page, the CLI's
default and `createKernel()` all use it. `vmlinux` stays the build input
and the reference (`--kernel vendor/build/kernel/vmlinux`). `lower` is
required: build.sh fetches Binaryen 133 if it finds no `wasm-opt` with
`--table64-lowering`.

## Two kernels: UP and SMP

One tree, two configs, two output directories: `kernel/build.sh kernel`
builds the UP kernel into `vendor/build/kernel` (`KOUT`), `smp` the SMP
kernel into `vendor/build/kernel-smp` (`KOUT_SMP`) with kwemu built with
atomics in `vendor/build/kwemu-smp` (`KWEMU_SMP=` takes a prebuilt one);
each is lowered, and `all` builds both (`KW_SMP=0`: UP only). `kernel`
stays the quick loop and never builds SMP. A step reconfigures when a
fragment (`kw_defconfig`, `kw_smp.config`) is newer than `.config` and
then checks that every option the fragments set is in `.config` as
written, failing with the list otherwise (Kconfig drops options whose
dependencies are not met silently; both configs pass as of 2026-11-17).

- **The bundle** (`bundle_alpine`, `kernel/tools/bundle.mjs --smp`)
  carries the UP kernel and a patch to the SMP kernel (js.md, CPU
  threads). bundle.mjs refuses two kernels that are not the UP and SMP
  builds of one tree: their banners must differ only in `SMP` (with the
  stamps below that means the same tree, kwemu sources and toolchain),
  kwemu's `kw_abi_version()` must return the same constant, only the SMP
  one may import `wasm_cpu_start`, and both must have the same memory
  index type. Every step that refreshes the bundle (`kernel`, `smp`,
  `lower`, `alpine`, `datadisk`, `bundle`) adds the patch when the SMP
  kernel exists and matches, and otherwise warns and leaves it out
  (`--smp-optional`), so after a tree change `kernel` gives a bundle
  without the patch until `smp` runs. `KW_SMP=1` (and `all`) makes a
  missing or mismatched SMP kernel an error; `KW_SMP=0` leaves the patch
  out. Making the patch takes about 15 s, so it is cached in
  `vendor/build/kernel-smp/up.kwpatch` (`--smp-patch`: reused when its
  header's SHA-256s are those of the two kernels, else made again).
- **Build stamps.** Kernels are reproducible: the same tree, kwemu
  sources and toolchain give the same bytes, and so the same patch
  (2026-11-17: two clean builds of each kernel into different output
  roots, and the bundles made from them, were byte-identical; with the
  stamps of a hand build the UP and SMP kernels were byte-identical to
  it). `kernel_stamps` exports `KBUILD_BUILD_USER` and `_HOST`
  (`unkernel`), `_VERSION` (the build id: 12 hex digits of a hash of the
  kernel tree's HEAD tree, its uncommitted and untracked changes, the
  repository's `src`, `include`, `build.zig*`, `kernel/patches/llvm`
  and `kernel/tools/fake-llvm`, the zig version and the JIT and stats
  options) and `_TIMESTAMP` (the newest author date on the tree, which a
  fresh `git am` of the series reproduces), unless the environment sets
  them. The banner then reads `Linux version 7.3.4+ (unkernel@unkernel)
  (clang ..., LLD ...) #<id> [SMP] <date>`. The build id matters beyond
  pairing: a snapshot is matched to its kernel by `linux_banner`
  (Parking), so every build whose module may differ needs another
  banner, and a fixed `#1` would let a snapshot restore into another
  build of the same date. A different clang or wasm-ld changes the
  banner through its compiler line. Libraries given as `KWEMU=` or
  `KWEMU_SMP=` count as built from the checkout's sources.
- **Overrides**: `KSRC` (the tree), `KOUT`, `KOUT_SMP`, and `KW_BUILD`
  (the output root, default `vendor/build`: kernels, kwemu-smp and
  kwemu-stats, initramfs, disks, bundle; the toolchain's
  `vendor/build/lld22` and alpine-opt.sh's package cache stay). The CLI,
  `bun run build` and the tests read `vendor/build`, so pass them paths.
  `LINUX_REPO` names where a fresh tree fetches the base commit from.
- On a fresh clone `prepare_kernel_tree` applies the whole series (UP and
  SMP patches alike) as `kw-riscv-user`; it warns when the checked-out
  HEAD of `KSRC` has another number of commits than the series has
  patches.

## Kernel tests

- kwtest (`kernel/guest/kwtest.c`, `/usr/bin/kwtest` in local builds and
  `alpine-test.cpio`, not in release bundles; kernel/README.md, alpine):
  run as `rdinit=` on both builds, with and without `--no-jit`. Device
  nodes come from devtmpfs when it is mounted, else they are made in
  `/tmp`; it never opens a node in `/tmp` once `/dev` has one, because
  the overlay root mounts `/tmp` nodev. It powers off on
  success and halts (exit 1) on failure. What it covers beyond syscalls:
  - ISA, reading `kw.isa=` from `/proc/cmdline`: the cpuinfo `isa` line
    (order, names, what must be listed), `riscv_hwprobe` `IMA_EXT_0` and
    `IMA_EXT_1` against it (and the three CBO block sizes, misaligned
    scalar FAST and vector UNSUPPORTED), misaligned loads and stores in a
    page and across pages (Zicclsm), `AT_HWCAP`, the hints and counters, and one
    probe instruction per optional extension that must raise SIGILL
    exactly when the extension is not listed (`isa_exts`). Listed
    extensions get result checks long enough to compile: FIPS-197 AES-128
    (Zkne/Zknd), OpenSSL's GHASH (Zbc or Zbkc, Zbkb), 13 B/Zicond
    instructions against plain C, a Zcb-compiled function against rv64gc,
    the MOPs, Zfa rounding/fli/fmin/fmax against libm, Zfhmin conversions,
    Zihpm counters reading 0, and the CBOs (including SIGSEGV on read-only
    and PROT_NONE pages, SIGILL for cbo.inval). Run it with
    `kw.isa=rv64gc` too after an ISA change.
  - `hot loops (JIT)` and `FP hot loop (JIT)` run long enough to compile
    (self-looping blocks with page faults, a thread, a COW child,
    SIGALRM); the FP hash comes from a native build (`fphot()`).
  - AF_VSOCK: with the host device (the CLI's default) the guest CID is 3
    and a connect to host port 9 is refused (ECONNRESET); without one
    (`--no-vsock`) `connect()` fails with ENODEV.
  - kwshm (CLI `--shm`, skipped otherwise): page counts of a 1 MiB memfd
    with holes and of a 10000-byte range, the EINVAL refusals (unaligned
    offset, range past the end, a pipe), `F_SEAL_WRITE` EBUSY while
    exported and fine after release or closing `/dev/kwshm`, a second
    release ENOENT.
  - kwfb (CLI `--display`, skipped otherwise): a second open of
    `/dev/fb0` fails with EBUSY while the first is open, while a forked
    child still holds the file after the parent closed it, and while a
    mapping outlives `close()`; it opens again after the child's exit and
    after `munmap`; `mmap` racing `FBIOPUT_VSCREENINFO` mode changes from
    another thread never maps a stale buffer and blocks mode changes while
    mapped.
  - `uaccess:` (every build): `read()` from a pipe into a userfaultfd
    page whose handler signals the reader before it supplies the page
    must return the data (a non-fatal signal neither ends the fault's
    wait nor fails the retried access); `FUTEX_WAKE_OP`'s add beside an
    amoadd loop on the same word, on another CPU when there is one, must
    lose no increment; aligned `get_user`/`put_user` (`FUTEX_WAIT` and
    `getcpu` beside another CPU's stores) never tear, and an unaligned
    `getcpu` across a page boundary works. `kwtest smp` runs it too.
  - `config:` checks the options below, and `input handlers` that no
    input handler besides evdev and sysrq is registered.
  - `smp:` (more than one CPU online; skipped otherwise): three threads,
    the main one among them, count to 900000 through amoadd, an LR/SC
    loop and a pthread mutex, and must have run on at least two CPUs.
  - `move:` (more than one CPU online; skipped otherwise; SMP above):
    2 threads per CPU (at most 8) started on CPU 0 and then allowed
    everywhere run `fphot()` for 2 s and must sit evenly on every CPU at
    1.2 s; the main thread moves itself round the CPUs 300 times between
    steps of a computation in registers, in FE_UPWARD with FE_DIVBYZERO
    raised, and must match the same run without moves (and its TLS);
    `sched_setaffinity` on a thread busy in user mode must return at once
    and move it within 1 s (6 times), on a thread asleep in `read()`
    return at once and move it at the wakeup; 2000 queued RT signals to
    a thread that keeps moving arrive exactly once each; 5000 pipe and
    5000 futex round trips between two threads that keep moving keep
    their order; a thread asleep in `read()` on CPU 0, which a thread
    pinned there keeps busy, woken 60 times from CPU 1 must leave CPU 0
    for good within its first 40 wakeups, every `read()` returning its
    value; of 5 children that exec beside that busy thread, at least 4
    must start their new image on another CPU; a thread asleep in
    `read()` that is moved to another CPU and woken by a `SA_RESTART`
    signal delivers the handler on the new CPU and restarts `read()`
    there without EINTR; a held kthread (`kthreadd`) refuses an affinity
    change with EBUSY, and flipping `kw_spin_unfair` under multi-CPU
    spinlock contention works; `/proc/kwmove` must show
    moves and no lost drops.
  - `jit:` (more than one CPU online; skipped otherwise; compiled code on
    several CPUs, kwemu.md, JIT on several harts): `hot()` and `fphot()`
    three times each on every CPU at once (one pinned thread per CPU),
    while the main thread sends each a signal every millisecond whose
    handler sets FE_TOWARDZERO and raises DZ (sigreturn must undo both);
    four threads on different CPUs increment their own byte and
    halfword of one cache line 200000 times each beside an amoadd and
    an LR/SC loop on the same line (no store lost); a thread in `hot()`
    and `fphot()` whose affinity changes every 4 ms; code that CPU 1
    calls in a loop (a compiled self-loop) rewritten 300 times by CPU 0
    with one aligned store and `__builtin___clear_cache()`, replaced 40
    times by `mremap()` of a prepared page over it, and made
    non-executable 10 times by `mprotect()`: once the writer has
    published a version, CPU 1 must never run an older one, never run
    the code while it is not executable (it must fault), and never
    crash; lazy-TLB invalidation across an idle CPU 1 (`mremap` of data
    and compiled code and `mprotect` to read-only on CPU 0 while CPU 1
    idles in lazy TLB mode, then moving back to CPU 1).
    `kwtest smp` (as `rdinit=/usr/bin/kwtest -- smp`) runs only
    `uaccess:`, `kwfb:`, `smp:`, `move:` and `jit:`.
- kwbench (`rdinit=/usr/bin/kwbench`, add `--stats` for the JIT counters)
  gives rough guest speed.
- `node test/wasi-node.ts`: the WASI side under `node:wasi` (no JIT).
- Ubuntu (`kernel/build.sh ubuntu`, kernel/README.md, Ubuntu) is the glibc
  check: boot it, and with a network run an `apt-get install`. To list
  what a userland lacks, build a throwaway kernel (`KOUT=` elsewhere) that
  `pr_info`s every `-ENOSYS` in `do_syscall` and every `do_user_trap`
  (traps.c); Ubuntu 24.04 boot, apt and python3 hit neither, systemd only
  `bpf` and `keyctl`. For a hang, the same kernel can print each user
  task's state and `a7` (the syscall it sleeps in) from `arch_cpu_idle`
  every 20 s; a busy host can be paused through the Node inspector
  (`kill -USR1`, then `Debugger.pause` over CDP), which shows the wasm
  kernel stack at the next import call.
- kw_defconfig has what systemd needs (CGROUPS, NAMESPACES, KCMP,
  FANOTIFY, AUTOFS_FS, EXT4_FS_SECURITY) and cheap options that tools probe
  for (CGROUP_PIDS, USER_NS, CHECKPOINT_RESTORE, PSI, TASKSTATS with I/O
  accounting, USERFAULTFD, IP_MULTICAST, the socket DIAGs, BLK_DEV_LOOP
  with MIN_COUNT=0, TUN, MAGIC_SYSRQ with its passive handler, see
  kwinput), and FUSE_FS for sshfs, rclone and AppImage (measured
  2026-11-14: +129 KB raw, +48 KB gzip, 20 KiB RAM), and policy routing
  (IP_ADVANCED_ROUTER with IP_MULTIPLE_TABLES: `ip rule`, which tailscaled
  uses for its table 52 and falls back to the main table without), VETH
  and DUMMY (measured together 2026-11-17: +64 KB raw, +24 KB gzip,
  20 KiB RAM, no new imports; DUMMY built in makes a `dummy0` link at
  boot). There is no netfilter. BPF_SYSCALL, KEYS, IPV6 and SECCOMP stay off. COREDUMP must
  stay off until the arch has `elf_core_copy_task_fpregs` and riscv64 core
  notes: without them a fault with a core limit is a wasm trap.
- To measure an option, copy a built `$KOUT`, append the option to its
  `.config`, run `make olddefconfig` and `vmlinux` with build.sh's make
  variables, lower it, and compare sizes. Also diff the module's imports
  against the base build: a new unresolved import (one the arch lacks)
  traps when it is called.
- Options left off, measured 2026-11-14 (one per build; base
  `vmlinux32.wasm` 6.83 MB raw, 2.21 MB gzip -9; RAM from the boot
  "Memory:" line). Remeasure if the tree has moved a lot.

  | Option(s) | raw | gzip | RAM | enables / checked |
  | --- | ---: | ---: | ---: | --- |
  | KEYS | +64 KB | +24 KB | 4 KiB | keyctl (systemd's other ENOSYS), cryptsetup |
  | VFAT_FS + NLS 437, iso8859-1, utf8 | +92 KB | +35 KB | 20 KiB | FAT images |
  | SWAP + ZRAM (lzo-rle) | +96 KB | +36 KB | 4 KiB | swap for 256 MiB phones; 64 MiB zram swapon worked |
  | MISC_FILESYSTEMS + SQUASHFS (zlib, xz, zstd) | +156 KB | +56 KB | 16 KiB | AppImage, snap |
  | TLS + CRYPTO_CHACHA20POLY1305 | +181 KB | +66 KB | 40 KiB | kTLS works, but curl, Node, Go, rustls, BoringSSL and busybox wget never use it, and the kernel's AES-GCM is no faster than user-space Zkn |
  | IO_URING | +192 KB | +71 KB | 16 KiB | liburing, PostgreSQL |
  | IPV6 | +467 KB | +170 KB | 52 KiB | `::1` ping worked; IPv6 is out of scope for now |
  | BPF_SYSCALL + CGROUP_BPF | +903 KB | +313 KB | 112 KiB | `docker run` (runc/crun device cgroup) worked with it |

  IKCONFIG/IKCONFIG_PROC: clang crashes on `kernel/configs.o`.
- tcrypt cannot benchmark here: `sec=N` loops forever (jiffies do not
  advance inside one long kernel stay) and `sec=0` needs `get_cycles`,
  which is 0 on arch/wasm.

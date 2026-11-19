// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Pooya Parsa <pooya@pi0.io>
/* unkernel smoke test (static riscv64 musl): /usr/bin/kwtest in the Alpine
 * initramfs, as /init with rdinit=/usr/bin/kwtest or from a shell. */
#include <errno.h>
#include <fcntl.h>
#include <fenv.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/reboot.h>
#include <sys/time.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile int got_signal;

static void on_usr1(int sig)
{
	got_signal = sig;
}

/* Wrong tp (clone tls/ctid swapped) shows up as a bad pthread_self or TLS. */
static _Thread_local int tls_var;

static void *thread_fn(void *arg)
{
	(void)arg;
	if (tls_var != 0)
		return NULL;
	tls_var = 2;
	return (void *)pthread_self();
}

/*
 * Hot loops for kwemu's JIT tier, which compiles a block once it has
 * retired 2^17 instructions: 64-bit and W integer ops, mul/div/rem, and
 * byte/half/word loads and stores over fresh anonymous pages, so the first
 * touch of each page faults from inside compiled code. HOT_EXPECT is what a
 * native build computes: `cc -O2 -o /tmp/kwtest kernel/guest/kwtest.c
 * -lpthread && /tmp/kwtest hot` on any 64-bit host.
 */
#define HOT_SEED 0x2545f4914f6cdd1dUL
#define HOT_EXPECT 0xd096af30f48152faUL
#define HOT_WORDS 4096

static unsigned long hot(unsigned long seed)
{
	unsigned long *w = mmap(NULL, HOT_WORDS * 8, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	unsigned char *b = (unsigned char *)w;
	unsigned long a = seed, sum = 0;

	if (w == MAP_FAILED)
		return 0;
	for (unsigned long r = 0; r < 24; r++) {
		for (unsigned long i = 0; i < HOT_WORDS; i++) {
			a = a * 6364136223846793005UL + i;
			unsigned long q = a / ((i | 1) + r) + a % 1000003;
			int32_t h = (int32_t)((uint32_t)(a >> 17) * 2654435761u);
			long s = (long)(h >> 3) / (long)(r + 3);
			uint16_t hw;
			uint32_t word;

			w[i] += q ^ (unsigned long)s;
			b[(i * 13) & (HOT_WORDS * 8 - 1)] ^= (unsigned char)a;
			memcpy(&hw, b + 2 * ((i * 7) & (HOT_WORDS * 4 - 1)), 2);
			memcpy(&word, b + 4 * ((i * 5) & (HOT_WORDS * 2 - 1)), 4);
			sum += w[(i * 7) & (HOT_WORDS - 1)] + hw + (unsigned long)(int32_t)word;
		}
	}
	munmap(w, HOT_WORDS * 8);
	return sum ^ a;
}

/*
 * FP hot loop for the JIT's F/D translation: double and float arithmetic,
 * fma(), sqrt(), fmax(), conversions both ways, compares, and a last round
 * in FE_UPWARD (dynamic rounding, which the JIT hands back). Returns a hash
 * of the results and of the accrued flags. FPHOT_EXPECT is what a native
 * build computes: `cc -O2 -ffp-contract=off -o /tmp/kwtest
 * kernel/guest/kwtest.c -lpthread -lm && /tmp/kwtest fphot` on a 64-bit
 * host with IEEE double/float (x86-64, aarch64).
 */
#pragma STDC FP_CONTRACT OFF
#pragma STDC FENV_ACCESS ON
#define FPHOT_EXPECT 0x75228a7bc4a10579UL

static unsigned long fphot(unsigned long seed)
{
	double x = 1.0 + (double)(seed & 0xffff) / 65536.0, acc = 0.0, m = 0.0;
	float fx = 0.5f, facc = 0.0f;
	unsigned long h = seed, bd, bm;
	uint32_t bf;

	feclearexcept(FE_ALL_EXCEPT);
	for (int r = 0; r < 4; r++) {
		if (r == 3)
			fesetround(FE_UPWARD);
		for (int i = 1; i <= 20000; i++) {
			double y = x * 1.000001 + 1.0 / i;
			acc = fma(y, 0.999, acc * 0.5);
			acc += sqrt(y) - (double)(i & 7);
			fx = fx * 1.0001f + (float)acc * 1e-3f;
			facc += sqrtf(fx > 0 ? fx : -fx) - fx / 3.0f;
			m = fmax(m, acc);
			long l = (long)(acc * 1024.0);
			h = (h ^ (unsigned long)l) * 0x100000001b3UL;
			if (y > acc)
				h += 1;
			x = y - (double)l / 4096.0 * 1e-6;
		}
	}
	fesetround(FE_TONEAREST);
	int ex = (fetestexcept(FE_INEXACT) ? 1 : 0) | (fetestexcept(FE_INVALID) ? 2 : 0) |
		 (fetestexcept(FE_OVERFLOW) ? 4 : 0) | (fetestexcept(FE_UNDERFLOW) ? 8 : 0) |
		 (fetestexcept(FE_DIVBYZERO) ? 16 : 0);
	memcpy(&bd, &acc, 8);
	memcpy(&bm, &m, 8);
	memcpy(&bf, &facc, 4);
	return h ^ bd ^ (bm * 3) ^ ((unsigned long)bf << 7) ^ (unsigned long)ex;
}

static int failures;
#define CHECK(cond, ...) do { \
	if (cond) printf("ok   " __VA_ARGS__); \
	else { printf("FAIL " __VA_ARGS__); failures++; } \
	printf("\n"); \
} while (0)

#ifdef __riscv
#include <setjmp.h>
#include <sys/auxv.h>
#include <linux/fb.h>
#include <linux/futex.h>
#include <poll.h>
#include <sys/epoll.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/syscall.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/sysmacros.h>
#include <linux/vm_sockets.h>
#include <linux/userfaultfd.h>
#include <linux/rtnetlink.h>
#include <linux/fib_rules.h>
#include <linux/veth.h>

#ifndef __NR_riscv_hwprobe
#define __NR_riscv_hwprobe 258
#endif
struct hwprobe_pair {
	int64_t key;
	uint64_t value;
};

/*
 * The extensions the kernel may list after "rv64imafdc" in /proc/cpuinfo,
 * in that canonical order, with their riscv_hwprobe IMA_EXT_0 bits (and
 * ext1, the IMA_EXT_1 bit of a platform property; see
 * arch/wasm/kernel/cpu.c). kind: 2 = part of rv64gc (always listed), 1 =
 * listed unless kw.isa= masks it (every kwemu has it, or it is an optional
 * extension kwemu implements), 0 = an optional extension kwemu does not
 * implement yet (either). probe: an instruction (rd = a0, rs1 = a0, rs2 =
 * a1, fd = fa0; a compressed one followed by c.nop in the same word) that
 * only this extension (or alt) defines; it must raise SIGILL exactly when
 * neither is listed, and give `want` for a0 = 3, a1 = 5 when want is not
 * 0. With `mem`, a0 is the address of a writable buffer instead of 3.
 */
static const struct isa_ext {
	const char *name;
	unsigned long hwprobe;
	int kind;
	uint32_t probe;
	const char *alt;
	unsigned long want;
	int mem;
	unsigned long ext1;
} isa_exts[] = {
	{ "zicbom", 1UL << 55, 1, 0x0015200f, NULL, 0, 1 },	/* cbo.clean (a0) */
	{ "zicbop", 1UL << 60, 1 },
	{ "zicboz", 1UL << 6, 1, 0x0045200f, NULL, 0, 1 },	/* cbo.zero (a0) */
	{ "ziccamoa", 0, 1, .ext1 = 1UL << 2 },
	{ "ziccif", 0, 1, .ext1 = 1UL << 3 },
	{ "zicclsm", 0, 1, .ext1 = 1UL << 1 },
	{ "ziccrse", 0, 1, .ext1 = 1UL << 4 },
	{ "zicntr", 1UL << 50, 1 },
	{ "zicond", 1UL << 35, 1, 0x0eb55533, NULL, 3 },	/* czero.eqz */
	{ "zicsr", 0, 2 },
	{ "zifencei", 0, 2 },
	{ "zihintntl", 1UL << 29, 1 },
	{ "zihintpause", 1UL << 36, 1 },
	{ "zihpm", 1UL << 51, 1, 0xc0302573 },	/* csrr a0, hpmcounter3 (0: checked below) */
	{ "zimop", 1UL << 42, 1, 0x81c54573 },	/* mop.r.0 a0, a0 (0: checked below) */
	{ "za64rs", 0, 1, .ext1 = 1UL << 5 },
	{ "zaamo", 1UL << 56, 1 },
	{ "zalrsc", 1UL << 57, 1 },
	{ "zawrs", 1UL << 48, 1, 0x00d00073, NULL, 3 },	/* wrs.nto */
	{ "zfa", 1UL << 32, 1, 0xf2180553, NULL, 3 },	/* fli.d fa0, 1.0 */
	{ "zfhmin", 1UL << 28, 1, 0xf4050553, NULL, 3 },	/* fmv.h.x fa0, a0 */
	{ "zca", 1UL << 43, 1 },
	{ "zcb", 1UL << 44, 1, 0x00019d75, NULL, ~3UL },	/* c.not a0; c.nop */
	{ "zcd", 1UL << 45, 1 },
	{ "zcmop", 1UL << 47, 1, 0x00016081, NULL, 3 },	/* c.mop.1; c.nop */
	{ "zba", 1UL << 3, 1, 0x20b52533, NULL, 11 },	/* sh1add */
	{ "zbb", 1UL << 4, 1, 0x60051513, NULL, 62 },	/* clz */
	{ "zbc", 1UL << 7, 1, 0x0ab52533 },	/* clmulr (3, 5) = 0: not checked */
	{ "zbkb", 1UL << 8, 1, 0x08b54533, NULL, 0x0000000500000003 },	/* pack */
	{ "zbkc", 1UL << 9, 1, 0x0ab51533, "zbc", 15 },	/* clmul */
	{ "zbkx", 1UL << 10, 1, 0x28b54533, NULL, 0x0303030303030300 },	/* xperm8 */
	{ "zbs", 1UL << 5, 1, 0x28b51533, NULL, 35 },	/* bset */
	{ "zknd", 1UL << 11, 1, 0x3ab50533, NULL, 0x52525252525252d5 },	/* aes64ds */
	{ "zkne", 1UL << 12, 1, 0x32b50533, NULL, 0x636363636363637b },	/* aes64es */
};
#define NISA (int)(sizeof(isa_exts) / sizeof(isa_exts[0]))

static int isa_find(const char *name, size_t len)
{
	for (int i = 0; i < NISA; i++)
		if (strlen(isa_exts[i].name) == len && !strncmp(isa_exts[i].name, name, len))
			return i;
	return -1;
}

/* The first line of `path` that starts with `key`, from after ": " or `key`. */
static int read_line(const char *path, const char *key, int colon, char *out, size_t n)
{
	char line[1024];
	FILE *f = fopen(path, "r");
	int found = 0;

	if (!f)
		return 0;
	while (!found && fgets(line, sizeof(line), f)) {
		char *v = line;

		if (strncmp(line, key, strlen(key)))
			continue;
		if (colon) {
			v = strstr(line, ": ");
			if (!v)
				continue;
			v += 2;
		}
		v[strcspn(v, "\n")] = 0;
		snprintf(out, n, "%s", v);
		found = 1;
	}
	fclose(f);
	return found;
}

static sigjmp_buf ill_jmp;

static void on_ill(int sig)
{
	(void)sig;
	siglongjmp(ill_jmp, 1);
}

/* Run n instruction words (ending in ret) as long f(a0, a1); -1 on SIGILL. */
static int run_code(const uint32_t *w, int n, long a0, long a1, long *ret)
{
	static uint32_t *page;
	struct sigaction sa = { .sa_handler = on_ill }, old;
	volatile int ill = 0;

	if (!page) {
		page = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (page == MAP_FAILED) {
			page = NULL;
			return -2;
		}
	}
	memcpy(page, w, n * 4);
	__asm__ volatile("fence.i" ::: "memory");
	sigaction(SIGILL, &sa, &old);
	if (sigsetjmp(ill_jmp, 1))
		ill = 1;
	else
		*ret = ((long (*)(long, long))(void *)page)(a0, a1);
	sigaction(SIGILL, &old, NULL);
	return ill ? -1 : 0;
}

/* Zkne / Zknd through .insn, so any assembler takes them. */
#define AESR(f7, a, b) ({ unsigned long _r; \
	__asm__ volatile(".insn r 0x33, 0, " #f7 ", %0, %1, %2" : "=r"(_r) : "r"(a), "r"(b)); _r; })
#define AESI(imm, a) ({ unsigned long _r; \
	__asm__ volatile(".insn i 0x13, 1, %0, %1, " #imm : "=r"(_r) : "r"(a)); _r; })
#define AES_ES(a, b) AESR(0x19, a, b)
#define AES_ESM(a, b) AESR(0x1b, a, b)
#define AES_DS(a, b) AESR(0x1d, a, b)
#define AES_DSM(a, b) AESR(0x1f, a, b)
#define AES_KS2(a, b) AESR(0x3f, a, b)
#define AES_IM(a) AESI(0x300, a)
#define AES_KS(i, rk) do { \
	rk[i + 1][0] = AES_KS2(AESI(0x31##i, rk[i][1]), rk[i][0]); \
	rk[i + 1][1] = AES_KS2(rk[i + 1][0], rk[i][1]); } while (0)

/* AES-128 encrypt + decrypt of FIPS-197 C.1, 5000 times; returns the misses. */
static int aes_fips(int *reps)
{
	unsigned long rk[11][2], dk[11][2];
	const unsigned long pt[2] = { 0x7766554433221100, 0xffeeddccbbaa9988 };
	const unsigned long ct[2] = { 0x30047b6ad8e0c469, 0x5ac5b47080b7cdd8 };
	int bad = 0;

	rk[0][0] = 0x0706050403020100;
	rk[0][1] = 0x0f0e0d0c0b0a0908;
	AES_KS(0, rk); AES_KS(1, rk); AES_KS(2, rk); AES_KS(3, rk); AES_KS(4, rk);
	AES_KS(5, rk); AES_KS(6, rk); AES_KS(7, rk); AES_KS(8, rk); AES_KS(9, rk);
	for (int r = 1; r < 10; r++) {
		dk[r][0] = AES_IM(rk[r][0]);
		dk[r][1] = AES_IM(rk[r][1]);
	}
	for (*reps = 0; *reps < 5000; ++*reps) {
		unsigned long s0 = pt[0] ^ rk[0][0], s1 = pt[1] ^ rk[0][1], n0, n1;

		for (int r = 1; r < 10; r++) {
			n0 = AES_ESM(s0, s1);
			n1 = AES_ESM(s1, s0);
			s0 = n0 ^ rk[r][0];
			s1 = n1 ^ rk[r][1];
		}
		n0 = AES_ES(s0, s1) ^ rk[10][0];
		n1 = AES_ES(s1, s0) ^ rk[10][1];
		bad += n0 != ct[0] || n1 != ct[1];
		s0 = n0 ^ rk[10][0];
		s1 = n1 ^ rk[10][1];
		for (int r = 9; r >= 1; r--) {
			n0 = AES_DSM(s0, s1);
			n1 = AES_DSM(s1, s0);
			s0 = n0 ^ dk[r][0];
			s1 = n1 ^ dk[r][1];
		}
		n0 = AES_DS(s0, s1) ^ rk[0][0];
		n1 = AES_DS(s1, s0) ^ rk[0][1];
		bad += n0 != pt[0] || n1 != pt[1];
	}
	return bad;
}

/* Zbc / Zbkb through .insn too. */
#define BKR(f3, f7, a, b) ({ unsigned long _r; \
	__asm__ volatile(".insn r 0x33, " #f3 ", " #f7 ", %0, %1, %2" : "=r"(_r) : "r"(a), "r"(b)); _r; })
#define CLMUL(a, b) BKR(1, 0x05, a, b)
#define CLMULH(a, b) BKR(3, 0x05, a, b)
#define BREV8(a) ({ unsigned long _r; \
	__asm__ volatile(".insn i 0x13, 5, %0, %1, 0x687" : "=r"(_r) : "r"(a)); _r; })
#define REV8(a) ({ unsigned long _r; \
	__asm__ volatile(".insn i 0x13, 5, %0, %1, 0x6b8" : "=r"(_r) : "r"(a)); _r; })

/* GHASH multiply as OpenSSL's Zbc + Zbkb code does it; x, y, z are blocks
 * as two big-endian halves. */
static void gf_mul(const unsigned long x[2], const unsigned long y[2], unsigned long z[2])
{
	unsigned long x0 = BREV8(REV8(x[0])), x1 = BREV8(REV8(x[1]));
	unsigned long y0 = BREV8(REV8(y[0])), y1 = BREV8(REV8(y[1]));
	unsigned long z0 = CLMUL(x0, y0);
	unsigned long z1 = CLMULH(x0, y0) ^ CLMUL(x0, y1) ^ CLMUL(x1, y0);
	unsigned long z2 = CLMULH(x0, y1) ^ CLMULH(x1, y0) ^ CLMUL(x1, y1);
	unsigned long z3 = CLMULH(x1, y1);

	z1 ^= CLMUL(z3, 0x87);
	z2 ^= CLMULH(z3, 0x87);
	z0 ^= CLMUL(z2, 0x87);
	z1 ^= CLMULH(z2, 0x87);
	z[0] = REV8(BREV8(z0));
	z[1] = REV8(BREV8(z1));
}

/* GHASH of the GCM spec's test case 2 (H, C = one block, no AAD) 5000
 * times; returns the misses. */
static int ghash_kat(int *reps)
{
	const unsigned long h[2] = { 0x66e94bd4ef8a2c3b, 0x884cfa59ca342b2e };
	const unsigned long c[2] = { 0x0388dace60b6a392, 0xf328c2b971b2fe78 };
	const unsigned long want[2] = { 0xf38cbb1ad69223dc, 0xc3457ae5b6b0f885 };
	int bad = 0;

	for (*reps = 0; *reps < 5000; ++*reps) {
		unsigned long y[2];

		gf_mul(c, h, y);
		y[1] ^= 128; /* len(A) = 0, len(C) = 128 bits */
		gf_mul(y, h, y);
		bad += y[0] != want[0] || y[1] != want[1];
	}
	return bad;
}

/* Zba / Zbb / Zbs / Zicond through .insn too. */
#define ZR(op, f3, f7, a, b) ({ unsigned long _r; \
	__asm__ volatile(".insn r " #op ", " #f3 ", " #f7 ", %0, %1, %2" : "=r"(_r) : "r"(a), "r"(b)); _r; })
#define ZI(op, f3, imm, a) ({ unsigned long _r; \
	__asm__ volatile(".insn i " #op ", " #f3 ", %0, %1, " #imm : "=r"(_r) : "r"(a)); _r; })

/*
 * A mix of Zba, Zbb, Zbs and Zicond instructions (sh3add, add.uw,
 * slli.uw, clz, cpopw, sext.h, orc.b, max, minu, bset, bext, binvi,
 * czero.nez) in a loop long enough to compile, against the same in plain C
 * (this file is built for rv64gc, so the C uses none of them). Returns the
 * misses.
 */
static int zb_mix(int *reps)
{
	unsigned long x = 0x0123456789abcdef, y = 0x0123456789abcdef;
	int bad = 0;

	for (*reps = 0; *reps < 20000; ++*reps) {
		unsigned long i = *reps, a = x ^ (i << 7), b = x >> (i & 31);
		unsigned long r = ZR(0x33, 6, 0x10, a, b);		/* sh3add */
		unsigned long c, w;

		r ^= ZR(0x3b, 0, 0x04, b, a);				/* add.uw */
		r += ZI(0x1b, 1, 0x083, a);				/* slli.uw 3 */
		r ^= ZI(0x13, 1, 0x600, b) << 8;			/* clz */
		r += ZI(0x1b, 1, 0x602, a) << 16;			/* cpopw */
		r ^= ZI(0x13, 1, 0x605, a);				/* sext.h */
		r += ZI(0x13, 5, 0x287, b & 0xff00ff0000ff00ff);	/* orc.b */
		r ^= ZR(0x33, 6, 0x05, a, b) + ZR(0x33, 5, 0x05, b, a);	/* max, minu */
		r = ZR(0x33, 1, 0x14, r, i) ^ ZR(0x33, 5, 0x24, a, i);	/* bset, bext */
		r = ZI(0x13, 1, 0x687, r);				/* binvi 7 */
		r += ZR(0x33, 7, 0x07, a, i & 1);			/* czero.nez */

		c = (a << 3) + b;
		c ^= (b & 0xffffffff) + a;
		c += (a & 0xffffffff) << 3;
		c ^= (unsigned long)(b ? __builtin_clzl(b) : 64) << 8;
		c += (unsigned long)__builtin_popcount((unsigned)a) << 16;
		c ^= (unsigned long)(long)(short)a;
		w = 0;
		for (int k = 0; k < 64; k += 8)
			if ((b & 0xff00ff0000ff00ff) >> k & 0xff)
				w |= 0xffUL << k;
		c += w;
		c ^= ((long)a > (long)b ? a : b) + (b < a ? b : a);
		c = (c | 1UL << (i & 63)) ^ (a >> (i & 63) & 1);
		c ^= 1UL << 7;
		c += i & 1 ? 0 : a;
		bad += r != c;
		x = x * 6364136223846793005UL + r;
		y = y * 6364136223846793005UL + c;
	}
	return bad + (x != y);
}

/* Writable, 64-byte aligned memory for the probes with `mem`. */
static unsigned char probe_buf[128] __attribute__((aligned(64)));

/*
 * Zcb (with Zbb and Zba for c.sext.*, c.zext.h and c.zext.w), Zimop and
 * Zcmop as the compiler emits them for a function built with them (the
 * rest of this file is rv64gc); zcb_plain() is the same C for rv64gc.
 */
#define ZCB_BODY \
	unsigned long x = p[1] * a + (unsigned short)b + (unsigned char)a + (unsigned)(a >> 7); \
	x += (unsigned long)(long)(signed char)b + (unsigned long)(long)(short)(a >> 3); \
	x ^= ~a + ((unsigned short *)p)[1] + (unsigned long)(long)((short *)p)[2]; \
	p[3] = (unsigned char)x; \
	((unsigned short *)p)[3] = (unsigned short)(x >> 8); \
	return x * b;
__attribute__((target("arch=+zcb,+zbb,+zba"), noinline)) static unsigned long zcb_fn(unsigned char *p, unsigned long a, unsigned long b)
{
	ZCB_BODY
}
__attribute__((noinline)) static unsigned long zcb_plain(unsigned char *p, unsigned long a, unsigned long b)
{
	ZCB_BODY
}

/* mop.r.N / mop.rr.N write 0, c.mop.N does nothing; returns the misses */
__attribute__((target("arch=+zimop"), noinline)) static int mop_check(unsigned long a, unsigned long b)
{
	unsigned long r0, r1;

	__asm__ volatile("mop.r.0 %0, %1" : "=r"(r0) : "r"(a));
	__asm__ volatile("mop.rr.7 %0, %1, %2" : "=r"(r1) : "r"(a), "r"(b));
	return (r0 != 0) + (r1 != 0);
}
__attribute__((target("arch=+zcmop"), noinline)) static unsigned long cmop_check(unsigned long a)
{
	__asm__ volatile("c.mop.1\n\tc.mop.3\n\tc.mop.5\n\tc.mop.7\n\tc.mop.15\n\tmv %0, %0" : "+r"(a));
	return a;
}

/*
 * Zfa: fround/froundnx in each static mode and dynamically, fli constants
 * and fmin/fmax, against libm's floor/ceil/trunc/round/rint and plain
 * constants in rv64gc code; plus fminm, fcvtmod.w.d and fltq.
 */
#define FRND(op, rm, x) ({ double _r; __asm__ volatile(op " %0, %1, " rm : "=f"(_r) : "f"(x)); _r; })
#define ZFA_BODY(FL, CE, TR, RO, RI, K) \
	double r = FL(a * 0.5) + CE(a) * K(0.25) - TR(a * 1.5) + RO(a) + RI(a * 0.75); \
	return fmin(r, 1e12) + fmax(r * K(0.125), -16.0) + RI(b) + K(0.3125);
#define Z_FL(x) FRND("fround.d", "rdn", x)
#define Z_CE(x) FRND("froundnx.d", "rup", x)
#define Z_TR(x) FRND("fround.d", "rtz", x)
#define Z_RO(x) FRND("froundnx.d", "rmm", x)
#define Z_RI(x) FRND("froundnx.d", "dyn", x)
#define Z_K(c) ({ double _r; __asm__ volatile("fli.d %0, " #c : "=f"(_r)); _r; })
#define P_K(c) (c)
__attribute__((target("arch=+zfa"), noinline)) static double zfa_fn(double a, double b)
{
	ZFA_BODY(Z_FL, Z_CE, Z_TR, Z_RO, Z_RI, Z_K)
}
__attribute__((noinline)) static double zfa_plain(double a, double b)
{
	ZFA_BODY(floor, ceil, trunc, round, rint, P_K)
}
__attribute__((target("arch=+zfa"), noinline)) static unsigned long zfa_minm(double a, double b)
{
	double m;
	unsigned long u;

	__asm__ volatile("fminm.d %0, %1, %2" : "=f"(m) : "f"(a), "f"(b));
	memcpy(&u, &m, 8);
	return u;
}
__attribute__((target("arch=+zfa"), noinline)) static long zfa_insns(double a, double b)
{
	double m;
	long w, q;

	__asm__ volatile("fminm.d %0, %1, %2" : "=f"(m) : "f"(a), "f"(b));
	__asm__ volatile("fcvtmod.w.d %0, %1, rtz" : "=r"(w) : "f"(a));
	__asm__ volatile("fltq.d %0, %1, %2" : "=r"(q) : "f"(a), "f"(b));
	return w + (long)m * 3 + q;
}

/*
 * Zfhmin: every half through fmv.h.x, fcvt.s.h, fcvt.h.s, fcvt.d.h,
 * fcvt.h.d and fmv.x.h, against a C decoding of the format; returns the
 * misses (NaNs convert to the canonical NaN).
 */
static unsigned h2s(unsigned h)
{
	unsigned s = (h >> 15) << 31, e = (h >> 10) & 31, m = h & 0x3ff;
	int k = 0;

	if (e == 31)
		return m ? 0x7fc00000 : s | 0x7f800000;
	if (e)
		return s | (e + 112) << 23 | m << 13;
	if (!m)
		return s;
	while (!(m & 0x400)) {
		m <<= 1;
		k++;
	}
	return s | (unsigned)(113 - k) << 23 | (m & 0x3ff) << 13;
}
__attribute__((target("arch=+zfhmin"), noinline)) static int zfh_all(void)
{
	int bad = 0;

	for (unsigned h = 0; h < 65536; h++) {
		float s;
		double d;
		long back, back2;
		unsigned sb;
		int nan = ((h >> 10) & 31) == 31 && (h & 0x3ff);

		__asm__ volatile("fmv.h.x ft0, %3\n\tfcvt.s.h %0, ft0\n\tfcvt.d.h %1, ft0\n\t"
				 "fcvt.h.s ft1, %0\n\tfmv.x.h %2, ft1"
				 : "=&f"(s), "=&f"(d), "=&r"(back) : "r"((long)h) : "ft0", "ft1");
		__asm__ volatile("fcvt.h.d ft1, %1, rtz\n\tfmv.x.h %0, ft1" : "=r"(back2) : "f"(d) : "ft1");
		memcpy(&sb, &s, 4);
		bad += sb != h2s(h) || (!nan && (double)s != d);
		bad += (back & 0xffff) != (nan ? 0x7e00 : h) || back != (long)(short)back;
		bad += (back2 & 0xffff) != (nan ? 0x7e00 : h);
	}
	__asm__ volatile("csrw fflags, x0");
	return bad;
}

static sigjmp_buf sig_jmp;

static void on_sig(int sig)
{
	siglongjmp(sig_jmp, sig);
}

/* Run fn(arg); the signal it raised (SIGSEGV, SIGILL), or 0. */
static int catch_sig(void (*fn)(void *), void *arg)
{
	struct sigaction sa = { .sa_handler = on_sig }, o1, o2;
	volatile int sig;

	sigaction(SIGSEGV, &sa, &o1);
	sigaction(SIGILL, &sa, &o2);
	sig = sigsetjmp(sig_jmp, 1);
	if (!sig)
		fn(arg);
	sigaction(SIGSEGV, &o1, NULL);
	sigaction(SIGILL, &o2, NULL);
	return sig;
}
static void do_cbo_zero(void *p)
{
	__asm__ volatile(".insn i 0x0f, 2, x0, %0, 4" :: "r"(p) : "memory");
}
static void do_cbo_clean(void *p)
{
	__asm__ volatile(".insn i 0x0f, 2, x0, %0, 1" :: "r"(p) : "memory");
}
static void do_cbo_flush(void *p)
{
	__asm__ volatile(".insn i 0x0f, 2, x0, %0, 2" :: "r"(p) : "memory");
}
static void do_cbo_inval(void *p)
{
	__asm__ volatile(".insn i 0x0f, 2, x0, %0, 0" :: "r"(p) : "memory");
}

/* The RVA23 extensions beyond probes: results, long enough to compile. */
static void rva23_checks(const int *have)
{
	int bad = 0;

	if (have[isa_find("zcb", 3)] && have[isa_find("zbb", 3)] && have[isa_find("zba", 3)]) {
		unsigned char p1[8], p2[8];
		unsigned long x = 0x0123456789abcdef;

		for (int i = 0; i < 20000; i++) {
			unsigned long a = x ^ ((unsigned long)i << 13), b = x >> (i & 31), r1, r2;

			for (int k = 0; k < 8; k++)
				p1[k] = p2[k] = (unsigned char)(x >> (8 * k));
			r1 = zcb_fn(p1, a, b);
			r2 = zcb_plain(p2, a, b);
			bad += r1 != r2 || memcmp(p1, p2, 8);
			x = x * 6364136223846793005UL + r1;
		}
		CHECK(!bad, "Zcb (compiled with Zbb, Zba): 20000 calls against rv64gc code, %d wrong", bad);
	}
	if (have[isa_find("zimop", 5)] && have[isa_find("zcmop", 5)]) {
		bad = 0;
		for (int i = 0; i < 20000; i++)
			bad += mop_check(i + 1, ~(unsigned long)i) + (cmop_check(i) != (unsigned long)i);
		CHECK(!bad, "Zimop, Zcmop: mop.r/mop.rr write 0, c.mop does nothing (20000 times), %d wrong", bad);
	}
	if (have[isa_find("zfa", 3)]) {
		double x = 0.37;

		bad = 0;
		for (int i = 0; i < 20000; i++) {
			double a = (double)(i % 2000) * 0.75 - 700.25 + x, b = x * 1e3 - (double)i;
			double r1 = zfa_fn(a, b), r2 = zfa_plain(a, b);

			bad += memcmp(&r1, &r2, 8) != 0;
			x = fmod(x * 3.7 + r1 * 1e-9, 1.0);
		}
		/* fcvtmod(-2^31 - 1) = 2^31 - 1, fminm = a, fltq = 1; fminm with a NaN is the canonical NaN */
		bad += zfa_insns(-2147483649.0, -3.0) != 2147483647L - 3 * 2147483649L + 1;
		bad += zfa_insns(5.75, 2.0) != 5 + 6 + 0;
		bad += zfa_minm(1.0, NAN) != 0x7ff8000000000000UL;
		CHECK(!bad, "Zfa: fround(nx) in 5 modes, fli, fmin/fmax 20000 times against libm, fminm, fcvtmod.w.d, fltq: %d wrong", bad);
	}
	if (have[isa_find("zihpm", 5)]) {
		unsigned long h3 = 1, h31 = 1;

		for (int i = 0; i < 1000; i++) {
			__asm__ volatile("csrr %0, 0xc03" : "=r"(h3));
			__asm__ volatile("csrr %0, 0xc1f" : "=r"(h31));
		}
		CHECK(h3 == 0 && h31 == 0, "Zihpm: hpmcounter3 = %lu, hpmcounter31 = %lu (no events counted)", h3, h31);
	}
	if (have[isa_find("zfhmin", 6)]) {
		bad = 0;
		for (int rep = 0; rep < 3; rep++)
			bad += zfh_all();
		CHECK(!bad, "Zfhmin: every half to single and double and back (3 times), %d wrong", bad);
	}
	if (have[isa_find("zicboz", 6)] && have[isa_find("zicbom", 6)]) {
		unsigned char *pg = mmap(NULL, 3 * 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		int s_ro, s_none, s_clean_ro, s_flush_none, s_inval;

		bad = 0;
		for (int i = 0; i < 2000 && pg != MAP_FAILED; i++) {
			int off = 64 + (i * 97) % 3900, b0 = off & ~63;

			memset(pg, 0x5a, 4096);
			do_cbo_clean(pg + off);
			do_cbo_flush(pg + off);
			do_cbo_zero(pg + off);
			for (int j = 0; j < 4096; j++)
				bad += pg[j] != (j >= b0 && j < b0 + 64 ? 0 : 0x5a);
		}
		/* read-only: cbo.clean works, cbo.zero faults; no access: both fault */
		memset(pg + 4096, 0x77, 4096);
		mprotect(pg + 4096, 4096, PROT_READ);
		mprotect(pg + 8192, 4096, PROT_NONE);
		s_ro = catch_sig(do_cbo_zero, pg + 4096 + 100);
		s_clean_ro = catch_sig(do_cbo_clean, pg + 4096 + 100);
		s_none = catch_sig(do_cbo_zero, pg + 8192);
		s_flush_none = catch_sig(do_cbo_flush, pg + 8192);
		s_inval = catch_sig(do_cbo_inval, pg);
		for (int j = 4096; j < 8192; j++)
			bad += pg[j] != 0x77;
		CHECK(!bad && s_ro == SIGSEGV && s_clean_ro == 0 && s_none == SIGSEGV && s_flush_none == SIGSEGV &&
		      s_inval == SIGILL,
		      "Zicbom, Zicboz: cbo.zero zeroes its 64-byte block (2000 times, %d wrong); read-only: zero %d, clean %d; "
		      "no access: zero %d, flush %d; cbo.inval %d", bad, s_ro, s_clean_ro, s_none, s_flush_none, s_inval);
		munmap(pg, 3 * 4096);
	}
}

/*
 * ISA advertising: the /proc/cpuinfo isa line, riscv_hwprobe and AT_HWCAP
 * agree with each other and with kw.isa= on the command line, the
 * extensions kwemu always has work, and an optional extension's
 * instructions run exactly when it is listed.
 */
static void isa_checks(void)
{
	char isa[512] = "", cmdline[1024] = "", mask[256] = "-";
	int want[NISA], have[NISA] = { 0 }, ordered = 1, unknown = 0, bad = 0, last = -1;
	unsigned long ext0 = 1UL << 0 | 1UL << 1; /* IMA_FD | IMA_C */
	unsigned long ext1 = 0;
	const char *p;

	mkdir("/proc", 0555);
	mount("proc", "/proc", "proc", 0, NULL); /* EBUSY when it is mounted */
	read_line("/proc/cpuinfo", "isa", 1, isa, sizeof(isa));
	read_line("/proc/cmdline", "", 0, cmdline, sizeof(cmdline));

	/* What should be listed: kind 2 and 1, then kw.isa= from left to right. */
	for (int i = 0; i < NISA; i++)
		want[i] = isa_exts[i].kind ? 1 : -1; /* -1: either */
	p = strstr(cmdline, "kw.isa=");
	if (p && (p == cmdline || p[-1] == ' ')) {
		p += 7;
		snprintf(mask, sizeof(mask), "%.*s", (int)strcspn(p, " "), p);
		for (char *tok = mask, *end; *tok; tok = *end ? end + 1 : end) {
			int on = *tok != '-', i;

			end = tok + strcspn(tok, ",");
			if (end - tok == 6 && !strncmp(tok, "rv64gc", 6)) {
				for (i = 0; i < NISA; i++)
					if (isa_exts[i].kind != 2)
						want[i] = 0;
				continue;
			}
			if (*tok == '-' || *tok == '+')
				tok++;
			i = isa_find(tok, end - tok);
			if (i >= 0 && isa_exts[i].kind != 2)
				want[i] = on ? (isa_exts[i].kind ? 1 : -1) : 0;
		}
	}

	/* Parse the isa line: rv64imafdc, then _ext in canonical order. */
	if (!strncmp(isa, "rv64imafdc", 10)) {
		for (p = isa + 10; *p == '_'; ) {
			size_t len = strcspn(p + 1, "_");
			int i = isa_find(p + 1, len);

			if (i < 0)
				unknown++;
			else {
				ordered &= i > last;
				last = i;
				have[i] = 1;
				ext0 |= isa_exts[i].hwprobe;
				ext1 |= isa_exts[i].ext1;
			}
			p += 1 + len;
		}
		unknown += *p != 0;
	} else
		unknown++;
	for (int i = 0; i < NISA; i++)
		if (want[i] >= 0 && want[i] != have[i]) {
			printf("     %s: want %s\n", isa_exts[i].name, want[i] ? "listed" : "not listed");
			bad++;
		}
	CHECK(!unknown && ordered && !bad, "cpuinfo isa: %s (kw.isa=%s)", isa, mask);

	/* IMA_EXT_0, then the ZICBOP, ZICBOZ and ZICBOM block sizes */
	struct hwprobe_pair pr[4] = { { 4 }, { 15 }, { 6 }, { 12 } };
	long rc = syscall(__NR_riscv_hwprobe, pr, 4, 0, NULL, 0);
	unsigned long zicbop = have[isa_find("zicbop", 6)] ? 64 : 0;
	unsigned long zicboz = have[isa_find("zicboz", 6)] ? 64 : 0;
	unsigned long zicbom = have[isa_find("zicbom", 6)] ? 64 : 0;
	CHECK(rc == 0 && pr[0].value == ext0 && pr[1].key == 15 && pr[1].value == zicbop &&
	      pr[2].key == 6 && pr[2].value == zicboz && pr[3].key == 12 && pr[3].value == zicbom,
	      "riscv_hwprobe IMA_EXT_0 %#lx (want %#lx), Zicbop/Zicboz/Zicbom blocks %lu/%lu/%lu (want %lu/%lu/%lu)",
	      (unsigned long)pr[0].value, ext0, (unsigned long)pr[1].value, (unsigned long)pr[2].value,
	      (unsigned long)pr[3].value, zicbop, zicboz, zicbom);

	/*
	 * IMA_EXT_1 (the platform properties) against the isa line; misaligned
	 * scalar accesses are fast (3) whatever kw.isa= says, vector ones
	 * unsupported (4).
	 */
	struct hwprobe_pair pr1[3] = { { 16 }, { 9 }, { 10 } };
	rc = syscall(__NR_riscv_hwprobe, pr1, 3, 0, NULL, 0);
	CHECK(rc == 0 && pr1[0].key == 16 && pr1[0].value == ext1 && pr1[1].key == 9 && pr1[1].value == 3 &&
	      pr1[2].key == 10 && pr1[2].value == 4,
	      "riscv_hwprobe IMA_EXT_1 %#lx (want %#lx), misaligned scalar/vector perf %lu/%lu (want 3/4)",
	      (unsigned long)pr1[0].value, ext1, (unsigned long)pr1[1].value, (unsigned long)pr1[2].value);

	/*
	 * HIGHEST_VIRT_ADDRESS is the end of Sv39 user space (1 << 38, as on
	 * riscv), the THEAD, SIFIVE and MIPS vendor keys are 0, and
	 * TIME_CSR_FREQ is unknown (key -1): the time CSR counts instructions.
	 */
	struct hwprobe_pair pr2[5] = { { 7 }, { 11 }, { 13 }, { 14 }, { 8 } };
	rc = syscall(__NR_riscv_hwprobe, pr2, 5, 0, NULL, 0);
	CHECK(rc == 0 && pr2[0].key == 7 && pr2[0].value == 1UL << 38 &&
	      pr2[1].key == 11 && pr2[1].value == 0 && pr2[2].key == 13 && pr2[2].value == 0 &&
	      pr2[3].key == 14 && pr2[3].value == 0 && pr2[4].key == -1 && pr2[4].value == 0,
	      "riscv_hwprobe highest virt %#lx (want %#lx), vendor keys %ld/%ld/%ld = %lu/%lu/%lu, time freq key %ld",
	      (unsigned long)pr2[0].value, 1UL << 38, (long)pr2[1].key, (long)pr2[2].key, (long)pr2[3].key,
	      (unsigned long)pr2[1].value, (unsigned long)pr2[2].value, (unsigned long)pr2[3].value,
	      (long)pr2[4].key);

	/*
	 * Zicclsm (a property of every kwemu, also when kw.isa= hides it):
	 * misaligned ld/sd, lw/sw and fld/fsd work, inside a page and across
	 * the boundary of two, long enough to compile.
	 */
	uint8_t *mp = mmap(NULL, 8192, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	int mis = mp == MAP_FAILED;
	for (int r = 0; !mis && r < 2000; r++)
		for (int off = 4085; off < 4100; off++) {
			uint8_t *q = mp + off;
			uint64_t v = 0x0123456789abcdefUL * (uint64_t)(r + off), d = 0, x;
			uint32_t w;
			double f, g;

			__asm__ volatile("sd %1, 0(%0)" :: "r"(q), "r"(v) : "memory");
			for (int k = 7; k >= 0; k--)
				d = d << 8 | q[k];
			__asm__ volatile("ld %0, 0(%1)" : "=r"(x) : "r"(q) : "memory");
			mis += d != v || x != v;
			__asm__ volatile("sw %2, 1(%1)\n\tlw %0, 1(%1)" : "=&r"(x) : "r"(q), "r"(~v) : "memory");
			memcpy(&w, q + 1, 4);
			mis += (uint32_t)x != (uint32_t)~v || w != (uint32_t)~v;
			memcpy(&f, &v, 8);
			__asm__ volatile("fsd %2, 3(%1)\n\tfld %0, 3(%1)" : "=&f"(g) : "r"(q), "f"(f) : "memory");
			memcpy(&x, &g, 8);
			memcpy(&d, q + 3, 8);
			mis += x != v || d != v;
		}
	CHECK(!mis, "Zicclsm: misaligned ld/sd, lw/sw, fld/fsd in a page and across pages (%d wrong)", mis);
	if (mp != MAP_FAILED)
		munmap(mp, 8192);
	CHECK(getauxval(AT_HWCAP) == 0x112d, "AT_HWCAP %#lx (IMAFDC)", getauxval(AT_HWCAP));

	/* Hints run as no-ops; instret counts the instruction between two reads. */
	static const uint32_t hints[] = {
		0x0100000f,				/* pause */
		0x00200033, 0x00300033, 0x00400033, 0x00500033, /* ntl.p1 ntl.pall ntl.s1 ntl.all */
		0x00056013, 0x00156013, 0x00356013,	/* prefetch.i/r/w 0(a0) */
		0x900e900a, 0x90169012,			/* c.ntl.p1 c.ntl.pall c.ntl.s1 c.ntl.all */
		0xc0002673, 0xc0102673,			/* rdcycle a2; rdtime a2 */
		0xc0202573, 0x00000013, 0xc02025f3,	/* rdinstret a0; nop; rdinstret a1 */
		0x40a58533, 0x00008067,			/* sub a0, a1, a0; ret */
	};
	long d = 0;
	rc = run_code(hints, sizeof(hints) / 4, 0, 0, &d);
	CHECK(rc == 0 && d == 2, "hints (pause, ntl, c.ntl, prefetch) and cycle/time/instret: instret delta %ld", d);

	/* Optional extensions: an instruction of each runs iff it is listed. */
	int ran = 0, trapped = 0;
	bad = 0;
	for (int i = 0; i < NISA; i++) {
		const struct isa_ext *e = &isa_exts[i];
		uint32_t code[2] = { e->probe, 0x00008067 };
		long r = 0;
		int listed;

		if (!e->probe)
			continue;
		listed = have[i] || (e->alt && have[isa_find(e->alt, strlen(e->alt))]);
		rc = run_code(code, 2, e->mem ? (long)probe_buf : 3, 5, &r);
		if (rc == 0)
			ran++;
		else
			trapped++;
		if ((rc == 0) != listed) {
			printf("     %s (%#x): %s but %s\n", e->name, e->probe, listed ? "listed" : "not listed",
			       rc == 0 ? "ran" : "raised SIGILL");
			bad++;
		} else if (rc == 0 && e->want && (unsigned long)r != e->want) {
			printf("     %s (%#x): %#lx, want %#lx\n", e->name, e->probe, (unsigned long)r, e->want);
			bad++;
		}
	}
	CHECK(!bad, "optional extensions: %d ran (listed), %d raised SIGILL (not listed)", ran, trapped);

	/* Zkne + Zknd: FIPS-197 C.1 (AES-128) as OpenSSL runs it, long enough to compile */
	if (have[isa_find("zkne", 4)] && have[isa_find("zknd", 4)]) {
		int reps = 0;

		bad = aes_fips(&reps);
		CHECK(!bad, "AES-128 (Zkne, Zknd): FIPS-197 C.1 %d times, %d wrong", reps, bad);
	}
	/* Zba + Zbb + Zbs + Zicond: a mix of them, long enough to compile */
	if (have[isa_find("zba", 3)] && have[isa_find("zbb", 3)] && have[isa_find("zbs", 3)] &&
	    have[isa_find("zicond", 6)]) {
		int reps = 0;

		bad = zb_mix(&reps);
		CHECK(!bad, "Zba, Zbb, Zbs, Zicond: a mix of 13 of them %d times, %d wrong", reps, bad);
	}
	/* Zbc (or Zbkc) + Zbkb: GHASH as OpenSSL runs it, long enough to compile */
	if ((have[isa_find("zbc", 3)] || have[isa_find("zbkc", 4)]) && have[isa_find("zbkb", 4)]) {
		int reps = 0;

		bad = ghash_kat(&reps);
		CHECK(!bad, "GHASH (Zbc, Zbkb): GCM test case 2 %d times, %d wrong", reps, bad);
	}
	rva23_checks(have);
}
#endif /* __riscv */

static volatile int alarms;

static void on_alarm(int sig)
{
	(void)sig;
	alarms++;
}

#ifdef __riscv
static int file_has(const char *path, const char *word)
{
	char buf[4096];
	int fd = open(path, O_RDONLY), n;

	if (fd < 0)
		return 0;
	n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	buf[n > 0 ? n : 0] = 0;
	return strstr(buf, word) != NULL;
}

/*
 * Optional kernel features in kw_defconfig (needs /proc, which isa_checks
 * mounted): the pids controller, user namespaces, userfaultfd, PSI, task
 * I/O accounting, sysrq and the loop-control and tun misc devices.
 */
static void config_checks(void)
{
	int status, uffd;
	pid_t pid = fork();

	if (pid == 0)
		_exit(syscall(SYS_unshare, 0x10000000 /* CLONE_NEWUSER */) ? 1 : 0);
	waitpid(pid, &status, 0);
	uffd = syscall(SYS_userfaultfd, O_CLOEXEC);
	if (uffd >= 0)
		close(uffd);
	CHECK(WIFEXITED(status) && !WEXITSTATUS(status) && uffd >= 0 && file_has("/proc/cgroups", "pids") &&
	      file_has("/proc/pressure/cpu", "some") && file_has("/proc/self/io", "rchar") &&
	      !access("/proc/sysrq-trigger", W_OK) && file_has("/proc/misc", "loop-control") &&
	      file_has("/proc/misc", " tun"),
	      "config: user ns %s, userfaultfd %s, pids cgroup, PSI, /proc/self/io, sysrq, loop-control, tun",
	      WIFEXITED(status) && !WEXITSTATUS(status) ? "ok" : "BAD", uffd >= 0 ? "ok" : "BAD");
}

/*
 * rtnetlink requests for net_config_checks: attributes appended to a
 * buffer (without data: a nest, or room that the caller fills).
 */
struct nl_req {
	struct nlmsghdr h;
	char body[256];
};

static struct rtattr *nl_attr(struct nl_req *r, int type, const void *data, int len)
{
	struct rtattr *a = (struct rtattr *)((char *)r + NLMSG_ALIGN(r->h.nlmsg_len));

	a->rta_type = type;
	a->rta_len = RTA_LENGTH(len);
	if (data)
		memcpy(RTA_DATA(a), data, len);
	r->h.nlmsg_len = NLMSG_ALIGN(r->h.nlmsg_len) + RTA_ALIGN(a->rta_len);
	return a;
}

static void nl_nest_end(struct nl_req *r, struct rtattr *a)
{
	a->rta_len = (char *)r + NLMSG_ALIGN(r->h.nlmsg_len) - (char *)a;
}

/* Sends the request and returns the kernel's ack: 0 or a negative errno. */
static int nl_ack(int fd, struct nl_req *r)
{
	struct {
		struct nlmsghdr h;
		struct nlmsgerr e;
		char pad[128];
	} ans;

	r->h.nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE | NLM_F_EXCL;
	if (send(fd, r, r->h.nlmsg_len, 0) < 0 || recv(fd, &ans, sizeof(ans), 0) < (ssize_t)NLMSG_LENGTH(sizeof(ans.e)) ||
	    ans.h.nlmsg_type != NLMSG_ERROR)
		return -EIO;
	return ans.e.error;
}

static void nl_newlink(struct nl_req *r, const char *name)
{
	memset(r, 0, sizeof(*r));
	r->h.nlmsg_type = RTM_NEWLINK;
	r->h.nlmsg_len = NLMSG_LENGTH(sizeof(struct ifinfomsg));
	nl_attr(r, IFLA_IFNAME, name, strlen(name) + 1);
}

/*
 * Network options in kw_defconfig, tried in a network namespace of the
 * child's own, so nothing is left behind: a dummy link, a veth pair and a
 * policy routing rule (IP_MULTIPLE_TABLES; tailscale's "from all lookup 52").
 */
static void net_config_checks(void)
{
	int status;
	pid_t pid = fork();

	if (pid == 0) {
		struct nl_req r;
		struct rtattr *info, *data, *peer;
		struct fib_rule_hdr *rule;
		uint32_t prio = 5270;
		int fd, bad = 0;

		if (syscall(SYS_unshare, 0x40000000 /* CLONE_NEWNET */))
			_exit(8);
		fd = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_ROUTE);
		if (fd < 0)
			_exit(8);

		nl_newlink(&r, "kwd0");
		info = nl_attr(&r, IFLA_LINKINFO, NULL, 0);
		nl_attr(&r, IFLA_INFO_KIND, "dummy", 5);
		nl_nest_end(&r, info);
		bad |= nl_ack(fd, &r) ? 1 : 0;

		nl_newlink(&r, "kwv0");
		info = nl_attr(&r, IFLA_LINKINFO, NULL, 0);
		nl_attr(&r, IFLA_INFO_KIND, "veth", 4);
		data = nl_attr(&r, IFLA_INFO_DATA, NULL, 0);
		peer = nl_attr(&r, VETH_INFO_PEER, NULL, sizeof(struct ifinfomsg));
		memset(RTA_DATA(peer), 0, sizeof(struct ifinfomsg));
		nl_attr(&r, IFLA_IFNAME, "kwv1", 5);
		nl_nest_end(&r, peer);
		nl_nest_end(&r, data);
		nl_nest_end(&r, info);
		bad |= nl_ack(fd, &r) ? 2 : 0;

		memset(&r, 0, sizeof(r));
		r.h.nlmsg_type = RTM_NEWRULE;
		r.h.nlmsg_len = NLMSG_LENGTH(sizeof(*rule));
		rule = NLMSG_DATA(&r.h);
		rule->family = AF_INET;
		rule->table = 52;
		rule->action = FR_ACT_TO_TBL;
		nl_attr(&r, FRA_PRIORITY, &prio, sizeof(prio));
		bad |= nl_ack(fd, &r) ? 4 : 0;
		_exit(bad);
	}
	waitpid(pid, &status, 0);
	status = WIFEXITED(status) ? WEXITSTATUS(status) : 8;
	CHECK(!status, "net config: netns %s, dummy %s, veth %s, ip rule %s", status & 8 ? "BAD" : "ok",
	      status & 9 ? "BAD" : "ok", status & 10 ? "BAD" : "ok", status & 12 ? "BAD" : "ok");
}

/*
 * Software uaccess (arch/wasm/mm/fault.c). A kernel access to user memory
 * whose fault returns VM_FAULT_RETRY with a signal pending must be retried
 * (only a fatal signal ends it): read() from a pipe into a userfaultfd page
 * while the handler signals the reader before it supplies the page. And
 * the futex ops on user words (FUTEX_WAKE_OP here) must be atomic against
 * user AMOs on other CPUs: one thread adds through FUTEX_OP_ADD while
 * another (on another CPU when there is one) runs amoadd on the same word,
 * and no increment may be lost.
 */
static volatile int ua_sigs;
static void ua_on_sig(int sig)
{
	ua_sigs++;
}

static struct {
	char *page;
	int fd[2];
	long n;
	int err;
	pid_t tid;
} ua_rd;

static void *ua_reader(void *arg)
{
	__atomic_store_n(&ua_rd.tid, syscall(SYS_gettid), __ATOMIC_RELEASE);
	ua_rd.n = read(ua_rd.fd[0], ua_rd.page, 100);
	ua_rd.err = ua_rd.n < 0 ? errno : 0;
	return NULL;
}

#define UA_ITERS 100000
#define UA_SCALAR_ITERS 20000
static unsigned ua_word, ua_dummy;
static volatile unsigned ua_flip, ua_cpu_word;
static volatile int ua_flip_stop, ua_cpu_torn;

static void *ua_adder(void *arg)
{
	unsigned long mask = 1UL << (long)arg;
	int i;

	syscall(SYS_sched_setaffinity, 0, sizeof(mask), &mask);
	for (i = 0; i < UA_ITERS; i++)
		__atomic_fetch_add(&ua_word, 1, __ATOMIC_RELAXED);
	return NULL;
}

static void *ua_wakeop(void *arg)
{
	unsigned long mask = 1UL << (long)arg;
	int i;

	syscall(SYS_sched_setaffinity, 0, sizeof(mask), &mask);
	for (i = 0; i < UA_ITERS; i++)
		syscall(SYS_futex, &ua_dummy, FUTEX_WAKE_OP_PRIVATE, 0, 0, &ua_word,
			FUTEX_OP(FUTEX_OP_ADD, 1, FUTEX_OP_CMP_EQ, 0));
	return NULL;
}

/*
 * Flip ua_flip between 0x5a5a0000 and 0x00005a5a (a torn get_user() in
 * FUTEX_WAIT could see 0 or 0x5a5a5a5a), and store ~0u to ua_cpu_word while
 * checking that put_user() in getcpu() never tears against it.
 */
static void *ua_flipper(void *arg)
{
	unsigned long mask = 1UL << ((long)arg & 63);
	long online = ((long)arg >> 8) ?: 1;

	syscall(SYS_sched_setaffinity, 0, sizeof(mask), &mask);
	while (!__atomic_load_n(&ua_flip_stop, __ATOMIC_RELAXED)) {
		unsigned c;

		__atomic_store_n(&ua_flip, 0x5a5a0000u, __ATOMIC_RELAXED);
		__atomic_store_n(&ua_flip, 0x00005a5au, __ATOMIC_RELAXED);
		c = __atomic_load_n(&ua_cpu_word, __ATOMIC_RELAXED);
		if (c != ~0u && c >= (unsigned)online)
			__atomic_fetch_add(&ua_cpu_torn, 1, __ATOMIC_RELAXED);
		__atomic_store_n(&ua_cpu_word, ~0u, __ATOMIC_RELAXED);
	}
	return NULL;
}

static void uaccess_checks(void)
{
	long online = sysconf(_SC_NPROCESSORS_ONLN);
	struct uffdio_api api = { .api = UFFD_API };
	struct sigaction sa = { .sa_handler = ua_on_sig }, old;
	char src[4096], *area;
	int uffd, rounds = 0, good = 0, i;
	unsigned sum = 0;

	/* 1. The fault retried with a signal pending. */
	uffd = syscall(SYS_userfaultfd, O_CLOEXEC);
	area = mmap(NULL, 4 * 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (uffd >= 0 && area != MAP_FAILED && !ioctl(uffd, UFFDIO_API, &api) && !pipe(ua_rd.fd)) {
		struct uffdio_register reg = {
			.range = { (unsigned long)area, 4 * 4096 }, .mode = UFFDIO_REGISTER_MODE_MISSING,
		};

		sigaction(SIGUSR2, &sa, &old);
		memset(src, 'u', sizeof(src));
		if (!ioctl(uffd, UFFDIO_REGISTER, &reg)) {
			for (i = 0; i < 4; i++) {
				struct pollfd pfd = { .fd = uffd, .events = POLLIN };
				struct uffd_msg msg;
				struct uffdio_copy cp = {
					.dst = (unsigned long)area + i * 4096, .src = (unsigned long)src, .len = 4096,
				};
				pthread_t th;

				rounds++;
				ua_rd.page = area + i * 4096;
				ua_rd.tid = 0;
				if (write(ua_rd.fd[1], "0123456789abcdef0123456789abcdef0123456789abcdef"
						       "0123456789abcdef0123456789abcdef0123", 100) != 100 ||
				    pthread_create(&th, NULL, ua_reader, NULL))
					break;
				/* The reader is now asleep in the fault. */
				if (poll(&pfd, 1, 5000) == 1 && read(uffd, &msg, sizeof(msg)) == sizeof(msg) &&
				    msg.event == UFFD_EVENT_PAGEFAULT) {
					while (!__atomic_load_n(&ua_rd.tid, __ATOMIC_ACQUIRE))
						;
					syscall(SYS_tgkill, getpid(), ua_rd.tid, SIGUSR2);
					usleep(20000);
				}
				ioctl(uffd, UFFDIO_COPY, &cp);
				pthread_join(th, NULL);
				good += ua_rd.n == 100 && !memcmp(ua_rd.page, "0123456789", 10);
				if (ua_rd.n != 100)
					printf("     uaccess: read() into a userfaultfd page with a signal pending: %ld (%s)\n",
					       ua_rd.n, strerror(ua_rd.err));
			}
		}
		sigaction(SIGUSR2, &old, NULL);
		close(ua_rd.fd[0]);
		close(ua_rd.fd[1]);
	}
	if (uffd >= 0)
		close(uffd);
	if (area != MAP_FAILED)
		munmap(area, 4 * 4096);
	CHECK(rounds == 4 && good == 4 && ua_sigs == 4,
	      "uaccess: fault retried with a signal pending (userfaultfd): %d/%d reads whole, %d signals", good, rounds,
	      ua_sigs);

	/* 2. FUTEX_WAKE_OP's add against amoadd on another CPU. */
	for (i = 0; i < 2; i++) {
		pthread_t a, b;

		ua_word = 0;
		pthread_create(&a, NULL, ua_adder, (void *)0L);
		pthread_create(&b, NULL, ua_wakeop, (void *)(long)(online > 1));
		pthread_join(a, NULL);
		pthread_join(b, NULL);
		sum += ua_word;
	}
	CHECK(sum == 2 * 2 * UA_ITERS, "uaccess: FUTEX_WAKE_OP add beside amoadd on %s CPU: %u, want %u",
	      online > 1 ? "another" : "the same", sum, 2 * 2 * UA_ITERS);

	/*
	 * 3. Aligned get_user() and put_user() scalar atomicity, and unaligned
	 * access across a page boundary.
	 */
	{
		struct timespec ts = { 0, 1000000 };
		unsigned long mask0 = 1, all = online >= 63 ? ~0UL : (1UL << online) - 1;
		int get_torn = 0, unal_ok = 0;
		unsigned unal_cpu = ~0u;
		char *strad = mmap(NULL, 2 * 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		pthread_t fl;

		ua_flip = 0x5a5a0000u;
		ua_cpu_word = ~0u;
		ua_flip_stop = 0;
		ua_cpu_torn = 0;
		syscall(SYS_sched_setaffinity, 0, sizeof(mask0), &mask0);
		if (!pthread_create(&fl, NULL, ua_flipper, (void *)((online << 8) | (online > 1)))) {
			for (i = 0; i < UA_SCALAR_ITERS; i++) {
				unsigned want = (i & 1) ? 0x5a5a5a5au : 0u, c;
				long r = syscall(SYS_futex, &ua_flip, FUTEX_WAIT_PRIVATE, want, &ts, NULL, 0);

				if (r != -1 || errno != EAGAIN)
					get_torn++;
				if (syscall(SYS_getcpu, &ua_cpu_word, NULL, NULL))
					ua_cpu_torn++;
				c = __atomic_load_n(&ua_cpu_word, __ATOMIC_RELAXED);
				if (c != ~0u && c >= (unsigned)online)
					ua_cpu_torn++;
			}
			__atomic_store_n(&ua_flip_stop, 1, __ATOMIC_RELAXED);
			pthread_join(fl, NULL);
		} else {
			get_torn++;
		}
		syscall(SYS_sched_setaffinity, 0, sizeof(all), &all);
		if (strad != MAP_FAILED) {
			memset(strad + 4092, 0xff, 8);
			if (!syscall(SYS_getcpu, strad + 4094, NULL, NULL)) {
				memcpy(&unal_cpu, strad + 4094, sizeof(unal_cpu));
				unal_ok = unal_cpu < (unsigned)online;
			}
			munmap(strad, 2 * 4096);
		}
		CHECK(!get_torn && !ua_cpu_torn && unal_ok,
		      "uaccess: aligned get_user/put_user untorn (%d/%d torn in %d rounds), unaligned across pages: %s (cpu %u)",
		      get_torn, ua_cpu_torn, UA_SCALAR_ITERS, unal_ok ? "ok" : "BAD", unal_cpu);
	}
}

/*
 * The input handlers. kwinput tells the host when a device is opened, and
 * the host then sends that device the keys and the pointer instead of the
 * console and the page, so only user space may open one: evdev opens a
 * device for a program that reads it, and sysrq is a passive observer
 * (drivers/tty/sysrq.c on wasm). Any other handler (VT kbd, leds, mousedev,
 * joydev, ...) opens every device it matches from boot. Before adding one
 * here, make it passive or keep it off the kwinput devices.
 */
static void input_handler_checks(void)
{
	char buf[1024], other[256] = "";
	int fd = open("/proc/bus/input/handlers", O_RDONLY), n, evdev = 0;
	char *p;

	n = fd < 0 ? -1 : read(fd, buf, sizeof(buf) - 1);
	if (fd >= 0)
		close(fd);
	buf[n > 0 ? n : 0] = 0;
	for (p = buf; (p = strstr(p, "Name=")); ) {
		size_t len = strcspn(p += 5, " \n");

		if (len == 5 && !strncmp(p, "evdev", 5))
			evdev = 1;
		else if (!(len == 5 && !strncmp(p, "sysrq", 5)) && strlen(other) + len + 2 < sizeof(other))
			strncat(strcat(other, " "), p, len);
		p += len;
	}
	CHECK(n > 0 && evdev && !other[0], "input handlers: evdev %s, others besides sysrq:%s",
	      evdev ? "ok" : "MISSING", other[0] ? other : " none");
}
/*
 * A path for the char device maj:min: devtmpfs's node dev when it is there,
 * else one made at tmp (as /init, /dev may have no devtmpfs). The node in
 * /dev comes first because a shell on the overlay root (the page with its
 * data disk) has /tmp mounted nodev, where opening a device node fails with
 * EACCES. *made says whether tmp was made (the caller unlinks it). NULL if
 * neither works.
 */
static const char *chrdev_node(const char *dev, const char *tmp, unsigned int maj, unsigned int min, int *made)
{
	struct stat st;

	*made = 0;
	if (!stat(dev, &st) && S_ISCHR(st.st_mode) && st.st_rdev == makedev(maj, min))
		return dev;
	unlink(tmp);   /* left over from a run that was killed */
	if (mknod(tmp, S_IFCHR | 0600, makedev(maj, min)))
		return NULL;
	*made = 1;
	return tmp;
}

/*
 * AF_VSOCK (kwvsock, net/vmw_vsock/kwvsock.c). The guest's CID comes from
 * /dev/vsock (its minor from /proc/misc; chrdev_node). With a host device
 * (the CLI's and the page's default) it is 3, and a connect to host port 9,
 * where nothing listens, is refused (the host answers the request with RST:
 * ECONNRESET). Without one (CLI --no-vsock) there is no transport:
 * VMADDR_CID_ANY, and connect fails with ENODEV.
 */
static void vsock_checks(void)
{
	struct sockaddr_vm a = { .svm_family = AF_VSOCK, .svm_cid = VMADDR_CID_HOST, .svm_port = 9 };
	const char *node;
	unsigned int cid = VMADDR_CID_ANY, minor;
	char buf[4096], *p;
	int fd = open("/proc/misc", O_RDONLY), n, s, rc, err = 0, made;

	n = fd < 0 ? -1 : read(fd, buf, sizeof(buf) - 1);
	if (fd >= 0)
		close(fd);
	buf[n > 0 ? n : 0] = 0;
	p = strstr(buf, " vsock\n");
	while (p && p > buf && p[-1] != '\n')
		p--;
	if (p && sscanf(p, "%u vsock", &minor) == 1 &&
	    (node = chrdev_node("/dev/vsock", "/tmp/.kwtest-vsock", 10, minor, &made))) {
		fd = open(node, O_RDONLY);
		if (made)
			unlink(node);
		if (fd >= 0) {
			ioctl(fd, IOCTL_VM_SOCKETS_GET_LOCAL_CID, &cid);
			close(fd);
		}
	}
	s = socket(AF_VSOCK, SOCK_STREAM, 0);
	rc = s < 0 ? -1 : connect(s, (struct sockaddr *)&a, sizeof(a));
	err = rc ? errno : 0;
	if (s >= 0)
		close(s);
	if (cid == VMADDR_CID_ANY)
		CHECK(s >= 0 && rc && err == ENODEV, "vsock: no host device (CLI --no-vsock): socket %s, connect: %s",
		      s >= 0 ? "ok" : "FAILED", rc ? strerror(err) : "succeeded?");
	else
		CHECK(cid == 3 && s >= 0 && rc && err == ECONNRESET, "vsock: guest CID %u, connect to host port 9 (nothing listens): %s",
		      cid, rc ? strerror(err) : "succeeded?");
}

/*
 * 9p (NET_9P, NET_9P_FD, 9P_FS in kw_defconfig): the file system type the
 * SDK's host mounts use (kernel/guest/kw9p.c, js/core/9p.ts). Kconfig drops
 * options silently, so pin that it is registered.
 */
static void ninep_checks(void)
{
	char buf[4096];
	int fd = open("/proc/filesystems", O_RDONLY), n;

	n = fd < 0 ? -1 : read(fd, buf, sizeof(buf) - 1);
	if (fd >= 0)
		close(fd);
	buf[n > 0 ? n : 0] = 0;
	CHECK(strstr(buf, "\t9p\n") != NULL, "9p: file system type %s", strstr(buf, "\t9p\n") ? "registered" : "MISSING from /proc/filesystems");
}

/* From the kernel's include/uapi/linux/kwshm.h. */
struct kwshm_export {
	int32_t fd;
	uint32_t flags;
	uint64_t offset;
	uint64_t length;
	uint64_t size;
	uint32_t id;
	uint32_t pages;
};
#define KWSHM_IOC_EXPORT	_IOWR(0xBB, 0x00, struct kwshm_export)
#define KWSHM_IOC_RELEASE	_IOW(0xBB, 0x01, uint32_t)
#ifndef F_ADD_SEALS
#define F_ADD_SEALS	1033
#define F_SEAL_WRITE	0x0008
#endif

/* A minor from /proc/misc ("NN name"), -1 if absent. */
static int misc_minor(const char *name)
{
	char buf[4096], pat[64], *p;
	int fd = open("/proc/misc", O_RDONLY), n;
	unsigned int minor;

	n = fd < 0 ? -1 : read(fd, buf, sizeof(buf) - 1);
	if (fd >= 0)
		close(fd);
	buf[n > 0 ? n : 0] = 0;
	snprintf(pat, sizeof(pat), " %s\n", name);
	p = strstr(buf, pat);
	while (p && p > buf && p[-1] != '\n')
		p--;
	return p && sscanf(p, "%u", &minor) == 1 ? (int)minor : -1;
}

static int shm_memfd(size_t size)
{
	int fd = syscall(__NR_memfd_create, "kwtest", 2 /* MFD_ALLOW_SEALING */);

	if (fd >= 0 && ftruncate(fd, size)) {
		close(fd);
		fd = -1;
	}
	return fd;
}

/*
 * kwshm (drivers/misc/kwshm.c): /dev/kwshm exists only with a host device
 * (CLI --shm). With one: a 1 MiB memfd, half of it written (the rest are
 * holes, allocated by the export), exports as 256 pages with an id; an
 * unaligned offset, a range past the end and a pipe are refused (EINVAL);
 * while exported its pages are pinned, so F_SEAL_WRITE fails with EBUSY
 * (the extra references that also stop migration); after KWSHM_IOC_RELEASE
 * a second release is ENOENT, and a range export released by closing
 * /dev/kwshm no longer blocks the seal either.
 */
static void shm_checks(void)
{
	const char *node = "/tmp/.kwtest-kwshm";
	int minor = misc_minor("kwshm"), dev, fd, fd2, p[2] = { -1, -1 };
	struct kwshm_export e = { 0 }, bad = { 0 }, r = { 0 };
	int rc, rc_unal, rc_past, rc_pipe, seal_busy, seal_after, rel2, seal_closed;
	static char half[512 * 1024];

	if (minor < 0) {
		CHECK(1, "kwshm: no host device (skipped; CLI --shm adds one)");
		return;
	}
	dev = mknod(node, S_IFCHR | 0600, makedev(10, minor)) ? -1 : open(node, O_RDWR);
	unlink(node);
	fd = shm_memfd(1 << 20);
	memset(half, 0x5a, sizeof(half));
	if (fd >= 0)
		write(fd, half, sizeof(half));
	e.fd = fd;
	rc = ioctl(dev, KWSHM_IOC_EXPORT, &e) ? errno : 0;
	bad.fd = fd;
	bad.offset = 100;
	rc_unal = ioctl(dev, KWSHM_IOC_EXPORT, &bad) ? errno : 0;
	bad.offset = 4096;
	bad.length = 1 << 20;
	rc_past = ioctl(dev, KWSHM_IOC_EXPORT, &bad) ? errno : 0;
	pipe(p);
	bad.fd = p[0];
	bad.offset = bad.length = 0;
	rc_pipe = ioctl(dev, KWSHM_IOC_EXPORT, &bad) ? errno : 0;
	close(p[0]);
	close(p[1]);
	seal_busy = fcntl(fd, F_ADD_SEALS, F_SEAL_WRITE) ? errno : 0;
	rc = rc ? rc : ioctl(dev, KWSHM_IOC_RELEASE, &e.id) ? errno : 0;
	rel2 = ioctl(dev, KWSHM_IOC_RELEASE, &e.id) ? errno : 0;
	seal_after = fcntl(fd, F_ADD_SEALS, F_SEAL_WRITE) ? errno : 0;
	close(fd);
	/* A range export, released by closing the device. */
	fd2 = shm_memfd(1 << 20);
	r.fd = fd2;
	r.offset = 8192;
	r.length = 10000;
	if (ioctl(dev, KWSHM_IOC_EXPORT, &r))
		r.pages = 0;
	close(dev);
	seal_closed = fcntl(fd2, F_ADD_SEALS, F_SEAL_WRITE) ? errno : 0;
	close(fd2);
	CHECK(dev >= 0 && !rc && e.id > 0 && e.size == 1 << 20 && e.pages == 256 && rc_unal == EINVAL &&
	      rc_past == EINVAL && rc_pipe == EINVAL && seal_busy == EBUSY && rel2 == ENOENT && !seal_after &&
	      r.size == 10000 && r.pages == 3 && !seal_closed,
	      "kwshm: export id %u, %llu bytes in %u pages (%s); refused: unaligned %s, past the end %s, a pipe %s; "
	      "F_SEAL_WRITE while exported: %s, after release: %s; second release: %s; range: %llu bytes in %u pages, "
	      "seal after closing /dev/kwshm: %s",
	      e.id, (unsigned long long)e.size, e.pages, rc ? strerror(rc) : "ok", strerror(rc_unal), strerror(rc_past),
	      strerror(rc_pipe), seal_busy ? strerror(seal_busy) : "allowed?", seal_after ? strerror(seal_after) : "ok",
	      strerror(rel2), (unsigned long long)r.size, r.pages, seal_closed ? strerror(seal_closed) : "ok");
}

/* Open and close @path: 0, or the errno of the open. */
static int open_err(const char *path)
{
	int fd = open(path, O_RDWR);

	if (fd < 0)
		return errno;
	close(fd);
	return 0;
}

static struct {
	int fd;
	volatile int ready, stop;
	int changes, bad;
} fb_race;

static void *fb_mode_changer(void *arg)
{
	unsigned long mask = 1UL << (long)arg;
	struct fb_var_screeninfo var;
	int step = 0;

	syscall(SYS_sched_setaffinity, 0, sizeof(mask), &mask);
	if (ioctl(fb_race.fd, FBIOGET_VSCREENINFO, &var)) {
		fb_race.bad++;
		__atomic_store_n(&fb_race.ready, 1, __ATOMIC_RELEASE);
		return NULL;
	}
	__atomic_store_n(&fb_race.ready, 1, __ATOMIC_RELEASE);
	while (!__atomic_load_n(&fb_race.stop, __ATOMIC_ACQUIRE)) {
		struct fb_var_screeninfo v = var;

		v.xres = v.xres_virtual = (step & 1) ? 320 : 256;
		v.yres = v.yres_virtual = (step & 1) ? 240 : 192;
		step++;
		if (!ioctl(fb_race.fd, FBIOPUT_VSCREENINFO, &v))
			__atomic_fetch_add(&fb_race.changes, 1, __ATOMIC_RELEASE);
		else if (errno != EBUSY)
			fb_race.bad++;
		if (!(long)arg)
			sched_yield();
	}
	return NULL;
}

/*
 * kwfb (drivers/video/fbdev/kwfb.c): /dev/fb0 (char 29:0; chrdev_node)
 * exists only with a host display (CLI --display). One program at a time:
 * while an open file exists a second open fails with EBUSY, also once its
 * opener has closed it but a forked child still holds the shared file, and
 * while a mapping outlives close(); when the last reference is gone (the
 * child's exit, munmap) the device opens again. And an mmap racing
 * FBIOPUT_VSCREENINFO from another thread never maps a stale buffer.
 */
static void fb_checks(void)
{
	const char *node;
	int fd = open("/proc/fb", O_RDONLY), n, a, b, go[2] = { -1, -1 }, status = 0, made;
	int a_err, busy_open, busy_child, after_child, busy_map, after_map;
	int race_maps = 0, race_stale = 0, race_busy = 0;
	long online = sysconf(_SC_NPROCESSORS_ONLN);
	unsigned long mask0 = 1, all = online >= 63 ? ~0UL : (1UL << online) - 1;
	struct fb_var_screeninfo orig_var;
	char buf[256], c = 0;
	void *map = MAP_FAILED;
	pid_t pid;

	n = fd < 0 ? -1 : read(fd, buf, sizeof(buf) - 1);
	if (fd >= 0)
		close(fd);
	buf[n > 0 ? n : 0] = 0;
	if (!strstr(buf, "0 kwfb")) {
		CHECK(1, "kwfb: no host display (skipped; CLI --display adds one)");
		return;
	}
	node = chrdev_node("/dev/fb0", "/tmp/.kwtest-fb0", 29, 0, &made);
	a = node ? open(node, O_RDWR) : -1;
	a_err = a < 0 ? errno : 0;
	if (!node)
		node = "/tmp/.kwtest-fb0";   /* so the opens below fail and report */
	busy_open = open_err(node);
	/* The child shares the file; it outlives the parent's close. */
	pipe(go);
	pid = fork();
	if (pid == 0) {
		read(go[0], &c, 1);
		_exit(0);
	}
	if (a >= 0)
		close(a);
	busy_child = open_err(node);
	write(go[1], &c, 1);
	waitpid(pid, &status, 0);
	close(go[0]);
	close(go[1]);
	/* A mapping keeps the file after close(). */
	b = open(node, O_RDWR);
	if (b >= 0) {
		after_child = 0;
		map = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, b, 0);
		close(b);
	} else {
		after_child = errno;
	}
	busy_map = open_err(node);
	if (map != MAP_FAILED)
		munmap(map, 4096);
	after_map = open_err(node);

	/* mmap racing FBIOPUT_VSCREENINFO from another thread. */
	memset(&fb_race, 0, sizeof(fb_race));
	fb_race.fd = open(node, O_RDWR);
	if (fb_race.fd >= 0 && !ioctl(fb_race.fd, FBIOGET_VSCREENINFO, &orig_var)) {
		pthread_t th;

		syscall(SYS_sched_setaffinity, 0, sizeof(mask0), &mask0);
		if (!pthread_create(&th, NULL, fb_mode_changer, (void *)(long)(online > 1))) {
			while (!__atomic_load_n(&fb_race.ready, __ATOMIC_ACQUIRE))
				sched_yield();
			for (int i = 1; i <= 200; i++) {
				uint32_t tag = 0xfb000000u | (uint32_t)i, got = 0;
				uint32_t *p = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fb_race.fd, 0);
				struct fb_var_screeninfo v = orig_var;

				if (p == MAP_FAILED) {
					fb_race.bad++;
					break;
				}
				race_maps++;
				__atomic_store_n(p, tag, __ATOMIC_RELEASE);
				if (pread(fb_race.fd, &got, sizeof(got), 0) != sizeof(got) || got != tag)
					race_stale++;
				v.xres = v.xres_virtual = 128;
				v.yres = v.yres_virtual = 128;
				if (!ioctl(fb_race.fd, FBIOPUT_VSCREENINFO, &v) || errno != EBUSY)
					race_busy++;
				munmap(p, 4096);
				if ((i & 7) == 0)
					sched_yield();
			}
			__atomic_store_n(&fb_race.stop, 1, __ATOMIC_RELEASE);
			pthread_join(th, NULL);
		} else {
			fb_race.bad++;
		}
		syscall(SYS_sched_setaffinity, 0, sizeof(all), &all);
		ioctl(fb_race.fd, FBIOPUT_VSCREENINFO, &orig_var);
		close(fb_race.fd);
	} else {
		if (fb_race.fd >= 0)
			close(fb_race.fd);
		fb_race.bad++;
	}
	if (made)
		unlink(node);
	CHECK(a >= 0 && busy_open == EBUSY && busy_child == EBUSY && WIFEXITED(status) && !after_child &&
	      map != MAP_FAILED && busy_map == EBUSY && !after_map &&
	      !fb_race.bad && race_maps == 200 && fb_race.changes > 0 && !race_stale && !race_busy,
	      "kwfb: first open %s; second open: %s, held by a forked child: %s, after its exit: %s; mmap %s, "
	      "open while mapped after close: %s, after munmap: %s; mmap vs mode change: %d maps, %d mode changes, %d stale, %d allowed while mapped",
	      a >= 0 ? "ok" : strerror(a_err), busy_open ? strerror(busy_open) : "allowed?",
	      busy_child ? strerror(busy_child) : "allowed?", after_child ? strerror(after_child) : "ok",
	      map != MAP_FAILED ? "ok" : "FAILED", busy_map ? strerror(busy_map) : "allowed?",
	      after_map ? strerror(after_map) : "ok", race_maps, fb_race.changes, race_stale, race_busy);
}

/*
 * Parking (arch/wasm/kernel/park.c): every task stops at a point where its
 * state is all in memory and resumes on a fresh stack. Children sleep in
 * read, poll, nanosleep, futex and epoll_wait, or run hot() in user mode,
 * while this process requests cycles through /proc/kwpark (and is parked
 * itself while it waits). Interrupted sleeps must restart transparently;
 * only epoll_wait may return EINTR (as after SIGSTOP and SIGCONT).
 */
struct park_info {
	unsigned req, done, users, kthreads;
	int result;
	unsigned long long us;
	char blocker[64];
};

static int park_read(struct park_info *p)
{
	char buf[256];
	int fd = open("/proc/kwpark", O_RDONLY), n;

	if (fd < 0)
		return -1;
	n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0)
		return -1;
	buf[n] = 0;
	return sscanf(buf, "requests %u done %u result %d users %u kthreads %u us %llu blocker %63s",
		      &p->req, &p->done, &p->result, &p->users, &p->kthreads, &p->us, p->blocker) == 7 ? 0 : -1;
}

/* Request a cycle and wait for it (or one that started after the request). */
static int park_cycle(struct park_info *p)
{
	struct timespec ms = { 0, 1000000 };
	unsigned want;
	int fd, i;

	if (park_read(p))
		return -1;
	want = p->req + 1;
	fd = open("/proc/kwpark", O_WRONLY);
	if (fd < 0 || write(fd, "1", 1) != 1)
		return -1;
	close(fd);
	for (i = 0; i < 5000; i++) {
		nanosleep(&ms, NULL);
		if (park_read(p))
			return -1;
		if ((int)(p->done - want) >= 0)
			return 0;
	}
	return -1;
}

static double mono(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec * 1e-9;
}

enum { PK_READ, PK_POLL, PK_SLEEP, PK_FUTEX, PK_EPOLL, PK_HOT, PK_N };
static const char *const park_names[PK_N] = { "read", "poll", "nanosleep", "futex", "epoll_wait", "hot" };

/* Exit status: 0 ok, 1 wrong result. Writes the number of EINTRs to *eintr. */
static int park_child(int kind, int rfd, volatile int *shared, volatile int *eintr)
{
	char c = 0;
	int r;

	switch (kind) {
	case PK_READ:
		r = read(rfd, &c, 1);
		return !(r == 1 && c == 'r');
	case PK_POLL: {
		struct pollfd pf = { rfd, POLLIN, 0 };

		r = poll(&pf, 1, 20000);
		return !(r == 1 && (pf.revents & POLLIN) && read(rfd, &c, 1) == 1 && c == 'p');
	}
	case PK_SLEEP: {
		struct timespec ts = { 0, 600000000 };	/* 0.6 s, across many cycles */
		double t = mono();

		r = nanosleep(&ts, NULL);
		t = mono() - t;
		return !(r == 0 && t >= 0.6);
	}
	case PK_FUTEX:
		while (!*shared) {
			r = syscall(SYS_futex, shared, FUTEX_WAIT, 0, NULL, NULL, 0);
			if (r < 0 && errno != EAGAIN)
				return 1;	/* EINTR would be a bug: FUTEX_WAIT restarts */
		}
		return 0;
	case PK_EPOLL: {
		struct epoll_event ev = { .events = EPOLLIN }, out;
		int ep = epoll_create1(0);

		epoll_ctl(ep, EPOLL_CTL_ADD, rfd, &ev);
		for (;;) {
			r = epoll_wait(ep, &out, 1, -1);
			if (r < 0 && errno == EINTR) {
				(*eintr)++;
				continue;
			}
			return !(r == 1 && read(rfd, &c, 1) == 1 && c == 'e');
		}
	}
	case PK_HOT: {
		int bad = 0, runs = 0;

		while (!*shared || runs < 2) {
			bad += hot(HOT_SEED) != HOT_EXPECT;
			runs++;
		}
		return bad != 0;
	}
	}
	return 1;
}

static void park_checks(void)
{
	struct park_info p = { 0 }, first;
	int fds[PK_N][2], st[PK_N], bad_cycles = 0, ok_children = 0, i, n = 0;
	unsigned long long us_sum = 0, us_max = 0;
	volatile int *shared;
	pid_t pid[PK_N];
	char wake[PK_N] = { 'r', 'p', 0, 0, 'e', 0 };

	if (park_read(&first)) {
		struct utsname u;

		/* An SMP kernel has no parking (kernel.md, Parking). */
		if (!uname(&u) && strstr(u.version, " SMP "))
			CHECK(1, "park: skipped (SMP kernel: no parking)");
		else
			CHECK(0, "park: no /proc/kwpark");
		return;
	}
	shared = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
	shared[0] = 0;	/* futex word and hot()'s stop flag */
	shared[1] = 0;	/* epoll_wait EINTRs */
	for (i = 0; i < PK_N; i++) {
		pipe(fds[i]);
		pid[i] = fork();
		if (pid[i] == 0)
			_exit(park_child(i, fds[i][0], &shared[0], &shared[1]));
	}

	/* Let them block (or start computing), then park and resume 20 times. */
	usleep(50000);
	for (i = 0; i < 20; i++) {
		if (park_cycle(&p) || p.result) {
			if (!bad_cycles++)
				printf("     park cycle %d: result %d, blocker %s\n", i, p.result, p.blocker);
			continue;
		}
		n++;
		us_sum += p.us;
		if (p.us > us_max)
			us_max = p.us;
	}

	shared[0] = 1;
	syscall(SYS_futex, &shared[0], FUTEX_WAKE, 1, NULL, NULL, 0);
	for (i = 0; i < PK_N; i++)
		if (wake[i])
			write(fds[i][1], &wake[i], 1);
	for (i = 0; i < PK_N; i++) {
		waitpid(pid[i], &st[i], 0);
		ok_children += WIFEXITED(st[i]) && !WEXITSTATUS(st[i]);
		if (!(WIFEXITED(st[i]) && !WEXITSTATUS(st[i])))
			printf("     park: %s child: status %#x\n", park_names[i], st[i]);
		close(fds[i][0]);
		close(fds[i][1]);
	}
	CHECK(!bad_cycles && ok_children == PK_N && p.users >= PK_N + 1 && p.kthreads > 0,
	      "park: %d/20 cycles (%u user tasks, %u kernel threads, %llu us mean, %llu us max); "
	      "read, poll, nanosleep, futex restarted, epoll_wait EINTR %d times, hot() in user mode: %d/%d children ok",
	      n, p.users, p.kthreads, n ? us_sum / n : 0, us_max, shared[1], ok_children, PK_N);
	munmap((void *)shared, 4096);
}

/*
 * SMP (more than one CPU online): threads on several CPUs hammer shared
 * counters through AMOs (amoadd), LR/SC (a compare-and-swap loop) and a
 * pthread mutex (LR/SC plus futex wait and wake across CPUs); every
 * increment must count, and the threads must have run on more than one
 * CPU (tasks stay on the CPU they first ran on).
 */
#define SMP_THREADS 3
#define SMP_ITERS 300000
static struct {
	unsigned amo, lrsc, locked;
	pthread_mutex_t lock;
	volatile int go;
} smp_shared = { .lock = PTHREAD_MUTEX_INITIALIZER };

static void *smp_worker(void *arg)
{
	unsigned long cpus = 0;
	unsigned cpu;
	int i;

	while (!smp_shared.go)
		;
	for (i = 0; i < SMP_ITERS; i++) {
		unsigned old = __atomic_load_n(&smp_shared.lrsc, __ATOMIC_RELAXED);

		__atomic_fetch_add(&smp_shared.amo, 1, __ATOMIC_RELAXED);
		while (!__atomic_compare_exchange_n(&smp_shared.lrsc, &old, old + 1, 1,
						    __ATOMIC_ACQ_REL, __ATOMIC_RELAXED))
			;
		if (!(i & 15)) {
			pthread_mutex_lock(&smp_shared.lock);
			smp_shared.locked++;
			pthread_mutex_unlock(&smp_shared.lock);
		}
		if (!(i & 4095) && !syscall(SYS_getcpu, &cpu, NULL, NULL) && cpu < 64)
			cpus |= 1UL << cpu;
	}
	return (void *)cpus;
}

static void smp_checks(void)
{
	long online = sysconf(_SC_NPROCESSORS_ONLN);
	unsigned long cpus = 0;
	pthread_t th[SMP_THREADS];
	int i, made = 0;
	void *r;

	if (online < 2) {
		printf("ok   smp: one CPU online (skipped)\n");
		return;
	}
	/* This thread works too: new threads go to the least busy CPU. */
	for (i = 1; i < SMP_THREADS; i++)
		made += !pthread_create(&th[i], NULL, smp_worker, NULL);
	smp_shared.go = 1;
	cpus = (unsigned long)smp_worker(NULL);
	made++;
	for (i = 1; i < SMP_THREADS; i++)
		if (!pthread_join(th[i], &r))
			cpus |= (unsigned long)r;
	CHECK(made == SMP_THREADS && smp_shared.amo == SMP_THREADS * SMP_ITERS &&
	      smp_shared.lrsc == SMP_THREADS * SMP_ITERS &&
	      smp_shared.locked == SMP_THREADS * (SMP_ITERS / 16) && __builtin_popcountl(cpus) >= 2,
	      "smp: %ld CPUs; %d threads on CPUs %#lx: amoadd %u, lr/sc %u, mutex %u (want %u, %u, %u)",
	      online, made, cpus, smp_shared.amo, smp_shared.lrsc, smp_shared.locked,
	      SMP_THREADS * SMP_ITERS, SMP_THREADS * SMP_ITERS, SMP_THREADS * (SMP_ITERS / 16));
}

/*
 * Moving tasks (SMP, more than one CPU online): a user task moves to
 * another CPU where it is switched out on its way to user mode, and starts
 * there on a fresh kernel stack (kernel.md, SMP). Its registers, FP state
 * (rounding mode, flags) and TLS must survive, as must signals and
 * wakeups; busy threads started on one CPU must spread; affinity changes
 * must take effect, for the caller itself, a busy thread and one asleep
 * in a system call.
 */
static long mv_now_ms(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1000L + t.tv_nsec / 1000000;
}

static int mv_cpu(void)
{
	unsigned cpu = 999;

	return syscall(SYS_getcpu, &cpu, NULL, NULL) ? -1 : (int)cpu;
}

static int mv_setaff(pid_t tid, unsigned long mask)
{
	return syscall(SYS_sched_setaffinity, tid, sizeof(mask), &mask) ? -errno : 0;
}

static unsigned long mv_getaff(pid_t tid)
{
	unsigned long mask = 0;

	return syscall(SYS_sched_getaffinity, tid, sizeof(mask), &mask) < 0 ? 0 : mask;
}

/* The CPU a thread is on (or last ran on): /proc/self/task/TID/stat field 39. */
static int mv_task_cpu(pid_t tid)
{
	char path[64], buf[512], *p;
	int fd, n, field = 2;

	snprintf(path, sizeof(path), "/proc/self/task/%d/stat", tid);
	fd = open(path, O_RDONLY);
	if (fd < 0)
		return -1;
	n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0)
		return -1;
	buf[n] = 0;
	p = strrchr(buf, ')');
	if (!p)
		return -1;
	for (p++; *p && field < 39; p++)
		if (*p == ' ')
			field++;
	return field == 39 ? atoi(p) : -1;
}

struct mv_stats {
	unsigned long released, resumed, moved, restarted, dropped, lost, hinted, followed;
};

static int mv_stats_read(struct mv_stats *s)
{
	FILE *f = fopen("/proc/kwmove", "r");
	int n;

	if (!f)
		return -1;
	s->hinted = s->followed = 0;
	n = fscanf(f, "released %lu resumed %lu moved %lu restarted %lu dropped %lu lost %lu hinted %lu followed %lu",
		   &s->released, &s->resumed, &s->moved, &s->restarted, &s->dropped, &s->lost,
		   &s->hinted, &s->followed);
	fclose(f);
	return n >= 6 ? 0 : -1;
}

static struct {
	unsigned long all;	/* the online CPUs */
	long online;
	volatile int go;
	volatile long deadline, midpoint;
} mv;

/* Threads started on CPU 0 widen their affinity and spin: they must spread. */
struct mv_spread {
	pthread_t th;
	unsigned long seen;
	int last, moves, bad, rounds;
};

static void *mv_spread_fn(void *arg)
{
	struct mv_spread *s = arg;
	int prev = 0;	/* they start on CPU 0 */

	s->last = -1;
	while (!mv.go)
		;
	if (mv_setaff(0, mv.all))
		s->bad++;
	while (mv_now_ms() < mv.deadline) {
		int c;

		s->bad += fphot(HOT_SEED) != FPHOT_EXPECT;
		c = mv_cpu();
		if (c >= 0 && c < 64)
			s->seen |= 1UL << c;
		if (c != prev)
			s->moves++;
		/* Where it is at the midpoint, while all of them still run. */
		if (s->last < 0 && mv_now_ms() >= mv.midpoint)
			s->last = c;
		prev = c;
		s->rounds++;
	}
	return NULL;
}

static void mv_spread_check(void)
{
	int n = mv.online * 2 > 8 ? 8 : mv.online * 2, i, made = 0, bad = 0, moves = 0, rounds = 0;
	unsigned long seen = 0, last = 0;
	struct mv_spread s[8];
	char per[64] = "", *q = per;
	int count[8] = { 0 };

	memset(s, 0, sizeof(s));
	mv.go = 0;
	/* All start on CPU 0 (they inherit this thread's affinity). */
	if (mv_setaff(0, 1) || mv_cpu() != 0)
		bad++;
	for (i = 0; i < n; i++)
		made += !pthread_create(&s[i].th, NULL, mv_spread_fn, &s[i]);
	mv_setaff(0, mv.all);
	mv.midpoint = mv_now_ms() + 1200;
	mv.deadline = mv.midpoint + 800;
	mv.go = 1;
	for (i = 0; i < n; i++) {
		pthread_join(s[i].th, NULL);
		seen |= s[i].seen;
		if (s[i].last >= 0 && s[i].last < 8) {
			last |= 1UL << s[i].last;
			count[s[i].last]++;
		}
		bad += s[i].bad;
		moves += s[i].moves;
		rounds += s[i].rounds;
	}
	for (i = 0; i < mv.online && i < 8; i++)
		q += snprintf(q, per + sizeof(per) - q, "%s%d", i ? "/" : "", count[i]);
	CHECK(made == n && !bad && seen == mv.all && last == mv.all && moves > 0,
	      "move: spread: %d threads started on CPU 0 ran on CPUs %#lx, %s per CPU after 1.2 s, %d CPU changes in %d fphot rounds (%d bad)",
	      made, seen, per, moves, rounds, bad);
}

/*
 * This thread moves itself round the CPUs (sched_setaffinity, which takes
 * effect on the way back to user mode) between steps of a computation kept
 * in registers, in FE_UPWARD with FE_DIVBYZERO raised; the result must
 * match the same computation without moves.
 */
#define MV_BOUNCES 300

static int mv_bounce(int moves, unsigned long *hp, double *dp, int *tlsp, int *missp)
{
	unsigned long h = 0xcbf29ce484222325UL;
	volatile double zero = 0.0;
	double d = 1.0, f = 3.0;
	int i, miss = 0, fpbad = 0;
	int *addr = &tls_var;

	tls_var = 0;
	feclearexcept(FE_ALL_EXCEPT);
	fesetround(FE_UPWARD);
	f = f / zero;	/* FE_DIVBYZERO, sticky */
	for (i = 0; i < MV_BOUNCES; i++) {
		if (moves) {
			int t = i % mv.online;

			if (mv_setaff(0, 1UL << t) || mv_cpu() != t)
				miss++;
		}
		d = d * 1.0000001 + i * 0.3;
		h = (h ^ (unsigned long)(long)(d * 16.0)) * 0x100000001b3UL + (unsigned long)i;
		tls_var += i;
		if (fegetround() != FE_UPWARD || !fetestexcept(FE_DIVBYZERO))
			fpbad++;
	}
	fesetround(FE_TONEAREST);
	feclearexcept(FE_ALL_EXCEPT);
	mv_setaff(0, mv.all);
	*hp = h;
	*dp = d;
	*tlsp = tls_var;
	*missp = miss;
	return fpbad + (addr != &tls_var) + (f < 0);
}

static void mv_bounce_check(void)
{
	unsigned long h0, h1;
	double d0, d1;
	int t0, t1, m0, m1, bad;

	bad = mv_bounce(0, &h0, &d0, &t0, &m0);
	bad += mv_bounce(1, &h1, &d1, &t1, &m1);
	CHECK(!bad && !m1 && h0 == h1 && !memcmp(&d0, &d1, sizeof(d0)) && t0 == t1,
	      "move: %d self-moves round %ld CPUs: %d missed, registers, FP state and TLS %s (h %#lx/%#lx)",
	      MV_BOUNCES, mv.online, m1, !bad && h0 == h1 && !memcmp(&d0, &d1, sizeof(d0)) && t0 == t1 ? "kept" : "BAD",
	      h0, h1);
}

/* Another thread's affinity: a busy one moves within its slice, a sleeping one when it wakes. */
static struct {
	volatile pid_t tid;
	volatile int stop, cpu_after;
	int pipe[2];
} mv_t;

static void *mv_busy_fn(void *arg)
{
	(void)arg;
	mv_t.tid = syscall(SYS_gettid);
	while (!mv_t.stop) {
		volatile unsigned long x = 0;

		for (int i = 0; i < 2000000 && !mv_t.stop; i++)
			x += i;
	}
	return NULL;
}

static void *mv_sleep_fn(void *arg)
{
	char c;

	(void)arg;
	mv_t.tid = syscall(SYS_gettid);
	read(mv_t.pipe[0], &c, 1);
	mv_t.cpu_after = mv_cpu();
	return NULL;
}

static void mv_other_check(void)
{
	pthread_t th;
	long worst = 0, set_worst = 0, t0, t;
	int i, moved = 0, err = 0, target = 0, cpu;
	unsigned long aff;

	mv_t.tid = 0;
	mv_t.stop = 0;
	if (pthread_create(&th, NULL, mv_busy_fn, NULL))
		err++;
	while (!err && !mv_t.tid)
		;
	for (i = 0; i < 6 && !err; i++) {
		cpu = mv_task_cpu(mv_t.tid);
		target = (cpu + 1) % mv.online;
		t0 = mv_now_ms();
		err += mv_setaff(mv_t.tid, 1UL << target) != 0;
		t = mv_now_ms() - t0;
		set_worst = t > set_worst ? t : set_worst;
		while (mv_task_cpu(mv_t.tid) != target && mv_now_ms() - t0 < 2000)
			usleep(1000);
		t = mv_now_ms() - t0;
		worst = t > worst ? t : worst;
		moved += mv_task_cpu(mv_t.tid) == target;
	}
	mv_t.stop = 1;
	pthread_join(th, NULL);
	CHECK(!err && moved == 6 && set_worst < 100 && worst < 1000,
	      "move: sched_setaffinity on a busy thread: %d/6 moved, call took <= %ld ms, move <= %ld ms",
	      moved, set_worst, worst);

	/* Asleep in read(): the call returns at once, the move happens at the wakeup. */
	mv_t.tid = 0;
	mv_t.cpu_after = -1;
	err = pipe(mv_t.pipe) != 0;
	if (!err && pthread_create(&th, NULL, mv_sleep_fn, NULL))
		err++;
	while (!err && !mv_t.tid)
		;
	usleep(50000);
	cpu = err ? 0 : mv_task_cpu(mv_t.tid);
	target = (cpu + 1) % mv.online;
	t0 = mv_now_ms();
	if (!err)
		err += mv_setaff(mv_t.tid, 1UL << target) != 0;
	t = mv_now_ms() - t0;
	aff = err ? 0 : mv_getaff(mv_t.tid);
	if (!err) {
		write(mv_t.pipe[1], "x", 1);
		pthread_join(th, NULL);
		close(mv_t.pipe[0]);
		close(mv_t.pipe[1]);
	}
	CHECK(!err && t < 100 && aff == 1UL << target && mv_t.cpu_after == target,
	      "move: sched_setaffinity on a thread asleep in read() on CPU %d: returned in %ld ms, mask %#lx, woke on CPU %d (want %d)",
	      cpu, t, aff, mv_t.cpu_after, target);
}

/* Queued RT signals to a thread that keeps moving: none lost, none twice. */
#define MV_SIGS 2000
static volatile unsigned long mv_sig_count, mv_sig_sum;

static void mv_on_rt(int sig, siginfo_t *si, void *uc)
{
	(void)sig;
	(void)uc;
	mv_sig_count++;
	mv_sig_sum += (unsigned long)si->si_value.sival_int;
}

static void *mv_sig_fn(void *arg)
{
	unsigned long i = 0;

	(void)arg;
	mv_t.tid = syscall(SYS_gettid);
	while (!mv_t.stop) {
		volatile unsigned long x = 0;

		mv_setaff(0, 1UL << (i++ % mv.online));
		for (int k = 0; k < 20000; k++)
			x += k;
	}
	mv_setaff(0, mv.all);
	return NULL;
}

static void mv_signal_check(void)
{
	struct sigaction sa = { .sa_sigaction = mv_on_rt, .sa_flags = SA_SIGINFO | SA_RESTART };
	pthread_t th;
	int i, err = 0, retries = 0;
	long t0;

	sigemptyset(&sa.sa_mask);
	sigaction(SIGRTMIN, &sa, NULL);
	mv_sig_count = mv_sig_sum = 0;
	mv_t.tid = 0;
	mv_t.stop = 0;
	if (pthread_create(&th, NULL, mv_sig_fn, NULL))
		err++;
	while (!err && !mv_t.tid)
		;
	for (i = 0; i < MV_SIGS && !err; i++) {
		siginfo_t si;

		memset(&si, 0, sizeof(si));
		si.si_signo = SIGRTMIN;
		si.si_code = SI_QUEUE;
		si.si_pid = getpid();
		si.si_uid = getuid();
		si.si_value.sival_int = i;
		while (syscall(SYS_rt_tgsigqueueinfo, getpid(), mv_t.tid, SIGRTMIN, &si)) {
			if (errno != EAGAIN || ++retries > 100000) {
				err++;
				break;
			}
			usleep(200);
		}
	}
	t0 = mv_now_ms();
	while (mv_sig_count < MV_SIGS && mv_now_ms() - t0 < 5000)
		usleep(1000);
	usleep(50000);
	mv_t.stop = 1;
	pthread_join(th, NULL);
	signal(SIGRTMIN, SIG_DFL);
	CHECK(!err && mv_sig_count == MV_SIGS && mv_sig_sum == (unsigned long)MV_SIGS * (MV_SIGS - 1) / 2,
	      "move: %d queued signals to a thread moving between CPUs: %lu delivered, sum %lu (want %lu)",
	      MV_SIGS, mv_sig_count, mv_sig_sum, (unsigned long)MV_SIGS * (MV_SIGS - 1) / 2);
}

/* Pipe and futex ping-pong between two threads that keep moving. */
#define MV_PP 5000
static struct {
	int ab[2], ba[2];
	volatile int word;
	int bad[2];
} mv_pp;

static void mv_pp_move(unsigned *seed)
{
	*seed = *seed * 1103515245 + 12345;
	mv_setaff(0, 1UL << ((*seed >> 16) % mv.online));
}

static void *mv_pp_fn(void *arg)
{
	int side = (int)(long)arg, i, v;
	unsigned seed = 7 + side;

	/* Pipes: side 0 sends i, side 1 answers i + 1. */
	for (i = 0; i < MV_PP; i++) {
		if (side == 0) {
			if (write(mv_pp.ab[1], &i, 4) != 4 || read(mv_pp.ba[0], &v, 4) != 4 || v != i + 1)
				mv_pp.bad[side]++;
		} else {
			if (read(mv_pp.ab[0], &v, 4) != 4 || v != i || (v = i + 1, write(mv_pp.ba[1], &v, 4) != 4))
				mv_pp.bad[side]++;
		}
		if (i % (31 + 6 * side) == 0)
			mv_pp_move(&seed);
	}
	/* Futex: the word says whose turn it is. */
	for (i = 0; i < MV_PP; i++) {
		while (__atomic_load_n(&mv_pp.word, __ATOMIC_ACQUIRE) != side)
			syscall(SYS_futex, &mv_pp.word, FUTEX_WAIT_PRIVATE, !side, NULL, NULL, 0);
		__atomic_store_n(&mv_pp.word, !side, __ATOMIC_RELEASE);
		syscall(SYS_futex, &mv_pp.word, FUTEX_WAKE_PRIVATE, 1, NULL, NULL, 0);
		if (i % (29 + 8 * side) == 0)
			mv_pp_move(&seed);
	}
	mv_setaff(0, mv.all);
	return NULL;
}

static void mv_pingpong_check(void)
{
	pthread_t th[2];
	int made = 0;
	long t0 = mv_now_ms();

	memset(&mv_pp, 0, sizeof(mv_pp));
	if (pipe(mv_pp.ab) || pipe(mv_pp.ba)) {
		CHECK(0, "move: ping-pong: no pipes");
		return;
	}
	made += !pthread_create(&th[0], NULL, mv_pp_fn, (void *)0L);
	made += !pthread_create(&th[1], NULL, mv_pp_fn, (void *)1L);
	if (made == 2) {
		pthread_join(th[0], NULL);
		pthread_join(th[1], NULL);
	}
	close(mv_pp.ab[0]);
	close(mv_pp.ab[1]);
	close(mv_pp.ba[0]);
	close(mv_pp.ba[1]);
	CHECK(made == 2 && !mv_pp.bad[0] && !mv_pp.bad[1] && mv_pp.word == 0,
	      "move: %d pipe and %d futex round trips between threads that keep moving: %d/%d bad, %ld ms",
	      MV_PP, MV_PP, mv_pp.bad[0], mv_pp.bad[1], mv_now_ms() - t0);
}

/*
 * Placement of held tasks (kernel.md, SMP). A thread asleep in read() on
 * CPU 0, which a busy thread pinned there keeps busy, is woken from CPU 1
 * again and again: it must leave CPU 0 on one of its ways back to user
 * mode (to the waker's CPU, which is about to sleep, or an idle one) and
 * stay away, and every read() must return its byte as usual (no EINTR, no
 * short read). Before, it woke on CPU 0 every time while CPU 1 idled.
 */
#define MV_WAKES 60
static struct {
	int p1[2], p2[2];
	volatile int stop;
	volatile pid_t tid;
	int cpu[MV_WAKES], bad;
} mv_w;

static void *mv_wake_hog(void *arg)
{
	(void)arg;
	if (mv_setaff(0, 1))
		mv_w.bad++;
	while (!mv_w.stop) {
		volatile unsigned long x = 0;

		for (int i = 0; i < 20000; i++)
			x += i;
	}
	return NULL;
}

static void *mv_wake_sleeper(void *arg)
{
	int i, v;

	(void)arg;
	mv_w.tid = syscall(SYS_gettid);
	for (i = 0; i < MV_WAKES; i++) {
		if (read(mv_w.p1[0], &v, sizeof(v)) != sizeof(v) || v != i)
			mv_w.bad++;
		mv_w.cpu[i] = mv_cpu();
		if (write(mv_w.p2[1], &v, sizeof(v)) != sizeof(v))
			mv_w.bad++;
	}
	return NULL;
}

static void mv_wake_check(void)
{
	struct mv_stats a, b;
	pthread_t hog, sl;
	int i, err = 0, left = -1, away = 0;

	memset(&mv_w, 0, sizeof(mv_w));
	if (pipe(mv_w.p1) || pipe(mv_w.p2)) {
		CHECK(0, "move: wakeup on a busy CPU: no pipes");
		return;
	}
	mv_stats_read(&a);
	err += mv_setaff(0, 1) != 0;	/* the sleeper starts on CPU 0 */
	err += pthread_create(&hog, NULL, mv_wake_hog, NULL) != 0;
	err += pthread_create(&sl, NULL, mv_wake_sleeper, NULL) != 0;
	while (!err && !mv_w.tid)
		usleep(1000);
	usleep(50000);
	if (!err)
		err += mv_setaff(mv_w.tid, mv.all) != 0;	/* asleep: held on CPU 0 */
	err += mv_setaff(0, 2) != 0;	/* the waker on CPU 1 */
	for (i = 0; i < MV_WAKES && !err; i++) {
		int v;

		if (write(mv_w.p1[1], &i, sizeof(i)) != sizeof(i) || read(mv_w.p2[0], &v, sizeof(v)) != sizeof(v)) {
			err++;
			break;
		}
		usleep(2000);
	}
	mv_w.stop = 1;
	pthread_join(hog, NULL);
	if (!err)
		pthread_join(sl, NULL);
	mv_setaff(0, mv.all);
	mv_stats_read(&b);
	for (i = MV_WAKES - 1; i >= 0 && mv_w.cpu[i] != 0; i--)
		;
	left = i + 1;	/* the first wakeup from which it stayed away */
	for (i = 0; i < MV_WAKES; i++)
		away += mv_w.cpu[i] != 0;
	close(mv_w.p1[0]);
	close(mv_w.p1[1]);
	close(mv_w.p2[0]);
	close(mv_w.p2[1]);
	CHECK(!err && !mv_w.bad && left <= MV_WAKES - 20,
	      "move: a thread woken in read() on a CPU a busy thread keeps: away from it from wakeup %d of %d on (%d away, %d bad), %lu better CPUs named, %lu taken",
	      left + 1, MV_WAKES, away, mv_w.bad, b.hinted - a.hinted, b.followed - a.followed);
}

/*
 * A child execs beside a busy thread pinned to CPU 0 while other CPUs idle:
 * the new image must start elsewhere (the move happens on execve()'s way
 * to user mode; the exec'd kwtest exits with its CPU).
 */
static void mv_exec_check(void)
{
	pthread_t hog;
	int i, err = 0, away = 0, n = 5;
	char cpus[16] = "";

	mv_w.stop = 0;
	mv_w.bad = 0;
	err += mv_setaff(0, 1) != 0;
	err += pthread_create(&hog, NULL, mv_wake_hog, NULL) != 0;
	usleep(20000);
	for (i = 0; i < n && !err; i++) {
		int status = 0;
		pid_t pid = fork();

		if (pid == 0) {
			mv_setaff(0, mv.all);
			execl("/proc/self/exe", "kwtest", "cpu", (char *)NULL);
			_exit(99);
		}
		if (pid < 0 || waitpid(pid, &status, 0) != pid || !WIFEXITED(status)) {
			err++;
			break;
		}
		cpus[i] = '0' + (WEXITSTATUS(status) < 10 ? WEXITSTATUS(status) : 0);
		away += WEXITSTATUS(status) > 0 && WEXITSTATUS(status) < 64;
	}
	mv_w.stop = 1;
	if (!err || i)
		pthread_join(hog, NULL);
	mv_setaff(0, mv.all);
	CHECK(!err && !mv_w.bad && away >= n - 1,
	      "move: exec beside a busy thread on CPU 0: %d of %d new images started on another CPU (%s)",
	      away, n, cpus);
}

/*
 * A system call interrupted by a SA_RESTART signal (-ERESTARTSYS) while an
 * affinity change moves the task to another CPU: kw_exit_to_user_move()
 * switches out before arch_do_signal_or_restart(), and kw_user_resume() on
 * the new CPU (sched_stay_switch_tail(), which keeps TIF_SIGPENDING) must
 * deliver the signal there and restart the system call without EINTR.
 */
#define MV_RESTARTS 20
static struct {
	int p[2], ack[2];
	volatile pid_t tid;
	volatile int sigs, sig_cpu, read_cpu, bad;
} mv_rs;

static void mv_on_restart_sig(int sig)
{
	(void)sig;
	mv_rs.sig_cpu = mv_cpu();
	__atomic_fetch_add(&mv_rs.sigs, 1, __ATOMIC_RELEASE);
}

static void *mv_restart_fn(void *arg)
{
	int i;

	(void)arg;
	mv_rs.tid = syscall(SYS_gettid);
	for (i = 0; i < MV_RESTARTS; i++) {
		char c = 0;
		ssize_t n;

		if (write(mv_rs.ack[1], "r", 1) != 1) {
			mv_rs.bad++;
			break;
		}
		n = read(mv_rs.p[0], &c, 1);
		mv_rs.read_cpu = mv_cpu();
		if (n != 1 || c != (char)('a' + (i % 26)))
			mv_rs.bad++;
		if (write(mv_rs.ack[1], "d", 1) != 1) {
			mv_rs.bad++;
			break;
		}
	}
	return NULL;
}

static void mv_restart_check(void)
{
	struct sigaction sa = { .sa_handler = mv_on_restart_sig, .sa_flags = SA_RESTART }, old;
	pthread_t th;
	int i, err = 0, moved = 0;

	memset(&mv_rs, 0, sizeof(mv_rs));
	if (pipe(mv_rs.p) || pipe(mv_rs.ack)) {
		CHECK(0, "move: SA_RESTART across CPU move: no pipes");
		return;
	}
	sigemptyset(&sa.sa_mask);
	sigaction(SIGUSR1, &sa, &old);
	if (pthread_create(&th, NULL, mv_restart_fn, NULL))
		err++;
	while (!err && !mv_rs.tid)
		usleep(1000);
	for (i = 0; i < MV_RESTARTS && !err; i++) {
		char tag = 0, byte = (char)('a' + (i % 26));
		int cpu, target, s0;
		long t0;

		if (read(mv_rs.ack[0], &tag, 1) != 1 || tag != 'r') {
			err++;
			break;
		}
		/* Wait until it is asleep in read(). */
		usleep(2000);
		cpu = mv_task_cpu(mv_rs.tid);
		target = (cpu + 1) % mv.online;
		s0 = __atomic_load_n(&mv_rs.sigs, __ATOMIC_ACQUIRE);
		mv_rs.sig_cpu = -1;
		mv_rs.read_cpu = -1;
		/* Queue the move while held in read(), then wake it with SIGUSR1. */
		if (mv_setaff(mv_rs.tid, 1UL << target) ||
		    syscall(SYS_tgkill, getpid(), mv_rs.tid, SIGUSR1)) {
			err++;
			break;
		}
		t0 = mv_now_ms();
		while (__atomic_load_n(&mv_rs.sigs, __ATOMIC_ACQUIRE) == s0 && mv_now_ms() - t0 < 2000)
			usleep(500);
		if (__atomic_load_n(&mv_rs.sigs, __ATOMIC_ACQUIRE) != s0 + 1) {
			err++;
			break;
		}
		if (write(mv_rs.p[1], &byte, 1) != 1 ||
		    read(mv_rs.ack[0], &tag, 1) != 1 || tag != 'd') {
			err++;
			break;
		}
		moved += mv_rs.sig_cpu == target && mv_rs.read_cpu == target;
	}
	if (!err)
		pthread_join(th, NULL);
	sigaction(SIGUSR1, &old, NULL);
	close(mv_rs.p[0]);
	close(mv_rs.p[1]);
	close(mv_rs.ack[0]);
	close(mv_rs.ack[1]);
	CHECK(!err && !mv_rs.bad && mv_rs.sigs == MV_RESTARTS && moved == MV_RESTARTS,
	      "move: %d SA_RESTART signals waking read() into a CPU move: %d signals, %d restarted on the new CPU, %d bad",
	      MV_RESTARTS, mv_rs.sigs, moved, mv_rs.bad);
}

/*
 * SMP boundary checks: a held kthread (kthreadd, PID 2) refuses an affinity
 * mask that excludes its CPU with EBUSY; and flipping kw_spin_unfair
 * between 0 (ticket locks) and 1 (steal wait) while threads on every CPU
 * contend on a kernel spinlock (files->file_lock in dup/close) works.
 */
static volatile int mv_spin_stop, mv_spin_bad;

static void *mv_spin_fn(void *arg)
{
	int cpu = (int)(long)arg;

	mv_setaff(0, 1UL << (cpu % mv.online));
	while (!__atomic_load_n(&mv_spin_stop, __ATOMIC_RELAXED)) {
		int fd = dup(0);

		if (fd < 0 || close(fd))
			__atomic_fetch_add(&mv_spin_bad, 1, __ATOMIC_RELAXED);
	}
	return NULL;
}

static void mv_edge_check(void)
{
	int kt_cpu = -1, kt_err = 0, pfd, flips = 0, i, n = mv.online > 8 ? 8 : mv.online, made = 0;
	char stat_buf[512], *p, orig = 'Y';
	pthread_t th[8];

	/* PID 2 is kthreadd, held on the CPU it started on (CPU 0). */
	pfd = open("/proc/2/stat", O_RDONLY);
	if (pfd >= 0) {
		int r = read(pfd, stat_buf, sizeof(stat_buf) - 1), field = 2;

		close(pfd);
		stat_buf[r > 0 ? r : 0] = 0;
		p = strrchr(stat_buf, ')');
		for (p = p ? p + 1 : NULL; p && *p && field < 39; p++)
			if (*p == ' ')
				field++;
		if (p && field == 39)
			kt_cpu = atoi(p);
	}
	if (kt_cpu >= 0 && kt_cpu < mv.online)
		kt_err = -mv_setaff(2, 1UL << ((kt_cpu + 1) % mv.online));

	mkdir("/sys", 0555);
	mount("sysfs", "/sys", "sysfs", 0, NULL);
	mv_spin_stop = 0;
	mv_spin_bad = 0;
	for (i = 0; i < n; i++)
		made += !pthread_create(&th[i], NULL, mv_spin_fn, (void *)(long)i);
	pfd = open("/sys/module/kernel/parameters/kw_spin_unfair", O_RDWR);
	if (pfd >= 0) {
		if (pread(pfd, &orig, 1, 0) != 1)
			orig = 'Y';
		for (i = 0; i < 10; i++) {
			const char *v = (i & 1) ? "1\n" : "0\n";

			if (pwrite(pfd, v, 2, 0) == 2)
				flips++;
			usleep(2000);
		}
		pwrite(pfd, orig == 'N' ? "0\n" : "1\n", 2, 0);
		close(pfd);
	}
	__atomic_store_n(&mv_spin_stop, 1, __ATOMIC_RELEASE);
	for (i = 0; i < made; i++)
		pthread_join(th[i], NULL);
	CHECK(kt_err == EBUSY && made == n && flips == 10 && !mv_spin_bad,
	      "move: held kthread affinity: %s (CPU %d); kw_spin_unfair flipped %d times under %d-CPU spinlock contention: %d bad",
	      kt_err ? strerror(kt_err) : "allowed?", kt_cpu, flips, made, mv_spin_bad);
}

static void move_checks(void)
{
	struct mv_stats a, b;

	mv.online = sysconf(_SC_NPROCESSORS_ONLN);
	if (mv.online < 2) {
		printf("ok   move: one CPU online (skipped)\n");
		return;
	}
	if (mv.online > 63)
		mv.online = 63;
	mv.all = (1UL << mv.online) - 1;
	if (mv_stats_read(&a)) {
		CHECK(0, "move: no /proc/kwmove");
		return;
	}
	mv_spread_check();
	mv_bounce_check();
	mv_other_check();
	mv_signal_check();
	mv_pingpong_check();
	mv_wake_check();
	mv_exec_check();
	mv_restart_check();
	mv_edge_check();
	mv_setaff(0, mv.all);
	if (mv_stats_read(&b)) {
		CHECK(0, "move: no /proc/kwmove");
		return;
	}
	CHECK(b.moved > a.moved && b.lost == a.lost,
	      "move: /proc/kwmove during these checks: released %lu, resumed in place %lu, moved %lu, kthreads restarted %lu, stacks dropped %lu, lost %lu",
	      b.released - a.released, b.resumed - a.resumed, b.moved - a.moved,
	      b.restarted - a.restarted, b.dropped - a.dropped, b.lost - a.lost);
}

/*
 * The JIT on SMP (more than one CPU online; kwemu.md, Several harts): each
 * CPU's kwemu compiles what it runs hot into its own code, so these run
 * compiled loops on several CPUs at once:
 *  - hot() and fphot() on every CPU, each thread pinned, while the main
 *    thread signals each of them every millisecond (the handler changes
 *    the rounding mode and raises DZ, which sigreturn must undo): exact
 *    results, and every thread took signals;
 *  - plain byte and halfword stores next to AMOs and LR/SC in one cache
 *    line, from loops that get compiled: no store may be lost;
 *  - a thread in hot() and fphot() moved round the CPUs every 4 ms;
 *  - code that one hart rewrites while another runs it compiled: after
 *    the writer's __builtin___clear_cache() (riscv_flush_icache) the
 *    runner never runs the old version again; a page replaced by
 *    mremap() likewise (the unmap flushes); code made non-executable by
 *    mprotect() faults.
 */
#define JS_MAXT 8
#define JS_ITERS 200000

static _Thread_local volatile int js_sigs;

static void js_on_usr2(int sig)
{
	volatile double z = 0.0, d;

	(void)sig;
	fesetround(FE_TOWARDZERO);
	d = 1.0 / z;	/* DZ: must not leak into the interrupted code */
	(void)d;
	js_sigs++;
}

struct js_hot {
	pthread_t th;
	int cpu, sigs, bad, runs;
	volatile int done;
};

static void *js_hot_fn(void *arg)
{
	struct js_hot *h = arg;

	if (mv_setaff(0, 1UL << h->cpu) || mv_cpu() != h->cpu)
		h->bad++;
	for (int r = 0; r < 3; r++) {
		h->bad += hot(HOT_SEED) != HOT_EXPECT;
		h->bad += fphot(HOT_SEED) != FPHOT_EXPECT;
		h->runs++;
	}
	h->sigs = js_sigs;
	h->done = 1;
	return NULL;
}

static void js_hot_check(void)
{
	int n = mv.online > JS_MAXT ? JS_MAXT : mv.online, i, made = 0, bad = 0, runs = 0, minsigs = 1 << 30, left;
	struct js_hot h[JS_MAXT];
	struct sigaction sa = { .sa_handler = js_on_usr2 };
	long t0 = mv_now_ms();

	memset(h, 0, sizeof(h));
	sigaction(SIGUSR2, &sa, NULL);
	for (i = 0; i < n; i++) {
		h[i].cpu = i;
		made += !pthread_create(&h[i].th, NULL, js_hot_fn, &h[i]);
	}
	do {
		left = 0;
		for (i = 0; i < n; i++)
			if (!h[i].done) {
				pthread_kill(h[i].th, SIGUSR2);
				left++;
			}
		usleep(1000);
	} while (left && made == n);
	for (i = 0; i < n; i++) {
		pthread_join(h[i].th, NULL);
		bad += h[i].bad;
		runs += h[i].runs;
		if (h[i].sigs < minsigs)
			minsigs = h[i].sigs;
	}
	signal(SIGUSR2, SIG_DFL);
	CHECK(made == n && !bad && runs == 3 * n && minsigs >= 3,
	      "jit: hot() and fphot() on %d CPUs at once, 3 times each: %d bad; at least %d signals per thread, %ld ms",
	      n, bad, minsigs, mv_now_ms() - t0);
}

static struct {
	_Alignas(64) volatile uint8_t b[8];
	volatile uint16_t h[4];
	unsigned long amo, lrsc;
	volatile int go;
} js_line;

static void *js_store_fn(void *arg)
{
	int i = (int)(long)arg;
	unsigned long cpus = 0;

	mv_setaff(0, 1UL << (i % mv.online));
	while (!js_line.go)
		;
	for (int k = 0; k < JS_ITERS; k++) {
		js_line.b[i]++;
		js_line.h[i] += 3;
		__atomic_fetch_add(&js_line.amo, 1, __ATOMIC_RELAXED);
		if (!(k & 3)) {
			unsigned long o = __atomic_load_n(&js_line.lrsc, __ATOMIC_RELAXED);

			while (!__atomic_compare_exchange_n(&js_line.lrsc, &o, o + 1, 1, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED))
				;
		}
		if (!(k & 8191)) {
			int c = mv_cpu();

			if (c >= 0 && c < 64)
				cpus |= 1UL << c;
		}
	}
	return (void *)cpus;
}

static void js_store_check(void)
{
	pthread_t th[4];
	int i, made = 0, bad = 0;
	unsigned long cpus = 0;
	void *r;

	memset((void *)&js_line, 0, sizeof(js_line));
	for (i = 0; i < 4; i++)
		made += !pthread_create(&th[i], NULL, js_store_fn, (void *)(long)i);
	js_line.go = 1;
	for (i = 0; i < 4; i++)
		if (!pthread_join(th[i], &r))
			cpus |= (unsigned long)r;
	for (i = 0; i < 4; i++)
		bad += js_line.b[i] != (uint8_t)JS_ITERS || js_line.h[i] != (uint16_t)(3 * JS_ITERS);
	CHECK(made == 4 && !bad && js_line.amo == 4UL * JS_ITERS && js_line.lrsc == JS_ITERS &&
	      cpus == (mv.online < 4 ? mv.all : 15UL),
	      "jit: byte and halfword stores beside AMOs and LR/SC in one line, 4 threads on CPUs %#lx: %d wrong, amoadd %lu, lr/sc %lu (want %lu, %d)",
	      cpus, bad, js_line.amo, js_line.lrsc, 4UL * JS_ITERS, JS_ITERS);
}

struct js_mig {
	volatile int stop;
	volatile pid_t tid;
	int bad, rounds, moves;
	unsigned long seen;
};

static void *js_mig_fn(void *arg)
{
	struct js_mig *s = arg;
	int prev;

	s->tid = syscall(SYS_gettid);
	prev = mv_cpu();
	while (!s->stop) {
		int c;

		s->bad += hot(HOT_SEED) != HOT_EXPECT;
		s->bad += fphot(HOT_SEED) != FPHOT_EXPECT;
		s->rounds++;
		c = mv_cpu();
		if (c >= 0 && c < 64)
			s->seen |= 1UL << c;
		s->moves += c != prev;
		prev = c;
	}
	return NULL;
}

static void js_mig_check(void)
{
	struct js_mig s;
	struct mv_stats a, b;
	pthread_t th;
	long end;
	int k = 0, made;

	memset(&s, 0, sizeof(s));
	if (mv_stats_read(&a)) {
		CHECK(0, "jit: no /proc/kwmove");
		return;
	}
	made = !pthread_create(&th, NULL, js_mig_fn, &s);
	while (made && !s.tid)
		usleep(1000);
	end = mv_now_ms() + 1500;
	while (made && (mv_now_ms() < end || s.rounds < 6)) {
		mv_setaff(s.tid, 1UL << (k++ % mv.online));
		usleep(4000);
	}
	s.stop = 1;
	if (made)
		pthread_join(th, NULL);
	if (mv_stats_read(&b))
		b = a;
	CHECK(made && !s.bad && s.rounds >= 6 && __builtin_popcountl(s.seen) >= 2 && b.moved - a.moved >= 20,
	      "jit: hot() and fphot() %d times in a thread moved %d times (CPUs %#lx; %lu moves in /proc/kwmove): %d bad",
	      s.rounds, k, s.seen, b.moved - a.moved, s.bad);
}

/* f(a0, a1): a1 passes of a0 += v, then return a0 (a self-loop, then ret). */
static void js_gen(uint32_t *p, int v)
{
	p[0] = 0x00050513u | ((uint32_t)v << 20);	/* addi a0, a0, v */
	p[1] = 0xfff58593u;				/* addi a1, a1, -1 */
	p[2] = 0xfe059ce3u;				/* bne a1, zero, -8 */
	p[3] = 0x00008067u;				/* ret */
}

#define JS_PASSES 64

static struct {
	uint32_t *volatile fn;
	unsigned long published, calls, faults, noexec_faults, ran_noexec, stale, wrong;
	/* odd while the code is not executable */
	unsigned long noexec_seq;
	int stop;
} jx;
static sigjmp_buf js_segv_jmp;

static void js_on_segv(int sig)
{
	(void)sig;
	siglongjmp(js_segv_jmp, 1);
}

/* The runner (CPU 1): calls the current code, checks the version it ran. */
static void *js_run_fn(void *arg)
{
	(void)arg;
	mv_setaff(0, 2);
	while (!__atomic_load_n(&jx.stop, __ATOMIC_ACQUIRE)) {
		unsigned long p0 = __atomic_load_n(&jx.published, __ATOMIC_ACQUIRE), r, p1;
		unsigned long s0 = __atomic_load_n(&jx.noexec_seq, __ATOMIC_ACQUIRE);

		if (sigsetjmp(js_segv_jmp, 1)) {
			__atomic_fetch_add(&jx.faults, 1, __ATOMIC_RELEASE);
			if (s0 & 1)
				__atomic_fetch_add(&jx.noexec_faults, 1, __ATOMIC_RELEASE);
			continue;
		}
		r = ((unsigned long (*)(unsigned long, unsigned long))jx.fn)(0, JS_PASSES);
		p1 = __atomic_load_n(&jx.published, __ATOMIC_ACQUIRE);
		/* The whole call fell into a time the code was not executable. */
		if ((s0 & 1) && __atomic_load_n(&jx.noexec_seq, __ATOMIC_ACQUIRE) == s0)
			jx.ran_noexec++;
		/* Every pass ran a version from p0 to the one being written. */
		if (r < JS_PASSES * p0)
			jx.stale++;
		else if (r > JS_PASSES * (p1 + 1))
			jx.wrong++;
		__atomic_fetch_add(&jx.calls, 1, __ATOMIC_RELEASE);
	}
	return NULL;
}

/* Wait until the runner made `n` more calls (its code gets compiled); 0 on a timeout. */
static int js_wait_calls(unsigned long n)
{
	unsigned long c0 = __atomic_load_n(&jx.calls, __ATOMIC_ACQUIRE);
	long end = mv_now_ms() + 5000;

	while (__atomic_load_n(&jx.calls, __ATOMIC_ACQUIRE) - c0 < n)
		if (mv_now_ms() > end)
			return 0;
	return 1;
}

static void js_smc_check(void)
{
	const int rewrites = 300, remaps = 40, noexecs = 10;
	struct sigaction sa = { .sa_handler = js_on_segv, .sa_flags = SA_NODEFER };
	int i, ok = 1, done_rw = 0, done_rm = 0, done_ne = 0;
	unsigned long v = 1;
	uint32_t *page;
	pthread_t th;
	long t0 = mv_now_ms();

	memset(&jx, 0, sizeof(jx));
	page = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (page == MAP_FAILED) {
		CHECK(0, "jit: cross-hart code changes: no RWX page");
		return;
	}
	js_gen(page, v);
	__builtin___clear_cache((char *)page, (char *)(page + 4));
	jx.fn = page;
	jx.published = v;
	sigaction(SIGSEGV, &sa, NULL);
	mv_setaff(0, 1);
	if (pthread_create(&th, NULL, js_run_fn, NULL)) {
		CHECK(0, "jit: cross-hart code changes: no thread");
		return;
	}
	/* In place: one aligned store of the new addi, then the flush. */
	for (i = 0; i < rewrites && ok; i++, done_rw++) {
		ok = js_wait_calls(2500);
		v++;
		__atomic_store_n(&page[0], 0x00050513u | ((uint32_t)v << 20), __ATOMIC_RELAXED);
		__builtin___clear_cache((char *)page, (char *)(page + 4));
		__atomic_store_n(&jx.published, v, __ATOMIC_RELEASE);
	}
	/* A new page at the same address (mremap moves a prepared one over it). */
	for (i = 0; i < remaps && ok; i++, done_rm++) {
		uint32_t *q = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);

		ok = js_wait_calls(2500) && q != MAP_FAILED;
		if (!ok)
			break;
		js_gen(q, ++v);
		/* MREMAP_MAYMOVE | MREMAP_FIXED (mremap() needs _GNU_SOURCE) */
		if ((void *)syscall(SYS_mremap, q, 4096, 4096, 1 | 2, page) != page) {
			ok = 0;
			break;
		}
		__atomic_store_n(&jx.published, v, __ATOMIC_RELEASE);
	}
	/* Not executable any more: the runner must fault (and then run again). */
	for (i = 0; i < noexecs && ok; i++, done_ne++) {
		unsigned long f0;
		long end;

		ok = js_wait_calls(2500);
		mprotect(page, 4096, PROT_READ | PROT_WRITE);
		f0 = __atomic_load_n(&jx.noexec_faults, __ATOMIC_ACQUIRE);
		__atomic_fetch_add(&jx.noexec_seq, 1, __ATOMIC_RELEASE);
		end = mv_now_ms() + 5000;
		while (__atomic_load_n(&jx.noexec_faults, __ATOMIC_ACQUIRE) - f0 < 3 && ok)
			ok = mv_now_ms() < end;
		__atomic_fetch_add(&jx.noexec_seq, 1, __ATOMIC_RELEASE);
		mprotect(page, 4096, PROT_READ | PROT_WRITE | PROT_EXEC);
	}
	__atomic_store_n(&jx.stop, 1, __ATOMIC_RELEASE);
	pthread_join(th, NULL);
	signal(SIGSEGV, SIG_DFL);
	mv_setaff(0, mv.all);
	munmap(page, 4096);
	CHECK(ok && !jx.stale && !jx.wrong && !jx.ran_noexec && done_rw == rewrites && done_rm == remaps && done_ne == noexecs,
	      "jit: code run on CPU 1, changed on CPU 0: %d rewrites + flush, %d mremaps, %d mprotects to no-exec; "
	      "%lu calls: %lu stale, %lu wrong, %lu ran while not executable, %lu faults; %ld ms",
	      done_rw, done_rm, done_ne, jx.calls, jx.stale, jx.wrong, jx.ran_noexec, jx.faults, mv_now_ms() - t0);
}

/*
 * Lazy-TLB shootdown deferral (arch/wasm/mm/tlb.c, kw_tlb_lazy /
 * kw_tlb_stale): this thread fills CPU 1's kwemu read, write and exec TLBs
 * (including compiled code), then moves to CPU 0 so CPU 1 idles in lazy TLB
 * mode with the mm still loaded. On CPU 0, mremap() replaces the data and
 * code pages and mprotect() makes a second data page read-only (marking
 * CPU 1 stale instead of waiting for an IPI). Moving back to CPU 1 must
 * flush CPU 1's TLBs in switch_mm(): it sees the new data and code and
 * faults on a write to the read-only page.
 */
static void do_write_u64(void *p)
{
	*(volatile uint64_t *)p = 0xdeadbeefUL;
}

static void js_lazy_tlb_check(void)
{
	uint64_t *d1 = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	uint64_t *d2 = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	uint32_t *code = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	int i, rounds = 10, bad = 0;

	if (d1 == MAP_FAILED || d2 == MAP_FAILED || code == MAP_FAILED) {
		CHECK(0, "jit: lazy-TLB flush: mmap failed");
		return;
	}
	for (i = 1; i <= rounds; i++) {
		uint64_t *nd;
		uint32_t *nc;
		unsigned long r;

		/* Fill CPU 1's read, write and exec TLBs, and compile code there. */
		if (mv_setaff(0, 2) || mv_cpu() != 1) {
			bad++;
			break;
		}
		*d1 = 0x11110000UL | (unsigned long)i;
		*d2 = 0x22220000UL | (unsigned long)i;
		js_gen(code, i);
		__builtin___clear_cache((char *)code, (char *)(code + 4));
		r = 0;
		for (int k = 0; k < 2500; k++)
			r = ((unsigned long (*)(unsigned long, unsigned long))code)(0, JS_PASSES);
		if (*d1 != (0x11110000UL | (unsigned long)i) || *d2 != (0x22220000UL | (unsigned long)i) ||
		    r != (unsigned long)JS_PASSES * (unsigned long)i)
			bad++;

		/* Move to CPU 0: CPU 1 enters lazy TLB mode (idle). */
		if (mv_setaff(0, 1) || mv_cpu() != 0) {
			bad++;
			break;
		}
		nd = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		nc = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (nd == MAP_FAILED || nc == MAP_FAILED) {
			bad++;
			break;
		}
		*nd = 0x99990000UL | (unsigned long)i;
		js_gen(nc, i + 20);
		if ((void *)syscall(SYS_mremap, nd, 4096, 4096, 1 | 2, d1) != d1 ||
		    (void *)syscall(SYS_mremap, nc, 4096, 4096, 1 | 2, code) != code ||
		    mprotect(d2, 4096, PROT_READ)) {
			bad++;
			break;
		}

		/* Back to CPU 1: switch_mm() must flush its stale TLBs and code. */
		if (mv_setaff(0, 2) || mv_cpu() != 1) {
			bad++;
			break;
		}
		r = ((unsigned long (*)(unsigned long, unsigned long))code)(0, JS_PASSES);
		if (*d1 != (0x99990000UL | (unsigned long)i) ||
		    r != (unsigned long)JS_PASSES * (unsigned long)(i + 20) ||
		    catch_sig(do_write_u64, d2) != SIGSEGV ||
		    *d2 != (0x22220000UL | (unsigned long)i))
			bad++;
		mprotect(d2, 4096, PROT_READ | PROT_WRITE);
	}
	mv_setaff(0, mv.all);
	munmap(d1, 4096);
	munmap(d2, 4096);
	munmap(code, 4096);
	CHECK(!bad && i == rounds + 1,
	      "jit: lazy-TLB flush across idle CPU 1 (%d rounds of mremap data + compiled code + mprotect RO on CPU 0): %d bad",
	      rounds, bad);
}

static void jit_smp_checks(void)
{
	mv.online = sysconf(_SC_NPROCESSORS_ONLN);
	if (mv.online < 2) {
		printf("ok   jit: one CPU online (SMP checks skipped)\n");
		return;
	}
	if (mv.online > 63)
		mv.online = 63;
	mv.all = (1UL << mv.online) - 1;
	js_hot_check();
	js_store_check();
	js_mig_check();
	js_smc_check();
	js_lazy_tlb_check();
	mv_setaff(0, mv.all);
}
#endif /* __riscv */

static void *hot_thread(void *arg)
{
	return (void *)hot((unsigned long)arg);
}

int main(int argc, char **argv)
{
	struct utsname u;
	const char msg[] = "hello from riscv64 user mode via write()\n";

	if (argc > 1 && !strcmp(argv[1], "child"))
		return 7;	/* exec'd by the execve test */
	if (argc > 1 && !strcmp(argv[1], "cpu")) {
		unsigned cpu = 99;

		syscall(SYS_getcpu, &cpu, NULL, NULL);
		return cpu;	/* exec'd by the move: exec check */
	}
	if (argc > 1 && !strcmp(argv[1], "hot")) {
		printf("%#lx\n", hot(HOT_SEED));	/* HOT_EXPECT, see hot() */
		return 0;
	}
	if (argc > 1 && !strcmp(argv[1], "fphot")) {
		printf("%#lx\n", fphot(HOT_SEED));	/* FPHOT_EXPECT, see fphot() */
		return 0;
	}
#ifdef __riscv
	/* Only the SMP checks (`rdinit=/usr/bin/kwtest -- smp` repeats them faster). */
	if (argc > 1 && !strcmp(argv[1], "smp")) {
		mount("proc", "/proc", "proc", 0, NULL);
		uaccess_checks();
		fb_checks();
		smp_checks();
		move_checks();
		jit_smp_checks();
		goto done;
	}
#endif

	write(1, msg, sizeof(msg) - 1);

	uname(&u);
	CHECK(!strcmp(u.machine, "riscv64"), "uname: %s %s %s", u.sysname, u.release, u.machine);
	CHECK(getpid() == 1 || getppid() > 0, "getpid = %d", getpid());
#ifdef __riscv
	isa_checks();
#endif

	/* brk/malloc and anonymous mmap */
	char *big = malloc(1 << 20);
	memset(big, 0x5a, 1 << 20);
	CHECK(big[12345] == 0x5a, "malloc 1 MiB");
	char *m = mmap(NULL, 3 * 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	CHECK(m != MAP_FAILED && m[4096] == 0, "mmap anon");
	strcpy(m + 4096, "cow");

	/* fork + COW + wait */
	int pipefd[2];
	pipe(pipefd);
	pid_t pid = fork();
	if (pid == 0) {
		strcpy(m + 4096, "child");
		write(pipefd[1], m + 4096, 6);
		_exit(42);
	}
	int status = 0;
	char buf[16] = { 0 };
	read(pipefd[0], buf, sizeof(buf));
	waitpid(pid, &status, 0);
	CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 42, "fork/wait status %d", WEXITSTATUS(status));
	CHECK(!strcmp(buf, "child") && !strcmp(m + 4096, "cow"), "pipe '%s', COW kept parent '%s'", buf, m + 4096);

	/* signals */
	signal(SIGUSR1, on_usr1);
	kill(getpid(), SIGUSR1);
	CHECK(got_signal == SIGUSR1, "signal handler + sigreturn");

	/* floating point survives a signal */
	volatile double d = 1.5;
	kill(getpid(), SIGUSR1);
	d = d * 3.0;
	CHECK(d == 4.5, "fp %.2f", d);

	/* mprotect + SIGSEGV in a child */
	pid = fork();
	if (pid == 0) {
		mprotect(m, 4096, PROT_READ);
		m[0] = 1;
		_exit(0);
	}
	waitpid(pid, &status, 0);
	CHECK(WIFSIGNALED(status) && WTERMSIG(status) == SIGSEGV, "SIGSEGV on write to read-only page");

	/* threads: clone(CLONE_SETTLS | CLONE_CHILD_CLEARTID) argument order */
	pthread_t th;
	void *thr = NULL;
	tls_var = 1;
	int prc = pthread_create(&th, NULL, thread_fn, NULL);
	CHECK(prc == 0 && pthread_join(th, &thr) == 0 && thr == (void *)th && tls_var == 1,
	      "pthread: create/join, pthread_self and TLS in the thread");

	/* exec */
	pid = fork();
	if (pid == 0) {
		char *av[] = { argv[0], "child", NULL };
		execvp(argv[0], av);
		_exit(99);
	}
	waitpid(pid, &status, 0);
	CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 7, "execve child exited %d", WEXITSTATUS(status));

	/*
	 * JIT tier: hot() in this process, in a thread and in a forked child
	 * (COW), while a 1 ms SIGALRM timer interrupts the compiled loops. Runs
	 * until at least 3 signals arrived.
	 */
	struct itimerval it = { { 0, 1000 }, { 0, 1000 } }, off = { 0 };
	pthread_t ht;
	void *hres = NULL;
	int runs = 0, bad = 0;

	signal(SIGALRM, on_alarm);
	setitimer(ITIMER_REAL, &it, NULL);
	prc = pthread_create(&ht, NULL, hot_thread, (void *)HOT_SEED);
	pid = fork();
	if (pid == 0)
		_exit(hot(HOT_SEED) == HOT_EXPECT ? 0 : 1);
	do {
		bad += hot(HOT_SEED) != HOT_EXPECT;
		runs++;
	} while ((alarms < 3 || runs < 2) && runs < 200);
	if (prc == 0)
		pthread_join(ht, &hres);
	waitpid(pid, &status, 0);
	setitimer(ITIMER_REAL, &off, NULL);
	CHECK(!bad && prc == 0 && (unsigned long)hres == HOT_EXPECT && WIFEXITED(status) && !WEXITSTATUS(status) && alarms >= 3,
	      "hot loops (JIT): %d runs, %d bad; thread %s, child %s; %d SIGALRMs", runs, bad,
	      (unsigned long)hres == HOT_EXPECT ? "ok" : "BAD", WIFEXITED(status) && !WEXITSTATUS(status) ? "ok" : "BAD", alarms);

	/* JIT tier, F/D: the FP hot loop twice (the second run is compiled) */
	unsigned long fp1 = fphot(HOT_SEED), fp2 = fphot(HOT_SEED);
	CHECK(fp1 == FPHOT_EXPECT && fp2 == FPHOT_EXPECT, "FP hot loop (JIT): %#lx %#lx, want %#lx", fp1, fp2, FPHOT_EXPECT);

#ifdef __riscv
	config_checks();
	net_config_checks();
	uaccess_checks();
	input_handler_checks();
	vsock_checks();
	ninep_checks();
	shm_checks();
	fb_checks();
	park_checks();
	smp_checks();
	move_checks();
	jit_smp_checks();
#endif

done:
	printf("kwtest: %d failure(s)\n", failures);
	fflush(stdout);
	if (getpid() == 1) {
		sync();
		reboot(failures ? RB_HALT_SYSTEM : RB_POWER_OFF);
	}
	return failures != 0;
}

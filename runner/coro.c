/* SPDX-License-Identifier: Apache-2.0 */
/*
 * Coroutine CPU (NCE) and thread (NCT) emulation for the native simulator, replacing its
 * nce.c and nct.c. Those run the CPU and every Zephyr thread on their own host thread, and
 * hand control between them with semaphores. Here they are coroutines on the caller's host
 * thread. A context switch (coro_switch) is, by default, a jump, inline. For comparison,
 * define instead:
 *   CORO_UCONTEXT     swapcontext(), which also saves and restores the signal mask: a system
 *                     call on each switch.
 *   CORO_SIGLONGJMP   siglongjmp(), not saving the signal mask; makecontext() and setcontext()
 *                     start each coroutine. (Note: POSIX does not define jumps to other stacks,
 *                     but C libraries allow them, and e.g.QEMU's coroutines do the same.)
 * By default they share the host thread's errno, floating-point environment and C++ exception
 * state. Define CORO_SAVE_CONTEXT to give each coroutine its own, as each host thread has.
 *
 * Each instance links a private copy, and native_sim has one CPU: the state is static.
 */
#define _GNU_SOURCE
/* A fortified longjmp() (glibc's) refuses to jump to another stack. */
#undef _FORTIFY_SOURCE
#include <errno.h>
#include <fenv.h>
#include <setjmp.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <ucontext.h>
#include <unistd.h>
#include "nce_if.h"
#include "nct_if.h"
#include "nsi_tracing.h"

#define STACK_SIZE (8 << 20) /* As a pthread's. Reserved, committed only as used. */

#ifdef CORO_SAVE_CONTEXT
/* The C++ runtime's per-thread exception state, if a C++ runtime is linked. */
struct cxa_eh_globals {
	void *caught_exceptions;
	unsigned int uncaught_exceptions;
};
struct cxa_eh_globals *__cxa_get_globals(void) __attribute__((weak));

struct context {
	int err;
	/* Cosmopolitan 4.0.2 declares fenv_t as 8 bytes, but x86-64 fegetenv() stores 32. */
	union {
		fenv_t env;
		unsigned char storage[64];
	} fenv;
	struct cxa_eh_globals eh;
};
#endif

struct coro {
#if defined(CORO_UCONTEXT)
	ucontext_t context;
#elif defined(CORO_SIGLONGJMP)
	sigjmp_buf env;
	ucontext_t start; /* How a new coroutine starts, */
	bool fresh;       /* until switched to once */
#else
	/* Where it resumes, while switched out: stack, code and frame pointers */
	void *sp, *pc, *fp;
#endif
	char *stack;
	void (*entry)(void *arg);
	void *arg;
#ifdef CORO_SAVE_CONTEXT
	struct context context;
#endif
};

/* Switch from one coroutine to another: from now resumes when switched to. */
#if defined(CORO_UCONTEXT)
static void coro_switch(struct coro *from, struct coro *to)
{
	/* Not checked: Cosmopolitan 4.0.2 returns a stale value on x86-64 when resumed. */
	swapcontext(&from->context, &to->context);
}
#elif defined(CORO_SIGLONGJMP)
static void coro_switch(struct coro *from, struct coro *to)
{
	if (sigsetjmp(from->env, 0) == 0) {
		if (to->fresh) {
			to->fresh = false;
			setcontext(&to->start);
		}
		siglongjmp(to->env, 1);
	}
}
#else
/*
 * Save where `from` resumes, at the end of this code, and jump to where `to` resumes. It is
 * inline, not a call, and declares every other register clobbered: the compiler saves only
 * those whose values it needs, around the switch only. Registers that Cosmopolitan's ABI
 * reserves (AArch64 x18, and x28, its TLS pointer) are the same on every coroutine of this
 * thread, and untouched.
 */
_Static_assert(offsetof(struct coro, sp) == 0 && offsetof(struct coro, pc) == 8 &&
	       offsetof(struct coro, fp) == 16, "coro_switch expects sp, pc, fp first");

static inline __attribute__((always_inline)) void coro_switch(struct coro *from, struct coro *to)
{
#if defined(__x86_64__)
	register struct coro *from_ __asm__("rdi") = from;
	register struct coro *to_ __asm__("rsi") = to;

	__asm__ volatile("leaq 1f(%%rip), %%rax\n\t"
			 "movq %%rsp, 0(%0)\n\t"
			 "movq %%rax, 8(%0)\n\t"
			 "movq %%rbp, 16(%0)\n\t"
			 "movq 0(%1), %%rsp\n\t"
			 "movq 16(%1), %%rbp\n\t"
			 "jmpq *8(%1)\n"
			 "1:"
			 : "+r"(from_), "+r"(to_)
			 :
			 : "rax", "rbx", "rcx", "rdx", "r8", "r9", "r10", "r11", "r12", "r13", "r14",
			   "r15", "xmm0", "xmm1", "xmm2", "xmm3", "xmm4", "xmm5", "xmm6", "xmm7",
			   "xmm8", "xmm9", "xmm10", "xmm11", "xmm12", "xmm13", "xmm14", "xmm15",
#ifdef __AVX512F__
			   "xmm16", "xmm17", "xmm18", "xmm19", "xmm20", "xmm21", "xmm22", "xmm23",
			   "xmm24", "xmm25", "xmm26", "xmm27", "xmm28", "xmm29", "xmm30", "xmm31",
			   "k1", "k2", "k3", "k4", "k5", "k6", "k7",
#endif
			   "st", "st(1)", "st(2)", "st(3)", "st(4)", "st(5)", "st(6)", "st(7)",
			   "cc", "memory");
#elif defined(__aarch64__)
	register struct coro *from_ __asm__("x0") = from;
	register struct coro *to_ __asm__("x1") = to;

	__asm__ volatile("adr x9, 1f\n\t"
			 "mov x10, sp\n\t"
			 "stp x10, x9, [%0]\n\t"
			 "str x29, [%0, #16]\n\t"
			 "ldp x10, x9, [%1]\n\t"
			 "ldr x29, [%1, #16]\n\t"
			 "mov sp, x10\n\t"
			 "br x9\n"
			 "1:"
			 : "+r"(from_), "+r"(to_)
			 :
			 : "x2", "x3", "x4", "x5", "x6", "x7", "x8", "x9", "x10", "x11", "x12", "x13",
			   "x14", "x15", "x16", "x17", "x19", "x20", "x21", "x22", "x23", "x24", "x25",
			   "x26", "x27", "x30", "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8",
			   "v9", "v10", "v11", "v12", "v13", "v14", "v15", "v16", "v17", "v18", "v19",
			   "v20", "v21", "v22", "v23", "v24", "v25", "v26", "v27", "v28", "v29", "v30",
			   "v31", "cc", "memory");
#else
#error "coro_switch: unsupported CPU"
#endif
}
#endif

static struct coro host, *current = &host;
static struct coro *zombie; /* Aborted while running: freed once switched away from */

static void coro_free(struct coro *c)
{
	munmap(c->stack, STACK_SIZE);
	free(c);
}

static void save_context(struct coro *c)
{
#ifdef CORO_SAVE_CONTEXT
	c->context.err = errno;
	fegetenv(&c->context.fenv.env);
	if (__cxa_get_globals != NULL) {
		c->context.eh = *__cxa_get_globals();
	}
#endif
}

/* Runs on the coroutine just switched to: free a zombie, restore the thread state. */
static void resume(void)
{
	if (zombie != NULL) {
		coro_free(zombie);
		zombie = NULL;
	}
#ifdef CORO_SAVE_CONTEXT
	if (__cxa_get_globals != NULL) {
		*__cxa_get_globals() = current->context.eh;
	}
	fesetenv(&current->context.fenv.env);
	errno = current->context.err;
#endif
}

static void switch_to(struct coro *to)
{
	struct coro *from = current;

	save_context(from);
	current = to;
	coro_switch(from, to);
	resume();
}

/* Where a new coroutine starts (it never returns) */
static __attribute__((noreturn)) void start(void)
{
	resume();
	current->entry(current->arg);
	nsi_print_error_and_exit("%s: coroutine returned\n", __func__);
}

static struct coro *coro_new(void (*entry)(void *arg), void *arg)
{
	struct coro *c = malloc(sizeof(*c));

	if (c == NULL) {
		nsi_print_error_and_exit("%s: out of memory\n", __func__);
	}
	c->stack = mmap(NULL, STACK_SIZE, PROT_READ | PROT_WRITE,
			MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
	if (c->stack == MAP_FAILED || mprotect(c->stack, sysconf(_SC_PAGESIZE), PROT_NONE)) {
		nsi_print_error_and_exit("%s: cannot allocate a stack\n", __func__);
	}
#if defined(CORO_UCONTEXT) || defined(CORO_SIGLONGJMP)
#ifdef CORO_UCONTEXT
	ucontext_t *context = &c->context;
#else
	ucontext_t *context = &c->start;
	c->fresh = true;
#endif
	if (getcontext(context) != 0) {
		nsi_print_error_and_exit("%s: getcontext failed\n", __func__);
	}
	context->uc_link = NULL;
	context->uc_stack.ss_sp = c->stack;
	context->uc_stack.ss_size = STACK_SIZE;
	context->uc_stack.ss_flags = 0;
	makecontext(context, start, 0);
#else
	c->sp = (void *)((uintptr_t)(c->stack + STACK_SIZE) & -16);
#if defined(__x86_64__)
	c->sp = (char *)c->sp - 8; /* The return address slot of a call */
#endif
	c->pc = (void *)start;
	c->fp = NULL;
#endif
	c->entry = entry;
	c->arg = arg;
	save_context(c); /* Inherit the creator's, as a new thread does */
	return c;
}

/* NCE: the CPU halts by returning to whoever woke it, the hardware models. */

static struct coro *cpu;   /* Where the CPU resumes: its boot code, or where it halted */
static struct coro *waker; /* Where it returns to when it halts */
static bool running;
static void (*boot_routine)(void);

static void boot(void *arg)
{
	(void)arg;
	boot_routine();
}

void *nce_init(void)
{
	return &cpu;
}

void nce_boot_cpu(void *this, void (*start_routine)(void))
{
	boot_routine = start_routine;
	cpu = coro_new(boot, NULL);
	nce_wake_cpu(this);
}

void nce_wake_cpu(void *this)
{
	running = true;
	waker = current;
	switch_to(cpu);
}

void nce_halt_cpu(void *this)
{
	running = false;
	cpu = current;
	switch_to(waker);
}

int nce_is_cpu_running(void *this)
{
	return running;
}

void nce_terminate(void *this)
{
	/* Unlike threads, coroutines need no stopping before the process exits. */
}

/* NCT: each Zephyr thread is a coroutine, and swapping threads switches to it. */

static void (*thread_entry)(void *payload);
static struct coro **threads;
static int n_threads;

void *nct_init(void (*fptr)(void *))
{
	thread_entry = fptr;
	return &threads;
}

int nct_new_thread(void *this, void *payload)
{
	threads = realloc(threads, (n_threads + 1) * sizeof(*threads));
	if (threads == NULL) {
		nsi_print_error_and_exit("%s: out of memory\n", __func__);
	}
	threads[n_threads] = coro_new(thread_entry, payload);
	return n_threads++;
}

void nct_first_thread_start(void *this, int thread_idx)
{
	switch_to(threads[thread_idx]); /* The CPU's boot coroutine is never resumed. */
}

void nct_swap_threads(void *this, int thread_idx)
{
	if (threads[thread_idx] != current) {
		switch_to(threads[thread_idx]);
	}
}

void nct_abort_thread(void *this, int thread_idx)
{
	struct coro *thread = threads[thread_idx];

	threads[thread_idx] = NULL;
	if (thread == current) {
		zombie = thread;
	} else if (thread != NULL) {
		coro_free(thread);
	}
}

int nct_get_unique_thread_id(void *this, int thread_idx)
{
	return thread_idx;
}

int nct_thread_name_set(void *this, int thread_idx, const char *str)
{
	return 0;
}

void nct_get_thread_stack(void *this, int thread_idx, void **stack_addr,
			  unsigned long *stack_size)
{
	*stack_addr = threads[thread_idx]->stack;
	*stack_size = STACK_SIZE;
}

void nct_clean_up(void *this)
{
	/* The process exit releases the stacks. */
}

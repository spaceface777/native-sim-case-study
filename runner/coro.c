/* SPDX-License-Identifier: Apache-2.0 */
/*
 * Coroutine CPU (NCE) and thread (NCT) emulation for the native simulator, replacing its
 * nce.c and nct.c. Those run the CPU and every Zephyr thread on their own host thread, and
 * hand control between them with semaphores. Here they are coroutines on the caller's host
 * thread, so a context switch is a function call (coro.S). By default they share the host
 * thread's errno, floating-point environment and C++ exception state. Define
 * CORO_SAVE_CONTEXT to give each coroutine its own, as each host thread has.
 *
 * Each instance links a private copy, and native_sim has one CPU: the state is static.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fenv.h>
#include <stdbool.h>
#include <stdlib.h>
#include <sys/mman.h>
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
	void *sp; /* While switched out */
	char *stack;
	void (*entry)(void *arg);
	void *arg;
#ifdef CORO_SAVE_CONTEXT
	struct context context;
#endif
};

void *coro_init(void *stack_top, void (*start)(void));
void coro_switch(void **save_sp, void *sp);

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
	coro_switch(&from->sp, to->sp);
	resume();
}

static void start(void)
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
	c->sp = coro_init(c->stack + STACK_SIZE, start);
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

/*
 * Copyright (c) 2026 Quercus
 *
 * SPDX-License-Identifier: Apache-2.0
 */

/*
 * Stackful coroutine switch which only uses the host C library, and makes no
 * system call per switch:
 * makecontext() starts each coroutine on its stack, once. Every later switch is
 * a _setjmp()/_longjmp() pair, which, unlike swapcontext(), does not save and
 * restore the signal mask.
 *
 * Note that this is not a supported use of longjmp(): Neither ISO C nor POSIX
 * describe jumping to a frame on another stack. It depends on how the C library
 * implements jmp_buf. It is known to work with glibc, and it is the same
 * technique QEMU's ucontext coroutine backend uses.
 */

/*
 * glibc's fortified longjmp() refuses to jump to a frame on another stack
 * ("longjmp causes uninitialized stack frame"), so this file cannot be fortified.
 */
#undef _FORTIFY_SOURCE

#include <setjmp.h>
#include <stdint.h>
#include <stdlib.h>
#include <ucontext.h>
#include "nsi_coro.h"

struct continuation {
	sigjmp_buf env;
	struct continuation *from;
	ucontext_t *start; /* Not NULL until the coroutine has been started */
	nsi_coro_entry_f entry;
};

struct new_coroutine {
	struct continuation continuation;
	ucontext_t context;
};

static _Thread_local struct continuation *starting;

static void trampoline(void)
{
	struct continuation *self = starting;

	self->entry(self->from);
	abort();
}

nsi_coro_t nsi_coro_create(void *stack_top, nsi_coro_entry_f entry)
{
	struct new_coroutine *new = (void *)((char *)stack_top - NSI_CORO_STACK_SIZE);
	uintptr_t stack_bottom = ((uintptr_t)(new + 1) + 15U) & ~(uintptr_t)15U;

	if (getcontext(&new->context) != 0) {
		abort();
	}
	new->context.uc_link = NULL;
	new->context.uc_stack.ss_sp = (void *)stack_bottom;
	new->context.uc_stack.ss_size = (uintptr_t)stack_top - stack_bottom;
	new->context.uc_stack.ss_flags = 0;
	makecontext(&new->context, trampoline, 0);
	new->continuation.entry = entry;
	new->continuation.from = NULL;
	new->continuation.start = &new->context;
	return &new->continuation;
}

nsi_coro_t nsi_coro_switch(nsi_coro_t target)
{
	struct continuation self;
	struct continuation *to = target;

	self.start = NULL;
	to->from = &self;
	if (sigsetjmp(self.env, 0) == 0) {
		if (to->start != NULL) {
			ucontext_t *start = to->start;

			to->start = NULL;
			starting = to;
			setcontext(start);
			abort();
		}
		siglongjmp(to->env, 1);
	}
	return self.from;
}

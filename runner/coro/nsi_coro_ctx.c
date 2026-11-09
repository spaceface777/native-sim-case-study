/*
 * Copyright (c) 2026 Quercus
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <errno.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include "nsi_coro_ctx.h"
#include "nsi_tracing.h"

#ifdef NSI_CORO_ASAN
void __sanitizer_start_switch_fiber(void **fake_stack_save, const void *bottom, size_t size);
void __sanitizer_finish_switch_fiber(void *fake_stack_save, const void **bottom_old,
				     size_t *size_old);
#endif

struct cxa_eh_globals *__cxa_get_globals(void) __attribute__((weak));

static struct nsi_coro_ctx host_ctx;
static struct nsi_coro_ctx *current = &host_ctx;
static struct nsi_coro_ctx *previous;
static struct nsi_coro_ctx *deferred_ctx;
static void *deferred_allocation;
static pthread_t owner;
static bool owner_set;

static void check_owner(void)
{
	pthread_t self = pthread_self();

	if (!owner_set) {
		owner = self;
		owner_set = true;
	} else if (!pthread_equal(owner, self)) {
		nsi_print_error_and_exit("%s: coroutine context migrated between host threads\n",
					 __func__);
	}
}

void nsi_coro_ctx_reset(void)
{
	memset(&host_ctx, 0, sizeof(host_ctx));
	current = &host_ctx;
	previous = NULL;
	deferred_ctx = NULL;
	deferred_allocation = NULL;
	owner_set = false;
}

void nsi_coro_ctx_free(struct nsi_coro_ctx *ctx)
{
	if (ctx->map != NULL) {
		(void)munmap(ctx->map, ctx->map_size);
		ctx->map = NULL;
	}
}

static void after_switch(nsi_coro_t from)
{
#ifdef NSI_CORO_ASAN
	const void *bottom;
	size_t size;

	__sanitizer_finish_switch_fiber(current->asan_fake_stack, &bottom, &size);
	if (previous->asan_bottom == NULL) {
		previous->asan_bottom = bottom;
		previous->asan_size = size;
	}
#endif
	previous->continuation = from;
	if (deferred_ctx != NULL) {
		nsi_coro_ctx_free(deferred_ctx);
		free(deferred_allocation);
		deferred_ctx = NULL;
		deferred_allocation = NULL;
	}
	if (fesetenv(&current->fenv.env) != 0) {
		nsi_print_error_and_exit("%s: cannot restore floating point environment\n",
					 __func__);
	}
	if (__cxa_get_globals != NULL) {
		*__cxa_get_globals() = current->eh;
	}
	errno = current->err;
}

void nsi_coro_ctx_switch(struct nsi_coro_ctx *to, bool final)
{
	check_owner();
	if (to == current || to->continuation == NULL) {
		nsi_print_error_and_exit("%s: invalid coroutine context switch\n", __func__);
	}

	current->err = errno;
	if (__cxa_get_globals != NULL) {
		current->eh = *__cxa_get_globals();
	}
	if (fegetenv(&current->fenv.env) != 0) {
		nsi_print_error_and_exit("%s: cannot save floating point environment\n",
					 __func__);
	}

	previous = current;
	current = to;
#ifdef NSI_CORO_ASAN
	__sanitizer_start_switch_fiber(final ? NULL : &previous->asan_fake_stack,
				       to->asan_bottom, to->asan_size);
#else
	(void)final;
#endif
	after_switch(nsi_coro_switch(to->continuation));
}

static void trampoline(nsi_coro_t from)
{
	after_switch(from);
	current->entry(current->arg);
	nsi_print_error_and_exit("%s: embedded coroutine returned\n", __func__);
}

void nsi_coro_ctx_create(struct nsi_coro_ctx *ctx, void (*entry)(void *), void *arg)
{
	size_t page = (size_t)sysconf(_SC_PAGESIZE);

	ctx->map_size = NSI_CORO_STACK_SIZE + 2 * page;
	ctx->map = mmap(NULL, ctx->map_size, PROT_NONE,
			MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
	if ((ctx->map == MAP_FAILED) ||
	    (mprotect((char *)ctx->map + page, NSI_CORO_STACK_SIZE,
		      PROT_READ | PROT_WRITE) != 0)) {
		nsi_print_error_and_exit("%s: cannot allocate coroutine stack\n", __func__);
	}

	ctx->continuation = nsi_coro_create((char *)ctx->map + page + NSI_CORO_STACK_SIZE,
					    trampoline);
	ctx->err = 0;
	if (fegetenv(&ctx->fenv.env) != 0) {
		nsi_print_error_and_exit("%s: cannot read floating point environment\n",
					 __func__);
	}
	ctx->entry = entry;
	ctx->arg = arg;
#ifdef NSI_CORO_ASAN
	ctx->asan_fake_stack = NULL;
	ctx->asan_bottom = (char *)ctx->map + page;
	ctx->asan_size = NSI_CORO_STACK_SIZE;
#endif
}

void nsi_coro_ctx_stack(struct nsi_coro_ctx *ctx, void **addr, unsigned long *size)
{
	size_t page = (size_t)sysconf(_SC_PAGESIZE);

	*addr = (char *)ctx->map + page;
	*size = NSI_CORO_STACK_SIZE;
}

struct nsi_coro_ctx *nsi_coro_ctx_current(void)
{
	return current;
}

void nsi_coro_ctx_defer_free(struct nsi_coro_ctx *ctx, void *allocation)
{
	if (deferred_ctx != NULL) {
		nsi_print_error_and_exit("%s: coroutine context already pending release\n", __func__);
	}
	deferred_ctx = ctx;
	deferred_allocation = allocation;
}

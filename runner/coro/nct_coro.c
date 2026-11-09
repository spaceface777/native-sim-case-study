/*
 * Copyright (c) 2026 Quercus
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <stdbool.h>
#include <stdlib.h>
#include "nct_if.h"
#include "nsi_config.h"
#include "nsi_coro_ctx.h"
#include "nsi_tracing.h"

#define NCT_ALLOC_CHUNK_SIZE 64

struct nct;

struct nct_thread {
	struct nsi_coro_ctx ctx;
	struct nct *owner;
	void *payload;
	bool aborting;
};

struct nct {
	void (*fptr)(void *payload);
	struct nct_thread **threads;
	int n_threads;
	int allocated;
	int current;
};

static struct nct nct_instances[NSI_N_CPUS];
static int nct_next;

static struct nct_thread *nct_get(struct nct *this, int idx)
{
	if ((idx < 0) || (idx >= this->n_threads) || (this->threads[idx] == NULL)) {
		nsi_print_error_and_exit("%s: invalid thread index %i\n", __func__, idx);
	}
	return this->threads[idx];
}

static void nct_release(struct nct *this, int idx)
{
	struct nct_thread *thread = this->threads[idx];

	nsi_coro_ctx_free(&thread->ctx);
	free(thread);
	this->threads[idx] = NULL;
}

static void thread_entry(void *arg)
{
	struct nct_thread *thread = arg;

	thread->owner->fptr(thread->payload);
	nsi_print_error_and_exit("%s: embedded thread returned\n", __func__);
}

void *nct_init(void (*fptr)(void *))
{
	struct nct *this = &nct_instances[nct_next];

#ifdef NSI_NCE_BACKEND_PTHREADS
	/* With pthread NCE, the CPU pthread is the root of the coroutine domain. */
	nsi_coro_ctx_reset();
#endif
	nct_next = (nct_next + 1) % NSI_N_CPUS;
	*this = (struct nct){.fptr = fptr, .current = -1};
	return this;
}

int nct_new_thread(void *this_arg, void *payload)
{
	struct nct *this = this_arg;
	struct nct_thread *thread;
	int idx = this->n_threads;

	if (idx == this->allocated) {
		struct nct_thread **threads = realloc(this->threads,
			(this->allocated + NCT_ALLOC_CHUNK_SIZE) * sizeof(*threads));

		if (threads == NULL) {
			nsi_print_error_and_exit("%s: out of memory\n", __func__);
		}
		this->threads = threads;
		this->allocated += NCT_ALLOC_CHUNK_SIZE;
	}

	thread = calloc(1, sizeof(*thread));
	if (thread == NULL) {
		nsi_print_error_and_exit("%s: out of memory\n", __func__);
	}
	thread->owner = this;
	thread->payload = payload;
	nsi_coro_ctx_create(&thread->ctx, thread_entry, thread);
	this->threads[idx] = thread;
	this->n_threads++;
	return idx;
}

void nct_swap_threads(void *this_arg, int next_allowed_thread_nbr)
{
	struct nct *this = this_arg;
	struct nct_thread *next = nct_get(this, next_allowed_thread_nbr);
	int current_idx = this->current;

	if (next_allowed_thread_nbr == current_idx) {
		return;
	}
	this->current = next_allowed_thread_nbr;

	if ((current_idx >= 0) && this->threads[current_idx]->aborting) {
		struct nct_thread *current_thread = this->threads[current_idx];

		this->threads[current_idx] = NULL;
		nsi_coro_ctx_defer_free(&current_thread->ctx, current_thread);
		nsi_coro_ctx_switch(&next->ctx, true);
	} else {
		nsi_coro_ctx_switch(&next->ctx, false);
		this->current = current_idx;
	}
}

void nct_first_thread_start(void *this_arg, int next_allowed_thread_nbr)
{
	struct nct *this = this_arg;

#ifndef NSI_NCE_BACKEND_PTHREADS
	/* Coroutine NCE's boot context is abandoned after the first thread starts. */
	nsi_coro_ctx_defer_free(nsi_coro_ctx_current(), NULL);
#endif
	this->current = next_allowed_thread_nbr;
	nsi_coro_ctx_switch(&nct_get(this, next_allowed_thread_nbr)->ctx, true);
}

void nct_abort_thread(void *this_arg, int thread_idx)
{
	struct nct *this = this_arg;

	if ((thread_idx < 0) || (thread_idx >= this->n_threads) ||
	    (this->threads[thread_idx] == NULL)) {
		return;
	}
	if (thread_idx == this->current) {
		this->threads[thread_idx]->aborting = true;
		return;
	}
	nct_release(this, thread_idx);
}

int nct_get_unique_thread_id(void *this_arg, int thread_idx)
{
	(void)this_arg;
	return thread_idx;
}

int nct_thread_name_set(void *this_arg, int thread_idx, const char *str)
{
	(void)this_arg;
	(void)thread_idx;
	(void)str;
	return 0;
}

void nct_get_thread_stack(void *this_arg, int thread_idx, void **stack_addr,
			  unsigned long *stack_size)
{
	nsi_coro_ctx_stack(&nct_get(this_arg, thread_idx)->ctx, stack_addr, stack_size);
}

void nct_clean_up(void *this_arg)
{
	struct nct *this = this_arg;

	if (this == NULL) {
		return;
	}
#ifdef NSI_NCE_BACKEND_PTHREADS
	/*
	 * A halted CPU pthread is blocked inside nce_halt_cpu() on the current
	 * coroutine stack. The pthread NCT implementation likewise leaves its
	 * hosted threads to process cleanup rather than risking their live stacks.
	 */
	return;
#else
	for (int i = 0; i < this->n_threads; i++) {
		if (this->threads[i] != NULL) {
			nct_release(this, i);
		}
	}
	free(this->threads);
	*this = (struct nct){.current = -1};
#endif
}

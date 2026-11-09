/*
 * Copyright (c) 2026 Quercus
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <stdbool.h>
#include "nce_if.h"
#include "nsi_config.h"
#include "nsi_coro_ctx.h"
#include "nsi_main.h"
#include "nsi_tracing.h"

struct nce {
	struct nsi_coro_ctx boot;
	struct nsi_coro_ctx *switch_ctx;
	struct nsi_coro_ctx *waker;
	void (*start_routine)(void);
	bool halted;
	bool terminated;
};

static struct nce nce_instances[NSI_N_CPUS];
static int nce_next;

static void boot_entry(void *arg)
{
	struct nce *this = arg;

	this->start_routine();
	nsi_print_error_and_exit("%s: CPU start routine returned\n", __func__);
}

void *nce_init(void)
{
	struct nce *this = &nce_instances[nce_next];

	/* Coroutine NCE owns the root context for this run. */
	nsi_coro_ctx_reset();
	nce_next = (nce_next + 1) % NSI_N_CPUS;
	*this = (struct nce){.halted = true};
	return this;
}

void nce_boot_cpu(void *this_arg, void (*start_routine)(void))
{
	struct nce *this = this_arg;

	this->start_routine = start_routine;
	nsi_coro_ctx_create(&this->boot, boot_entry, this);
	this->switch_ctx = &this->boot;
	nce_wake_cpu(this);
}

void nce_halt_cpu(void *this_arg)
{
	struct nce *this = this_arg;

	if (this->halted) {
		nsi_print_error_and_exit("%s: CPU was already halted\n", __func__);
	}
	this->halted = true;
	this->switch_ctx = nsi_coro_ctx_current();
	nsi_coro_ctx_switch(this->waker, false);
}

void nce_wake_cpu(void *this_arg)
{
	struct nce *this = this_arg;

	if (this->terminated) {
		return;
	}
	if (!this->halted) {
		nsi_print_error_and_exit("%s: CPU was already awake\n", __func__);
	}
	this->halted = false;
	this->waker = nsi_coro_ctx_current();
	nsi_coro_ctx_switch(this->switch_ctx, false);

	if (this->terminated) {
		nsi_exit(0);
	}
}

void nce_terminate(void *this_arg)
{
	struct nce *this = this_arg;

	if (this == NULL) {
		return;
	}
	if (!this->halted) {
		this->terminated = true;
		this->halted = true;
		nsi_coro_ctx_switch(this->waker, true);
	}
	nsi_coro_ctx_free(&this->boot);
}

int nce_is_cpu_running(void *this_arg)
{
	struct nce *this = this_arg;

	return (this != NULL) && !this->halted;
}

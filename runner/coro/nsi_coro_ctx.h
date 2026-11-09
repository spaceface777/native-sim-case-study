/*
 * Copyright (c) 2026 Quercus
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef NSI_COMMON_CORO_NSI_CORO_CTX_H
#define NSI_COMMON_CORO_NSI_CORO_CTX_H

#include <fenv.h>
#include <stdbool.h>
#include <stddef.h>
#include "nsi_coro.h"

#if defined(__SANITIZE_ADDRESS__)
#define NSI_CORO_ASAN 1
#elif defined(__has_feature)
#if __has_feature(address_sanitizer)
#define NSI_CORO_ASAN 1
#endif
#endif

struct cxa_eh_globals {
	void *caught_exceptions;
	unsigned int uncaught_exceptions;
};

struct nsi_coro_ctx {
	struct cxa_eh_globals eh;
	nsi_coro_t continuation;
	void *map;
	size_t map_size;
	int err;
	/*
	 * Room for the floating point environment. Cosmopolitan Libc 4.0.2 declares fenv_t as
	 * one pointer (8 bytes), but its x86-64 fegetenv() stores 32 (fnstenv + stmxcsr).
	 */
	union {
		fenv_t env;
		unsigned char storage[64];
	} fenv;
	void (*entry)(void *arg);
	void *arg;
#ifdef NSI_CORO_ASAN
	void *asan_fake_stack;
	const void *asan_bottom;
	size_t asan_size;
#endif
};

void nsi_coro_ctx_reset(void);
void nsi_coro_ctx_create(struct nsi_coro_ctx *ctx, void (*entry)(void *), void *arg);
void nsi_coro_ctx_free(struct nsi_coro_ctx *ctx);
void nsi_coro_ctx_stack(struct nsi_coro_ctx *ctx, void **addr, unsigned long *size);
void nsi_coro_ctx_switch(struct nsi_coro_ctx *to, bool final);
struct nsi_coro_ctx *nsi_coro_ctx_current(void);
void nsi_coro_ctx_defer_free(struct nsi_coro_ctx *ctx, void *allocation);

#endif /* NSI_COMMON_CORO_NSI_CORO_CTX_H */

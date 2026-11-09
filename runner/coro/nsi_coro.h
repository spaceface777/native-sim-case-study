/*
 * Copyright (c) 2026 Quercus
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef NSI_COMMON_CORO_NSI_CORO_H
#define NSI_COMMON_CORO_NSI_CORO_H

#ifdef __cplusplus
extern "C" {
#endif

#ifndef NSI_CORO_STACK_SIZE
#define NSI_CORO_STACK_SIZE (8 * 1024 * 1024)
#endif

/*
 * Minimal stackful coroutine interface.
 *
 * A continuation is opaque to the caller and valid for exactly one resume.
 * The selected implementation only transfers execution between stacks;
 * scheduling and per-context host state live above this interface.
 */
typedef void *nsi_coro_t;

/*
 * Entry function of a new coroutine. <from> is the continuation of whoever
 * switched into it for the first time. It must never return.
 */
typedef void (*nsi_coro_entry_f)(nsi_coro_t from);

/*
 * Prepare a new coroutine whose stack ends (is highest) at <stack_top>, so
 * that the first switch to the returned continuation calls <entry>.
 * The caller owns the stack.
 */
nsi_coro_t nsi_coro_create(void *stack_top, nsi_coro_entry_f entry);

/*
 * Suspend the running code and resume <target>. Returns when somebody switches
 * back, with the continuation of that somebody.
 */
nsi_coro_t nsi_coro_switch(nsi_coro_t target);

#ifdef __cplusplus
}
#endif

#endif /* NSI_COMMON_CORO_NSI_CORO_H */

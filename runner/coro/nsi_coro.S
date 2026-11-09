/*
 * Copyright (c) 2026 Quercus
 *
 * SPDX-License-Identifier: Apache-2.0
 */

/*
 * Stackful coroutine switch for the native simulator coroutine CPU backend.
 * See nsi_coro.h for the interface.
 *
 * nsi_coro_switch() saves exactly the registers the host ABI requires a
 * called function to preserve, and returns one pointer in the ABI return
 * register. Caller-saved registers do not need saving, as the switch is a
 * normal function call for the compiler. The floating point control/status
 * state is handled by the C caller (fegetenv()/fesetenv()).
 *
 * nsi_coro_create() writes an initial frame, such that the first switch
 * "returns" into nsi_coro_trampoline, which calls the entry function with the
 * continuation of the switching coroutine as argument. Saved frame pointers
 * are 0 so unwinders stop at the bottom of a coroutine stack.
 *
 * Supported: x86-64 (System V ABI) and AArch64 (AAPCS64), as ELF objects. Cosmopolitan
 * uses these conventions on every OS (Win32 calls go through ms_abi thunks). On AArch64,
 * x18 (platform register) is never touched, and x28 (Cosmopolitan's TLS pointer) is
 * saved and restored like any other callee-saved register: it is the same within a thread.
 * The switch returns with a plain ret, so it is not compatible with hardware
 * shadow stacks (x86 CET SHSTK).
 */

	.text

#if defined(__x86_64__)

/*
 * Saved frame, lowest address first:
 * 0x00 r15, 0x08 r14, 0x10 r13, 0x18 r12, 0x20 rbx, 0x28 rbp, 0x30 return address
 */

/* nsi_coro_t nsi_coro_create(void *stack_top (rdi), nsi_coro_entry_f entry (rsi)) */
	.balign 16
	.globl nsi_coro_create
	.type nsi_coro_create, %function
nsi_coro_create:
	endbr64
	/* After the 7 pops of the first switch, rsp is 16 byte aligned, as needed at a call */
	andq	$-16, %rdi
	subq	$56, %rdi
	xorl	%eax, %eax
	movq	%rax, 0x00(%rdi)
	movq	%rax, 0x08(%rdi)
	movq	%rax, 0x10(%rdi)
	movq	%rax, 0x18(%rdi)
	movq	%rsi, 0x20(%rdi)		/* rbx = entry */
	movq	%rax, 0x28(%rdi)		/* rbp = 0 */
	leaq	nsi_coro_trampoline(%rip), %rax
	movq	%rax, 0x30(%rdi)
	movq	%rdi, %rax
	ret
	.size nsi_coro_create, . - nsi_coro_create

/* nsi_coro_t nsi_coro_switch(nsi_coro_t target (rdi)) */
	.balign 16
	.globl nsi_coro_switch
	.type nsi_coro_switch, %function
nsi_coro_switch:
	endbr64
	pushq	%rbp
	pushq	%rbx
	pushq	%r12
	pushq	%r13
	pushq	%r14
	pushq	%r15
	movq	%rsp, %rax			/* our continuation is the return value */
	movq	%rdi, %rsp
	popq	%r15
	popq	%r14
	popq	%r13
	popq	%r12
	popq	%rbx
	popq	%rbp
	ret
	.size nsi_coro_switch, . - nsi_coro_switch

	.balign 16
	.type nsi_coro_trampoline, %function
nsi_coro_trampoline:
	movq	%rax, %rdi			/* from */
	call	*%rbx
	ud2					/* the entry function must not return */
	.size nsi_coro_trampoline, . - nsi_coro_trampoline

#elif defined(__aarch64__)

/*
 * Saved frame, 160 bytes, lowest address first:
 * 0x00 d8-d9, 0x10 d10-d11, 0x20 d12-d13, 0x30 d14-d15,
 * 0x40 x19-x20, 0x50 x21-x22, 0x60 x23-x24, 0x70 x25-x26, 0x80 x27-x28,
 * 0x90 x29 (frame pointer), 0x98 x30 (link register)
 * x18 is never touched, as it may be reserved by the platform.
 */

/* nsi_coro_t nsi_coro_create(void *stack_top (x0), nsi_coro_entry_f entry (x1)) */
	.balign 16
	.globl nsi_coro_create
	.type nsi_coro_create, %function
nsi_coro_create:
	and	x0, x0, #~15
	sub	x0, x0, #0xa0
	stp	xzr, xzr, [x0, #0x00]
	stp	xzr, xzr, [x0, #0x10]
	stp	xzr, xzr, [x0, #0x20]
	stp	xzr, xzr, [x0, #0x30]
	stp	x1,  xzr, [x0, #0x40]		/* x19 = entry */
	stp	xzr, xzr, [x0, #0x50]
	stp	xzr, xzr, [x0, #0x60]
	stp	xzr, xzr, [x0, #0x70]
	/* x28 = the creator's: Cosmopolitan keeps its TLS pointer there (-ffixed-x28). */
	stp	xzr, x28, [x0, #0x80]
	adrp	x2, nsi_coro_trampoline
	add	x2, x2, :lo12:nsi_coro_trampoline
	stp	xzr, x2,  [x0, #0x90]		/* x29 = 0, x30 = trampoline */
	ret
	.size nsi_coro_create, . - nsi_coro_create

/* nsi_coro_t nsi_coro_switch(nsi_coro_t target (x0)) */
	.balign 16
	.globl nsi_coro_switch
	.type nsi_coro_switch, %function
nsi_coro_switch:
	stp	d8,  d9,  [sp, #-0xa0]!
	stp	d10, d11, [sp, #0x10]
	stp	d12, d13, [sp, #0x20]
	stp	d14, d15, [sp, #0x30]
	stp	x19, x20, [sp, #0x40]
	stp	x21, x22, [sp, #0x50]
	stp	x23, x24, [sp, #0x60]
	stp	x25, x26, [sp, #0x70]
	stp	x27, x28, [sp, #0x80]
	stp	x29, x30, [sp, #0x90]
	mov	x2, sp				/* our continuation is the return value */
	mov	sp, x0
	mov	x0, x2
	ldp	d8,  d9,  [sp, #0x00]
	ldp	d10, d11, [sp, #0x10]
	ldp	d12, d13, [sp, #0x20]
	ldp	d14, d15, [sp, #0x30]
	ldp	x19, x20, [sp, #0x40]
	ldp	x21, x22, [sp, #0x50]
	ldp	x23, x24, [sp, #0x60]
	ldp	x25, x26, [sp, #0x70]
	ldp	x27, x28, [sp, #0x80]
	ldp	x29, x30, [sp, #0x90]
	add	sp, sp, #0xa0
	ret
	.size nsi_coro_switch, . - nsi_coro_switch

	.balign 16
	.type nsi_coro_trampoline, %function
nsi_coro_trampoline:
	blr	x19				/* x0 (from) is already the argument */
	brk	#0				/* the entry function must not return */
	.size nsi_coro_trampoline, . - nsi_coro_trampoline

#else
#error "The coroutine CPU backend does not support this host architecture"
#endif

	.section .note.GNU-stack, "", %progbits

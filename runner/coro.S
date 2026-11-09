/* SPDX-License-Identifier: Apache-2.0 */
/*
 * void coro_switch(void **save_sp, void *sp)
 *	Push the callee-saved registers, store the stack pointer in *save_sp, then pop
 *	the registers saved on the stack sp and return there.
 * void *coro_init(void *stack_top, void (*start)(void))
 *	Return a stack that coro_switch resumes by calling start, which never returns.
 *	The stack must be zero-filled, as fresh anonymous memory is.
 *
 * Cosmopolitan uses the System V ABI on x86-64 and AAPCS64 on AArch64 on every OS.
 */
	.text
	.globl coro_switch, coro_init

#if defined(__x86_64__)

coro_switch:
	push	%rbp
	push	%rbx
	push	%r12
	push	%r13
	push	%r14
	push	%r15
	mov	%rsp, (%rdi)
	mov	%rsi, %rsp
	pop	%r15
	pop	%r14
	pop	%r13
	pop	%r12
	pop	%rbx
	pop	%rbp
	ret

coro_init:
	/* Six zero registers, then start, which sees an empty return address slot. */
	and	$-16, %rdi
	lea	-64(%rdi), %rax
	mov	%rsi, 48(%rax)
	ret

#elif defined(__aarch64__)

coro_switch:
	sub	sp, sp, #160
	stp	x19, x20, [sp, #0]
	stp	x21, x22, [sp, #16]
	stp	x23, x24, [sp, #32]
	stp	x25, x26, [sp, #48]
	stp	x27, x28, [sp, #64]
	stp	x29, x30, [sp, #80]
	stp	d8, d9, [sp, #96]
	stp	d10, d11, [sp, #112]
	stp	d12, d13, [sp, #128]
	stp	d14, d15, [sp, #144]
	mov	x9, sp
	str	x9, [x0]
	mov	sp, x1
	ldp	x19, x20, [sp, #0]
	ldp	x21, x22, [sp, #16]
	ldp	x23, x24, [sp, #32]
	ldp	x25, x26, [sp, #48]
	ldp	x27, x28, [sp, #64]
	ldp	x29, x30, [sp, #80]
	ldp	d8, d9, [sp, #96]
	ldp	d10, d11, [sp, #112]
	ldp	d12, d13, [sp, #128]
	ldp	d14, d15, [sp, #144]
	add	sp, sp, #160
	ret

coro_init:
	and	x0, x0, #-16
	sub	x0, x0, #160
	str	x28, [x0, #72]	/* Cosmopolitan's TLS pointer: the same on every stack */
	str	x1, [x0, #88]	/* x30: return into start */
	ret

#endif

	.section .note.GNU-stack, "", %progbits

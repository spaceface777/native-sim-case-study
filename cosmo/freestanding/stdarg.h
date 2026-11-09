/* SPDX-License-Identifier: Apache-2.0 */
/* Freestanding <stdarg.h> for compilers without their own (e.g. cosmocc). */
#ifndef _STDARG_H
#define _STDARG_H
typedef __builtin_va_list va_list;
typedef __builtin_va_list __gnuc_va_list;
#define va_start(ap, ...) __builtin_va_start(ap, 0)
#define va_end(ap)        __builtin_va_end(ap)
#define va_arg(ap, type)  __builtin_va_arg(ap, type)
#define va_copy(dst, src) __builtin_va_copy(dst, src)
#endif

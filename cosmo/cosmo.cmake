# SPDX-License-Identifier: Apache-2.0
#
# Build Zephyr's native_sim firmware with cosmocc's GNU toolchain (GCC 14 + binutils),
# for the host's own CPU architecture (x86_64 or aarch64).
# Include this file *before* find_package(Zephyr), and call cosmo_firmware_options()
# after it.
#
# Zephyr already supports cross-compiling native_sim targets with
#   ZEPHYR_TOOLCHAIN_VARIANT=cross-compile CROSS_COMPILE=<prefix> NATIVE_TARGET_HOST=<arch>
# so cosmocc is selected without modifying Zephyr: its compiler and binutils use the
# usual <arch>-linux-cosmo- prefix.
#
# The firmware is freestanding: it uses Zephyr's own C library. It needs only cosmocc's
# compiler and Cosmopolitan's ABI flags. Cosmopolitan Libc itself is linked once, into
# the final executable, together with the native simulator runners.

set(COSMOCC "$ENV{COSMOCC}" CACHE PATH "Extracted cosmocc toolchain directory")

# Target the host's CPU. Runs before project(), so CMAKE_HOST_SYSTEM_PROCESSOR is not yet
# known. COSMO_ARCH (x86_64|aarch64) overrides it, only to cross-build test binaries.
if(DEFINED ENV{COSMO_ARCH})
  set(host_cpu $ENV{COSMO_ARCH})
else()
  cmake_host_system_information(RESULT host_cpu QUERY OS_PLATFORM)
endif()
if(host_cpu MATCHES "^(x86_64|amd64|AMD64)$")
  set(COSMO_ARCH x86_64)
  # Cosmopolitan's x86-64 ABI, as applied by cosmocc to every object it compiles:
  #  - no red zone: Windows writes below the stack pointer during exception dispatch,
  #  - no direct %fs TLS references, so the runtime can relocate TLS on Windows/XNU.
  set(COSMO_ABI_FLAGS -mno-red-zone -mno-tls-direct-seg-refs -fno-pie)
elseif(host_cpu MATCHES "^(aarch64|arm64|ARM64)$")
  set(COSMO_ARCH aarch64)
  # Cosmopolitan's AArch64 ABI: x18 is reserved by Apple/Windows, x28 holds the TLS
  # pointer (cosmocc's fixupobj rewrites tpidr_el0 reads), and char is signed.
  set(COSMO_ABI_FLAGS -ffixed-x18 -ffixed-x28 -fsigned-char -fno-pie)
else()
  message(FATAL_ERROR "cosmocc supports x86_64 and aarch64 hosts, not ${host_cpu}")
endif()

if(NOT EXISTS "${COSMOCC}/bin/${COSMO_ARCH}-linux-cosmo-gcc")
  message(FATAL_ERROR "COSMOCC (${COSMOCC}) is not an extracted cosmocc toolchain")
endif()

set(ZEPHYR_TOOLCHAIN_VARIANT cross-compile CACHE STRING "" FORCE)
set(CROSS_COMPILE "${COSMOCC}/bin/${COSMO_ARCH}-linux-cosmo-" CACHE PATH "" FORCE)
set(NATIVE_TARGET_HOST ${COSMO_ARCH} CACHE STRING "" FORCE)
# Only libc.a's location matters to Zephyr; it is never linked into the firmware.
set(SYSROOT_DIR "${COSMOCC}/${COSMO_ARCH}-linux-cosmo" CACHE PATH "" FORCE)

function(cosmo_firmware_options)
  zephyr_compile_options(${COSMO_ABI_FLAGS})
endfunction()

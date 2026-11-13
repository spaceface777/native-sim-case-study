# SPDX-License-Identifier: Apache-2.0
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(native_sim_case_study)
target_sources(app PRIVATE main.c)
target_sources(native_simulator INTERFACE ${CMAKE_CURRENT_SOURCE_DIR}/runner.c)
if(CONFIG_NATIVE_SIMULATOR_NCT_CUSTOM)
  # This application's own CPU and thread emulation, instead of Zephyr's.
  target_sources(native_simulator INTERFACE ${CMAKE_CURRENT_SOURCE_DIR}/../nct-nce-custom-asm.c)
endif()
# Zephyr builds the runner without optimization by default.
target_compile_options(native_simulator INTERFACE -O2)

# SPDX-License-Identifier: Apache-2.0
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(native_sim_case_study)
target_sources(app PRIVATE main.c)
target_sources(native_simulator INTERFACE ${CMAKE_CURRENT_SOURCE_DIR}/runner.c)
separate_arguments(runner_options NATIVE_COMMAND "${CONFIG_COMPILER_OPT}")
target_compile_options(native_simulator INTERFACE -DNSI_NO_MAIN ${runner_options} -fno-common)

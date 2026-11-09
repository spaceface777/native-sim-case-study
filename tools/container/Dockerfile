# Optional Linux build container, e.g. for macOS hosts. Use the host's native platform:
#   docker build -t native-sim-cosmo tools/container
#   docker run --rm -it -v "$PWD:$PWD" -v "$ZEPHYR_BASE:$ZEPHYR_BASE" -w "$PWD" \
#       -e ZEPHYR_BASE -e BUILD="$PWD/build" native-sim-cosmo ./run.sh build
# The Cosmopolitan build needs only CMake, Ninja, make, Python, curl and unzip: cosmocc
# brings its own GCC and binutils. The rest is optional:
#  - gcc, g++, Boost.Context: building the previous, pre-Cosmopolitan baseline,
#  - qemu-user: smoke-testing simulators cross-built with COSMO_ARCH for another CPU.
FROM ubuntu:24.04
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl unzip cmake ninja-build make python3 python3-pip \
        gcc g++ libboost-context-dev qemu-user \
    && rm -rf /var/lib/apt/lists/*
RUN pip3 install --break-system-packages pyelftools pyyaml pykwalify packaging jsonschema

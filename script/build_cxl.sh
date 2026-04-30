#!/bin/bash
# Build the CXL binary on mn0 (alongside the existing RDMA build).
set -euo pipefail

DEFT_ROOT="${DEFT_ROOT:-/deft_code/deft}"

if command -v gcc-10 >/dev/null 2>&1; then
    export CC="$(command -v gcc-10)"
    export CXX="$(command -v g++-10)"
else
    export CC="$(command -v gcc)"
    export CXX="$(command -v g++)"
fi

echo "building CXL mode in ${DEFT_ROOT}/build_cxl ..."
echo "  CC=${CC}  CXX=${CXX}"

mkdir -p "${DEFT_ROOT}/build_cxl"
cd "${DEFT_ROOT}/build_cxl"
rm -f CMakeCache.txt
rm -rf CMakeFiles

cmake .. \
    -DUSE_CXL=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="${CC}" \
    -DCMAKE_CXX_COMPILER="${CXX}"

make -j16

echo "done. CXL binaries:"
ls -la server client client_non_stop 2>/dev/null || true

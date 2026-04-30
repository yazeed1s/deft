#!/usr/bin/env bash
# Fast rebuild path: do the same sync + cityhash + build steps as cloudlab_setup.
set -euo pipefail

LOG_FILE=/tmp/cloudlab_rebuild.log
exec > >(tee -a "$LOG_FILE") 2>&1

DEFT_ROOT=/deft_code/deft

usage() {
  cat <<'EOF'
Usage:
  ./script/cloudlab_rebuild.sh
  ./script/cloudlab_rebuild.sh --help

Behavior:
  - Run on mn0 only.
  - Sync repo to /deft_code/deft using the same source rules as cloudlab_setup.sh.
  - Ensure cityhash exists (same logic as cloudlab_setup.sh).
  - Rebuild server/client in /deft_code/deft/build.
EOF
}

if [[ $# -gt 1 ]]; then
  usage
  exit 1
fi
if [[ $# -eq 1 ]]; then
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac
fi

if [[ "$(hostname)" != "mn0" && "$(hostname)" != mn0.* ]]; then
  echo "error: run this on mn0"
  exit 1
fi

REAL_USER=${SUDO_USER:-$USER}
REAL_GROUP=$(id -gn "$REAL_USER")

echo "[1/3] syncing repository to ${DEFT_ROOT}..."
sudo mkdir -p "$DEFT_ROOT"
sudo chown "$REAL_USER:$REAL_GROUP" /deft_code "$DEFT_ROOT"

if [[ -d /local/repository/.git ]]; then
  sudo rsync -a --delete --exclude build --exclude build_cxl /local/repository/ "$DEFT_ROOT"/
elif [[ -f CMakeLists.txt ]]; then
  sudo rsync -a --delete --exclude build --exclude build_cxl ./ "$DEFT_ROOT"/
else
  echo "error: cannot find repo source. expected /local/repository or current repo root."
  exit 1
fi

sudo chown -R "$REAL_USER:$REAL_GROUP" "$DEFT_ROOT"
cd "$DEFT_ROOT"

echo "[2/3] ensuring cityhash..."
if ! ldconfig -p | grep -q libcityhash; then
  cd /tmp
  if [[ ! -d cityhash ]]; then
    git clone https://github.com/google/cityhash.git
  fi
  cd cityhash
  autoreconf -if
  ./configure
  make -j4
  sudo make install
  sudo ldconfig
fi

echo "[3/4] building deft (RDMA mode)..."
if command -v gcc-10 >/dev/null 2>&1 && command -v g++-10 >/dev/null 2>&1; then
  export CC="$(command -v gcc-10)"
  export CXX="$(command -v g++-10)"
else
  export CC="$(command -v gcc)"
  export CXX="$(command -v g++)"
fi
mkdir -p "$DEFT_ROOT/build"
cd "$DEFT_ROOT/build"
echo "using CC=${CC}"
echo "using CXX=${CXX}"
rm -f CMakeCache.txt
rm -rf CMakeFiles
cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER="${CC}" -DCMAKE_CXX_COMPILER="${CXX}" ..
make -j4
test -x ./server
test -x ./client

echo "[4/4] building deft (CXL mode)..."
mkdir -p "$DEFT_ROOT/build_cxl"
cd "$DEFT_ROOT/build_cxl"
rm -f CMakeCache.txt
rm -rf CMakeFiles
cmake -DUSE_CXL=ON -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER="${CC}" -DCMAKE_CXX_COMPILER="${CXX}" ..
make -j4
test -x ./server
test -x ./client

echo "done. sync + cityhash + build (RDMA & CXL) completed."

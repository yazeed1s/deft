#!/bin/bash
# Run RDMA and CXL benchmark campaigns back-to-back, then plot comparison.
# Usage: ./run_comparison.sh [--smoke-only] [--force-hugepage]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$SCRIPT_DIR"

cleanup_local_artifacts() {
    pkill -9 server >/dev/null 2>&1 || true
    pkill -9 client >/dev/null 2>&1 || true
    rm -f /dev/shm/deft_dsm /dev/shm/deft_lock /dev/shm/deft_rpc >/dev/null 2>&1 || true
}

trap cleanup_local_artifacts EXIT

MODES="smoke,small,mid"
READ_RATIOS="0,50,100"
ZIPFS="0.99"
REPEATS=3
FORCE_HP=""
RDMA_FORCE_HP="--force-hugepage"

for arg in "$@"; do
    case "$arg" in
        --smoke-only)
            MODES="smoke"
            READ_RATIOS="50"
            REPEATS=1
            ;;
        --force-hugepage)
            FORCE_HP="--force-hugepage"
            ;;
    esac
done

STAMP=$(date +%Y%m%d-%H%M%S)
RDMA_OUT="${DEFT_ROOT}/result/rdma-campaign-${STAMP}"
CXL_OUT="${DEFT_ROOT}/result/cxl-campaign-${STAMP}"
COMP_OUT="${DEFT_ROOT}/result/comparison-${STAMP}"
mkdir -p "$RDMA_OUT" "$CXL_OUT" "$COMP_OUT"

echo "============================================"
echo "  RDMA vs CXL Benchmark Comparison"
echo "  Modes: ${MODES}"
echo "  Read ratios: ${READ_RATIOS}"
echo "  Repeats: ${REPEATS}"
echo "  RDMA output: ${RDMA_OUT}"
echo "  CXL output:  ${CXL_OUT}"
echo "============================================"

# ── Phase 1: Build CXL if needed ──
if [[ ! -x "${DEFT_ROOT}/build_cxl/server" ]]; then
    echo ""
    echo "[phase 0] building CXL binaries..."
    bash "${SCRIPT_DIR}/build_cxl.sh"
fi

# ── Phase 2: RDMA Campaign ──
echo ""
echo "========== RDMA CAMPAIGN =========="
python3 gen_config.py   # generates RDMA config (multi-machine)

python3 run_campaign.py \
    --modes "$MODES" \
    --read-ratios "$READ_RATIOS" \
    --zipfs "$ZIPFS" \
    --repeats "$REPEATS" \
    $RDMA_FORCE_HP \
    --outdir "$RDMA_OUT"

echo "RDMA campaign done: ${RDMA_OUT}/runs.csv"

# Fail fast: do not proceed to CXL when RDMA campaign has failures.
if awk -F, 'NR>1 && $7=="fail"{found=1} END{exit(found?0:1)}' "${RDMA_OUT}/runs.csv"; then
    echo "error: RDMA campaign has failures. Skipping CXL phase."
    echo "check: ${RDMA_OUT}/runs.csv"
    exit 1
fi

# ── Phase 3: CXL Campaign ──
echo ""
echo "========== CXL CAMPAIGN =========="
python3 gen_config_cxl.py   # switches config to localhost + build_cxl

python3 run_campaign.py \
    --modes "$MODES" \
    --read-ratios "$READ_RATIOS" \
    --zipfs "$ZIPFS" \
    --repeats "$REPEATS" \
    ${FORCE_HP:-} \
    --outdir "$CXL_OUT"

echo "CXL campaign done: ${CXL_OUT}/runs.csv"

# ── Phase 4: Restore RDMA config ──
python3 gen_config.py
echo "restored RDMA config."

# ── Phase 5: Merge & Plot ──
echo ""
echo "========== GENERATING COMPARISON =========="
python3 plot_comparison.py \
    --rdma-csv "${RDMA_OUT}/runs.csv" \
    --cxl-csv "${CXL_OUT}/runs.csv" \
    --outdir "$COMP_OUT"

echo ""
echo "============================================"
echo "  All done!"
echo "  RDMA results: ${RDMA_OUT}/runs.csv"
echo "  CXL results:  ${CXL_OUT}/runs.csv"
echo "  Comparison:   ${COMP_OUT}/"
echo "============================================"

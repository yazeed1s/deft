#!/bin/bash
# Run short DEFT breakage-plan phases (A/B) end-to-end.
# Usage:
#   ./run_breakage_plan.sh [--phase-a] [--phase-b] [--phase-c] [--phase-d] [--phase-e] [--smoke12] [--no-force-hugepage] [--cxl-clients N] [--rnic-id N]
#
# Defaults:
#   - runs both Phase A and Phase B
#   - force hugepages enabled
#   - CXL_CLIENT_COUNT=5
#   - RNIC_ID environment passthrough (if set by caller)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$SCRIPT_DIR"

RUN_A=0
RUN_B=0
RUN_C=0
RUN_D=0
RUN_E=0
SMOKE12=0
FORCE_HP=1
CXL_CLIENT_COUNT="${CXL_CLIENT_COUNT:-5}"
RNIC_ID_ARG="${RNIC_ID:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase-a)
      RUN_A=1
      shift
      ;;
    --phase-b)
      RUN_B=1
      shift
      ;;
    --phase-c)
      RUN_C=1
      shift
      ;;
    --phase-d)
      RUN_D=1
      shift
      ;;
    --phase-e)
      RUN_E=1
      shift
      ;;
    --smoke12)
      SMOKE12=1
      RUN_A=1
      RUN_B=1
      RUN_C=1
      shift
      ;;
    --no-force-hugepage)
      FORCE_HP=0
      shift
      ;;
    --cxl-clients)
      CXL_CLIENT_COUNT="$2"
      shift 2
      ;;
    --rnic-id)
      RNIC_ID_ARG="$2"
      shift 2
      ;;
    *)
      echo "unknown arg: $1"
      exit 1
      ;;
  esac
done

# default: run both phases
if [[ "$RUN_A" -eq 0 && "$RUN_B" -eq 0 && "$RUN_C" -eq 0 && "$RUN_D" -eq 0 && "$RUN_E" -eq 0 ]]; then
  RUN_A=1
  RUN_B=1
fi

HP_FLAG=""
if [[ "$FORCE_HP" -eq 1 ]]; then
  HP_FLAG="--force-hugepage"
fi

if [[ -n "$RNIC_ID_ARG" ]]; then
  export RNIC_ID="$RNIC_ID_ARG"
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT_OUT="${DEFT_ROOT}/result/breakage-report-${STAMP}"

run_phase() {
  local phase="$1"
  local modes="$2"
  local rrs="$3"
  local zipfs="$4"
  local repeats="$5"
  local phase_stamp="${STAMP}-${phase}"

  local rdma_out="${DEFT_ROOT}/result/rdma-${phase}-${phase_stamp}"
  local cxl_out="${DEFT_ROOT}/result/cxl-${phase}-${phase_stamp}"
  local cmp_out="${DEFT_ROOT}/result/comparison-${phase}-${phase_stamp}"
  mkdir -p "$rdma_out" "$cxl_out" "$cmp_out"

  echo ""
  echo "============================================"
  echo "  Breakage Plan ${phase}"
  echo "  modes=${modes}"
  echo "  read-ratios=${rrs}"
  echo "  zipfs=${zipfs}"
  echo "  repeats=${repeats}"
  echo "  force_hugepage=${FORCE_HP}"
  echo "  cxl_clients=${CXL_CLIENT_COUNT}"
  echo "  rnic_id=${RNIC_ID:-unset}"
  echo "============================================"

  echo ""
  echo "[${phase}] RDMA campaign"
  python3 gen_config.py
  if [[ "$SMOKE12" -eq 1 ]]; then
    python3 run_campaign.py \
      --modes "smoke" \
      --read-ratios "50" \
      --zipfs "0.99" \
      --repeats "2" \
      $HP_FLAG \
      --outdir "$rdma_out"
  else
    python3 run_campaign.py \
      --modes "$modes" \
      --read-ratios "$rrs" \
      --zipfs "$zipfs" \
      --repeats "$repeats" \
      $HP_FLAG \
      --outdir "$rdma_out"
  fi
  echo "[${phase}] RDMA done: ${rdma_out}/runs.csv"

  if awk -F, 'NR>1 && $7=="fail"{found=1} END{exit(found?0:1)}' "${rdma_out}/runs.csv"; then
    echo "[${phase}] error: RDMA has failures. Skipping CXL and plot for this phase."
    return 1
  fi

  echo ""
  echo "[${phase}] CXL campaign"
  CXL_CLIENT_COUNT="${CXL_CLIENT_COUNT}" python3 gen_config_cxl.py
  if [[ "$SMOKE12" -eq 1 ]]; then
    python3 run_campaign.py \
      --modes "smoke" \
      --read-ratios "50" \
      --zipfs "0.99" \
      --repeats "2" \
      $HP_FLAG \
      --outdir "$cxl_out"
  else
    python3 run_campaign.py \
      --modes "$modes" \
      --read-ratios "$rrs" \
      --zipfs "$zipfs" \
      --repeats "$repeats" \
      $HP_FLAG \
      --outdir "$cxl_out"
  fi
  echo "[${phase}] CXL done: ${cxl_out}/runs.csv"

  echo ""
  echo "[${phase}] restore RDMA config"
  python3 gen_config.py

  echo ""
  echo "[${phase}] plot comparison"
  python3 plot_comparison.py \
    --rdma-csv "${rdma_out}/runs.csv" \
    --cxl-csv "${cxl_out}/runs.csv" \
    --outdir "$cmp_out"

  cat > "${cmp_out}/phase_manifest.txt" <<EOF
phase=${phase}
modes=${modes}
read_ratios=${rrs}
zipfs=${zipfs}
repeats=${repeats}
force_hugepage=${FORCE_HP}
cxl_clients=${CXL_CLIENT_COUNT}
rnic_id=${RNIC_ID:-unset}
rdma_csv=${rdma_out}/runs.csv
cxl_csv=${cxl_out}/runs.csv
EOF

  echo "[${phase}] comparison: ${cmp_out}"
}

run_phase_c() {
  local phase="phaseC"
  local phase_stamp="${STAMP}-${phase}"
  local base_out="${DEFT_ROOT}/result/${phase}-${phase_stamp}"
  local rdma_root="${base_out}/rdma"
  local cxl_root="${base_out}/cxl"
  mkdir -p "$rdma_root" "$cxl_root"

  # Short sweep definition (repeats=2 only).
  local tpcs=("1" "4" "8" "16" "30")
  local rrs=("50" "10" "0")
  local zfs=("0.99" "0.99" "0.999")
  local cxl_clients=("1" "3" "5")
  local repeats="2"
  local key_space="10000000"
  if [[ "$SMOKE12" -eq 1 ]]; then
    tpcs=("1" "8")
    rrs=("50")
    zfs=("0.99")
    cxl_clients=("${CXL_CLIENT_COUNT}")
    repeats="1"
  fi

  echo ""
  echo "============================================"
  echo "  Breakage Plan phaseC (thread/client scaling)"
  echo "  threads_per_client=${tpcs[*]}"
  echo "  (rr,zipf)={(50,0.99),(10,0.99),(0,0.999)}"
  echo "  cxl_clients=${cxl_clients[*]}"
  echo "  repeats=${repeats}"
  echo "  force_hugepage=${FORCE_HP}"
  echo "  key_space=${key_space}"
  echo "============================================"

  # RDMA sweeps
  python3 gen_config.py
  for t in "${tpcs[@]}"; do
    for i in "${!rrs[@]}"; do
      rr="${rrs[$i]}"
      zf="${zfs[$i]}"
      outdir="${rdma_root}/tpc${t}-rr${rr}-z${zf}"
      echo ""
      echo "[phaseC][RDMA] tpc=${t} rr=${rr} zipf=${zf}"
      python3 run_campaign.py \
        --modes smoke \
        --read-ratios "${rr}" \
        --zipfs "${zf}" \
        --repeats "${repeats}" \
        --threads-per-client "${t}" \
        --prefill-threads "${t}" \
        --key-space "${key_space}" \
        $HP_FLAG \
        --outdir "${outdir}"
    done
  done

  # CXL sweeps with client-count sweep
  for cc in "${cxl_clients[@]}"; do
    CXL_CLIENT_COUNT="${cc}" python3 gen_config_cxl.py
    for t in "${tpcs[@]}"; do
      for i in "${!rrs[@]}"; do
        rr="${rrs[$i]}"
        zf="${zfs[$i]}"
        outdir="${cxl_root}/c${cc}-tpc${t}-rr${rr}-z${zf}"
        echo ""
        echo "[phaseC][CXL] clients=${cc} tpc=${t} rr=${rr} zipf=${zf}"
        python3 run_campaign.py \
          --modes smoke \
          --read-ratios "${rr}" \
          --zipfs "${zf}" \
          --repeats "${repeats}" \
          --threads-per-client "${t}" \
          --prefill-threads "${t}" \
          --key-space "${key_space}" \
          $HP_FLAG \
          --outdir "${outdir}"
      done
    done
  done

  python3 gen_config.py

  cat > "${base_out}/phase_manifest.txt" <<EOF
phase=phaseC
threads_per_client=$(IFS=,; echo "${tpcs[*]}")
rr_zipf=(50,0.99);(10,0.99);(0,0.999)
cxl_clients=$(IFS=,; echo "${cxl_clients[*]}")
repeats=${repeats}
force_hugepage=${FORCE_HP}
key_space=${key_space}
rnic_id=${RNIC_ID:-unset}
rdma_root=${rdma_root}
cxl_root=${cxl_root}
EOF

  echo "[phaseC] done: ${base_out}"
}

run_phase_d() {
  # Phase D: isolate key-space driven growth.
  # Keep workload shape fixed; vary only key_space.
  # Full run: 5 keyspaces x 2 repeats x 2 transports = 20 tests.
  # Smoke run: 3 keyspaces x 1 repeat x 2 transports = 6 tests.
  local phase="phaseD"
  local phase_stamp="${STAMP}-${phase}"
  local rdma_out="${DEFT_ROOT}/result/rdma-${phase}-${phase_stamp}"
  local cxl_out="${DEFT_ROOT}/result/cxl-${phase}-${phase_stamp}"
  local cmp_out="${DEFT_ROOT}/result/comparison-${phase}-${phase_stamp}"
  mkdir -p "$rdma_out" "$cxl_out" "$cmp_out"

  local mode="smoke"
  local rr="50"
  local zf="0.99"
  local tpc="8"
  local repeats="2"
  local keyspaces=("1000" "100000" "1000000" "10000000" "100000000" "400000000")
  if [[ "$SMOKE12" -eq 1 ]]; then
    repeats="1"
    keyspaces=("1000" "1000000" "100000000")
  fi

  echo ""
  echo "============================================"
  echo "  Breakage Plan ${phase} (key-space isolation)"
  echo "  mode=${mode}"
  echo "  fixed rr=${rr}"
  echo "  fixed zipf=${zf}"
  echo "  fixed threads_per_client=${tpc}"
  echo "  key_spaces=${keyspaces[*]}"
  echo "  repeats=${repeats}"
  echo "  force_hugepage=${FORCE_HP}"
  echo "  cxl_clients=${CXL_CLIENT_COUNT}"
  echo "  rnic_id=${RNIC_ID:-unset}"
  echo "============================================"

  echo ""
  echo "[${phase}] RDMA campaign"
  python3 gen_config.py
  for ks in "${keyspaces[@]}"; do
    outdir="${rdma_out}/ks${ks}"
    echo "[${phase}][RDMA] key_space=${ks} tpc=${tpc} rr=${rr} zipf=${zf}"
    python3 run_campaign.py \
      --modes "${mode}" \
      --read-ratios "${rr}" \
      --zipfs "${zf}" \
      --repeats "${repeats}" \
      --threads-per-client "${tpc}" \
      --prefill-threads "${tpc}" \
      --key-space "${ks}" \
      $HP_FLAG \
      --outdir "${outdir}"
  done
  echo "[${phase}] RDMA done: ${rdma_out}"

  # Merge per-keyspace RDMA runs into a single CSV.
  python3 - "$rdma_out" <<'PY'
import csv, glob, os, sys
root = sys.argv[1]
rows = []
for p in sorted(glob.glob(os.path.join(root, "ks*", "runs.csv"))):
    with open(p, newline="") as fp:
        rows.extend(list(csv.DictReader(fp)))
if not rows:
    sys.exit(1)
fields = list(rows[0].keys())
out = os.path.join(root, "runs.csv")
with open(out, "w", newline="") as fp:
    w = csv.DictWriter(fp, fieldnames=fields)
    w.writeheader()
    w.writerows(rows)
print(out)
PY

  if awk -F, 'NR>1 && $7=="fail"{found=1} END{exit(found?0:1)}' "${rdma_out}/runs.csv"; then
    echo "[${phase}] error: RDMA has failures. Skipping CXL and plot for this phase."
    return 1
  fi

  echo ""
  echo "[${phase}] CXL campaign"
  CXL_CLIENT_COUNT="${CXL_CLIENT_COUNT}" python3 gen_config_cxl.py
  for ks in "${keyspaces[@]}"; do
    outdir="${cxl_out}/ks${ks}"
    echo "[${phase}][CXL] key_space=${ks} tpc=${tpc} rr=${rr} zipf=${zf}"
    python3 run_campaign.py \
      --modes "${mode}" \
      --read-ratios "${rr}" \
      --zipfs "${zf}" \
      --repeats "${repeats}" \
      --threads-per-client "${tpc}" \
      --prefill-threads "${tpc}" \
      --key-space "${ks}" \
      $HP_FLAG \
      --outdir "${outdir}"
  done
  echo "[${phase}] CXL done: ${cxl_out}"

  # Merge per-keyspace CXL runs into a single CSV.
  python3 - "$cxl_out" <<'PY'
import csv, glob, os, sys
root = sys.argv[1]
rows = []
for p in sorted(glob.glob(os.path.join(root, "ks*", "runs.csv"))):
    with open(p, newline="") as fp:
        rows.extend(list(csv.DictReader(fp)))
if not rows:
    sys.exit(1)
fields = list(rows[0].keys())
out = os.path.join(root, "runs.csv")
with open(out, "w", newline="") as fp:
    w = csv.DictWriter(fp, fieldnames=fields)
    w.writeheader()
    w.writerows(rows)
print(out)
PY

  echo ""
  echo "[${phase}] restore RDMA config"
  python3 gen_config.py

  echo ""
  echo "[${phase}] plot comparison"
  python3 plot_comparison.py \
    --rdma-csv "${rdma_out}/runs.csv" \
    --cxl-csv "${cxl_out}/runs.csv" \
    --outdir "$cmp_out"

  cat > "${cmp_out}/phase_manifest.txt" <<EOF
phase=${phase}
mode=${mode}
read_ratios=${rr}
zipfs=${zf}
threads_per_client=${tpc}
key_spaces=$(IFS=,; echo "${keyspaces[*]}")
repeats=${repeats}
force_hugepage=${FORCE_HP}
cxl_clients=${CXL_CLIENT_COUNT}
rnic_id=${RNIC_ID:-unset}
rdma_csv=${rdma_out}/runs.csv
cxl_csv=${cxl_out}/runs.csv
EOF

  echo "[${phase}] comparison: ${cmp_out}"
}

run_phase_e() {
  # Phase E: key-space x (rr,zipf) interaction sweep.
  # Full run defaults:
  #   keyspaces=3, rr=4, zipf=4, repeats=1 => 48 tests per transport (96 total).
  # Smoke run defaults:
  #   keyspaces=2, rr=2, zipf=2, repeats=1 => 8 tests per transport (16 total).
  local phase="phaseE"
  local phase_stamp="${STAMP}-${phase}"
  local rdma_out="${DEFT_ROOT}/result/rdma-${phase}-${phase_stamp}"
  local cxl_out="${DEFT_ROOT}/result/cxl-${phase}-${phase_stamp}"
  local cmp_out="${DEFT_ROOT}/result/comparison-${phase}-${phase_stamp}"
  mkdir -p "$rdma_out" "$cxl_out" "$cmp_out"

  local mode="smoke"
  local tpc="8"
  local repeats="1"
  local rrs=("0" "10" "50" "90")
  local zfs=("0.0" "0.8" "0.99" "0.999")
  local keyspaces=("1000" "1000000" "100000000" "400000000")

  # Optional environment overrides for quick tuning.
  if [[ -n "${PHASE_E_RRS:-}" ]]; then
    IFS=',' read -r -a rrs <<< "${PHASE_E_RRS}"
  fi
  if [[ -n "${PHASE_E_ZIPFS:-}" ]]; then
    IFS=',' read -r -a zfs <<< "${PHASE_E_ZIPFS}"
  fi
  if [[ -n "${PHASE_E_KEYSPACES:-}" ]]; then
    IFS=',' read -r -a keyspaces <<< "${PHASE_E_KEYSPACES}"
  fi
  if [[ -n "${PHASE_E_REPEATS:-}" ]]; then
    repeats="${PHASE_E_REPEATS}"
  fi
  if [[ -n "${PHASE_E_TPC:-}" ]]; then
    tpc="${PHASE_E_TPC}"
  fi

  if [[ "$SMOKE12" -eq 1 ]]; then
    repeats="1"
    rrs=("10" "90")
    zfs=("0.0" "0.99")
    keyspaces=("1000" "100000000")
  fi

  echo ""
  echo "============================================"
  echo "  Breakage Plan ${phase} (key-space x rr/zipf)"
  echo "  mode=${mode}"
  echo "  fixed threads_per_client=${tpc}"
  echo "  read_ratios=${rrs[*]}"
  echo "  zipfs=${zfs[*]}"
  echo "  key_spaces=${keyspaces[*]}"
  echo "  repeats=${repeats}"
  echo "  force_hugepage=${FORCE_HP}"
  echo "  cxl_clients=${CXL_CLIENT_COUNT}"
  echo "  rnic_id=${RNIC_ID:-unset}"
  echo "============================================"

  echo ""
  echo "[${phase}] RDMA campaign"
  python3 gen_config.py
  for rr in "${rrs[@]}"; do
    for zf in "${zfs[@]}"; do
      for ks in "${keyspaces[@]}"; do
        outdir="${rdma_out}/rr${rr}-z${zf}/ks${ks}"
        echo "[${phase}][RDMA] rr=${rr} zipf=${zf} key_space=${ks} tpc=${tpc}"
        python3 run_campaign.py \
          --modes "${mode}" \
          --read-ratios "${rr}" \
          --zipfs "${zf}" \
          --repeats "${repeats}" \
          --threads-per-client "${tpc}" \
          --prefill-threads "${tpc}" \
          --key-space "${ks}" \
          $HP_FLAG \
          --outdir "${outdir}"
      done
    done
  done
  echo "[${phase}] RDMA done: ${rdma_out}"

  python3 - "$rdma_out" <<'PY'
import csv, glob, os, sys
root = sys.argv[1]
rows = []
for p in sorted(glob.glob(os.path.join(root, "rr*-z*", "ks*", "runs.csv"))):
    with open(p, newline="") as fp:
        rows.extend(list(csv.DictReader(fp)))
if not rows:
    sys.exit(1)
fields = list(rows[0].keys())
out = os.path.join(root, "runs.csv")
with open(out, "w", newline="") as fp:
    w = csv.DictWriter(fp, fieldnames=fields)
    w.writeheader()
    w.writerows(rows)
print(out)
PY

  if awk -F, 'NR>1 && $7=="fail"{found=1} END{exit(found?0:1)}' "${rdma_out}/runs.csv"; then
    echo "[${phase}] error: RDMA has failures. Skipping CXL and plot for this phase."
    return 1
  fi

  echo ""
  echo "[${phase}] CXL campaign"
  CXL_CLIENT_COUNT="${CXL_CLIENT_COUNT}" python3 gen_config_cxl.py
  for rr in "${rrs[@]}"; do
    for zf in "${zfs[@]}"; do
      for ks in "${keyspaces[@]}"; do
        outdir="${cxl_out}/rr${rr}-z${zf}/ks${ks}"
        echo "[${phase}][CXL] rr=${rr} zipf=${zf} key_space=${ks} tpc=${tpc}"
        python3 run_campaign.py \
          --modes "${mode}" \
          --read-ratios "${rr}" \
          --zipfs "${zf}" \
          --repeats "${repeats}" \
          --threads-per-client "${tpc}" \
          --prefill-threads "${tpc}" \
          --key-space "${ks}" \
          $HP_FLAG \
          --outdir "${outdir}"
      done
    done
  done
  echo "[${phase}] CXL done: ${cxl_out}"

  python3 - "$cxl_out" <<'PY'
import csv, glob, os, sys
root = sys.argv[1]
rows = []
for p in sorted(glob.glob(os.path.join(root, "rr*-z*", "ks*", "runs.csv"))):
    with open(p, newline="") as fp:
        rows.extend(list(csv.DictReader(fp)))
if not rows:
    sys.exit(1)
fields = list(rows[0].keys())
out = os.path.join(root, "runs.csv")
with open(out, "w", newline="") as fp:
    w = csv.DictWriter(fp, fieldnames=fields)
    w.writeheader()
    w.writerows(rows)
print(out)
PY

  echo ""
  echo "[${phase}] restore RDMA config"
  python3 gen_config.py

  echo ""
  echo "[${phase}] plot comparison"
  python3 plot_comparison.py \
    --rdma-csv "${rdma_out}/runs.csv" \
    --cxl-csv "${cxl_out}/runs.csv" \
    --outdir "$cmp_out"

  cat > "${cmp_out}/phase_manifest.txt" <<EOF
phase=${phase}
mode=${mode}
threads_per_client=${tpc}
read_ratios=$(IFS=,; echo "${rrs[*]}")
zipfs=$(IFS=,; echo "${zfs[*]}")
key_spaces=$(IFS=,; echo "${keyspaces[*]}")
repeats=${repeats}
force_hugepage=${FORCE_HP}
cxl_clients=${CXL_CLIENT_COUNT}
rnic_id=${RNIC_ID:-unset}
rdma_csv=${rdma_out}/runs.csv
cxl_csv=${cxl_out}/runs.csv
EOF

  echo "[${phase}] comparison: ${cmp_out}"
}

if [[ "$RUN_A" -eq 1 ]]; then
  # Phase A (short baseline): smoke,small,mid × rr50 × z{0.0,0.8,0.99} × rep3
  run_phase "phaseA" "smoke,small,mid" "50" "0.0,0.8,0.99" "3"
fi

if [[ "$RUN_B" -eq 1 ]]; then
  # Phase B (contention/skew short): small,mid × rr{10,50,90} × z{0.0,0.8,0.99,0.999} × rep2
  run_phase "phaseB" "small,mid" "10,50,90" "0.0,0.8,0.99,0.999" "2"
fi

if [[ "$RUN_C" -eq 1 ]]; then
  run_phase_c
fi

if [[ "$RUN_D" -eq 1 ]]; then
  run_phase_d
fi

if [[ "$RUN_E" -eq 1 ]]; then
  run_phase_e
fi

echo ""
echo "Generating consolidated stress report plots..."
python3 plot_breakage_report.py \
  --result-root "${DEFT_ROOT}/result" \
  --outdir "${REPORT_OUT}"
echo "Stress report: ${REPORT_OUT}"

echo ""
echo "Done."
echo "Results root: ${DEFT_ROOT}/result"

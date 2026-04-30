# Benchmarking Plan: RDMA vs CXL

## Goal

Run identical workloads on both the RDMA and CXL backends, collect throughput (Mops/s) and latency (µs), and produce comparison charts for the report/presentation.

---

## Current Infrastructure

| Script | Purpose |
|--------|---------|
| `gen_config.py` | Auto-detects mn/cn nodes, writes `global_config.yaml` and `memcached.conf` |
| `restartMemc.sh` | Kills/restarts memcached on mn0, seeds `ServerNum=0`, `ClientNum=0` |
| `run_bench.py` | Runs one benchmark job: starts server(s), client(s) via SSH, waits, collects results |
| `run_campaign.py` | Loops over (mode, read_ratio, zipf, repeat) combos, writes structured CSV |
| `plot_campaign.py` | Reads CSV, plots throughput and latency vs thread count |

### Key run_bench.py Flags

```
--smoke           1 thread, 1K keys (sanity check, ~30s)
--small           5 threads, 10M keys (~2 min)
--mid            15 threads, 100M keys (~5 min)
--big            30 threads, 400M keys (~15+ min)
--read-ratio     0..100 (50 = mixed)
--zipf           0.0..0.99
--force-hugepage Use huge pages instead of regular pages
--name           Label for result file
```

### What the Client Binary Reports

```
Loading Results TP: X.XXX Mops/s Lat: X.XXX us    ← prefill phase
Final Results: TP: X.XXX Mops/s Lat: X.XXX us     ← benchmark phase
```

The `run_campaign.py` script parses both lines into a CSV with columns:
`mode, read_ratio, zipf, total_threads, loading_tp_mops, loading_lat_us, final_tp_mops, final_lat_us`

---

## Benchmarking Strategy

### Phase 1: RDMA Baseline (CloudLab, multi-machine)

**Topology:** mn0 (server) + cn0, cn1 (clients)

```bash
# On mn0:
cd /deft_code/deft/script
python3 gen_config.py
python3 run_campaign.py \
    --modes smoke,small,mid \
    --read-ratios 0,50,100 \
    --zipfs 0.99 \
    --repeats 3 \
    --force-hugepage \
    --outdir ../result/rdma-campaign
```

This produces:
- `result/rdma-campaign/runs.csv`
- `result/rdma-campaign/logs/`

**Estimated time:** ~45 min for 3 modes × 3 read ratios × 3 repeats = 27 runs

### Phase 2: CXL Benchmark (Single machine — mn0 only)

**Topology:** mn0 runs BOTH server and client (same machine, shared `/dev/shm`)

**Step 1: Build CXL on mn0**

The CXL binary isn't built by `cloudlab_setup.sh` (it builds RDMA by default). You need to build separately:

```bash
ssh mn0
cd /deft_code/deft
mkdir -p build_cxl && cd build_cxl
cmake .. -DUSE_CXL=ON -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=/usr/bin/gcc-10 \
    -DCMAKE_CXX_COMPILER=/usr/bin/g++-10
make -j$(nproc)
```

**Step 2: Manual config for CXL**

Create a CXL-specific config since both server and client run on mn0:

```bash
cat > /deft_code/deft/script/global_config_cxl.yaml <<'EOF'
src_path: /deft_code/deft
app_rel_path: build_cxl
server_app: server
client_app: client
rnic_id: 0
username: yazeed_n
password: ''
servers:
  - ip: 127.0.0.1
    numa_id: 0
clients:
  - ip: 127.0.0.1
    numa_id: 0
EOF
```

> **Important differences from RDMA config:**
> - `app_rel_path: build_cxl` (not `build`)
> - Both server and client on `127.0.0.1` (same machine)
> - `rnic_id: 0` (unused under CXL but required by gflags)
> - Single server, single client

**Step 3: Point run_bench at CXL config**

Either:
- (a) Copy the CXL yaml to `global_config.yaml` before running, or
- (b) Create a small wrapper script (recommended):

```bash
#!/bin/bash
# run_cxl_campaign.sh
cp /deft_code/deft/script/global_config_cxl.yaml \
   /deft_code/deft/script/global_config.yaml

python3 run_campaign.py \
    --modes smoke,small,mid \
    --read-ratios 0,50,100 \
    --zipfs 0.99 \
    --repeats 3 \
    --outdir ../result/cxl-campaign

# Restore RDMA config for next run
python3 gen_config.py
```

> [!WARNING]
> CXL runs on a single machine, so `--force-hugepage` is NOT needed (no RDMA MR registration).
> Use the default `DEFT_DISABLE_HUGEPAGE=1` mode.

**Step 4: Run**

```bash
ssh mn0
cd /deft_code/deft/script
./run_cxl_campaign.sh
```

This produces:
- `result/cxl-campaign/runs.csv`
- `result/cxl-campaign/logs/`

---

## Phase 3: Comparison Plots

### Option A: Use existing plot_campaign.py per-campaign

```bash
python3 plot_campaign.py --csv ../result/rdma-campaign/runs.csv
python3 plot_campaign.py --csv ../result/cxl-campaign/runs.csv
```

### Option B: Merge CSVs and plot side-by-side (recommended)

Add a `transport` column and merge:

```bash
cd /deft_code/deft/result
# Add transport column
head -1 rdma-campaign/runs.csv | sed 's/$/,transport/' > merged.csv
tail -n+2 rdma-campaign/runs.csv | sed 's/$/,rdma/' >> merged.csv
tail -n+2 cxl-campaign/runs.csv | sed 's/$/,cxl/' >> merged.csv
```

Then use a custom plot script (or modify `plot_campaign.py`) to group by transport.

---

## Benchmark Matrix

| Dimension | Values | Notes |
|-----------|--------|-------|
| **Transport** | RDMA, CXL | Two separate builds |
| **Mode** | smoke, small, mid | Big skipped unless time permits |
| **Read ratio** | 0% (write-only), 50% (mixed), 100% (read-only) | Tests different access patterns |
| **Zipf** | 0.99 | High skew (realistic) |
| **Repeats** | 3 | For median calculation |

**Total runs:** 2 transports × 3 modes × 3 read ratios × 3 repeats = **54 runs**

---

## Expected Results

| Metric | RDMA (Expected) | CXL (Expected) | Why |
|--------|-----------------|-----------------|-----|
| **Throughput** | Lower | Higher | CXL has no network round-trip; memcpy is faster than ibv_post_send + poll_cq |
| **Latency** | Higher (~3-10µs per op) | Lower (~0.1-1µs per op) | No NIC DMA latency |
| **Scalability** | Good (NIC handles parallelism) | May plateau (single machine, cache contention) | CXL bottlenecked by shared memory bus |
| **Write-heavy** | Moderate penalty (CAS + write verbs) | Minimal penalty (direct atomic ops) | Software CAS vs hardware CAS |

---

## Presentation-Ready Charts

For the report/presentation, produce these 4 charts:

1. **Throughput vs Read Ratio** (grouped bar: RDMA vs CXL at 0%, 50%, 100% read)
2. **Latency vs Read Ratio** (same grouping)
3. **Throughput vs Thread Count** (line chart: RDMA vs CXL across smoke/small/mid)
4. **Latency Breakdown** (stacked bar: lock, read_page, write_page — from client logs)

---

## Quick Smoke Test (Do This First)

Before running the full campaign, verify both backends work end-to-end:

```bash
# RDMA smoke (on mn0, uses cn0/cn1)
cd /deft_code/deft/script
python3 gen_config.py
python3 run_bench.py --smoke --name rdma-smoke

# CXL smoke (on mn0, local only)
cp global_config_cxl.yaml global_config.yaml
python3 run_bench.py --smoke --name cxl-smoke
python3 gen_config.py  # restore
```

If both print `Final Results: TP: X.XXX Mops/s Lat: X.XXX us`, you're good to run the full campaign.

---

## Potential Issues

| Issue | Mitigation |
|-------|------------|
| CXL server/client both on mn0 compete for CPU | Pin server to NUMA 0, client to NUMA 1 via `numa_id` in config |
| Memcached must be accessible on 127.0.0.1 | `restartMemc.sh` starts it on mn0's LAN IP — update `memcached.conf` to use `127.0.0.1` for CXL runs |
| `run_bench.py` SSHes into nodes — needs SSH to localhost | Ensure passwordless SSH to `127.0.0.1` works |
| Huge pages not available for CXL | Use `DEFT_DISABLE_HUGEPAGE=1` (already the default when `--force-hugepage` is not passed) |
| CXL `Sum()` barrier uses memcached | Works fine — both processes can reach memcached on localhost |

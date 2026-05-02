#!/usr/bin/env python3
"""
Aggregate breakage-plan runs and generate stress-focused plots.

Usage:
  python3 plot_breakage_report.py \
    --result-root /deft_code/deft/result \
    --outdir /deft_code/deft/result/breakage-report-$(date +%Y%m%d-%H%M%S)
"""

import argparse
import csv
import os
import re
from collections import defaultdict
from statistics import median

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


def to_float(v):
    try:
        return float(v)
    except Exception:
        return None


def to_int(v):
    try:
        return int(float(v))
    except Exception:
        return None


def discover_runs_csv(result_root):
    out = []
    for root, _, files in os.walk(result_root):
        if "runs.csv" in files:
            p = os.path.join(root, "runs.csv")
            if "/rdma-phase" in p or "/cxl-phase" in p or "/phaseC-" in p:
                out.append(p)
    return sorted(out)


def infer_transport(path):
    low = path.lower()
    if "/rdma" in low:
        return "rdma"
    if "/cxl" in low:
        return "cxl"
    return "unknown"


def infer_phase(path):
    low = path.lower()
    if "phasea" in low:
        return "phaseA"
    if "phaseb" in low:
        return "phaseB"
    if "phasec" in low:
        return "phaseC"
    return "other"


def infer_cxl_clients(path):
    m = re.search(r"/c(\d+)-tpc", path)
    if m:
        return int(m.group(1))
    return None


def load_rows(result_root):
    rows = []
    for p in discover_runs_csv(result_root):
        transport = infer_transport(p)
        phase = infer_phase(p)
        cc = infer_cxl_clients(p)
        with open(p, newline="") as fp:
            for r in csv.DictReader(fp):
                if r.get("status") != "ok":
                    continue
                rec = {
                    "path": p,
                    "transport": transport,
                    "phase": phase,
                    "mode": r.get("mode", ""),
                    "rr": to_int(r.get("read_ratio")),
                    "zipf": to_float(r.get("zipf")),
                    "threads": to_int(r.get("total_threads")),
                    "tp": to_float(r.get("final_tp_mops")),
                    "lat": to_float(r.get("final_lat_us")),
                    "cpu": to_float(r.get("cluster_cpu_avg_pct")),
                    "rss": to_float(r.get("cluster_rss_avg_mb")),
                    "cxl_clients": cc,
                }
                if rec["tp"] is None or rec["lat"] is None:
                    continue
                rows.append(rec)
    return rows


def median_by(rows, key_fn, value_key):
    buckets = defaultdict(list)
    for r in rows:
        v = r.get(value_key)
        if v is None:
            continue
        buckets[key_fn(r)].append(v)
    return {k: median(vs) for k, vs in buckets.items() if vs}


def plot_phase_overview(rows, outdir):
    # Throughput and latency grouped by phase+transport.
    keys = []
    tp_vals = []
    lat_vals = []
    for phase in ["phaseA", "phaseB", "phaseC"]:
        for t in ["rdma", "cxl"]:
            sub = [r for r in rows if r["phase"] == phase and r["transport"] == t]
            if not sub:
                continue
            keys.append(f"{phase}-{t}")
            tp_vals.append(median([r["tp"] for r in sub]))
            lat_vals.append(median([r["lat"] for r in sub]))

    if not keys:
        return

    fig, ax = plt.subplots(figsize=(10, 5))
    x = list(range(len(keys)))
    ax.bar(x, tp_vals, color="#4C78A8")
    ax.set_xticks(x)
    ax.set_xticklabels(keys, rotation=25, ha="right")
    ax.set_ylabel("Throughput (Mops/s)")
    ax.set_title("Median Throughput by Phase/Transport")
    ax.grid(axis="y", alpha=0.3)
    fig.tight_layout()
    fig.savefig(os.path.join(outdir, "overview_throughput_by_phase.png"), dpi=180)
    plt.close(fig)

    fig, ax = plt.subplots(figsize=(10, 5))
    ax.bar(x, lat_vals, color="#F58518")
    ax.set_xticks(x)
    ax.set_xticklabels(keys, rotation=25, ha="right")
    ax.set_ylabel("Latency (us)")
    ax.set_title("Median Latency by Phase/Transport")
    ax.grid(axis="y", alpha=0.3)
    fig.tight_layout()
    fig.savefig(os.path.join(outdir, "overview_latency_by_phase.png"), dpi=180)
    plt.close(fig)


def plot_phaseb_heatmap(rows, outdir, metric="tp"):
    # Heatmap-like matrix for phaseB across rr x zipf, split by mode and transport.
    pb = [r for r in rows if r["phase"] == "phaseB"]
    if not pb:
        return
    modes = sorted(set(r["mode"] for r in pb))
    rrs = sorted(set(r["rr"] for r in pb if r["rr"] is not None))
    zfs = sorted(set(r["zipf"] for r in pb if r["zipf"] is not None))

    for mode in modes:
        fig, axs = plt.subplots(1, 2, figsize=(12, 4.5), sharey=True)
        for idx, t in enumerate(["rdma", "cxl"]):
            ax = axs[idx]
            mat = []
            for rr in rrs:
                row_vals = []
                for zf in zfs:
                    vals = [r[metric] for r in pb if r["mode"] == mode and r["transport"] == t and r["rr"] == rr and r["zipf"] == zf and r[metric] is not None]
                    row_vals.append(median(vals) if vals else float("nan"))
                mat.append(row_vals)
            im = ax.imshow(mat, aspect="auto")
            ax.set_title(f"{t.upper()} mode={mode}")
            ax.set_xticks(range(len(zfs)))
            ax.set_xticklabels([f"{z:.3g}" for z in zfs], rotation=25, ha="right")
            ax.set_yticks(range(len(rrs)))
            ax.set_yticklabels([str(rr) for rr in rrs])
            ax.set_xlabel("Zipf")
            if idx == 0:
                ax.set_ylabel("Read ratio")
            fig.colorbar(im, ax=ax, fraction=0.046, pad=0.04)
        title = "Throughput" if metric == "tp" else "Latency"
        fig.suptitle(f"PhaseB {title} Stress Matrix")
        fig.tight_layout()
        fig.savefig(os.path.join(outdir, f"phaseB_{metric}_heatmap_{mode}.png"), dpi=180)
        plt.close(fig)


def plot_phasec_scaling(rows, outdir):
    pc = [r for r in rows if r["phase"] == "phaseC" and r["threads"] is not None]
    if not pc:
        return
    combos = sorted(set((r["rr"], r["zipf"]) for r in pc if r["rr"] is not None and r["zipf"] is not None))
    for rr, zf in combos:
        fig, ax = plt.subplots(figsize=(10, 6))
        # RDMA line
        rd = [r for r in pc if r["transport"] == "rdma" and r["rr"] == rr and r["zipf"] == zf]
        by_t = defaultdict(list)
        for r in rd:
            by_t[r["threads"]].append(r["tp"])
        if by_t:
            xs = sorted(by_t.keys())
            ys = [median(by_t[x]) for x in xs]
            ax.plot(xs, ys, marker="o", linewidth=2, label="RDMA", color="#1f77b4")

        # CXL lines by client count
        cxl_ccs = sorted(set(r["cxl_clients"] for r in pc if r["transport"] == "cxl" and r["cxl_clients"] is not None))
        palette = ["#ff7f0e", "#2ca02c", "#d62728", "#9467bd", "#8c564b"]
        for i, cc in enumerate(cxl_ccs):
            cx = [r for r in pc if r["transport"] == "cxl" and r["rr"] == rr and r["zipf"] == zf and r["cxl_clients"] == cc]
            by_t = defaultdict(list)
            for r in cx:
                by_t[r["threads"]].append(r["tp"])
            if not by_t:
                continue
            xs = sorted(by_t.keys())
            ys = [median(by_t[x]) for x in xs]
            ax.plot(xs, ys, marker="s", linewidth=2, label=f"CXL c={cc}", color=palette[i % len(palette)])

        ax.set_xlabel("Total Threads")
        ax.set_ylabel("Throughput (Mops/s)")
        ax.set_title(f"PhaseC Scaling: rr={rr}, zipf={zf}")
        ax.grid(alpha=0.3)
        ax.legend()
        fig.tight_layout()
        fig.savefig(os.path.join(outdir, f"phaseC_scaling_tp_rr{rr}_z{zf}.png"), dpi=180)
        plt.close(fig)


def plot_efficiency(rows, outdir):
    # Scatter: throughput vs CPU and throughput vs RSS
    for xkey, fname, xlabel in [
        ("cpu", "efficiency_tp_vs_cpu.png", "Cluster CPU (%)"),
        ("rss", "efficiency_tp_vs_rss.png", "Cluster RSS (MB)"),
    ]:
        fig, ax = plt.subplots(figsize=(9, 6))
        for t, color, marker in [("rdma", "#1f77b4", "o"), ("cxl", "#ff7f0e", "s")]:
            sub = [r for r in rows if r["transport"] == t and r.get(xkey) is not None]
            if not sub:
                continue
            xs = [r[xkey] for r in sub]
            ys = [r["tp"] for r in sub]
            ax.scatter(xs, ys, alpha=0.7, s=35, c=color, marker=marker, label=t.upper())
        ax.set_xlabel(xlabel)
        ax.set_ylabel("Throughput (Mops/s)")
        ax.set_title(f"Stress Efficiency: Throughput vs {xlabel}")
        ax.grid(alpha=0.3)
        ax.legend()
        fig.tight_layout()
        fig.savefig(os.path.join(outdir, fname), dpi=180)
        plt.close(fig)


def write_summary(rows, outdir):
    path = os.path.join(outdir, "stress_summary.csv")
    fields = [
        "phase", "transport", "mode", "rr", "zipf", "threads", "cxl_clients",
        "tp_med", "lat_med", "cpu_med", "rss_med", "n",
    ]
    buckets = defaultdict(list)
    for r in rows:
        k = (r["phase"], r["transport"], r["mode"], r["rr"], r["zipf"], r["threads"], r["cxl_clients"])
        buckets[k].append(r)

    with open(path, "w", newline="") as fp:
        w = csv.DictWriter(fp, fieldnames=fields)
        w.writeheader()
        for k, rs in sorted(buckets.items(), key=lambda x: str(x[0])):
            phase, transport, mode, rr, zipf, threads, cxl_clients = k
            def med(key):
                vals = [r[key] for r in rs if r.get(key) is not None]
                return median(vals) if vals else ""
            w.writerow({
                "phase": phase,
                "transport": transport,
                "mode": mode,
                "rr": rr,
                "zipf": zipf,
                "threads": threads,
                "cxl_clients": cxl_clients if cxl_clients is not None else "",
                "tp_med": med("tp"),
                "lat_med": med("lat"),
                "cpu_med": med("cpu"),
                "rss_med": med("rss"),
                "n": len(rs),
            })
    return path


def main():
    ap = argparse.ArgumentParser(description="Generate stress report plots across breakage-plan phases.")
    ap.add_argument("--result-root", required=True, help="Result root directory")
    ap.add_argument("--outdir", required=True, help="Output report directory")
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    rows = load_rows(args.result_root)
    if not rows:
        print("No breakage-plan runs.csv files found.")
        return

    summary = write_summary(rows, args.outdir)
    plot_phase_overview(rows, args.outdir)
    plot_phaseb_heatmap(rows, args.outdir, metric="tp")
    plot_phaseb_heatmap(rows, args.outdir, metric="lat")
    plot_phasec_scaling(rows, args.outdir)
    plot_efficiency(rows, args.outdir)

    print(f"rows loaded: {len(rows)}")
    print(f"summary: {summary}")
    print(f"plots: {args.outdir}")


if __name__ == "__main__":
    main()


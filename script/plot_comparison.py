#!/usr/bin/env python3
"""
Merge RDMA and CXL campaign CSVs and produce comparison plots.

Usage:
    python3 plot_comparison.py \
        --rdma-csv ../result/rdma-campaign/runs.csv \
        --cxl-csv  ../result/cxl-campaign/runs.csv \
        --outdir   ../result/comparison
"""

import argparse
import csv
import os
from collections import defaultdict
from statistics import median

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


def load_rows(csv_path, transport):
    rows = []
    with open(csv_path, newline="") as fp:
        for r in csv.DictReader(fp):
            r["transport"] = transport
            rows.append(r)
    return rows


def to_float(v):
    try:
        return float(v)
    except Exception:
        return None


def aggregate(rows):
    """Group by (transport, mode, read_ratio, zipf) → lists of tp/lat."""
    agg = defaultdict(lambda: {"tp": [], "lat": [], "ok": 0, "all": 0, "threads": 0})
    for r in rows:
        key = (
            r["transport"],
            r["mode"],
            int(r["read_ratio"]),
            float(r["zipf"]),
        )
        agg[key]["all"] += 1
        agg[key]["threads"] = int(r.get("total_threads") or 0)
        if r["status"] == "ok":
            agg[key]["ok"] += 1
            tp = to_float(r["final_tp_mops"])
            lat = to_float(r["final_lat_us"])
            if tp is not None:
                agg[key]["tp"].append(tp)
            if lat is not None:
                agg[key]["lat"].append(lat)
    return agg


# ── Colors & style ──
COLORS = {"rdma": "#2196F3", "cxl": "#FF5722"}
BAR_WIDTH = 0.35


def plot_tp_vs_readratio(agg, outdir):
    """Grouped bar chart: throughput at each read ratio, RDMA vs CXL."""
    fig, ax = plt.subplots(figsize=(9, 5.5))

    # Collect data per (mode, rr) for each transport
    modes_seen = sorted({k[1] for k in agg})
    rrs = sorted({k[2] for k in agg})

    for mode in modes_seen:
        rdma_vals, cxl_vals, labels = [], [], []
        for rr in rrs:
            label = f"{rr}% read"
            labels.append(label)
            rdma_key = ("rdma", mode, rr, 0.99)
            cxl_key = ("cxl", mode, rr, 0.99)
            rdma_vals.append(median(agg[rdma_key]["tp"]) if rdma_key in agg and agg[rdma_key]["tp"] else 0)
            cxl_vals.append(median(agg[cxl_key]["tp"]) if cxl_key in agg and agg[cxl_key]["tp"] else 0)

        x = range(len(labels))
        offset = BAR_WIDTH / 2
        ax.bar([i - offset for i in x], rdma_vals, BAR_WIDTH, label=f"RDMA ({mode})", color=COLORS["rdma"], alpha=0.85)
        ax.bar([i + offset for i in x], cxl_vals, BAR_WIDTH, label=f"CXL ({mode})", color=COLORS["cxl"], alpha=0.85)

        ax.set_xticks(list(x))
        ax.set_xticklabels(labels)
        ax.set_ylabel("Throughput (Mops/s)")
        ax.set_title(f"Throughput: RDMA vs CXL — {mode} mode")
        ax.legend()
        ax.grid(axis="y", alpha=0.3)
        fig.tight_layout()
        fig.savefig(os.path.join(outdir, f"tp_vs_readratio_{mode}.png"), dpi=160)
        ax.clear()

    plt.close(fig)


def plot_lat_vs_readratio(agg, outdir):
    """Grouped bar chart: latency at each read ratio, RDMA vs CXL."""
    fig, ax = plt.subplots(figsize=(9, 5.5))

    modes_seen = sorted({k[1] for k in agg})
    rrs = sorted({k[2] for k in agg})

    for mode in modes_seen:
        rdma_vals, cxl_vals, labels = [], [], []
        for rr in rrs:
            labels.append(f"{rr}% read")
            rdma_key = ("rdma", mode, rr, 0.99)
            cxl_key = ("cxl", mode, rr, 0.99)
            rdma_vals.append(median(agg[rdma_key]["lat"]) if rdma_key in agg and agg[rdma_key]["lat"] else 0)
            cxl_vals.append(median(agg[cxl_key]["lat"]) if cxl_key in agg and agg[cxl_key]["lat"] else 0)

        x = range(len(labels))
        offset = BAR_WIDTH / 2
        ax.bar([i - offset for i in x], rdma_vals, BAR_WIDTH, label=f"RDMA ({mode})", color=COLORS["rdma"], alpha=0.85)
        ax.bar([i + offset for i in x], cxl_vals, BAR_WIDTH, label=f"CXL ({mode})", color=COLORS["cxl"], alpha=0.85)

        ax.set_xticks(list(x))
        ax.set_xticklabels(labels)
        ax.set_ylabel("Latency (µs)")
        ax.set_title(f"Latency: RDMA vs CXL — {mode} mode")
        ax.legend()
        ax.grid(axis="y", alpha=0.3)
        fig.tight_layout()
        fig.savefig(os.path.join(outdir, f"lat_vs_readratio_{mode}.png"), dpi=160)
        ax.clear()

    plt.close(fig)


def plot_tp_vs_threads(agg, outdir):
    """Line chart: throughput vs thread count for both transports."""
    fig, ax = plt.subplots(figsize=(9, 5.5))

    for transport in ["rdma", "cxl"]:
        pts = []
        for key, v in agg.items():
            if key[0] == transport and v["tp"]:
                pts.append((v["threads"], median(v["tp"])))
        if not pts:
            continue
        pts.sort()
        # Deduplicate by thread count (take max)
        thread_map = defaultdict(list)
        for t, tp in pts:
            thread_map[t].append(tp)
        xs = sorted(thread_map.keys())
        ys = [max(thread_map[t]) for t in xs]
        ax.plot(xs, ys, marker="o", label=transport.upper(), color=COLORS[transport], linewidth=2)

    ax.set_xlabel("Total Threads")
    ax.set_ylabel("Throughput (Mops/s)")
    ax.set_title("Throughput vs Thread Count: RDMA vs CXL")
    ax.legend()
    ax.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(os.path.join(outdir, "tp_vs_threads.png"), dpi=160)
    plt.close(fig)


def write_summary(rows, agg, outdir):
    """Write a text summary of all runs."""
    total = len(rows)
    ok = sum(1 for r in rows if r["status"] == "ok")
    path = os.path.join(outdir, "summary.txt")
    with open(path, "w") as fp:
        fp.write(f"total_runs: {total}\n")
        fp.write(f"ok_runs: {ok}\n")
        fp.write(f"failed_runs: {total - ok}\n\n")

        fp.write(f"{'Transport':<10} {'Mode':<8} {'RR':<5} {'Zipf':<6} {'Threads':<8} "
                 f"{'TP(Mops)':<12} {'Lat(us)':<12} {'OK/All'}\n")
        fp.write("-" * 85 + "\n")
        for key in sorted(agg.keys()):
            v = agg[key]
            transport, mode, rr, zf = key
            med_tp = f"{median(v['tp']):.3f}" if v["tp"] else "-"
            med_lat = f"{median(v['lat']):.3f}" if v["lat"] else "-"
            fp.write(f"{transport:<10} {mode:<8} {rr:<5} {zf:<6.2f} {v['threads']:<8} "
                     f"{med_tp:<12} {med_lat:<12} {v['ok']}/{v['all']}\n")

    print(f"summary written to {path}")


def write_merged_csv(rows, outdir):
    """Write merged CSV with transport column."""
    path = os.path.join(outdir, "merged.csv")
    if not rows:
        return
    fields = list(rows[0].keys())
    with open(path, "w", newline="") as fp:
        writer = csv.DictWriter(fp, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)
    print(f"merged CSV written to {path}")


def main():
    parser = argparse.ArgumentParser(description="Compare RDMA vs CXL campaign results.")
    parser.add_argument("--rdma-csv", required=True, help="Path to RDMA runs.csv")
    parser.add_argument("--cxl-csv", required=True, help="Path to CXL runs.csv")
    parser.add_argument("--outdir", default="", help="Output directory for plots and summary")
    args = parser.parse_args()

    outdir = args.outdir or os.path.join(os.path.dirname(args.rdma_csv), "comparison")
    os.makedirs(outdir, exist_ok=True)

    rdma_rows = load_rows(args.rdma_csv, "rdma")
    cxl_rows = load_rows(args.cxl_csv, "cxl")
    all_rows = rdma_rows + cxl_rows
    agg = aggregate(all_rows)

    print(f"loaded {len(rdma_rows)} RDMA runs, {len(cxl_rows)} CXL runs")

    write_merged_csv(all_rows, outdir)
    write_summary(all_rows, agg, outdir)
    plot_tp_vs_readratio(agg, outdir)
    plot_lat_vs_readratio(agg, outdir)
    plot_tp_vs_threads(agg, outdir)

    print(f"\nplots and summary written to: {outdir}/")


if __name__ == "__main__":
    main()

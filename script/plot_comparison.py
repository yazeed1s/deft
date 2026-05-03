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
    agg = defaultdict(
        lambda: {
            "tp": [], "lat": [], "ok": 0, "all": 0, "threads": [],
            "cpu": [], "rss": [], "key_space": [],
        }
    )
    for r in rows:
        key = (
            r["transport"],
            r["mode"],
            int(r["read_ratio"]),
            float(r["zipf"]),
        )
        agg[key]["all"] += 1
        thr = int(r.get("total_threads") or 0)
        if thr > 0:
            agg[key]["threads"].append(thr)
        ks = to_float(r.get("key_space"))
        if ks is not None and ks > 0:
            agg[key]["key_space"].append(ks)
        if r["status"] == "ok":
            agg[key]["ok"] += 1
            tp = to_float(r["final_tp_mops"])
            lat = to_float(r["final_lat_us"])
            if tp is not None:
                agg[key]["tp"].append(tp)
            if lat is not None:
                agg[key]["lat"].append(lat)
            cpu = to_float(r.get("cluster_cpu_avg_pct"))
            rss = to_float(r.get("cluster_rss_avg_mb"))
            if cpu is not None:
                agg[key]["cpu"].append(cpu)
            if rss is not None:
                agg[key]["rss"].append(rss)
    return agg


# ── Colors & style ──
COLORS = {"rdma": "#2196F3", "cxl": "#FF5722"}
BAR_WIDTH = 0.35

def p25_p75(vals):
    if not vals:
        return (None, None)
    if len(vals) == 1:
        return (vals[0], vals[0])
    xs = sorted(vals)
    def pct(p):
        idx = (len(xs) - 1) * p
        lo = int(idx)
        hi = min(lo + 1, len(xs) - 1)
        frac = idx - lo
        return xs[lo] * (1 - frac) + xs[hi] * frac
    return pct(0.25), pct(0.75)

def med_iqr(vals):
    if not vals:
        return None, None, None
    med = median(vals)
    p25, p75 = p25_p75(vals)
    return med, p25, p75

def _combo_keys(agg):
    keys = set()
    for (transport, mode, rr, zf) in agg.keys():
        keys.add((mode, rr, zf))
    return sorted(keys, key=lambda x: (x[0], x[1], x[2]))

def plot_metric_combined(agg, outdir, metric, ylabel, filename, title):
    """Single combined grouped-bar plot across all (mode, rr, zipf) permutations."""
    combos = _combo_keys(agg)
    if not combos:
        return

    labels = [f"{m}|rr{rr}|z{zf:.2f}" for (m, rr, zf) in combos]
    rdma_vals, cxl_vals = [], []
    rdma_err_low, rdma_err_high = [], []
    cxl_err_low, cxl_err_high = [], []

    for (mode, rr, zf) in combos:
        rdma_key = ("rdma", mode, rr, zf)
        cxl_key = ("cxl", mode, rr, zf)
        rdma_data = agg[rdma_key][metric] if rdma_key in agg else []
        cxl_data = agg[cxl_key][metric] if cxl_key in agg else []
        rmed, rp25, rp75 = med_iqr(rdma_data)
        cmed, cp25, cp75 = med_iqr(cxl_data)
        rdma_vals.append(rmed if rmed is not None else 0)
        cxl_vals.append(cmed if cmed is not None else 0)
        rdma_err_low.append((rmed - rp25) if rmed is not None else 0)
        rdma_err_high.append((rp75 - rmed) if rmed is not None else 0)
        cxl_err_low.append((cmed - cp25) if cmed is not None else 0)
        cxl_err_high.append((cp75 - cmed) if cmed is not None else 0)

    fig, ax = plt.subplots(figsize=(16, 6))
    x = range(len(labels))
    off = BAR_WIDTH / 2
    ax.bar(
        [i - off for i in x], rdma_vals, BAR_WIDTH, color=COLORS["rdma"],
        label="RDMA (median)", yerr=[rdma_err_low, rdma_err_high], capsize=3
    )
    ax.bar(
        [i + off for i in x], cxl_vals, BAR_WIDTH, color=COLORS["cxl"],
        label="CXL (median)", yerr=[cxl_err_low, cxl_err_high], capsize=3
    )
    ax.set_xticks(list(x))
    ax.set_xticklabels(labels, rotation=45, ha="right")
    ax.set_ylabel(ylabel)
    ax.set_title(title)
    ax.grid(axis="y", alpha=0.3)
    ax.legend()
    fig.tight_layout()
    fig.savefig(os.path.join(outdir, filename), dpi=180)
    plt.close(fig)

def plot_resource_vs_threads(agg, outdir, metric, ylabel, filename, title):
    fig, ax = plt.subplots(figsize=(10, 6))
    plotted = False
    for (transport, mode, rr, zf), v in sorted(agg.items()):
        if not v[metric] or not v["threads"]:
            continue
        t = int(median(v["threads"]))
        m = median(v[metric])
        label = f"{transport.upper()} {mode}|rr{rr}|z{zf:.2f}"
        ax.scatter(
            [t], [m],
            color=COLORS[transport],
            marker="o" if transport == "rdma" else "s",
            s=70,
            alpha=0.85,
            label=label
        )
        plotted = True
    if not plotted:
        plt.close(fig)
        return
    ax.set_xlabel("Total Threads")
    ax.set_ylabel(ylabel)
    ax.set_title(title)
    ax.grid(alpha=0.3)
    handles, labels = ax.get_legend_handles_labels()
    uniq = {}
    for h, l in zip(handles, labels):
        if l not in uniq:
            uniq[l] = h
    ax.legend(list(uniq.values()), list(uniq.keys()), fontsize=8, ncol=2, loc="best")
    fig.tight_layout()
    fig.savefig(os.path.join(outdir, filename), dpi=180)
    plt.close(fig)

def plot_metric_vs_keyspace(agg, outdir, metric, ylabel, filename, title):
    fig, ax = plt.subplots(figsize=(10, 6))
    plotted = False
    for (transport, mode, rr, zf), v in sorted(agg.items()):
        if not v[metric] or not v["key_space"]:
            continue
        ks = median(v["key_space"])
        m = median(v[metric])
        label = f"{transport.upper()} {mode}|rr{rr}|z{zf:.2f}"
        ax.scatter(
            [ks], [m],
            color=COLORS[transport],
            marker="o" if transport == "rdma" else "s",
            s=70,
            alpha=0.85,
            label=label
        )
        plotted = True
    if not plotted:
        plt.close(fig)
        return
    ax.set_xscale("log")
    ax.set_xlabel("Key Space (log scale)")
    ax.set_ylabel(ylabel)
    ax.set_title(title)
    ax.grid(alpha=0.3)
    handles, labels = ax.get_legend_handles_labels()
    uniq = {}
    for h, l in zip(handles, labels):
        if l not in uniq:
            uniq[l] = h
    ax.legend(list(uniq.values()), list(uniq.keys()), fontsize=8, ncol=2, loc="best")
    fig.tight_layout()
    fig.savefig(os.path.join(outdir, filename), dpi=180)
    plt.close(fig)

def plot_tp_vs_threads_combined(agg, outdir):
    """Single combined scatter: throughput vs total threads across all permutations."""
    fig, ax = plt.subplots(figsize=(10, 6))
    plotted = False

    for (transport, mode, rr, zf), v in sorted(agg.items()):
        if not v["tp"] or not v["threads"]:
            continue
        t = int(median(v["threads"]))
        tp = median(v["tp"])
        label = f"{transport.upper()} {mode}|rr{rr}|z{zf:.2f}"
        ax.scatter(
            [t], [tp],
            color=COLORS[transport],
            marker="o" if transport == "rdma" else "s",
            s=70,
            alpha=0.85,
            label=label
        )
        plotted = True

    if not plotted:
        plt.close(fig)
        return

    ax.set_xlabel("Total Threads")
    ax.set_ylabel("Throughput (Mops/s)")
    ax.set_title("Throughput vs Thread Count (All Permutations)")
    ax.grid(alpha=0.3)
    # de-duplicate legend entries
    handles, labels = ax.get_legend_handles_labels()
    uniq = {}
    for h, l in zip(handles, labels):
        if l not in uniq:
            uniq[l] = h
    ax.legend(list(uniq.values()), list(uniq.keys()), fontsize=8, ncol=2, loc="best")
    fig.tight_layout()
    fig.savefig(os.path.join(outdir, "tp_vs_threads_combined.png"), dpi=180)
    plt.close(fig)


def plot_metric_vs_readratio(agg, outdir, metric, ylabel, prefix):
    """Grouped bar chart by read ratio for each (mode, zipf), with IQR error bars."""
    fig, ax = plt.subplots(figsize=(9, 5.5))
    modes_seen = sorted({k[1] for k in agg})
    zipfs_seen = sorted({k[3] for k in agg})
    rrs = sorted({k[2] for k in agg})
    for mode in modes_seen:
        for zf in zipfs_seen:
            rdma_vals, cxl_vals = [], []
            rdma_err_low, rdma_err_high = [], []
            cxl_err_low, cxl_err_high = [], []
            labels = []
            any_data = False
            for rr in rrs:
                labels.append(f"{rr}% read")
                rdma_key = ("rdma", mode, rr, zf)
                cxl_key = ("cxl", mode, rr, zf)
                rdma_data = agg[rdma_key][metric] if rdma_key in agg else []
                cxl_data = agg[cxl_key][metric] if cxl_key in agg else []

                rmed, rp25, rp75 = med_iqr(rdma_data)
                cmed, cp25, cp75 = med_iqr(cxl_data)

                rdma_vals.append(rmed if rmed is not None else 0)
                cxl_vals.append(cmed if cmed is not None else 0)
                rdma_err_low.append((rmed - rp25) if rmed is not None else 0)
                rdma_err_high.append((rp75 - rmed) if rmed is not None else 0)
                cxl_err_low.append((cmed - cp25) if cmed is not None else 0)
                cxl_err_high.append((cp75 - cmed) if cmed is not None else 0)
                any_data = any_data or bool(rdma_data or cxl_data)

            if not any_data:
                continue

            x = range(len(labels))
            offset = BAR_WIDTH / 2
            ax.bar(
                [i - offset for i in x], rdma_vals, BAR_WIDTH,
                label="RDMA (median)", color=COLORS["rdma"], alpha=0.85,
                yerr=[rdma_err_low, rdma_err_high], capsize=3
            )
            ax.bar(
                [i + offset for i in x], cxl_vals, BAR_WIDTH,
                label="CXL (median)", color=COLORS["cxl"], alpha=0.85,
                yerr=[cxl_err_low, cxl_err_high], capsize=3
            )

            ax.set_xticks(list(x))
            ax.set_xticklabels(labels)
            ax.set_ylabel(ylabel)
            ax.set_title(f"{prefix}: RDMA vs CXL — mode={mode}, zipf={zf:.2f}")
            ax.legend()
            ax.grid(axis="y", alpha=0.3)
            fig.tight_layout()
            fig.savefig(
                os.path.join(outdir, f"{metric}_vs_readratio_{mode}_zipf{zf:.2f}.png"),
                dpi=160
            )
            ax.clear()

    plt.close(fig)


def plot_tp_vs_threads(agg, outdir):
    """Line chart: throughput vs thread count for each (mode, zipf)."""
    fig, ax = plt.subplots(figsize=(9, 5.5))
    modes_seen = sorted({k[1] for k in agg})
    zipfs_seen = sorted({k[3] for k in agg})
    for mode in modes_seen:
        for zf in zipfs_seen:
            plotted = False
            for transport in ["rdma", "cxl"]:
                pts = []
                for key, v in agg.items():
                    if key[0] == transport and key[1] == mode and key[3] == zf and v["tp"]:
                        thr = int(median(v["threads"])) if v["threads"] else 0
                        if thr > 0:
                            pts.append((thr, median(v["tp"])))
                if not pts:
                    continue
                plotted = True
                pts.sort()
                thread_map = defaultdict(list)
                for t, tp in pts:
                    thread_map[t].append(tp)
                xs = sorted(thread_map.keys())
                ys = [median(thread_map[t]) for t in xs]
                ax.plot(xs, ys, marker="o", label=transport.upper(),
                        color=COLORS[transport], linewidth=2)

            if plotted:
                ax.set_xlabel("Total Threads")
                ax.set_ylabel("Throughput (Mops/s)")
                ax.set_title(f"Throughput vs Thread Count: mode={mode}, zipf={zf:.2f}")
                ax.legend()
                ax.grid(alpha=0.3)
                fig.tight_layout()
                fig.savefig(
                    os.path.join(outdir, f"tp_vs_threads_{mode}_zipf{zf:.2f}.png"),
                    dpi=160
                )
                ax.clear()
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
        fp.write("aggregation: median with IQR error bars in plots\n")
        fp.write("note: compare rows only when topology/thread-count are equivalent\n\n")

        fp.write(f"{'Transport':<10} {'Mode':<8} {'RR':<5} {'Zipf':<6} {'Threads':<8} "
                 f"{'TP(Mops)':<12} {'Lat(us)':<12} {'OK/All'}\n")
        fp.write("-" * 85 + "\n")
        for key in sorted(agg.keys()):
            v = agg[key]
            transport, mode, rr, zf = key
            med_tp = f"{median(v['tp']):.3f}" if v["tp"] else "-"
            med_lat = f"{median(v['lat']):.3f}" if v["lat"] else "-"
            med_cpu = f"{median(v['cpu']):.2f}" if v["cpu"] else "-"
            med_rss = f"{median(v['rss']):.2f}" if v["rss"] else "-"
            thr = int(median(v["threads"])) if v["threads"] else 0
            fp.write(f"{transport:<10} {mode:<8} {rr:<5} {zf:<6.2f} {thr:<8} "
                     f"{med_tp:<12} {med_lat:<12} cpu={med_cpu:<8} rss_mb={med_rss:<10} {v['ok']}/{v['all']}\n")

        fp.write("\ncomparability_warnings:\n")
        pairs = defaultdict(dict)
        for (transport, mode, rr, zf), v in agg.items():
            if v["threads"]:
                pairs[(mode, rr, zf)][transport] = int(median(v["threads"]))
        warned = False
        for (mode, rr, zf), p in sorted(pairs.items()):
            if "rdma" in p and "cxl" in p and p["rdma"] != p["cxl"]:
                warned = True
                fp.write(
                    f"- mode={mode} rr={rr} zipf={zf:.2f}: "
                    f"thread mismatch rdma={p['rdma']} cxl={p['cxl']}\n"
                )
        if not warned:
            fp.write("- none\n")

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
    # Core performance plots.
    plot_metric_combined(
        agg, outdir, "tp", "Throughput (Mops/s)",
        "throughput_combined.png",
        "Throughput: RDMA vs CXL (All Permutations)"
    )
    plot_metric_combined(
        agg, outdir, "lat", "Latency (µs)",
        "latency_combined.png",
        "Latency: RDMA vs CXL (All Permutations)"
    )
    plot_tp_vs_threads_combined(agg, outdir)
    # Resource plots.
    plot_resource_vs_threads(
        agg, outdir, "cpu", "Cluster CPU (% sum across processes)",
        "cpu_vs_threads_combined.png",
        "CPU vs Thread Count (All Permutations)"
    )
    plot_resource_vs_threads(
        agg, outdir, "rss", "Cluster RSS (MB sum across processes)",
        "rss_vs_threads_combined.png",
        "Memory RSS vs Thread Count (All Permutations)"
    )
    # Key-space sensitivity plots.
    plot_metric_vs_keyspace(
        agg, outdir, "tp", "Throughput (Mops/s)",
        "tp_vs_keyspace_combined.png",
        "Throughput vs Key Space (All Permutations)"
    )
    plot_metric_vs_keyspace(
        agg, outdir, "cpu", "Cluster CPU (% sum across processes)",
        "cpu_vs_keyspace_combined.png",
        "CPU vs Key Space (All Permutations)"
    )
    plot_metric_vs_keyspace(
        agg, outdir, "rss", "Cluster RSS (MB sum across processes)",
        "rss_vs_keyspace_combined.png",
        "RSS vs Key Space (All Permutations)"
    )

    print(f"\nplots and summary written to: {outdir}/")


if __name__ == "__main__":
    main()

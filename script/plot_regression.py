#!/usr/bin/env python3
"""
Plot performance change between two runs (baseline vs candidate).

Inputs can be either:
  1) two merged.csv files (from comparison-* directories), or
  2) two runs.csv files for a single transport.

For merged.csv, regressions are computed independently per transport.

Outputs:
  - delta_throughput_pct.png  (positive is improvement)
  - delta_latency_pct.png     (negative is improvement)
  - regression_summary.csv
"""

import argparse
import csv
import os
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


def load_rows(path, transport_override=None):
    rows = []
    with open(path, newline="") as fp:
        for r in csv.DictReader(fp):
            if transport_override:
                r["transport"] = transport_override
            elif "transport" not in r or not r["transport"]:
                r["transport"] = "single"
            rows.append(r)
    return rows


def aggregate(rows):
    """
    Key = (transport, mode, rr, zipf, threads)
    Value = medians of final throughput/latency over successful repeats.
    """
    buckets = defaultdict(lambda: {"tp": [], "lat": [], "cpu": [], "rss": []})
    for r in rows:
        if r.get("status") != "ok":
            continue
        t = r.get("transport", "single")
        mode = r.get("mode", "")
        rr = int(float(r.get("read_ratio", 0)))
        zf = float(r.get("zipf", 0.0))
        thr = int(float(r.get("total_threads", 0) or 0))
        key = (t, mode, rr, zf, thr)
        tp = to_float(r.get("final_tp_mops"))
        lat = to_float(r.get("final_lat_us"))
        cpu = to_float(r.get("cluster_cpu_avg_pct"))
        rss = to_float(r.get("cluster_rss_avg_mb"))
        if tp is not None:
            buckets[key]["tp"].append(tp)
        if lat is not None:
            buckets[key]["lat"].append(lat)
        if cpu is not None:
            buckets[key]["cpu"].append(cpu)
        if rss is not None:
            buckets[key]["rss"].append(rss)

    out = {}
    for k, v in buckets.items():
        if not v["tp"] or not v["lat"]:
            continue
        out[k] = {
            "tp_med": median(v["tp"]),
            "lat_med": median(v["lat"]),
            "cpu_med": median(v["cpu"]) if v["cpu"] else None,
            "rss_med": median(v["rss"]) if v["rss"] else None,
            "samples": min(len(v["tp"]), len(v["lat"])),
        }
    return out


def pct_change(new, old):
    if old == 0:
        return None
    return (new - old) / old * 100.0


def build_delta(base_agg, cand_agg):
    rows = []
    for k, b in base_agg.items():
        if k not in cand_agg:
            continue
        c = cand_agg[k]
        tp_delta = pct_change(c["tp_med"], b["tp_med"])       # positive = better
        lat_delta = pct_change(c["lat_med"], b["lat_med"])    # negative = better
        if tp_delta is None or lat_delta is None:
            continue
        t, mode, rr, zf, thr = k
        rows.append({
            "transport": t,
            "mode": mode,
            "read_ratio": rr,
            "zipf": zf,
            "threads": thr,
            "baseline_tp_mops": b["tp_med"],
            "candidate_tp_mops": c["tp_med"],
            "delta_tp_pct": tp_delta,
            "baseline_lat_us": b["lat_med"],
            "candidate_lat_us": c["lat_med"],
            "delta_lat_pct": lat_delta,
            "baseline_cpu_pct": b.get("cpu_med"),
            "candidate_cpu_pct": c.get("cpu_med"),
            "delta_cpu_pct": pct_change(c.get("cpu_med"), b.get("cpu_med")) if b.get("cpu_med") not in (None, 0) and c.get("cpu_med") is not None else None,
            "baseline_rss_mb": b.get("rss_med"),
            "candidate_rss_mb": c.get("rss_med"),
            "delta_rss_pct": pct_change(c.get("rss_med"), b.get("rss_med")) if b.get("rss_med") not in (None, 0) and c.get("rss_med") is not None else None,
            "samples_used": min(b["samples"], c["samples"]),
        })
    rows.sort(key=lambda r: (r["transport"], r["mode"], r["read_ratio"], r["zipf"], r["threads"]))
    return rows


def plot_delta(rows, outdir, metric_key, fname, title, ylabel):
    if not rows:
        return
    vals = [r[metric_key] for r in rows if r.get(metric_key) is not None]
    labels = [
        f'{r["transport"]}|{r["mode"]}|rr{r["read_ratio"]}|z{r["zipf"]:.2f}|t{r["threads"]}'
        for r in rows if r.get(metric_key) is not None
    ]
    if not vals:
        return
    colors = ["#2E7D32" if v >= 0 else "#C62828" for v in vals]

    fig, ax = plt.subplots(figsize=(18, 6))
    ax.bar(range(len(vals)), vals, color=colors, alpha=0.9)
    ax.axhline(0, color="black", linewidth=1)
    ax.set_xticks(range(len(vals)))
    ax.set_xticklabels(labels, rotation=50, ha="right")
    ax.set_title(title)
    ax.set_ylabel(ylabel)
    ax.grid(axis="y", alpha=0.3)
    fig.tight_layout()
    fig.savefig(os.path.join(outdir, fname), dpi=180)
    plt.close(fig)


def write_csv(rows, outdir):
    path = os.path.join(outdir, "regression_summary.csv")
    fields = [
        "transport", "mode", "read_ratio", "zipf", "threads",
        "baseline_tp_mops", "candidate_tp_mops", "delta_tp_pct",
        "baseline_lat_us", "candidate_lat_us", "delta_lat_pct",
        "baseline_cpu_pct", "candidate_cpu_pct", "delta_cpu_pct",
        "baseline_rss_mb", "candidate_rss_mb", "delta_rss_pct",
        "samples_used",
    ]
    with open(path, "w", newline="") as fp:
        w = csv.DictWriter(fp, fieldnames=fields)
        w.writeheader()
        for r in rows:
            w.writerow(r)
    return path


def main():
    ap = argparse.ArgumentParser(description="Plot regression between baseline and candidate runs.")
    ap.add_argument("--baseline-csv", required=True, help="baseline merged.csv or runs.csv")
    ap.add_argument("--candidate-csv", required=True, help="candidate merged.csv or runs.csv")
    ap.add_argument("--outdir", required=True, help="output directory")
    ap.add_argument("--transport", default="", help="force transport name if using runs.csv (e.g., rdma)")
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)

    b_rows = load_rows(args.baseline_csv, args.transport or None)
    c_rows = load_rows(args.candidate_csv, args.transport or None)

    b_agg = aggregate(b_rows)
    c_agg = aggregate(c_rows)
    delta = build_delta(b_agg, c_agg)

    csv_path = write_csv(delta, args.outdir)
    plot_delta(
        delta, args.outdir, "delta_tp_pct", "delta_throughput_pct.png",
        "Throughput Change: Candidate vs Baseline", "Δ Throughput (%)  (+ better)"
    )
    plot_delta(
        delta, args.outdir, "delta_lat_pct", "delta_latency_pct.png",
        "Latency Change: Candidate vs Baseline", "Δ Latency (%)  (- better)"
    )
    plot_delta(
        delta, args.outdir, "delta_cpu_pct", "delta_cpu_pct.png",
        "CPU Change: Candidate vs Baseline", "Δ CPU (%)  (- better)"
    )
    plot_delta(
        delta, args.outdir, "delta_rss_pct", "delta_rss_pct.png",
        "Memory RSS Change: Candidate vs Baseline", "Δ RSS (%)  (- better)"
    )

    print(f"baseline points: {len(b_agg)}")
    print(f"candidate points: {len(c_agg)}")
    print(f"overlap points: {len(delta)}")
    print(f"summary csv: {csv_path}")
    print(f"plots: {args.outdir}")


if __name__ == "__main__":
    main()

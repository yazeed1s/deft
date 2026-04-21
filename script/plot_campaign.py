#!/usr/bin/env python3

import argparse
import csv
import os
from collections import defaultdict
from statistics import median

import matplotlib.pyplot as plt


def load_rows(csv_path):
    rows = []
    with open(csv_path, newline="") as fp:
        for r in csv.DictReader(fp):
            rows.append(r)
    return rows


def to_float(v):
    try:
        return float(v)
    except Exception:
        return None


def aggregate_ok(rows):
    agg = defaultdict(lambda: {"tp": [], "lat": [], "ok": 0, "all": 0})
    for r in rows:
        key = (
            r["mode"],
            int(r["read_ratio"]),
            float(r["zipf"]),
            int(r["total_threads"] or 0),
        )
        agg[key]["all"] += 1
        if r["status"] == "ok":
            agg[key]["ok"] += 1
            tp = to_float(r["final_tp_mops"])
            lat = to_float(r["final_lat_us"])
            if tp is not None:
                agg[key]["tp"].append(tp)
            if lat is not None:
                agg[key]["lat"].append(lat)
    return agg


def plot_metric(agg, out_path, metric):
    plt.figure(figsize=(8.5, 5))
    grouped = defaultdict(list)
    for (mode, rr, zf, threads), v in agg.items():
        if not v[metric]:
            continue
        y = median(v[metric])
        grouped[(mode, rr, zf)].append((threads, y))

    for key, pts in sorted(grouped.items()):
        mode, rr, zf = key
        pts.sort()
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        label = f"{mode} rr={rr} z={zf}"
        plt.plot(xs, ys, marker="o", label=label)

    plt.xlabel("Total Threads")
    if metric == "tp":
        plt.ylabel("Median Final Throughput (Mops/s)")
        plt.title("Final Throughput vs Total Threads")
    else:
        plt.ylabel("Median Final Latency (us)")
        plt.title("Final Latency vs Total Threads")
    plt.grid(True, alpha=0.3)
    if len(grouped) <= 10:
        plt.legend(fontsize=8)
    plt.tight_layout()
    plt.savefig(out_path, dpi=160)
    plt.close()


def write_summary(rows, agg, out_path):
    total = len(rows)
    ok = sum(1 for r in rows if r["status"] == "ok")
    fail = total - ok
    with open(out_path, "w") as fp:
        fp.write(f"total_runs: {total}\n")
        fp.write(f"ok_runs: {ok}\n")
        fp.write(f"failed_runs: {fail}\n")
        fp.write("\n# per-case summary (mode,read_ratio,zipf,total_threads)\n")
        for key in sorted(agg.keys()):
            v = agg[key]
            med_tp = median(v["tp"]) if v["tp"] else None
            med_lat = median(v["lat"]) if v["lat"] else None
            fp.write(
                f"{key}: success={v['ok']}/{v['all']}, "
                f"median_final_tp={med_tp}, median_final_lat={med_lat}\n"
            )


def main():
    parser = argparse.ArgumentParser(description="Plot minimal campaign figures.")
    parser.add_argument("--csv", required=True, help="path to campaign runs.csv")
    parser.add_argument("--outdir", default="", help="plots output dir (default: sibling plots/)")
    args = parser.parse_args()

    rows = load_rows(args.csv)
    agg = aggregate_ok(rows)

    base = args.outdir or os.path.join(os.path.dirname(args.csv), "plots")
    os.makedirs(base, exist_ok=True)

    plot_metric(agg, os.path.join(base, "final_tp_vs_threads.png"), "tp")
    plot_metric(agg, os.path.join(base, "final_lat_vs_threads.png"), "lat")
    write_summary(rows, agg, os.path.join(base, "summary.txt"))

    print(f"plots written to: {base}")


if __name__ == "__main__":
    main()

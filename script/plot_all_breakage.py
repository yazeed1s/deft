#!/usr/bin/env python3
import argparse
import csv
import glob
import os
from collections import defaultdict
from statistics import median

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

COLORS = {"rdma": "#2196F3", "cxl": "#FF5722"}


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


def pctl(vals, p):
    xs = sorted(vals)
    if not xs:
        return None
    if len(xs) == 1:
        return xs[0]
    pos = (len(xs) - 1) * p
    lo = int(pos)
    hi = min(lo + 1, len(xs) - 1)
    w = pos - lo
    return xs[lo] * (1 - w) + xs[hi] * w


def iqr_filter(vals):
    if len(vals) < 4:
        return vals[:]
    q1 = pctl(vals, 0.25)
    q3 = pctl(vals, 0.75)
    iqr = q3 - q1
    lo = q1 - 1.5 * iqr
    hi = q3 + 1.5 * iqr
    out = [v for v in vals if lo <= v <= hi]
    return out if out else vals[:]


def med_iqr(vals):
    if not vals:
        return None, None, None
    return median(vals), pctl(vals, 0.25), pctl(vals, 0.75)


def read_runs(path, transport=None, phase=None):
    rows = []
    with open(path, newline="") as fp:
        for r in csv.DictReader(fp):
            if r.get("status") != "ok":
                continue
            tr = transport or r.get("transport", "")
            rows.append({
                "transport": tr,
                "phase": phase,
                "mode": (r.get("mode") or "").strip(),
                "rr": to_int(r.get("read_ratio")),
                "zipf": to_float(r.get("zipf")),
                "threads": to_int(r.get("total_threads")),
                "key_space": to_int(r.get("key_space")),
                "tp": to_float(r.get("final_tp_mops")),
                "lat": to_float(r.get("final_lat_us")),
                "cpu": to_float(r.get("cluster_cpu_avg_pct")),
                "rss": to_float(r.get("cluster_rss_avg_mb")),
            })
    return [r for r in rows if r["tp"] is not None and r["lat"] is not None]


def ensure_dir(d):
    os.makedirs(d, exist_ok=True)


def plot_grouped_mode_zipf(rows, metric, ylabel, title, out_png):
    combos = sorted({(r["mode"], r["zipf"]) for r in rows if r.get("mode") and r.get("zipf") is not None})
    labels = [f"{m}|z{z:.2f}" for m, z in combos]
    rd, cx, rd_lo, rd_hi, cx_lo, cx_hi = [], [], [], [], [], []
    for m, z in combos:
        rv = [r[metric] for r in rows if r["transport"] == "rdma" and r["mode"] == m and r["zipf"] == z and r.get(metric) is not None]
        cv = [r[metric] for r in rows if r["transport"] == "cxl" and r["mode"] == m and r["zipf"] == z and r.get(metric) is not None]
        rv, cv = iqr_filter(rv), iqr_filter(cv)
        rm, r25, r75 = med_iqr(rv)
        cm, c25, c75 = med_iqr(cv)
        rd.append(rm or 0.0); cx.append(cm or 0.0)
        rd_lo.append((rm - r25) if rm is not None else 0.0); rd_hi.append((r75 - rm) if rm is not None else 0.0)
        cx_lo.append((cm - c25) if cm is not None else 0.0); cx_hi.append((c75 - cm) if cm is not None else 0.0)

    fig, ax = plt.subplots(figsize=(14, 6))
    x = list(range(len(labels))); w = 0.36
    ax.bar([i - w/2 for i in x], rd, w, yerr=[rd_lo, rd_hi], capsize=3, label="RDMA", color=COLORS["rdma"])
    ax.bar([i + w/2 for i in x], cx, w, yerr=[cx_lo, cx_hi], capsize=3, label="CXL", color=COLORS["cxl"])
    ax.set_xticks(x); ax.set_xticklabels(labels, rotation=35, ha="right")
    ax.set_ylabel(ylabel); ax.set_title(title); ax.grid(axis="y", alpha=0.3); ax.legend()
    fig.tight_layout(); fig.savefig(out_png, dpi=180); plt.close(fig)


def plot_line_by_threads(rows, metric, ylabel, title, out_png):
    fig, ax = plt.subplots(figsize=(10, 6))
    for t, mk in (("rdma", "o"), ("cxl", "s")):
        ag = defaultdict(list)
        for r in rows:
            if r["transport"] == t and r.get("threads") is not None and r.get(metric) is not None:
                ag[r["threads"]].append(r[metric])
        xs = sorted(ag.keys())
        ys = [median(iqr_filter(ag[x])) for x in xs]
        if xs:
            ax.plot(xs, ys, marker=mk, linewidth=2, label=t.upper(), color=COLORS[t])
    ax.set_xlabel("Total Threads"); ax.set_ylabel(ylabel); ax.set_title(title); ax.grid(alpha=0.3); ax.legend()
    fig.tight_layout(); fig.savefig(out_png, dpi=180); plt.close(fig)


def plot_hist(rows, metric, xlabel, title, out_png):
    fig, ax = plt.subplots(figsize=(10, 6))
    for t in ("rdma", "cxl"):
        vals = [r[metric] for r in rows if r["transport"] == t and r.get(metric) is not None]
        vals = iqr_filter(vals)
        ax.hist(vals, bins=20, density=True, alpha=0.45, label=t.upper(), color=COLORS[t], edgecolor="black", linewidth=0.4)
    ax.set_xlabel(xlabel); ax.set_ylabel("Density"); ax.set_title(title); ax.grid(alpha=0.25); ax.legend()
    fig.tight_layout(); fig.savefig(out_png, dpi=180); plt.close(fig)


def plot_line_by_keyspace(rows, metric, ylabel, title, out_png):
    fig, ax = plt.subplots(figsize=(10, 6))
    for t, mk in (("rdma", "o"), ("cxl", "s")):
        ag = defaultdict(list)
        for r in rows:
            if r["transport"] == t and r.get("key_space") is not None and r.get(metric) is not None:
                ag[r["key_space"]].append(r[metric])
        xs = sorted(ag.keys())
        ys = [median(iqr_filter(ag[x])) for x in xs]
        if xs:
            ax.plot(xs, ys, marker=mk, linewidth=2, label=t.upper(), color=COLORS[t])
    ax.set_xscale("log"); ax.set_xlabel("Key Space (log scale)"); ax.set_ylabel(ylabel); ax.set_title(title); ax.grid(alpha=0.3); ax.legend()
    fig.tight_layout(); fig.savefig(out_png, dpi=180); plt.close(fig)


def plot_small_multiples_phase_e(rows, metric, ylabel, title_prefix, out_png):
    zfs = sorted({r["zipf"] for r in rows if r.get("zipf") is not None})
    fig, axs = plt.subplots(2, 2, figsize=(12, 8), squeeze=False, sharey=True)
    for idx, zf in enumerate(zfs[:4]):
        ax = axs[idx // 2][idx % 2]
        for t, mk in (("rdma", "o"), ("cxl", "s")):
            ag = defaultdict(list)
            for r in rows:
                if r["transport"] == t and r.get("zipf") == zf and r.get("rr") is not None and r.get(metric) is not None:
                    ag[r["rr"]].append(r[metric])
            xs = sorted(ag.keys())
            ys = [median(iqr_filter(ag[x])) for x in xs]
            if xs:
                ax.plot(xs, ys, marker=mk, linewidth=2, label=t.upper(), color=COLORS[t])
        ax.set_title(f"zipf={zf:.3f}")
        ax.set_xlabel("Read Ratio")
        ax.grid(alpha=0.25)
    axs[0][0].set_ylabel(ylabel)
    handles, labels = axs[0][0].get_legend_handles_labels()
    if handles:
        fig.legend(handles, labels, loc="upper center", ncol=2)
    fig.suptitle(title_prefix)
    fig.tight_layout(rect=[0, 0, 1, 0.95])
    fig.savefig(out_png, dpi=180); plt.close(fig)


def plot_phase_e_tp_vs_keyspace_by_rr(rows, out_png):
    rrs = sorted({r["rr"] for r in rows if r.get("rr") is not None})
    fig, axs = plt.subplots(2, 2, figsize=(12, 8), squeeze=False, sharey=True)
    for idx, rr in enumerate(rrs[:4]):
        ax = axs[idx // 2][idx % 2]
        for t, mk in (("rdma", "o"), ("cxl", "s")):
            ag = defaultdict(list)
            for r in rows:
                if r["transport"] == t and r.get("rr") == rr and r.get("key_space") is not None and r.get("tp") is not None:
                    ag[r["key_space"]].append(r["tp"])
            xs = sorted(ag.keys())
            ys = [median(iqr_filter(ag[x])) for x in xs]
            if xs:
                ax.plot(xs, ys, marker=mk, linewidth=2, label=t.upper(), color=COLORS[t])
        ax.set_xscale("log")
        ax.set_title(f"rr={rr}")
        ax.set_xlabel("Key Space")
        ax.grid(alpha=0.25)
    axs[0][0].set_ylabel("Throughput (Mops/s)")
    handles, labels = axs[0][0].get_legend_handles_labels()
    if handles:
        fig.legend(handles, labels, loc="upper center", ncol=2)
    fig.suptitle("Phase E: Throughput vs Key Space (by Read Ratio)")
    fig.tight_layout(rect=[0, 0, 1, 0.95]); fig.savefig(out_png, dpi=180); plt.close(fig)


def plot_bridge(v4_rows, stress_rows, out_png):
    # Overlay baseline medians vs stress IQR envelope for TP and Lat.
    tp_base = [r["tp"] for r in v4_rows if r.get("tp") is not None]
    lat_base = [r["lat"] for r in v4_rows if r.get("lat") is not None]
    tp_st = [r["tp"] for r in stress_rows if r.get("tp") is not None]
    lat_st = [r["lat"] for r in stress_rows if r.get("lat") is not None]
    tp_base = iqr_filter(tp_base); lat_base = iqr_filter(lat_base)
    tp_st = iqr_filter(tp_st); lat_st = iqr_filter(lat_st)

    fig, axs = plt.subplots(1, 2, figsize=(12, 4.8))
    for ax, base, st, name in [(axs[0], tp_base, tp_st, "Throughput (Mops/s)"), (axs[1], lat_base, lat_st, "Latency (us)")]:
        bm = median(base); sm = median(st)
        s25, s75 = pctl(st, 0.25), pctl(st, 0.75)
        ax.bar([0], [bm], width=0.5, color="#4caf50", label="v4 median")
        ax.bar([1], [sm], width=0.5, color="#607d8b", label="stress median")
        ax.vlines([1], [s25], [s75], colors="black", linewidth=3, label="stress IQR")
        ax.set_xticks([0, 1]); ax.set_xticklabels(["Baseline v4", "Stress v6+v7"])
        ax.set_title(name)
        ax.grid(axis="y", alpha=0.3)
    handles, labels = axs[0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="upper center", ncol=3)
    fig.suptitle("Baseline vs Stress Envelope")
    fig.tight_layout(rect=[0, 0, 1, 0.92]); fig.savefig(out_png, dpi=180); plt.close(fig)


def load_all(v4_root, v6_root, v7_root):
    v4 = []
    v4 += read_runs(glob.glob(os.path.join(v4_root, "rdma-campaign-*", "runs.csv"))[0], "rdma", "baseline")
    v4 += read_runs(glob.glob(os.path.join(v4_root, "cxl-campaign-*", "runs.csv"))[0], "cxl", "baseline")

    # stress ABC
    abc = []
    abc += read_runs(glob.glob(os.path.join(v6_root, "rdma-phaseA-*", "runs.csv"))[0], "rdma", "phaseA")
    abc += read_runs(glob.glob(os.path.join(v6_root, "cxl-phaseA-*", "runs.csv"))[0], "cxl", "phaseA")
    abc += read_runs(glob.glob(os.path.join(v6_root, "rdma-phaseB-*", "runs.csv"))[0], "rdma", "phaseB")
    abc += read_runs(glob.glob(os.path.join(v6_root, "cxl-phaseB-*", "runs.csv"))[0], "cxl", "phaseB")
    phasec = glob.glob(os.path.join(v6_root, "phaseC-*"))[0]
    for p in glob.glob(os.path.join(phasec, "rdma", "**", "runs.csv"), recursive=True):
        abc += read_runs(p, "rdma", "phaseC")
    for p in glob.glob(os.path.join(phasec, "cxl", "**", "runs.csv"), recursive=True):
        abc += read_runs(p, "cxl", "phaseC")

    # stress D/E from top-level merged runs
    d = []
    d += read_runs(glob.glob(os.path.join(v7_root, "rdma-phaseD-*", "runs.csv"))[0], "rdma", "phaseD")
    d += read_runs(glob.glob(os.path.join(v7_root, "cxl-phaseD-*", "runs.csv"))[0], "cxl", "phaseD")
    e = []
    e += read_runs(glob.glob(os.path.join(v7_root, "rdma-phaseE-*", "runs.csv"))[0], "rdma", "phaseE")
    e += read_runs(glob.glob(os.path.join(v7_root, "cxl-phaseE-*", "runs.csv"))[0], "cxl", "phaseE")
    return v4, abc, d, e


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--v4-root", default="deft-resultsv4")
    ap.add_argument("--v6-root", default="deft-resultsv6")
    ap.add_argument("--v7-root", default="deft-resultsv7")
    ap.add_argument("--outdir", required=True)
    args = ap.parse_args()

    ensure_dir(args.outdir)
    bdir = os.path.join(args.outdir, "baseline_plots")
    sdir = os.path.join(args.outdir, "stress_plots")
    xdir = os.path.join(args.outdir, "bridge_plots")
    ensure_dir(bdir); ensure_dir(sdir); ensure_dir(xdir)

    v4, abc, d, e = load_all(args.v4_root, args.v6_root, args.v7_root)

    # baseline B1-B6
    plot_grouped_mode_zipf(v4, "tp", "Throughput (Mops/s)", "B1 Throughput by (mode, zipf)", os.path.join(bdir, "B1_tp_mode_zipf.png"))
    plot_grouped_mode_zipf(v4, "lat", "Latency (us)", "B2 Latency by (mode, zipf)", os.path.join(bdir, "B2_lat_mode_zipf.png"))
    plot_grouped_mode_zipf(v4, "cpu", "Cluster CPU (%)", "B3 CPU by (mode, zipf)", os.path.join(bdir, "B3_cpu_mode_zipf.png"))
    plot_grouped_mode_zipf(v4, "rss", "Cluster RSS (MB)", "B4 RSS by (mode, zipf)", os.path.join(bdir, "B4_rss_mode_zipf.png"))
    plot_line_by_threads(v4, "tp", "Throughput (Mops/s)", "B5 Throughput vs Threads", os.path.join(bdir, "B5_tp_threads.png"))
    plot_line_by_threads(v4, "lat", "Latency (us)", "B6 Latency vs Threads", os.path.join(bdir, "B6_lat_threads.png"))

    # stress S1-S10
    plot_hist(abc, "tp", "Throughput (Mops/s)", "S1 Phase A/B/C Throughput Distribution", os.path.join(sdir, "S1_abc_tp_hist.png"))
    plot_hist(abc, "lat", "Latency (us)", "S2 Phase A/B/C Latency Distribution", os.path.join(sdir, "S2_abc_lat_hist.png"))
    phasec_rows = [r for r in abc if r["phase"] == "phaseC"]
    plot_line_by_threads(phasec_rows, "tp", "Throughput (Mops/s)", "S3 Phase C Throughput vs Total Threads", os.path.join(sdir, "S3_phasec_tp_threads.png"))
    plot_line_by_threads(phasec_rows, "lat", "Latency (us)", "S4 Phase C Latency vs Total Threads", os.path.join(sdir, "S4_phasec_lat_threads.png"))
    plot_line_by_keyspace(d, "tp", "Throughput (Mops/s)", "S5 Phase D Throughput vs Key Space", os.path.join(sdir, "S5_phased_tp_keyspace.png"))
    plot_line_by_keyspace(d, "cpu", "Cluster CPU (%)", "S6 Phase D CPU vs Key Space", os.path.join(sdir, "S6_phased_cpu_keyspace.png"))
    plot_line_by_keyspace(d, "rss", "Cluster RSS (MB)", "S7 Phase D RSS vs Key Space", os.path.join(sdir, "S7_phased_rss_keyspace.png"))
    plot_small_multiples_phase_e(e, "tp", "Throughput (Mops/s)", "S8 Phase E Throughput vs Read Ratio (by zipf)", os.path.join(sdir, "S8_phasee_tp_rr_zipf.png"))
    plot_small_multiples_phase_e(e, "lat", "Latency (us)", "S9 Phase E Latency vs Read Ratio (by zipf)", os.path.join(sdir, "S9_phasee_lat_rr_zipf.png"))
    plot_phase_e_tp_vs_keyspace_by_rr(e, os.path.join(sdir, "S10_phasee_tp_keyspace_rr.png"))

    # bridge X1
    plot_bridge(v4, abc + d + e, os.path.join(xdir, "X1_baseline_vs_stress_envelope.png"))

    with open(os.path.join(args.outdir, "manifest.txt"), "w") as fp:
        fp.write("outlier_filter=IQR_1.5x_per_series\n")
        fp.write(f"baseline_rows={len(v4)}\n")
        fp.write(f"stress_abc_rows={len(abc)}\n")
        fp.write(f"stress_d_rows={len(d)}\n")
        fp.write(f"stress_e_rows={len(e)}\n")

    print(f"baseline rows: {len(v4)}")
    print(f"stress rows: {len(abc) + len(d) + len(e)}")
    print(f"outdir: {args.outdir}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3

import argparse
import csv
import os
import re
import subprocess
import sys
import time
from datetime import datetime


LINE_LOAD = re.compile(r"Loading Results TP:\s*([0-9.]+)\s*Mops/s Lat:\s*([0-9.]+)\s*us")
LINE_FINAL = re.compile(r"Final Results:\s*TP:\s*([0-9.]+)\s*Mops/s Lat:\s*([0-9.]+)\s*us")
LINE_DONE = re.compile(r"done\.\s+saved to\s+(.+)")
LINE_JOB = re.compile(
    r"starting job \d+/\d+: total_threads=(\d+) .* key_space=(\d+) read_ratio=([0-9.]+) zipf=([0-9.]+)"
)
LINE_FAIL = re.compile(r"(server|client)\s+(\d+)\s+failed with exit code\s+(-?\d+)")


def parse_list_int(s):
    return [int(x.strip()) for x in s.split(",") if x.strip()]


def parse_list_float(s):
    return [float(x.strip()) for x in s.split(",") if x.strip()]


def parse_modes(s):
    modes = [x.strip() for x in s.split(",") if x.strip()]
    valid = {"smoke", "small", "mid", "big"}
    bad = [m for m in modes if m not in valid]
    if bad:
        raise ValueError(f"invalid mode(s): {bad}")
    return modes


def run_one(script_dir, mode, rr, zf, repeat_id, force_hugepage, run_name):
    cmd = [
        "python3",
        "run_bench.py",
        f"--{mode}",
        "--read-ratio",
        str(rr),
        "--zipf",
        str(zf),
        "--name",
        run_name,
    ]
    if force_hugepage:
        cmd.append("--force-hugepage")

    t0 = time.time()
    proc = subprocess.run(
        cmd,
        cwd=script_dir,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        universal_newlines=True,
    )
    dt = time.time() - t0
    out = proc.stdout or ""

    m_load = LINE_LOAD.search(out)
    m_final = LINE_FINAL.search(out)
    m_done = LINE_DONE.search(out)
    m_job = LINE_JOB.search(out)
    m_fail = LINE_FAIL.search(out)

    row = {
        "timestamp": datetime.now().isoformat(timespec="seconds"),
        "mode": mode,
        "read_ratio": rr,
        "zipf": zf,
        "repeat": repeat_id,
        "force_hugepage": int(force_hugepage),
        "status": "ok",
        "exit_code": proc.returncode,
        "failure_signature": "",
        "total_threads": "",
        "key_space": "",
        "loading_tp_mops": "",
        "loading_lat_us": "",
        "final_tp_mops": "",
        "final_lat_us": "",
        "elapsed_sec": f"{dt:.2f}",
        "result_file": m_done.group(1).strip() if m_done else "",
    }

    if m_job:
        row["total_threads"] = m_job.group(1)
        row["key_space"] = m_job.group(2)

    if m_load:
        row["loading_tp_mops"] = m_load.group(1)
        row["loading_lat_us"] = m_load.group(2)
    if m_final:
        row["final_tp_mops"] = m_final.group(1)
        row["final_lat_us"] = m_final.group(2)

    if proc.returncode != 0 or not m_final:
        row["status"] = "fail"
        if m_fail:
            row["failure_signature"] = f"{m_fail.group(1)}_{m_fail.group(2)}_exit_{m_fail.group(3)}"
        elif proc.returncode != 0:
            row["failure_signature"] = f"run_bench_exit_{proc.returncode}"
        else:
            row["failure_signature"] = "missing_final_results"

    return row, out


def main():
    parser = argparse.ArgumentParser(description="Run a benchmark campaign and store structured results.")
    parser.add_argument("--modes", type=parse_modes, default=["smoke", "mid", "big"],
                        help="comma list: smoke,small,mid,big")
    parser.add_argument("--read-ratios", type=parse_list_int, default=[50],
                        help="comma list, e.g. 0,50,100")
    parser.add_argument("--zipfs", type=parse_list_float, default=[0.99],
                        help="comma list, e.g. 0.0,0.8,0.99")
    parser.add_argument("--repeats", type=int, default=3, help="repeats per (mode,read_ratio,zipf)")
    parser.add_argument("--force-hugepage", action="store_true", help="pass --force-hugepage to run_bench.py")
    parser.add_argument("--outdir", type=str, default="", help="output directory")
    args = parser.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    root_dir = os.path.dirname(script_dir)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    outdir = args.outdir or os.path.join(root_dir, "result", f"campaign-{stamp}")
    logs_dir = os.path.join(outdir, "logs")
    os.makedirs(logs_dir, exist_ok=True)

    csv_path = os.path.join(outdir, "runs.csv")
    fields = [
        "timestamp", "mode", "read_ratio", "zipf", "repeat", "force_hugepage",
        "status", "exit_code", "failure_signature",
        "total_threads", "key_space",
        "loading_tp_mops", "loading_lat_us",
        "final_tp_mops", "final_lat_us",
        "elapsed_sec", "result_file",
    ]

    with open(csv_path, "w", newline="") as fp:
        writer = csv.DictWriter(fp, fieldnames=fields)
        writer.writeheader()

        total = len(args.modes) * len(args.read_ratios) * len(args.zipfs) * args.repeats
        idx = 0
        for mode in args.modes:
            for rr in args.read_ratios:
                for zf in args.zipfs:
                    for rep in range(1, args.repeats + 1):
                        idx += 1
                        run_name = f"campaign-{mode}-rr{rr}-z{zf}-r{rep}"
                        print(
                            f"[{idx}/{total}] mode={mode} rr={rr} zipf={zf} rep={rep} "
                            f"force_hugepage={int(args.force_hugepage)}"
                        )
                        row, raw = run_one(
                            script_dir=script_dir,
                            mode=mode,
                            rr=rr,
                            zf=zf,
                            repeat_id=rep,
                            force_hugepage=args.force_hugepage,
                            run_name=run_name,
                        )
                        writer.writerow(row)
                        fp.flush()

                        log_path = os.path.join(logs_dir, f"{idx:03d}-{run_name}.log")
                        with open(log_path, "w") as lf:
                            lf.write(raw)

                        status = row["status"]
                        final_tp = row["final_tp_mops"] or "-"
                        final_lat = row["final_lat_us"] or "-"
                        print(f"  -> status={status} final_tp={final_tp} final_lat={final_lat}")

    print(f"\nDone. CSV: {csv_path}")
    print(f"Logs: {logs_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/bin/bash
set -e

cd /deft_code/deft/script

if [[ ! -f "global_config.yaml" ]]; then
    echo "yaml config not found. running gen_config.py..."
    python3 gen_config.py
fi

echo "setting hugepages on all nodes..."
sudo sysctl -w vm.nr_hugepages=16384 || true
sudo sysctl -w kernel.watchdog_thresh=120 || true
python3 all_hugepage.py

echo "running benchmarks..."
python3 run_bench.py "$@"

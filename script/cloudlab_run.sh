#!/bin/bash
set -e

cd /mydata/deft/script

if [[ ! -f "global_config.yaml" ]]; then
    echo "yaml config not found. running gen_config.py..."
    python3 gen_config.py
fi

echo "setting hugepages on all nodes..."
python3 all_hugepage.py

echo "running benchmarks..."
python3 run_bench.py "$@"

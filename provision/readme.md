# deft reproduction scripts

Scripts to set up and run deft on CloudLab (Utah cluster, d6515 machines).

## Setup

8 nodes total: 2 memory nodes (mn0, mn1) and 6 compute nodes (cn0–cn5).

| Script | Run on | Purpose |
|---|---|---|
| `setup_all.sh` | all 3 nodes | Install RDMA drivers, dependencies, mount NFS |
| `setup_mn.sh` | mn0 only | Clone repo, build deft, start memcached |
| `run_servers.sh` | mn0, mn1 | Start deft server process |
| `run_clients.sh` | cn0–cn5 | Start deft client process |

## Usage

Get mn0's IP from the CloudLab experiment page, then:

```bash
# 1. on mn0 first (install deps, RDMA drivers; skips NFS self-mount automatically)
bash setup_all.sh <mn0-ip>

# 2. on mn0 (clone repo, build deft, start memcached)
bash setup_mn.sh

# 3. on remaining 7 nodes in parallel (install deps, mount NFS)
bash setup_all.sh <mn0-ip>

# 4. on mn0 and mn1
bash run_servers.sh

# 5. on cn0–cn5
bash run_clients.sh
```

## Notes

- **MLNX_OFED version**: Must use 4.9-5.1.0.0. Version 5.x requires source modifications.
- **NFS**: The repo is cloned to `/mydata` on mn0 and shared via NFS so the binary only needs to be built once.
- **Memcached**: Used for exchanging RDMA queue pair (QP) info between nodes during connection setup.
- **Huge pages**: Configured automatically by the setup scripts.

## Workloads

Use the `run_bench.py` script in `deft/script/` to run YCSB workloads (A–E). Edit parameters in that file for thread count, workload type, etc. All workloads use 400M keys with zipfian distribution (skew=0.99).

## Troubleshooting

- **OFED download fails**: Mellanox sometimes changes download links — check their site.
- **NFS mount fails**: Make sure `setup_mn.sh` finishes before running `setup_all.sh`.
- **Memcached not running**: `ps aux | grep memcached` on mn0.
- **RDMA not working**: `ibv_devinfo` — NIC should show `PORT_ACTIVE`.
- **Huge pages not set**: `cat /proc/meminfo | grep Huge`.

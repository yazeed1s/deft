# deft reproduction scripts

Scripts to set up and run deft on CloudLab (Utah cluster, d6515 machines).

## Setup

3 nodes total: 1 memory node (mn0) and 2 compute nodes (cn0, cn1).

| Script | Run on | Purpose |
|---|---|---|
| `setup_all.sh` | all 3 nodes | Install RDMA drivers, dependencies, mount NFS |
| `setup_mn.sh` | mn0 only | Clone repo, build deft, start memcached |
| `run_servers.sh` | mn0 | Start deft server process |
| `run_clients.sh` | cn0, cn1 | Start deft client process |

## Usage

Get mn0's IP from the CloudLab experiment page, then:

```bash
# on mn0 first (sets up NFS server, clones and builds deft)
bash setup_mn.sh

# on all 3 nodes (installs RDMA, deps; skips NFS mount on mn0 automatically)
bash setup_all.sh <mn0-ip>

# on mn0
bash run_servers.sh

# on cn0, cn1
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

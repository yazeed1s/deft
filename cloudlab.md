# CloudLab Guide for DEFT

How to run DEFT on CloudLab using scripts in `script/` folder.

## 1. Setup
- **Memory Nodes (mn0, mn1...)**: Keep index memory. Target for RDMA.
- **Compute Nodes (cn0, cn1...)**: Run client threads.
- **Shared Folder**: Profile mounts `/mydata` from `mn0` to all nodes using NFS. Code should be run from `/mydata/deft`.
- **Memcached**: Runs on `mn0`. Used for RDMA queue pairs connect.

## 2. CloudLab Profile
Use `profile.py` in this repo on CloudLab website. 
- You can change `NUM_MN` and `NUM_CN` in the web UI. 
- 2 MN and 6 CN is good for default test.
- Choose `d6515` or `r650` nodes (needs Mellanox NIC).
- Profile will install packages (cmake, memcached, etc) and mount NFS for you during boot.

## 3. First Setup Script
When CloudLab says "Ready", SSH into `mn0`.

Run this script on `mn0`:
```bash
sudo ./script/cloudlab_setup.sh
```
This script will:
1. Check if RDMA works (`ibv_devinfo`).
2. Copy code to `/mydata/deft`.
3. Install `cityhash`.
4. Run `cmake` and `make`.

> **About RDMA**: DEFT wants MLNX_OFED 4.9. CloudLab default driver can work sometimes, but for best performance or on-chip memory you need to install MLNX_OFED yourself. The script will check and warn you. We don't auto-install it because it breaks easily.

## 4. Make Config
Still in `mn0`, run:
```bash
cd /mydata/deft/script
python3 gen_config.py
```
This script finds all node IP address and creates `global_config.yaml`. It also makes `memcached.conf`.

## 5. Run Benchmark
Use `cloudlab_run.sh`. It will set hugepages automatically and run things.

### Quick Test
Test if things work first:
```bash
./cloudlab_run.sh --smoke
```
This runs 1 thread just to see if no crash.

### Full Test
```bash
./cloudlab_run.sh --name "test1"
```
Change `threads_CN_arr`, `key_space_arr` in `run_bench.py` before running if you want other numbers.

## 6. Check Results
- Logs: Check `/mydata/deft/log/` folder.
- Results: Written to `/mydata/deft/result/`. File name looks like `bench-test1-date.txt`.

## 7. Problems? 
1. **SSH error**: Script uses `~/.ssh/id_rsa`. Make sure you have your ssh key on `mn0`.
2. **ibv_devinfo error**: OS cannot see RDMA card. 
3. **Memcached error**: Check if `memcached.conf` has correct `mn0` internal IP. Run `./killall.py` to stop bad tests.

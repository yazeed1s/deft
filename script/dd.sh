#!/usr/bin/env bash
set -euo pipefail

NODES=(10.10.1.1 10.10.1.2 10.10.1.3)
OUT="/tmp/deft_full_diag_$(date +%Y%m%d-%H%M%S).log"
SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8"

{
  echo "timestamp: $(date -Is)"
  echo "runner: $(hostname -f 2>/dev/null || hostname)"
  echo "nodes: ${NODES[*]}"
  echo
  echo "==== global_config.yaml ===="
  sed -n '1,200p' /deft_code/deft/script/global_config.yaml || true
  echo

  for n in "${NODES[@]}"; do
    echo "################################################################"
    echo "NODE $n"
    echo "################################################################"
    ssh ${SSH_OPTS} "$USER@$n" 'bash -lc "
      set +e
      echo \"-- host/os --\"
      hostname -f 2>/dev/null || hostname
      uname -a
      cat /etc/os-release | head -n 6

      echo
      echo \"-- numa topology --\"
      numactl -H || true
      lscpu | egrep \"NUMA|Socket|CPU\\(s\\):\" || true

      echo
      echo \"-- hugepages global --\"
      grep -E \"HugePages_(Total|Free|Rsvd|Surp)|Hugepagesize\" /proc/meminfo

      echo
      echo \"-- hugepages per NUMA node --\"
      for d in /sys/devices/system/node/node*/hugepages/hugepages-2048kB; do
        echo \"\$d nr=\$(cat \$d/nr_hugepages 2>/dev/null) free=\$(cat \$d/free_hugepages 2>/dev/null)\"
      done

      echo
      echo \"-- memlock/limits --\"
      ulimit -l
      cat /proc/self/limits | egrep -i \"Max locked memory|Max open files\"

      echo
      echo \"-- RNIC inventory and NUMA affinity --\"
      ibv_devinfo -l || true
      ibdev2netdev || true
      for d in /sys/class/infiniband/*; do
        dev=\$(basename \$d)
        echo \"dev=\$dev numa=\$(cat \$d/device/numa_node 2>/dev/null)\"
      done

      echo
      echo \"-- GIDs --\"
      show_gids 2>/dev/null | sed -n \"1,160p\" || true

      echo
      echo \"-- key device details (mlx5_0 + mlx5_2) --\"
      ibv_devinfo -d mlx5_0 -i 1 2>/dev/null | egrep -i \"hca_id|fw_ver|state|active_mtu|link_layer|max_mr_size|max_qp_rd_atom|max_res_rd_atom\" || true
      ibv_devinfo -d mlx5_2 -i 1 2>/dev/null | egrep -i \"hca_id|fw_ver|state|active_mtu|link_layer|max_mr_size|max_qp_rd_atom|max_res_rd_atom\" || true

      echo
      echo \"-- network --\"
      ip -4 -br a
      ip -4 route

      echo
      echo \"-- iommu/kernel cmdline --\"
      cat /proc/cmdline

      echo
      echo \"-- rdma/mlx modules --\"
      lsmod | egrep \"mlx5|ib_uverbs|ib_core|rdma_cm|ib_cm\" || true

      echo
      echo \"-- recent kernel messages --\"
      dmesg -T | egrep -i \"mlx5|rdma|ib_|mr|mkey|EFAULT|fault|IOMMU|DMAR|warn|error\" | tail -n 120 || true

      echo
      echo \"-- quick hugetlb mmap test (2MB) with membind 0 and 1 --\"
      for nn in 0 1; do
        echo \"membind=\$nn\"
        numactl --membind=\$nn python3 - <<PY
import ctypes, os
libc=ctypes.CDLL(\"libc.so.6\", use_errno=True)
PROT_READ=1; PROT_WRITE=2
MAP_PRIVATE=2; MAP_ANON=0x20; MAP_HUGETLB=0x40000
sz=2*1024*1024
libc.mmap.restype=ctypes.c_void_p
p=libc.mmap(None, sz, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANON|MAP_HUGETLB, -1, 0)
if p == ctypes.c_void_p(-1).value:
    e=ctypes.get_errno()
    print(\"mmap_hugetlb_fail errno=%d %s\"%(e, os.strerror(e)))
else:
    buf=(ctypes.c_char*1).from_address(p); buf[0]=b\"\\0\"[0]
    print(\"mmap_hugetlb_ok addr=0x%x\"%p)
PY
      done
    "'
    echo
  done

  echo "==== latest Deft logs on mn0 ===="
  tail -n 200 /deft_code/deft/log/server_0.log || true
  tail -n 200 /deft_code/deft/log/client_0.log || true
  tail -n 200 /deft_code/deft/log/client_1.log || true
} | tee "$OUT"

echo "saved: $OUT"

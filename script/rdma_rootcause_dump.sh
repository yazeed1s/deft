#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./script/rdma_rootcause_dump.sh [mn_node] [cn0_node] [cn1_node] [user]
# Example:
#   ./script/rdma_rootcause_dump.sh mn0 cn0 cn1 yazeed_n

MN_NODE="${1:-mn0}"
CN0_NODE="${2:-cn0}"
CN1_NODE="${3:-cn1}"
SSH_USER="${4:-${SUDO_USER:-$USER}}"

RNIC="${RNIC:-mlx5_2}"
PORT="${PORT:-1}"
GID_INDEX="${GID_INDEX:-3}"
MN_IP="${MN_IP:-10.10.1.1}"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="rdma_debug_${STAMP}.log"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8)

nodes=("$MN_NODE" "$CN0_NODE" "$CN1_NODE")

say() {
  echo
  echo "===== $* =====" | tee -a "$OUT"
}

run_local() {
  local cmd="$1"
  echo "\$ $cmd" >>"$OUT"
  bash -lc "$cmd" >>"$OUT" 2>&1 || true
}

run_remote() {
  local node="$1"
  local cmd="$2"
  {
    echo "\$ ssh ${SSH_USER}@${node} \"$cmd\""
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${node}" "$cmd"
  } >>"$OUT" 2>&1 || true
}

say "Header"
{
  echo "timestamp: $(date -Is)"
  echo "runner: $(hostname -f 2>/dev/null || hostname)"
  echo "nodes: ${nodes[*]}"
  echo "ssh_user: ${SSH_USER}"
  echo "rnic: ${RNIC}  port: ${PORT}  gid_index: ${GID_INDEX}  mn_ip: ${MN_IP}"
} >>"$OUT"

say "Quick Reachability"
for n in "${nodes[@]}"; do
  run_local "getent hosts ${n}"
done
for ip in "$MN_IP" 10.10.1.2 10.10.1.3; do
  run_local "timeout 3 bash -c 'cat </dev/null >/dev/tcp/${ip}/22' && echo ${ip}:ssh_ok || echo ${ip}:ssh_fail"
done

for n in "${nodes[@]}"; do
  say "Node ${n} - System and RDMA Basics"
  run_remote "$n" "hostname -f; uname -a; cat /etc/os-release | head -n 6"
  run_remote "$n" "ofed_info -s || true"
  run_remote "$n" "ibv_devinfo -l || true"
  run_remote "$n" "show_gids | sed -n '1,80p' || true"
  run_remote "$n" "ip -4 -br a"
  run_remote "$n" "ip -4 route"
  run_remote "$n" "ulimit -l; cat /proc/self/limits | grep -i 'Max locked memory' || true"
  run_remote "$n" "ibv_devinfo -d ${RNIC} -i ${PORT} 2>/dev/null | egrep 'hca_id|transport|fw_ver|active_mtu|max_qp|max_qp_wr|max_sge|max_cq|max_pd' || true"
  run_remote "$n" "ldconfig -p | egrep 'libibverbs|librdmacm|libmlx|libcityhash|libgflags|libmemcached' || true"
  run_remote "$n" "for b in /deft_code/deft/build/server /deft_code/deft/build/client; do [ -x \$b ] && { echo \"--- ldd \$b\"; ldd \$b | egrep 'not found|libibverbs|librdmacm|libmlx|libcityhash|libgflags|libmemcached'; }; done"
  run_remote "$n" "dmesg -T | egrep -i 'mlx5|rdma|infiniband|ib_|qp|cq|mr|fault|error|warn' | tail -n 120 || true"
done

say "Global Config and Bench Logs (mn)"
run_remote "$MN_NODE" "cd /deft_code/deft/script && ls -l global_config.yaml && cat global_config.yaml"
run_remote "$MN_NODE" "cd /deft_code/deft/log && ls -l || true"
run_remote "$MN_NODE" "tail -n 120 /deft_code/deft/log/server_0.log || true"
run_remote "$MN_NODE" "tail -n 120 /deft_code/deft/log/client_0.log || true"
run_remote "$MN_NODE" "tail -n 120 /deft_code/deft/log/client_1.log || true"

say "RC Pingpong Self-Test (mn server + cn0 client)"
PINGPONG_SERVER_LOG="/tmp/ibv_rc_pingpong_server_${STAMP}.log"
PINGPONG_CLIENT_LOG="/tmp/ibv_rc_pingpong_client_${STAMP}.log"

run_remote "$MN_NODE" "pkill -f 'ibv_rc_pingpong -d ${RNIC}' || true"
run_remote "$CN0_NODE" "pkill -f 'ibv_rc_pingpong -d ${RNIC}' || true"
run_remote "$MN_NODE" "nohup timeout 25 ibv_rc_pingpong -d ${RNIC} -i ${PORT} -g ${GID_INDEX} >${PINGPONG_SERVER_LOG} 2>&1 & echo server_pid:\$!"
run_local "sleep 2"
run_remote "$CN0_NODE" "timeout 25 ibv_rc_pingpong -d ${RNIC} -i ${PORT} -g ${GID_INDEX} ${MN_IP} >${PINGPONG_CLIENT_LOG} 2>&1; echo client_rc:\$?"
run_remote "$MN_NODE" "tail -n 120 ${PINGPONG_SERVER_LOG} || true"
run_remote "$CN0_NODE" "tail -n 120 ${PINGPONG_CLIENT_LOG} || true"

say "Done"
echo "saved: ${OUT}" | tee -a "$OUT"
echo "Paste this file here: ${OUT}"

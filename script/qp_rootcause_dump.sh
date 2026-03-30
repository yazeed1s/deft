#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./script/qp_rootcause_dump.sh [mn_node] [cn0_node] [cn1_node] [ssh_user]
# Example:
#   ./script/qp_rootcause_dump.sh mn0 cn0 cn1 yazeed_n

MN_NODE="${1:-mn0}"
CN0_NODE="${2:-cn0}"
CN1_NODE="${3:-cn1}"
SSH_USER="${4:-${SUDO_USER:-$USER}}"

RNIC="${RNIC:-mlx5_2}"
PORT="${PORT:-1}"
MN_IP="${MN_IP:-10.10.1.1}"
GID_LIST="${GID_LIST:-0 3}"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="qp_debug_${STAMP}.log"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8)
NODES=("$MN_NODE" "$CN0_NODE" "$CN1_NODE")

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
  echo "nodes: ${NODES[*]}"
  echo "ssh_user: ${SSH_USER}"
  echo "rnic: ${RNIC}  port: ${PORT}  mn_ip: ${MN_IP}"
  echo "gid_list: ${GID_LIST}"
} >>"$OUT"

say "Quick Reachability"
for n in "${NODES[@]}"; do
  run_local "getent hosts ${n}"
done
for ip in "$MN_IP" 10.10.1.2 10.10.1.3; do
  run_local "timeout 3 bash -c 'cat </dev/null >/dev/tcp/${ip}/22' && echo ${ip}:ssh_ok || echo ${ip}:ssh_fail"
done

for n in "${NODES[@]}"; do
  say "Node ${n} - System, Limits, and RDMA"
  run_remote "$n" "hostname -f; uname -a; cat /etc/os-release | head -n 6"
  run_remote "$n" "id; groups"
  run_remote "$n" "ulimit -a; cat /proc/self/limits | egrep -i 'Max locked memory|Max open files'"
  run_remote "$n" "bash -l -c 'echo login_shell_ulimit_lock=\$(ulimit -l); cat /proc/self/limits | grep -i \"Max locked memory\"'"
  run_remote "$n" "grep -nE 'memlock|soft|hard|\\*' /etc/security/limits.conf /etc/security/limits.d/*.conf 2>/dev/null || true"
  run_remote "$n" "grep -nE 'pam_limits|session' /etc/pam.d/sshd /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive 2>/dev/null || true"
  run_remote "$n" "grep -nE 'UsePAM|PermitUserEnvironment' /etc/ssh/sshd_config 2>/dev/null || true"
  run_remote "$n" "which ibv_devinfo || true; which ibv_rc_pingpong || true; which show_gids || true; which ofed_info || true"
  run_remote "$n" "ibv_devinfo -l || true"
  run_remote "$n" "ibv_devinfo -d ${RNIC} -i ${PORT} || true"
  run_remote "$n" "ibstat || true"
  run_remote "$n" "ibdev2netdev || true"
  run_remote "$n" "ip -4 -br a; ip -4 route"
  run_remote "$n" "show_gids 2>/dev/null | sed -n '1,120p' || true"
  run_remote "$n" "for f in /sys/class/infiniband/*/ports/*/gids/*; do [ -f \"\$f\" ] && echo \"\$f \$(cat \$f)\"; done | head -n 120"
  run_remote "$n" "ldconfig -p | egrep 'libibverbs|librdmacm|libmlx|rdmav2|libnl|libgflags|libcityhash|libmemcached' || true"
  run_remote "$n" "ls -l /usr/lib/libibverbs /usr/lib/x86_64-linux-gnu/libibverbs 2>/dev/null || true"
  run_remote "$n" "dpkg -l | egrep '^(ii|hi|rc)\\s+(rdma-core|ibverbs-utils|ibverbs-providers|libibverbs|librdmacm|libmlx5|infiniband-diags|mlnx|ofed)' || true"
  run_remote "$n" "for b in /deft_code/deft/build/server /deft_code/deft/build/client; do [ -x \$b ] && { echo \"--- ldd \$b\"; ldd \$b | egrep 'not found|libibverbs|librdmacm|libmlx|libcityhash|libgflags|libmemcached'; }; done"
  run_remote "$n" "coredumpctl --no-pager --reverse | head -n 30 || true"
  run_remote "$n" "dmesg -T | egrep -i 'mlx5|rdma|infiniband|uverbs|qp|cq|mr|segfault|fault|error|warn' | tail -n 160 || true"
done

say "RC Pingpong Matrix (plain + Deft env)"
for gid in ${GID_LIST}; do
  run_remote "$MN_NODE" "pkill -f 'ibv_rc_pingpong -d ${RNIC}' || true"
  run_remote "$CN0_NODE" "pkill -f 'ibv_rc_pingpong -d ${RNIC}' || true"

  run_remote "$MN_NODE" "nohup timeout 25 ibv_rc_pingpong -d ${RNIC} -i ${PORT} -g ${gid} >/tmp/pp_plain_s_${STAMP}_g${gid}.log 2>&1 & echo server_pid:\$!"
  run_local "sleep 2"
  run_remote "$CN0_NODE" "timeout 25 ibv_rc_pingpong -d ${RNIC} -i ${PORT} -g ${gid} ${MN_IP} >/tmp/pp_plain_c_${STAMP}_g${gid}.log 2>&1; echo client_rc:\$?"
  run_remote "$MN_NODE" "tail -n 120 /tmp/pp_plain_s_${STAMP}_g${gid}.log || true"
  run_remote "$CN0_NODE" "tail -n 120 /tmp/pp_plain_c_${STAMP}_g${gid}.log || true"

  run_remote "$MN_NODE" "pkill -f 'ibv_rc_pingpong -d ${RNIC}' || true"
  run_remote "$CN0_NODE" "pkill -f 'ibv_rc_pingpong -d ${RNIC}' || true"

  run_remote "$MN_NODE" "nohup env IBV_DRIVERS=mlx5 LD_LIBRARY_PATH=/usr/lib/libibverbs:/usr/lib/x86_64-linux-gnu/libibverbs:\$LD_LIBRARY_PATH timeout 25 ibv_rc_pingpong -d ${RNIC} -i ${PORT} -g ${gid} >/tmp/pp_deftenv_s_${STAMP}_g${gid}.log 2>&1 & echo server_pid:\$!"
  run_local "sleep 2"
  run_remote "$CN0_NODE" "env IBV_DRIVERS=mlx5 LD_LIBRARY_PATH=/usr/lib/libibverbs:/usr/lib/x86_64-linux-gnu/libibverbs:\$LD_LIBRARY_PATH timeout 25 ibv_rc_pingpong -d ${RNIC} -i ${PORT} -g ${gid} ${MN_IP} >/tmp/pp_deftenv_c_${STAMP}_g${gid}.log 2>&1; echo client_rc:\$?"
  run_remote "$MN_NODE" "tail -n 120 /tmp/pp_deftenv_s_${STAMP}_g${gid}.log || true"
  run_remote "$CN0_NODE" "tail -n 120 /tmp/pp_deftenv_c_${STAMP}_g${gid}.log || true"
done

say "Deft Config and Logs"
run_remote "$MN_NODE" "cd /deft_code/deft/script && ls -l global_config.yaml && cat global_config.yaml"
run_remote "$MN_NODE" "cd /deft_code/deft/log && ls -l || true"
run_remote "$MN_NODE" "tail -n 120 /deft_code/deft/log/server_0.log || true"
run_remote "$MN_NODE" "tail -n 120 /deft_code/deft/log/client_0.log || true"
run_remote "$MN_NODE" "tail -n 120 /deft_code/deft/log/client_1.log || true"

say "Done"
echo "saved: ${OUT}" | tee -a "$OUT"
echo "share this file: ${OUT}"

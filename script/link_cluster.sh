# #!/usr/bin/env bash
# # Run locally: copy mn0 SSH pubkey to all CN authorized_keys.
# set -euo pipefail

# usage() {
#     echo "usage: $0 <mn-host> <cn-host1> [cn-host2 ...] [--user USER] [--key KEY_PATH]"
#     echo "example:"
#     echo "  $0 clnode263.clemson.cloudlab.us clnode262.clemson.cloudlab.us clnode274.clemson.cloudlab.us --user yazeed_n --key ~/.ssh/id_cloudlab"
# }

# if [[ $# -lt 2 ]]; then
#     usage
#     exit 1
# fi

# MN_HOST="$1"
# shift

# CN_HOSTS=()
# SSH_USER="${USER:-}"
# KEY_PATH="${HOME}/.ssh/id_cloudlab"

# while [[ $# -gt 0 ]]; do
#     case "$1" in
#         --user)
#             SSH_USER="$2"
#             shift 2
#             ;;
#         --key)
#             KEY_PATH="$2"
#             shift 2
#             ;;
#         -*)
#             echo "error: unknown option: $1"
#             usage
#             exit 1
#             ;;
#         *)
#             CN_HOSTS+=("$1")
#             shift
#             ;;
#     esac
# done

# if [[ -z "${SSH_USER}" ]]; then
#     SSH_USER="$(whoami)"
# fi

# if [[ ${#CN_HOSTS[@]} -eq 0 ]]; then
#     echo "error: provide at least one CN host"
#     usage
#     exit 1
# fi

# if [[ ! -f "${KEY_PATH}" ]]; then
#     echo "error: ssh key not found: ${KEY_PATH}"
#     exit 1
# fi

# SSH_OPTS=(
#     -i "${KEY_PATH}"
#     -o StrictHostKeyChecking=accept-new
#     -o ConnectTimeout=10
# )

# echo "[0/5] validating mn host argument..."
# MN_NICKNAME="$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MN_HOST}" "cat /var/emulab/boot/nickname 2>/dev/null || hostname -s" || true)"
# if [[ -z "${MN_NICKNAME}" ]]; then
#     echo "error: cannot reach ${MN_HOST} with --user ${SSH_USER} and --key ${KEY_PATH}"
#     exit 1
# fi
# if [[ "${MN_NICKNAME}" != "mn0" && "${MN_NICKNAME}" != mn* ]]; then
#     echo "error: first argument must be the MN host; got ${MN_HOST} (remote nickname: ${MN_NICKNAME})"
#     exit 1
# fi

# echo "[1/5] ensure mn keypair exists on ${MN_HOST}..."
# ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MN_HOST}" \
#     "mkdir -p ~/.ssh && chmod 700 ~/.ssh && if [ ! -f ~/.ssh/id_rsa ]; then ssh-keygen -m PEM -t rsa -b 4096 -N '' -f ~/.ssh/id_rsa >/dev/null; fi && if [ ! -f ~/.ssh/id_rsa.pub ]; then ssh-keygen -y -f ~/.ssh/id_rsa > ~/.ssh/id_rsa.pub; fi && chmod 600 ~/.ssh/id_rsa && chmod 644 ~/.ssh/id_rsa.pub"

# echo "[2/5] fetch mn public key..."
# MN_PUB_KEY="$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MN_HOST}" "cat ~/.ssh/id_rsa.pub")"
# if [[ -z "${MN_PUB_KEY}" ]]; then
#     echo "error: failed to read mn public key"
#     exit 1
# fi
# MN_PUB_KEY_B64="$(printf '%s' "${MN_PUB_KEY}" | base64 | tr -d '\n')"

# echo "[3/5] add mn key to CN authorized_keys..."
# for cn in "${CN_HOSTS[@]}"; do
#     echo "  -> ${cn}"
#     ssh "${SSH_OPTS[@]}" "${SSH_USER}@${cn}" \
#         "k=\$(echo '${MN_PUB_KEY_B64}' | base64 -d); mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && grep -qxF \"\$k\" ~/.ssh/authorized_keys || printf '%s\n' \"\$k\" >> ~/.ssh/authorized_keys"
# done

# echo "[4/5] warm known_hosts on mn for CN hosts..."
# CN_JOINED="$(printf ' %q' "${CN_HOSTS[@]}")"
# ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MN_HOST}" \
#     "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/known_hosts && chmod 600 ~/.ssh/known_hosts; for h in${CN_JOINED}; do ssh-keyscan -H \"\$h\" 2>/dev/null >> ~/.ssh/known_hosts || true; done; sort -u ~/.ssh/known_hosts -o ~/.ssh/known_hosts"

# echo "[5/5] verifying key propagation + mn->cn passwordless ssh..."
# MISSING_KEY=()
# AUTH_FAIL=()
# for cn in "${CN_HOSTS[@]}"; do
#     if ! ssh "${SSH_OPTS[@]}" "${SSH_USER}@${cn}" "k=\$(echo '${MN_PUB_KEY_B64}' | base64 -d); grep -qxF \"\$k\" ~/.ssh/authorized_keys"; then
#         MISSING_KEY+=("${cn}")
#         continue
#     fi
#     if ! ssh "${SSH_OPTS[@]}" "${SSH_USER}@${MN_HOST}" "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 '${cn}' 'hostname >/dev/null'"; then
#         AUTH_FAIL+=("${cn}")
#     fi
# done

# if [[ "${#MISSING_KEY[@]}" -gt 0 ]]; then
#     echo "error: mn public key is NOT present on: ${MISSING_KEY[*]}"
#     exit 1
# fi

# if [[ "${#AUTH_FAIL[@]}" -gt 0 ]]; then
#     echo "error: mn passwordless ssh to CN failed for: ${AUTH_FAIL[*]}"
#     exit 1
# fi

# echo "done. mn key exists, CN authorized_keys confirmed, and mn->cn ssh works."

KEY=~/.ssh/id_cloudlab
USER=yazeed_n
NODES="clnode262.clemson.cloudlab.us clnode263.clemson.cloudlab.us clnode274.clemson.cloudlab.us"

for h in $NODES; do
  ssh -i "$KEY" "$USER@$h" '
    cd /local/repository || exit 1
    sudo bash script/net_heal.sh || true
    sudo systemctl restart ssh || sudo systemctl restart sshd || true
    echo "== $(hostname -s) =="
    ip -4 -br a | grep 10.10.1 || true
    ss -lnt | grep ":22 " || true
  '
done

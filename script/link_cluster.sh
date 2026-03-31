#!/usr/bin/env bash
# Run locally: install mn SSH pubkey on CN nodes and verify mn->cn passwordless SSH.
set -euo pipefail

usage() {
    echo "usage: $0 <mn-host> <cn-host1> [cn-host2 ...] [--user USER] [--key KEY_PATH]"
    echo "example:"
    echo "  $0 clnode262.clemson.cloudlab.us clnode263.clemson.cloudlab.us clnode274.clemson.cloudlab.us --user yazeed_n --key ~/.ssh/id_cloudlab"
}

SSH_USER="${USER:-$(whoami)}"
KEY_PATH="${HOME}/.ssh/id_cloudlab"
POSITIONAL=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)
            SSH_USER="$2"
            shift 2
            ;;
        --key)
            KEY_PATH="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "error: unknown option: $1"
            usage
            exit 1
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

if [[ "${#POSITIONAL[@]}" -lt 2 ]]; then
    usage
    exit 1
fi

MN_HOST="${POSITIONAL[0]}"
CN_HOSTS=("${POSITIONAL[@]:1}")
KEY_PATH="${KEY_PATH/#\~/$HOME}"

if [[ ! -f "${KEY_PATH}" ]]; then
    echo "error: ssh key not found: ${KEY_PATH}"
    exit 1
fi

SSH_OPTS=(
    -i "${KEY_PATH}"
    -o BatchMode=yes
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=10
)

remote() {
    local host="$1"
    shift
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "$@"
}

echo "[0/6] validating connectivity and mn argument..."
ALL_HOSTS=("${MN_HOST}" "${CN_HOSTS[@]}")
UNREACHABLE=()
for h in "${ALL_HOSTS[@]}"; do
    if ! remote "${h}" "echo ok >/dev/null"; then
        UNREACHABLE+=("${h}")
    fi
done
if [[ "${#UNREACHABLE[@]}" -gt 0 ]]; then
    echo "error: cannot ssh to: ${UNREACHABLE[*]}"
    exit 1
fi

MN_NAME="$(remote "${MN_HOST}" "cat /var/emulab/boot/nickname 2>/dev/null || hostname -s")"
if [[ "${MN_NAME}" != mn* ]]; then
    echo "error: first argument must be MN host; got '${MN_HOST}' (remote name '${MN_NAME}')"
    exit 1
fi

echo "[1/6] ensuring mn keypair exists on ${MN_HOST}..."
remote "${MN_HOST}" "bash -s" <<'EOF'
set -euo pipefail
mkdir -p ~/.ssh
chmod 700 ~/.ssh
if [[ ! -f ~/.ssh/id_rsa ]]; then
    ssh-keygen -m PEM -t rsa -b 4096 -N '' -f ~/.ssh/id_rsa >/dev/null
fi
if [[ ! -f ~/.ssh/id_rsa.pub ]]; then
    ssh-keygen -y -f ~/.ssh/id_rsa > ~/.ssh/id_rsa.pub
fi
chmod 600 ~/.ssh/id_rsa
chmod 644 ~/.ssh/id_rsa.pub
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
k="$(cat ~/.ssh/id_rsa.pub)"
grep -qxF "$k" ~/.ssh/authorized_keys || printf '%s\n' "$k" >> ~/.ssh/authorized_keys
EOF

echo "[2/6] fetching mn public key..."
MN_PUB_KEY="$(remote "${MN_HOST}" "cat ~/.ssh/id_rsa.pub")"
if [[ -z "${MN_PUB_KEY}" ]]; then
    echo "error: failed to read mn public key"
    exit 1
fi
MN_PUB_KEY_B64="$(printf '%s' "${MN_PUB_KEY}" | base64 | tr -d '\n')"

echo "[3/6] installing mn key on CN authorized_keys..."
declare -A CN_SHORT_BY_HOST=()
for cn in "${CN_HOSTS[@]}"; do
    echo "  -> ${cn}"
    remote "${cn}" "bash -s" -- "${MN_PUB_KEY_B64}" <<'EOF'
set -euo pipefail
k="$(printf '%s' "$1" | base64 -d)"
mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
grep -qxF "$k" ~/.ssh/authorized_keys || printf '%s\n' "$k" >> ~/.ssh/authorized_keys
EOF
    CN_SHORT_BY_HOST["${cn}"]="$(remote "${cn}" "hostname -s")"
done

echo "[4/6] warming known_hosts on mn..."
KNOWN_TARGETS=("${CN_HOSTS[@]}")
for cn in "${CN_HOSTS[@]}"; do
    short="${CN_SHORT_BY_HOST[${cn}]}"
    if [[ -n "${short}" ]]; then
        KNOWN_TARGETS+=("${short}")
    fi
done
remote "${MN_HOST}" "bash -s" -- "${KNOWN_TARGETS[@]}" <<'EOF'
set -euo pipefail
mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/known_hosts
chmod 600 ~/.ssh/known_hosts
for h in "$@"; do
    [[ -n "${h}" ]] || continue
    ssh-keyscan -H "${h}" 2>/dev/null >> ~/.ssh/known_hosts || true
done
sort -u ~/.ssh/known_hosts -o ~/.ssh/known_hosts
EOF

echo "[5/6] verifying key propagation on CNs..."
MISSING_KEY=()
for cn in "${CN_HOSTS[@]}"; do
    if ! remote "${cn}" "bash -s" -- "${MN_PUB_KEY_B64}" <<'EOF'
set -euo pipefail
k="$(printf '%s' "$1" | base64 -d)"
grep -qxF "$k" ~/.ssh/authorized_keys
EOF
    then
        MISSING_KEY+=("${cn}")
    fi
done
if [[ "${#MISSING_KEY[@]}" -gt 0 ]]; then
    echo "error: mn key missing on: ${MISSING_KEY[*]}"
    exit 1
fi

echo "[6/6] verifying mn -> cn passwordless ssh..."
AUTH_FAIL=()
for cn in "${CN_HOSTS[@]}"; do
    targets=("$cn")
    short="${CN_SHORT_BY_HOST[${cn}]:-}"
    if [[ -n "${short}" && "${short}" != "${cn}" ]]; then
        targets+=("${short}")
    fi
    ok=0
    for t in "${targets[@]}"; do
        if remote "${MN_HOST}" "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 '${SSH_USER}@${t}' 'hostname >/dev/null'"; then
            ok=1
            break
        fi
    done
    if [[ $ok -eq 0 ]]; then
        AUTH_FAIL+=("${targets[*]}")
    fi
done
if [[ "${#AUTH_FAIL[@]}" -gt 0 ]]; then
    echo "error: mn passwordless ssh failed for: ${AUTH_FAIL[*]}"
    exit 1
fi

echo "done: mn key setup is correct and mn can ssh to all CNs."

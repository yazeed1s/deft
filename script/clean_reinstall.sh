#!/bin/bash
# Clean all nodes and re-run cloudlab_catchup.sh from scratch (no SSH key reset).
set -euo pipefail

NODES=${*:-"mn0 cn0 cn1 cn2"}

echo "nodes: ${NODES}"

for h in ${NODES}; do
  echo "=== ${h}: cleanup ==="
  ssh "${h}" "
    set -e
    export DEBIAN_FRONTEND=noninteractive

    # stop services that hold rdma modules
    sudo systemctl stop nfs-server nfs-kernel-server rpcbind rpcbind.socket || true

    # unload rdma modules best-effort
    sudo modprobe -r rpcrdma rdma_cm iw_cm ib_uverbs ib_core mlx5_ib mlx5_core bnxt_re || true

    # remove MLNX_OFED if present
    if command -v ofed_info >/dev/null 2>&1; then
      OFED_VER=\$(ofed_info -s | awk -F: '{print \$1}')
      OFED_DIR=\${OFED_VER#MLNX_OFED_LINUX-}
      if [ -n \"\${OFED_DIR}\" ] && [ -x \"/tmp/\${OFED_DIR}/uninstall.sh\" ]; then
        sudo /tmp/\${OFED_DIR}/uninstall.sh --force || true
      elif [ -x /usr/sbin/mlnxofeduninstall ]; then
        sudo /usr/sbin/mlnxofeduninstall --force || true
      fi
    fi

    # purge rdma-related packages actually installed
    sudo apt-get update -q || true
    PKGS=\$(dpkg -l | awk '/^ii/ && \$2 ~ /(mlnx-ofed|ofed-|rdma|ibverbs|mlx5|librdmacm|ibacm|infiniband|srp|iser|isert)/ {print \$2}')
    if [ -n \"\${PKGS}\" ]; then
      sudo apt-get purge -y \${PKGS} || true
    fi
    sudo apt-get -f install -y || true

    # remove libibverbs provider config (if any leftovers)
    sudo rm -rf /etc/libibverbs.d || true
    sudo rm -f /etc/modprobe.d/mlx5.conf /etc/modules-load.d/mlx5.conf || true

    # clean build artifacts and logs (keep repo + configs)
    sudo rm -rf /mydata/deft/build /mydata/deft/log /mydata/deft/result || true
  "
done

echo "=== cleanup done ==="
echo "run this next on mn0:"
echo "  sudo /mydata/deft/script/cloudlab_catchup.sh"

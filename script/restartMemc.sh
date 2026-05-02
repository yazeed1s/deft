#!/bin/bash

set -euo pipefail

addr=$(head -1 ../memcached.conf)
port=$(awk 'NR==2{print}' ../memcached.conf)
ssh_opts="-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8"

# kill old one if pid file exists
sudo ssh ${ssh_opts} "${addr}" "if [ -f /tmp/memcached.pid ]; then kill \$(cat /tmp/memcached.pid) || true; fi"

sudo sh -c "echo 3 > /proc/sys/vm/drop_caches"

# launch memcached
sudo ssh ${ssh_opts} "${addr}" "memcached -u root -l ${addr} -p ${port} -c 10000 -d -P /tmp/memcached.pid"
sleep 1

# clear stale metadata from prior runs (e.g., cxl_*_size_0 keys)
echo -e "flush_all\r\nquit\r" | nc ${addr} ${port}

# init
echo -e "set ServerNum 0 0 1\r\n0\r\nquit\r" | nc ${addr} ${port}
echo -e "set ClientNum 0 0 1\r\n0\r\nquit\r" | nc ${addr} ${port}

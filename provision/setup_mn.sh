#!/bin/bash
# setup_mn.sh - run on mn0 only
# clones the repo, builds deft, and starts memcached
# run setup_all.sh first

set -e

echo "starting mn0 setup..."

# clone into the nfs-shared directory so all nodes see the binary
cd /mydata
git clone https://github.com/yazeed1s/deft
cd deft

sudo ./script/hugepage.sh

mkdir -p build
cd build
cmake -DCMAKE_BUILD_TYPE=Release ..
make -j$(nproc)
cd ..

# memcached config — nodes use this to exchange RDMA QP info
MN0_IP=$(hostname -I | awk '{print $1}')
cp script/restartMemc.sh build/
echo "$MN0_IP" > memcached.conf
echo "11211" >> memcached.conf

cd build
./restartMemc.sh
cd ..

echo "done. deft built at /mydata/deft/build"

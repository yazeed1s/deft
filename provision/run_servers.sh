#!/bin/bash
# run_servers.sh - run on mn0

SERVER_COUNT=1
CLIENT_COUNT=2

echo "starting deft server on $(hostname)..."
cd /mydata/deft/build
./server --server_count $SERVER_COUNT --client_count $CLIENT_COUNT --numa_id 0

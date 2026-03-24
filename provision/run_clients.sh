#!/bin/bash
# run_clients.sh - run on cn0–cn5

SERVER_COUNT=2
CLIENT_COUNT=6

echo "starting deft client on $(hostname)..."
cd /mydata/deft/build
./client --server_count $SERVER_COUNT --client_count $CLIENT_COUNT --numa_id 0

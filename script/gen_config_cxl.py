#!/usr/bin/python3
"""Generate global_config.yaml for CXL mode (single-machine, localhost)."""
import getpass
import os
import socket
import yaml

def main():
    username = getpass.getuser()

    # CXL: both server and client on the same machine (mn0 / localhost)
    local_ip = "127.0.0.1"

    config = {
        'src_path': '/deft_code/deft',
        'app_rel_path': 'build_cxl',
        'server_app': 'server',
        'client_app': 'client',
        'rnic_id': 0,            # unused under CXL but required by gflags
        'username': username,
        'password': '',
        'servers': [{'ip': local_ip, 'numa_id': 0}],
        'clients': [{'ip': local_ip, 'numa_id': 1}],  # pin client to NUMA 1
    }

    out_path = '/deft_code/deft/script/global_config.yaml'
    with open(out_path, 'w') as f:
        try:
            yaml.dump(config, f, sort_keys=False)
        except TypeError:
            yaml.dump(config, f)

    # memcached.conf must point to localhost for CXL
    with open('/deft_code/deft/memcached.conf', 'w') as f:
        f.write(f"{local_ip}\n11211\n")

    print(f"done. CXL config written to {out_path}")
    print(f"  server: {local_ip} (NUMA 0)")
    print(f"  client: {local_ip} (NUMA 1)")
    print(f"  build:  build_cxl/")

if __name__ == '__main__':
    main()

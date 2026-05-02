#!/usr/bin/python3
import os
import socket
import getpass
import re
import subprocess
import yaml
import glob

def resolve_ip(hostname):
    try:
        return socket.gethostbyname(hostname)
    except:
        return None

def detect_rnic_id():
    import glob
    try:
        devices = sorted([os.path.basename(d) for d in glob.glob("/sys/class/infiniband/*")])
        if not devices:
            return 0
        # If there's an mlx5_2, use its index
        for i, dev in enumerate(devices):
            if dev == "mlx5_2":
                return i
        return 0 # Default to the first device (e.g. mlx4_0)
    except Exception:
        return 0

def detect_preferred_numa_id():
    try:
        nodes = sorted(
            int(os.path.basename(p).replace("node", ""))
            for p in glob.glob("/sys/devices/system/node/node[0-9]*")
        )
        if not nodes:
            return 0
        return 1 if 1 in nodes else 0
    except Exception:
        return 0

def main():
    username = getpass.getuser()

    mn_ips = []
    for i in range(10):
        ip = resolve_ip(f"mn{i}")
        if ip: mn_ips.append(ip)

    if not mn_ips:
        mn_ips = [socket.gethostbyname(socket.gethostname())]

    cn_ips = []
    for i in range(30):
        ip = resolve_ip(f"cn{i}")
        if ip: cn_ips.append(ip)

    if not cn_ips:
        print("warning: cannot find cn hostnames. using mn for clients")
        cn_ips = mn_ips.copy()

    config = {
        'src_path': '/deft_code/deft',
        'app_rel_path': 'build',
        'server_app': 'server',
        'client_app': 'client',
        'rnic_id': detect_rnic_id(),
        'username': username,
        'password': '',
        'servers': [],
        'clients': []
    }

    for ip in mn_ips:
        config['servers'].append({'ip': ip, 'numa_id': detect_preferred_numa_id()})

    numa_id = detect_preferred_numa_id()
    for numa_id in [numa_id]:
        for ip in cn_ips:
            config['clients'].append({'ip': ip, 'numa_id': numa_id})

    with open('/deft_code/deft/script/global_config.yaml', 'w') as f:
        # PyYAML on Ubuntu 18.04 does not support sort_keys.
        try:
            yaml.dump(config, f, sort_keys=False)
        except TypeError:
            yaml.dump(config, f)

    # Generate memcached.conf for restartMemc.sh
    mn0_ip = socket.gethostbyname("mn0") if resolve_ip("mn0") else mn_ips[0]
    with open('/deft_code/deft/memcached.conf', 'w') as f:
        f.write(f"{mn0_ip}\n11211\n")

    print(f"done. config has {len(config['servers'])} servers and {len(config['clients'])} clients.")

if __name__ == '__main__':
    main()

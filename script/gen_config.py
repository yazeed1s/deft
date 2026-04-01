#!/usr/bin/python3
import os
import socket
import getpass
import re
import subprocess
import yaml

def resolve_ip(hostname):
    try:
        return socket.gethostbyname(hostname)
    except:
        return None

def detect_rnic_id():
    # Prefer the RNIC carrying the experiment LAN (10.10.1.x) in show_gids output.
    try:
        out = subprocess.check_output(["show_gids"], stderr=subprocess.STDOUT, text=True)
        for line in out.splitlines():
            if "10.10.1." in line:
                m = re.search(r"(mlx5_(\d+))", line)
                if m:
                    return int(m.group(2))
                # Newer stacks can expose names like rocep202s0f0/rocep202s0f1.
                m = re.search(r"f(\d+)\b", line)
                if m:
                    return int(m.group(1))
    except Exception:
        pass
    # CloudLab r650 commonly uses mlx5_2 for experiment VLAN.
    return 2

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
        config['servers'].append({'ip': ip, 'numa_id': 1})

    # Clemson r650 + mlx5_2 path runs on NUMA 1.
    for numa_id in [1]:
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

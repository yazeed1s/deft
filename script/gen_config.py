#!/usr/bin/python3
import os
import socket
import getpass
import yaml

def resolve_ip(hostname):
    try:
        return socket.gethostbyname(hostname)
    except:
        return None

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
        'username': username,
        'password': '',
        'servers': [],
        'clients': []
    }

    for ip in mn_ips:
        config['servers'].append({'ip': ip, 'numa_id': 0})

    # single socket machines (like d6515) only have numa 0
    for numa_id in [0]:
        for ip in cn_ips:
            config['clients'].append({'ip': ip, 'numa_id': numa_id})

    with open('/deft_code/deft/script/global_config.yaml', 'w') as f:
        yaml.dump(config, f, sort_keys=False)

    # Generate memcached.conf for restartMemc.sh
    mn0_ip = socket.gethostbyname("mn0") if resolve_ip("mn0") else mn_ips[0]
    with open('/deft_code/deft/memcached.conf', 'w') as f:
        f.write(f"{mn0_ip}\n11211\n")

    print(f"done. config has {len(config['servers'])} servers and {len(config['clients'])} clients.")

if __name__ == '__main__':
    main()

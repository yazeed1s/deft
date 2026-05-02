#!/usr/bin/python3

import yaml
from ssh_connect import ssh_command

with open('../script/global_config.yaml', 'r') as f:
    g_cfg = yaml.safe_load(f)

SERVER_HUGEPAGE_FRACTION = 0.40
CLIENT_HUGEPAGE_MIN = 2304

def query_total_ram_pages(ip, username, password):
    from ssh_connect import ssh_command
    cmd = "bash -lc 'grep MemTotal /proc/meminfo | awk \"{print \\$2}\"'"
    try:
        ssh, stdin, stdout, stderr = ssh_command(ip, username, password, cmd)
        out = stdout.read().decode("utf-8", errors="replace").strip()
        ssh.close()
        return int(out.splitlines()[-1]) // 2048
    except Exception:
        return 16384  # fallback

def all_hugepage():
    username = g_cfg['username']
    password = g_cfg['password']
    nodes = {}
    ram_cache = {}

    for n in g_cfg.get('servers', []):
        ip = n['ip']
        if ip not in ram_cache:
            ram_cache[ip] = query_total_ram_pages(ip, username, password)
        numa_id = int(n.get('numa_id', 0))
        target = int(ram_cache[ip] * SERVER_HUGEPAGE_FRACTION)
        nodes[ip] = {'role': 'server', 'numa_id': numa_id, 'target': target}

    for n in g_cfg.get('clients', []):
        ip = n['ip']
        numa_id = int(n.get('numa_id', 0))
        if ip not in nodes:
            nodes[ip] = {'role': 'client', 'numa_id': numa_id, 'target': CLIENT_HUGEPAGE_MIN}

    for ip in sorted(nodes.keys()):
        role = nodes[ip]['role']
        numa_id = nodes[ip]['numa_id']
        target = nodes[ip]['target']
        other_numa = 1 if numa_id == 0 else 0
        print(f'hugepage {ip} role={role} numa={numa_id} target={target}')
        cmd = (
            f"bash -lc '"
            f"echo {target} | sudo -n tee /sys/devices/system/node/node{numa_id}/hugepages/hugepages-2048kB/nr_hugepages >/dev/null "
            f"&& if [ -d /sys/devices/system/node/node{other_numa} ]; then "
            f"echo 0 | sudo -n tee /sys/devices/system/node/node{other_numa}/hugepages/hugepages-2048kB/nr_hugepages >/dev/null; "
            f"fi "
            f"&& sudo -n sysctl -w vm.nr_hugepages={target} >/dev/null "
            f"&& sudo -n sysctl -w kernel.watchdog_thresh=120 >/dev/null "
            f"&& echo total=$(cat /proc/sys/vm/nr_hugepages) "
            f"&& echo node{numa_id}=$(cat /sys/devices/system/node/node{numa_id}/hugepages/hugepages-2048kB/free_hugepages) "
            f"&& if [ -d /sys/devices/system/node/node{other_numa} ]; then "
            f"echo node{other_numa}=$(cat /sys/devices/system/node/node{other_numa}/hugepages/hugepages-2048kB/free_hugepages); "
            f"fi'"
        )
        try:
            ssh, stdin, stdout, stderr = ssh_command(ip, username, password, cmd)
            out = stdout.read().decode("utf-8", errors="replace").strip()
            err = stderr.read().decode("utf-8", errors="replace").strip()
            ssh.close()
        except Exception as e:
            print(f'error: {ip} ssh failed: {e}')
            continue

        if err:
            print(f'  {ip} stderr: {err}')
        if out:
            print(f'  {ip} {out.replace(chr(10), " ")}')
        else:
            print(f'  {ip} no output from sysctl command')

if __name__ == '__main__':
    all_hugepage()
    print('done.')

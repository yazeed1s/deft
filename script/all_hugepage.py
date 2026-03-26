#!/usr/bin/python3

import yaml
from ssh_connect import ssh_command

with open('../script/global_config.yaml', 'r') as f:
    g_cfg = yaml.safe_load(f)

SERVER_HUGEPAGES = 32768
CLIENT_HUGEPAGES = 1024

def all_hugepage():
    ip_set = set()
    username = g_cfg['username']
    password = g_cfg['password']

    server_ips = {n['ip'] for n in g_cfg.get('servers', [])}
    client_ips = {n['ip'] for n in g_cfg.get('clients', [])}

    for ip in sorted(server_ips | client_ips):
        if ip in ip_set:
            continue
        ip_set.add(ip)
        target = SERVER_HUGEPAGES if ip in server_ips else CLIENT_HUGEPAGES
        print(f'hugepage {ip} -> {target}')
        cmd = (
            f"bash -lc '"
            f"sudo -n sysctl -w vm.nr_hugepages={target} "
            f"&& sudo -n sysctl -w kernel.watchdog_thresh=120 "
            f"&& cat /proc/sys/vm/nr_hugepages'"
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
            print(f'  {ip} now vm.nr_hugepages={out.splitlines()[-1]}')
        else:
            print(f'  {ip} no output from sysctl command')

if __name__ == '__main__':
    all_hugepage()
    print('done.')

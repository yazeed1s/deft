#!/usr/bin/python3

import yaml
from ssh_connect import ssh_command

with open('../script/global_config.yaml', 'r') as f:
    g_cfg = yaml.safe_load(f)

def all_hugepage():
    ip_set = set()
    username=g_cfg['username']
    password=g_cfg['password']
    for node_list in [g_cfg['clients'], g_cfg['servers']]:
        for i in range(len(node_list)):
            ip = node_list[i]['ip']
            if ip in ip_set:
                continue
            ip_set.add(ip)
            print(f'hugepage ${ip}')
            cmd = f'sudo sysctl -w vm.nr_hugepages=32768 && sudo sysctl -w kernel.watchdog_thresh=120'
            ssh, stdin, stdout, stderr = ssh_command(ip, username, password, cmd)
            ssh.close()

if __name__ == '__main__':
    all_hugepage()
    print('done.')

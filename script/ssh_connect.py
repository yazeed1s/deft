#!/usr/bin/python3

import yaml
import paramiko

with open('../script/global_config.yaml', 'r') as f:
    g_cfg = yaml.safe_load(f)

def ssh_command(ip, username, password, cmd):
    ssh = paramiko.SSHClient()
    ssh.load_system_host_keys()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    import os
    for key_name in ['id_rsa', 'id_ed25519', 'id_ecdsa', 'id_cloudlab']:
        key_path = os.path.expanduser(f'~/.ssh/{key_name}')
        if os.path.exists(key_path):
            ssh.connect(ip, username=username, key_filename=key_path)
            break
    else:
        ssh.connect(ip, username=username, password=password)
    stdin, stdout, stderr = ssh.exec_command(cmd)
    return ssh, stdin, stdout, stderr

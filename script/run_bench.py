#!/usr/bin/python3

import os
import sys
import subprocess
import time
import yaml
import argparse
import killall
from itertools import product
from time import gmtime, strftime
from ssh_connect import ssh_command

# Hugepage requirements as a fraction of physical RAM (2MB pages).
SERVER_HUGEPAGE_FRACTION = 0.40   # 40% of total RAM
CLIENT_HUGEPAGE_MIN = 2048        # ~4 GB fixed minimum for clients
CLIENT_HUGEPAGE_NUMA_MIN = 1536   # ~3 GB when --force-hugepage

def query_total_ram_pages(ip, username, password):
    """Query total RAM on a node, return as number of 2MB hugepages."""
    cmd = "bash -lc 'grep MemTotal /proc/meminfo | awk \"{print \\$2}\"'"
    try:
        ssh, stdin, stdout, stderr = ssh_command(ip, username, password, cmd)
        out = stdout.read().decode("utf-8", errors="replace").strip()
        ssh.close()
        mem_kb = int(out.splitlines()[-1])
        return mem_kb // 2048  # convert KB to 2MB pages
    except Exception:
        return 16384  # fallback: assume 32GB

def get_hugepage_requirements(g_cfg):
    """Compute per-node hugepage requirements based on actual hardware."""
    username = g_cfg['username']
    password = g_cfg['password']
    ram_cache = {}

    for node in g_cfg.get('servers', []):
        ip = node['ip']
        if ip not in ram_cache:
            ram_cache[ip] = query_total_ram_pages(ip, username, password)

    for node in g_cfg.get('clients', []):
        ip = node['ip']
        if ip not in ram_cache:
            ram_cache[ip] = query_total_ram_pages(ip, username, password)

    server_ips = {n['ip'] for n in g_cfg.get('servers', [])}
    requirements = {}
    for ip, total_pages in ram_cache.items():
        if ip in server_ips:
            req = int(total_pages * SERVER_HUGEPAGE_FRACTION)
        else:
            req = CLIENT_HUGEPAGE_MIN
        requirements[ip] = req

    return requirements

def dump_remote_log(ip, username, password, log_path, role, idx, lines=80):
    cmd = (
        "bash -lc '"
        f"if [ -f \"{log_path}\" ]; then "
        f"echo \"--- {role} {idx} log tail ({log_path}) ---\"; "
        f"tail -n {lines} \"{log_path}\"; "
        "else "
        f"echo \"--- {role} {idx} log missing ({log_path}) ---\"; "
        "fi'"
    )
    try:
        ssh, stdin, stdout, stderr = ssh_command(ip, username, password, cmd)
        out = stdout.read().decode("utf-8", errors="replace").strip()
        err = stderr.read().decode("utf-8", errors="replace").strip()
        ssh.close()
        if out:
            print(out)
        if err:
            print(f"ssh stderr while reading {role} {idx} log on {ip}: {err}")
    except Exception as e:
        print(f"failed to fetch {role} {idx} log from {ip}: {e}")

def check_hugepages(g_cfg, force_hugepage=False):
    username = g_cfg['username']
    password = g_cfg['password']
    failed = False

    dynamic_reqs = get_hugepage_requirements(g_cfg)
    required_per_ip = {}
    required_per_ip_numa = {}

    for node in g_cfg['servers']:
        ip = node['ip']
        required_per_ip[ip] = dynamic_reqs.get(ip, CLIENT_HUGEPAGE_MIN)
        numa_id = int(node.get('numa_id', 0))
        required_per_ip_numa[ip] = (numa_id, dynamic_reqs.get(ip, CLIENT_HUGEPAGE_MIN))

    for node in g_cfg['clients']:
        ip = node['ip']
        required_per_ip[ip] = max(required_per_ip.get(ip, 0), dynamic_reqs.get(ip, CLIENT_HUGEPAGE_MIN))
        if force_hugepage:
            numa_id = int(node.get('numa_id', 0))
            prev = required_per_ip_numa.get(ip)
            need = CLIENT_HUGEPAGE_NUMA_MIN
            if prev is None or need > prev[1]:
                required_per_ip_numa[ip] = (numa_id, need)

    print("preflight: checking hugepages on all nodes...")
    for ip, min_hp in sorted(required_per_ip.items()):
        cmd = "bash -lc 'cat /proc/sys/vm/nr_hugepages 2>/dev/null || echo -1'"
        try:
            ssh, stdin, stdout, stderr = ssh_command(ip, username, password, cmd)
            out = stdout.read().decode("utf-8", errors="replace").strip()
            err = stderr.read().decode("utf-8", errors="replace").strip()
            ssh.close()
        except Exception as e:
            print(f"preflight error on {ip}: cannot query hugepages ({e})")
            failed = True
            continue

        try:
            hp = int(out.splitlines()[-1]) if out else -1
        except ValueError:
            hp = -1

        print(f"  node {ip}: vm.nr_hugepages={hp} (required >= {min_hp})")
        if err:
            print(f"  node {ip}: ssh stderr: {err}")

        if hp < min_hp:
            failed = True

        if force_hugepage and ip in required_per_ip_numa:
            numa_id, min_numa_hp = required_per_ip_numa[ip]
            cmd_numa = (
                "bash -lc '"
                f"cat /sys/devices/system/node/node{numa_id}/hugepages/hugepages-2048kB/free_hugepages 2>/dev/null || echo -1'"
            )
            try:
                ssh, stdin, stdout, stderr = ssh_command(ip, username, password, cmd_numa)
                out_numa = stdout.read().decode("utf-8", errors="replace").strip()
                err_numa = stderr.read().decode("utf-8", errors="replace").strip()
                ssh.close()
            except Exception as e:
                print(f"preflight error on {ip}: cannot query NUMA hugepages ({e})")
                failed = True
                continue

            try:
                hp_numa = int(out_numa.splitlines()[-1]) if out_numa else -1
            except ValueError:
                hp_numa = -1

            print(f"  node {ip}: node{numa_id}.free_hugepages={hp_numa} (required >= {min_numa_hp})")
            if err_numa:
                print(f"  node {ip}: ssh stderr (numa): {err_numa}")
            if hp_numa < min_numa_hp:
                failed = True

    if failed:
        print("preflight failed: hugepages are insufficient on one or more nodes.")
        print("run: python3 ../script/all_hugepage.py")
        return False
    return True

def get_res_name(s, postfix=""):
    if postfix:
        postfix = "-" + postfix
    return '../result/' + s + postfix + strftime("-%m-%d-%H-%M", gmtime())  + ".txt"

def main():
    parser = argparse.ArgumentParser(description="run deft benchmark")
    parser.add_argument("--smoke", action="store_true", help="run fast test")
    parser.add_argument("--small", action="store_true", help="run small benchmark")
    parser.add_argument("--mid", action="store_true", help="run medium benchmark")
    parser.add_argument("--big", action="store_true", help="run big benchmark")
    parser.add_argument("--threads-per-client", type=int, default=None,
                        help="override benchmark threads per client")
    parser.add_argument("--key-space", type=int, default=None,
                        help="override key space")
    parser.add_argument("--read-ratio", type=int, default=None,
                        help="override read ratio [0..100]")
    parser.add_argument("--zipf", type=float, default=None,
                        help="override zipf factor")
    parser.add_argument("--prefill-threads", type=int, default=None,
                        help="override prefill threads per client process")
    parser.add_argument("--force-hugepage", action="store_true",
                        help="set DEFT_FORCE_HUGEPAGE=1 instead of DEFT_DISABLE_HUGEPAGE=1")
    parser.add_argument("--name", type=str, default="", help="name for result file")
    args, _ = parser.parse_known_args()

    if not os.path.exists('../result'):
        os.makedirs('../result')
    if not os.path.exists('../log'):
        os.makedirs('../log')

    try:
        with open('../script/global_config.yaml', 'r') as f:
            g_cfg = yaml.safe_load(f)
    except FileNotFoundError:
        print("error: global_config.yaml not found. run gen_config.py first.")
        sys.exit(1)

    num_servers = len(g_cfg.get('servers', []))
    num_clients = len(g_cfg.get('clients', []))

    if num_servers == 0 or num_clients == 0:
        print("error: no servers or clients in config")
        sys.exit(1)

    print(f"topology: {num_servers} servers, {num_clients} clients")
    if not check_hugepages(g_cfg, force_hugepage=args.force_hugepage):
        sys.exit(1)

    if args.smoke:
        threads_CN_arr = [1]
        key_space_arr = [1000]
        read_ratio_arr = [50]
        zipf_arr = [0.99]
    elif args.small:
        threads_CN_arr = [5]
        key_space_arr = [10e6]
        read_ratio_arr = [50]
        zipf_arr = [0.99]
    elif args.mid:
        threads_CN_arr = [15]
        key_space_arr = [100e6]
        read_ratio_arr = [50]
        zipf_arr = [0.99]
    elif args.big:
        threads_CN_arr = [30]
        key_space_arr = [400e6]
        read_ratio_arr = [50]
        zipf_arr = [0.99]
    else:
        threads_CN_arr = [30]
        key_space_arr = [400e6]
        read_ratio_arr = [50]
        zipf_arr = [0.99]

    file_postfix = args.name if args.name else ("smoke" if args.smoke else "")
    file_name = get_res_name("bench", file_postfix)

    exe_path = f'{g_cfg["src_path"]}/{g_cfg["app_rel_path"]}'
    username = g_cfg['username']
    password = g_cfg['password']
    # Clemson/CloudLab experiment network is typically on mlx5_2 (10.10.1.x).
    rnic_id = int(g_cfg.get('rnic_id', 2))
    hp_env = "DEFT_FORCE_HUGEPAGE=1" if args.force_hugepage else "DEFT_DISABLE_HUGEPAGE=1"
    print(f"memory mode: {'force_hugepage' if args.force_hugepage else 'disable_hugepage'}")
    had_any_error = False

    with open(file_name, 'w') as fp:
        if args.threads_per_client is not None:
            threads_CN_arr = [args.threads_per_client]
        if args.key_space is not None:
            key_space_arr = [args.key_space]
        if args.read_ratio is not None:
            read_ratio_arr = [args.read_ratio]
        if args.zipf is not None:
            zipf_arr = [args.zipf]

        product_list = list(product(key_space_arr, read_ratio_arr, zipf_arr, threads_CN_arr))

        for job_id, (key_space, read_ratio, zipf, num_threads) in enumerate(product_list):
            key_space = int(key_space)
            num_prefill_threads = num_threads if args.smoke else 30
            if args.prefill_threads is not None:
                num_prefill_threads = args.prefill_threads

            print(f'\nstarting job {job_id + 1}/{len(product_list)}: total_threads={num_threads * num_clients} clients={num_clients} threads_per_client={num_threads} key_space={key_space} read_ratio={read_ratio} zipf={zipf}')
            fp.write(f'total_threads: {num_threads * num_clients} num_servers: {num_servers} num_clients: {num_clients} num_threads: {num_threads} key_space: {key_space} read_ratio: {read_ratio} zipf: {zipf}\n')
            fp.flush()

            print("restarting memcache...")
            subprocess.run('cd ../script && ./restartMemc.sh', shell=True)

            server_sshs = []
            server_stdouts = []
            server_stderrs = []
            for i in range(num_servers):
                ip = g_cfg['servers'][i]['ip']
                numa_id = g_cfg['servers'][i]['numa_id']
                print(f'start server {i} on {ip} (numa {numa_id})')
                cmd = (
                    f'cd {exe_path} && '
                    'sudo sh -c "echo 3 > /proc/sys/vm/drop_caches" && '
                    f'sudo bash -c "ulimit -l unlimited && numactl --membind={numa_id} --cpunodebind={numa_id} '
                    f'stdbuf -oL -eL env {hp_env} '
                    f'./{g_cfg["server_app"]} '
                    f'--server_count {num_servers} --client_count {num_clients} '
                    f'--numa_id {numa_id} --rnic_id {rnic_id} > ../log/server_{i}.log 2>&1"'
                )
                print(f'  server {i} cmd: {cmd}')

                ssh, stdin, stdout, stderr = ssh_command(ip, username, password, cmd)
                server_sshs.append(ssh)
                server_stdouts.append(stdout)
                server_stderrs.append(stderr)
                time.sleep(1)

            time.sleep(2)

            client_sshs = []
            client_stdouts = []
            client_stderrs = []
            for i in range(num_clients):
                ip = g_cfg['clients'][i]['ip']
                numa_id = g_cfg['clients'][i]['numa_id']
                print(f'start client {i} on {ip} (numa {numa_id})')
                cmd = (
                    f'cd {exe_path} && '
                    f'sudo bash -c "ulimit -l unlimited && numactl --membind={numa_id} --cpunodebind={numa_id} '
                    f'stdbuf -oL -eL env {hp_env} '
                    f'./{g_cfg["client_app"]} '
                    f'--server_count {num_servers} --client_count {num_clients} '
                    f'--numa_id {numa_id} --rnic_id {rnic_id} --num_prefill_threads {num_prefill_threads} '
                    f'--num_bench_threads {num_threads} --key_space {key_space} '
                    f'--read_ratio {read_ratio} --zipf {zipf} '
                    f'> ../log/client_{i}.log 2>&1"'
                )
                print(f'  client {i} cmd: {cmd}')
                ssh, stdin, stdout, stderr = ssh_command(ip, username, password, cmd)
                client_sshs.append(ssh)
                client_stdouts.append(stdout)
                client_stderrs.append(stderr)
                time.sleep(1)

            print("waiting to finish...")
            finish = False
            has_error = False
            server_exit_codes = [None] * num_servers
            client_exit_codes = [None] * num_clients
            while not finish and not has_error:
                time.sleep(2)
                finish = True
                for i in range(num_servers):
                    if server_stdouts[i].channel.exit_status_ready():
                        code = server_stdouts[i].channel.recv_exit_status()
                        server_exit_codes[i] = code
                        if code != 0:
                            has_error = True
                            print(f'server {i} failed with exit code {code}')
                            break
                    else:
                        finish = False

                if not has_error:
                    for i in range(num_clients):
                        if client_stdouts[i].channel.exit_status_ready():
                            code = client_stdouts[i].channel.recv_exit_status()
                            client_exit_codes[i] = code
                            if code != 0:
                                has_error = True
                                print(f'client {i} failed with exit code {code}')
                                break
                        else:
                            finish = False

            if has_error:
                had_any_error = True
                print("error: killing processes")
                for i in range(num_servers):
                    if server_stderrs[i].channel.recv_ready():
                        stderr_msg = server_stderrs[i].read().decode("utf-8", errors="replace").strip()
                        if stderr_msg:
                            print(f'server {i} ssh stderr: {stderr_msg}')
                    ip = g_cfg['servers'][i]['ip']
                    abs_log = f'{g_cfg["src_path"]}/log/server_{i}.log'
                    dump_remote_log(ip, username, password, abs_log, "server", i)

                for i in range(num_clients):
                    if client_stderrs[i].channel.recv_ready():
                        stderr_msg = client_stderrs[i].read().decode("utf-8", errors="replace").strip()
                        if stderr_msg:
                            print(f'client {i} ssh stderr: {stderr_msg}')
                    ip = g_cfg['clients'][i]['ip']
                    abs_log = f'{g_cfg["src_path"]}/log/client_{i}.log'
                    dump_remote_log(ip, username, password, abs_log, "client", i)

                killall.killall()

            for i in range(num_servers):
                server_sshs[i].close()
            for i in range(num_clients):
                client_sshs[i].close()

            if not has_error:
                print("reading results from client 0...")
                loading_subproc = subprocess.run(f'grep "Loading Results" ../log/client_0.log', stdout=subprocess.PIPE, shell=True)
                tmp = loading_subproc.stdout.decode("utf-8")
                if tmp:
                    print(tmp.strip())
                    fp.write(tmp)
                else:
                    print("warning: cannot find loading results")

                res_subproc = subprocess.run(f'grep "Final Results" ../log/client_0.log', stdout=subprocess.PIPE, shell=True)
                tmp = res_subproc.stdout.decode("utf-8")
                if tmp:
                    print(tmp.strip())
                    fp.write(tmp + "\n")
                else:
                    print("warning: cannot find final results")
                fp.flush()

            print("cleaning up...")
            subprocess.run(f'cd ../script && ./killall.py', stdout=subprocess.DEVNULL, shell=True)

            if job_id < len(product_list) - 1:
                print("wait before next job...")
                time.sleep(5)

    print(f"\ndone. saved to {file_name}")
    if had_any_error:
        sys.exit(1)

if __name__ == '__main__':
    main()

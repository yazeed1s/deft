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

    file_name = get_res_name("bench", args.name if not args.smoke else "smoke")

    exe_path = f'{g_cfg["src_path"]}/{g_cfg["app_rel_path"]}'
    username = g_cfg['username']
    password = g_cfg['password']

    with open(file_name, 'w') as fp:
        product_list = list(product(key_space_arr, read_ratio_arr, zipf_arr, threads_CN_arr))

        for job_id, (key_space, read_ratio, zipf, num_threads) in enumerate(product_list):
            key_space = int(key_space)
            num_prefill_threads = num_threads if args.smoke else 30

            print(f'\nstarting job {job_id + 1}/{len(product_list)}: total_threads={num_threads * num_clients} clients={num_clients} threads_per_client={num_threads} key_space={key_space} read_ratio={read_ratio} zipf={zipf}')
            fp.write(f'total_threads: {num_threads * num_clients} num_servers: {num_servers} num_clients: {num_clients} num_threads: {num_threads} key_space: {key_space} read_ratio: {read_ratio} zipf: {zipf}\n')
            fp.flush()

            print("restarting memcache...")
            subprocess.run('cd ../script && ./restartMemc.sh', shell=True)

            server_sshs = []
            server_stdouts = []
            for i in range(num_servers):
                ip = g_cfg['servers'][i]['ip']
                numa_id = g_cfg['servers'][i]['numa_id']
                print(f'start server {i} on {ip} (numa {numa_id})')
                cmd = f'cd {exe_path} && sudo sh -c "echo 3 > /proc/sys/vm/drop_caches" && numactl --membind={numa_id} --cpunodebind={numa_id} ./{g_cfg["server_app"]} --server_count {num_servers} --client_count {num_clients} --numa_id {numa_id} &> ../log/server_{i}.log'

                ssh, stdin, stdout, stderr = ssh_command(ip, username, password, cmd)
                server_sshs.append(ssh)
                server_stdouts.append(stdout)
                time.sleep(1)

            time.sleep(2)

            client_sshs = []
            client_stdouts = []
            for i in range(num_clients):
                ip = g_cfg['clients'][i]['ip']
                numa_id = g_cfg['clients'][i]['numa_id']
                print(f'start client {i} on {ip} (numa {numa_id})')
                cmd = f'cd {exe_path} && numactl --membind={numa_id} --cpunodebind={numa_id} ./{g_cfg["client_app"]} --server_count {num_servers} --client_count {num_clients} --numa_id {numa_id} --num_prefill_threads {num_prefill_threads} --num_bench_threads {num_threads} --key_space {key_space} --read_ratio {read_ratio} --zipf {zipf} &> ../log/client_{i}.log'
                ssh, stdin, stdout, stderr = ssh_command(ip, username, password, cmd)
                client_sshs.append(ssh)
                client_stdouts.append(stdout)
                time.sleep(1)

            print("waiting to finish...")
            finish = False
            has_error = False
            while not finish and not has_error:
                time.sleep(2)
                finish = True
                for i in range(num_servers):
                    if server_stdouts[i].channel.exit_status_ready():
                        if server_stdouts[i].channel.recv_exit_status() != 0:
                            has_error = True
                            print(f'server {i} failed')
                            break
                    else:
                        finish = False
                
                if not has_error:
                    for i in range(num_clients):
                        if client_stdouts[i].channel.exit_status_ready():
                            if client_stdouts[i].channel.recv_exit_status() != 0:
                                has_error = True
                                print(f'client {i} failed')
                                break
                        else:
                            finish = False

            if has_error:
                print("error: killing processes")
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

if __name__ == '__main__':
    main()

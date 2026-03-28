#define STRIP_FLAG_HELP 1 // this must go before the #include!
#include "Timer.h"
#include "Tree.h"
#include "dsm_server.h"
#include "zipf.h"
#include <gflags/gflags.h>

#include <city.h>
#include <stdlib.h>
#include <thread>
#include <time.h>
#include <unistd.h>
#include <vector>

//////////////////// workload parameters /////////////////////

DEFINE_int32(numa_id, 0, "numa node id");
DEFINE_int32(rnic_id, 0, "rdma device index (ibv device id)");
DEFINE_int32(server_count, 1, "server count");
DEFINE_int32(client_count, 1, "client count");
// int kReadRatio;
// double zipfan = 0;



DSMServer *dsm_server;

void print_args() {
  printf("ServerCount %d, ClientCount %d\n", FLAGS_server_count,
         FLAGS_client_count);
}

int main(int argc, char *argv[]) {
  gflags::ParseCommandLineFlags(&argc, &argv, true);
  print_args();

  DSMConfig config;
  config.rnic_id = FLAGS_rnic_id;
  config.num_server = FLAGS_server_count;
  config.num_client = FLAGS_client_count;
  dsm_server = DSMServer::GetInstance(config);

  dsm_server->Run();

  printf("server stopped\n");
  return 0;
}

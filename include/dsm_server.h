#pragma once

#include <atomic>

#include "Config.h"
#include "GlobalAddress.h"

#ifdef USE_CXL
#include "CxlTransport.h"
#include "GlobalAllocator.h"
#include "RawMessageConnection.h"  // for RawMessage / RpcType
#include "dsm_keeper.h"            // for Keeper base class
#else
#include "connection.h"
#include "dsm_keeper.h"
#include "Directory.h"
#endif

class DSMServer {
 public:
  static DSMServer* GetInstance(const DSMConfig& conf) {
    static DSMServer server(conf);
    return &server;
  }

  void Run();

 private:
  DSMConfig conf_;
  uint64_t base_addr_;
  uint32_t my_server_id_;

#ifdef USE_CXL
  // CXL shared-memory regions
  cxl::SharedRegion dsm_region_;    // main disaggregated memory pool
  cxl::SharedRegion lock_region_;   // lock memory (replaces on-chip DM)
  cxl::SharedRegion rpc_region_;    // inter-process RPC message queues

  // One allocator per directory (same as RDMA path)
  GlobalAllocator *chunk_alloc_[NR_DIRECTORY];

  // Coordination
  Keeper *keeper_;

  void InitCxlMemory();
  void ProcessMessage(const RawMessage *m, uint16_t dir_id);
#else
  DSMServerKeeper *keeper_;
  RemoteConnectionToClient *conn_to_client_;
  DirectoryConnection *dir_con_[NR_DIRECTORY];
  Directory *dir_agent_[NR_DIRECTORY];

  void InitRdmaConnection();
#endif

  DSMServer(const DSMConfig &conf);
};

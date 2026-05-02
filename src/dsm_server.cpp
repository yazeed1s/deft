#include "dsm_server.h"

#ifdef USE_CXL
// =========================================================================
// CXL server implementation
// =========================================================================
#include "HugePageAlloc.h"

// Global root pointer shared between directories (same as RDMA path)
static GlobalAddress g_root_ptr = GlobalAddress::Null();
static int g_root_level = -1;

DSMServer::DSMServer(const DSMConfig &conf) : conf_(conf) {
  InitCxlMemory();

  // Simple keeper for barrier / coordination (transport-agnostic)
  keeper_ = new Keeper();
  if (!keeper_->ConnectMemcached()) {
    Debug::notifyError("DSMServer: could not connect to memcached");
  }

  // Register ourselves as a server
  uint64_t server_num;
  while (true) {
    memcached_return rc = memcached_increment(
        keeper_->memc, "ServerNum", strlen("ServerNum"), 1, &server_num);
    if (rc == MEMCACHED_SUCCESS) {
      my_server_id_ = server_num - 1;
      break;
    }
    usleep(10000);
  }
  printf("CXL server %d ready\n", my_server_id_);

  // Publish DSM region info so clients can open them
  // Key: "cxl_dsm_base_<server_id>" -> base_addr as uint64_t
  // Key: "cxl_dsm_size_<server_id>" -> dsm_size
  // Key: "cxl_lock_size_<server_id>" -> lock_size
  {
    std::string key;
    key = "cxl_dsm_base_" + std::to_string(my_server_id_);
    uint64_t dsm_base = (uint64_t)dsm_region_.base_addr;
    keeper_->MemcSet(key.c_str(), key.size(), (char *)&dsm_base,
                     sizeof(dsm_base));

    key = "cxl_dsm_size_" + std::to_string(my_server_id_);
    uint64_t dsm_sz = dsm_region_.size;
    keeper_->MemcSet(key.c_str(), key.size(), (char *)&dsm_sz,
                     sizeof(dsm_sz));

    key = "cxl_lock_base_" + std::to_string(my_server_id_);
    uint64_t lock_base = (uint64_t)lock_region_.base_addr;
    keeper_->MemcSet(key.c_str(), key.size(), (char *)&lock_base,
                     sizeof(lock_base));

    key = "cxl_lock_size_" + std::to_string(my_server_id_);
    uint64_t lock_sz = lock_region_.size;
    keeper_->MemcSet(key.c_str(), key.size(), (char *)&lock_sz,
                     sizeof(lock_sz));

    key = "cxl_rpc_size_" + std::to_string(my_server_id_);
    uint64_t rpc_sz = rpc_region_.size;
    keeper_->MemcSet(key.c_str(), key.size(), (char *)&rpc_sz,
                     sizeof(rpc_sz));
  }

  keeper_->Barrier("DSMServer-init", conf_.num_server, my_server_id_ == 0);
}

void DSMServer::InitCxlMemory() {
  uint64_t dsm_size_bytes = (uint64_t)conf_.dsm_size * define::GB;

  // 1. Create the DSM memory pool as a POSIX shared-memory region.
  //    Unlike the RDMA path, we don't use hugePageAlloc + ibv_reg_mr.
  //    The shared region itself IS the disaggregated memory.
  dsm_region_ = cxl::create_region("/deft_dsm", dsm_size_bytes);
  base_addr_ = (uint64_t)dsm_region_.base_addr;
  Debug::notifyInfo("CXL DSM pool: %p, %lu GB", dsm_region_.base_addr,
                    conf_.dsm_size);

  // Warm up (fault in pages, same as RDMA path)
  for (uint64_t i = 0; i < dsm_size_bytes; i += 2 * define::MB) {
    *(volatile char *)((char *)dsm_region_.base_addr + i) = 0;
  }
  // Clear first chunk
  memset(dsm_region_.base_addr, 0, define::kChunkSize);

  // 2. Create lock memory region (replaces on-chip device memory)
  uint64_t lock_size = define::kLockChipMemSize;
  lock_region_ = cxl::create_region("/deft_lock", lock_size);
  Debug::notifyInfo("CXL lock region: %p, %lu bytes",
                    lock_region_.base_addr, lock_size);

  // 3. Create RPC region for message queues
  uint64_t rpc_size =
      cxl::rpc_region_size(conf_.num_client, MAX_APP_THREAD, NR_DIRECTORY);
  rpc_region_ = cxl::create_region("/deft_rpc", rpc_size);
  cxl::init_rpc_region(rpc_region_.base_addr, conf_.num_client,
                       MAX_APP_THREAD, NR_DIRECTORY);
  Debug::notifyInfo("CXL RPC region: %p, %lu bytes",
                    rpc_region_.base_addr, rpc_size);

  // 4. Set up chunk allocators (one per directory, same as RDMA path)
  uint64_t per_dir_size = dsm_size_bytes / NR_DIRECTORY;
  for (int i = 0; i < NR_DIRECTORY; ++i) {
    GlobalAddress start;
    start.nodeID = 0;  // single server in CXL mode
    start.offset = per_dir_size * i;
    chunk_alloc_[i] = new GlobalAllocator(start, per_dir_size);
  }

  Debug::notifyInfo("CXL server memory initialized: dsm=%lu GB, "
                    "lock=%lu KB, rpc=%lu KB",
                    conf_.dsm_size, lock_size / 1024, rpc_size / 1024);
}

void DSMServer::ProcessMessage(const RawMessage *m, uint16_t dir_id) {
  RawMessage reply;
  bool has_reply = false;

  switch (m->type) {
  case RpcType::MALLOC: {
    reply.addr = chunk_alloc_[dir_id]->alloc_chunck();
    has_reply = true;
    break;
  }
  case RpcType::NEW_ROOT: {
    if (g_root_level < m->level) {
      g_root_ptr = m->addr;
      g_root_level = m->level;
    }
    break;
  }
  case RpcType::TERMINATE: {
    Debug::notifyInfo("CXL server: received TERMINATE");
    // Signal all directory threads to stop — in single-threaded mode
    // we just return from Run().
    return;
  }
  default:
    Debug::notifyError("CXL server: unknown RPC type %d", (int)m->type);
    break;
  }

  // Send reply back through the client's reply queue
  if (has_reply) {
    auto *rep_q =
        cxl::get_reply_queue(rpc_region_.base_addr, m->node_id, m->app_id);
    cxl::rpc_send(rep_q, &reply, sizeof(reply));
  }
}

void DSMServer::Run() {
  Debug::notifyInfo("CXL server %d running (polling RPC queues)...",
                    my_server_id_);

  // Poll all request queues across all app threads and directories.
  // This is the CXL equivalent of the RDMA server's ibv_poll_cq loop.
  bool running = true;
  while (running) {
    for (uint32_t c = 0; c < (uint32_t)conf_.num_client && running; ++c) {
      for (uint32_t t = 0; t < MAX_APP_THREAD && running; ++t) {
        for (uint32_t d = 0; d < NR_DIRECTORY && running; ++d) {
          auto *req_q =
              cxl::get_request_queue(rpc_region_.base_addr, c, t, d);

          RawMessage m;
          if (cxl::rpc_try_recv(req_q, &m, sizeof(m))) {
            ProcessMessage(&m, d);
            if (m.type == RpcType::TERMINATE) {
              running = false;
            }
          }
        }
      }
    }
  }

  Debug::notifyInfo("CXL server %d stopped", my_server_id_);
}

#else
// =========================================================================
// RDMA server implementation (original, unchanged)
// =========================================================================
#include "DirectoryConnection.h"

DSMServer::DSMServer(const DSMConfig &conf) : conf_(conf) {
  base_addr_ = (uint64_t)hugePageAlloc(conf.dsm_size * define::GB);
  Debug::notifyInfo("number of threads on memory node: %d", NR_DIRECTORY);

  // warmup
  for (uint64_t i = base_addr_; i < base_addr_ + conf.dsm_size * define::GB;
       i += 2 * define::MB) {
    *(char *)i = 0;
  }

  // clear up first chunk
  memset((char *)base_addr_, 0, define::kChunkSize);

  InitRdmaConnection();
  Debug::notifyInfo("number of threads on memory node: %d", NR_DIRECTORY);
  for (int i = 0; i < NR_DIRECTORY; ++i) {
    dir_agent_[i] = new Directory(dir_con_[i], i, my_server_id_);
  }

  keeper_->Barrier("DSMServer-init", conf_.num_server, my_server_id_ == 0);
}

void DSMServer::InitRdmaConnection() {
  Debug::notifyInfo("number of servers: %d", conf_.num_server);
  conn_to_client_ = new RemoteConnectionToClient[conf_.num_client];

  for (int i = 0; i < NR_DIRECTORY; ++i) {
    dir_con_[i] = new DirectoryConnection(
        i, (void *)base_addr_, conf_.dsm_size * define::GB, conf_.num_client,
        conf_.rnic_id, conn_to_client_);
  }

  keeper_ = new DSMServerKeeper(dir_con_, conn_to_client_, conf_.num_client);
  my_server_id_ = keeper_->get_my_server_id();
}

void DSMServer::Run() {
  for (int i = 1; i < NR_DIRECTORY; ++i) {
    dir_agent_[i]->dirTh =
        new std::thread(&Directory::dirThread, dir_agent_[i]);
  }

  dir_agent_[0]->dirThread();
  for (int i = 1; i < NR_DIRECTORY; ++i) {
    dir_agent_[i]->stop_flag.store(true, std::memory_order_release);
    if (dir_agent_[i]->dirTh->joinable()) {
      dir_agent_[i]->dirTh->join();
    }
  }
}

#endif  // USE_CXL

#pragma once

#include <atomic>

#include "Cache.h"
#include "Config.h"
#include "GlobalAddress.h"
#include "LocalAllocator.h"
#include "RdmaBuffer.h"
#include "RawMessageConnection.h"   // RawMessage, RpcType (transport-agnostic)

#ifdef USE_RDMA
#include "connection.h"
#include "dsm_keeper.h"
#include "ThreadConnection.h"
#endif

#ifdef USE_CXL
#include "CxlTransport.h"
#include "dsm_keeper.h"   // for Keeper base class (memcached)
#endif

class Directory;

class DSMClient {
 public:
  static DSMClient *GetInstance(const DSMConfig &conf) {
    static DSMClient dsm(conf);
    return &dsm;
  }

  // clear the network resources for all threads
  void ResetThread() { app_id_.store(0); }
  // obtain netowrk resources for a thread
  void RegisterThread();
  bool IsRegistered() { return thread_id_ != -1; }

  uint16_t get_my_client_id() { return my_client_id_; }
  uint16_t get_my_thread_id() { return thread_id_; }
  uint16_t get_server_size() { return conf_.num_server; }
  uint16_t get_client_size() { return conf_.num_client; }
  uint64_t get_thread_tag() { return thread_tag_; }

  void Barrier(const std::string &ss) {
    keeper_->Barrier(ss, conf_.num_client, my_client_id_ == 0);
  }

  char *get_rdma_buffer() { return rdma_buffer_; }
  RdmaBuffer &get_rbuf(int coro_id) { return rbuf_[coro_id]; }

  // RDMA operations
  // buffer is registered memory
  void Read(char *buffer, GlobalAddress gaddr, size_t size, bool signal,
            CoroContext *ctx = nullptr);
  void ReadSync(char *buffer, GlobalAddress gaddr, size_t size,
                CoroContext *ctx = nullptr);

  void Write(const char *buffer, GlobalAddress gaddr, size_t size,
             bool signal = true, CoroContext *ctx = nullptr);
  void WriteSync(const char *buffer, GlobalAddress gaddr, size_t size,
                 CoroContext *ctx = nullptr);

  void ReadBatch(RdmaOpRegion *rs, int k, bool signal = true,
                 CoroContext *ctx = nullptr);
  void ReadBatchSync(RdmaOpRegion *rs, int k, CoroContext *ctx = nullptr);

  void WriteBatch(RdmaOpRegion *rs, int k, bool signal = true,
                  CoroContext *ctx = nullptr);
  void WriteBatchSync(RdmaOpRegion *rs, int k, CoroContext *ctx = nullptr);

  void WriteFaa(RdmaOpRegion &write_ror, RdmaOpRegion &faa_ror,
                uint64_t add_val, bool signal = true,
                CoroContext *ctx = nullptr);
  void WriteFaaSync(RdmaOpRegion &write_ror, RdmaOpRegion &faa_ror,
                    uint64_t add_val, CoroContext *ctx = nullptr);

  void WriteCas(RdmaOpRegion &write_ror, RdmaOpRegion &cas_ror, uint64_t equal,
                uint64_t val, bool signal = true, CoroContext *ctx = nullptr);
  void WriteCasSync(RdmaOpRegion &write_ror, RdmaOpRegion &cas_ror,
                    uint64_t equal, uint64_t val, CoroContext *ctx = nullptr);

  void Cas(GlobalAddress gaddr, uint64_t equal, uint64_t val,
           uint64_t *rdma_buffer, bool signal = true,
           CoroContext *ctx = nullptr);
  bool CasSync(GlobalAddress gaddr, uint64_t equal, uint64_t val,
               uint64_t *rdma_buffer, CoroContext *ctx = nullptr);

  void CasRead(RdmaOpRegion &cas_ror, RdmaOpRegion &read_ror, uint64_t equal,
               uint64_t val, bool signal = true, CoroContext *ctx = nullptr);
  bool CasReadSync(RdmaOpRegion &cas_ror, RdmaOpRegion &read_ror,
                   uint64_t equal, uint64_t val, CoroContext *ctx = nullptr);

  void FaaRead(RdmaOpRegion &faab_ror, RdmaOpRegion &read_ror, uint64_t add,
               bool signal = true, CoroContext *ctx = nullptr);
  void FaaReadSync(RdmaOpRegion &faab_ror, RdmaOpRegion &read_ror, uint64_t add,
                   CoroContext *ctx = nullptr);

  void FaaBoundRead(RdmaOpRegion &faab_ror, RdmaOpRegion &read_ror,
                    uint64_t add, uint64_t boundary, bool signal = true,
                    CoroContext *ctx = nullptr);
  void FaaBoundReadSync(RdmaOpRegion &faab_ror, RdmaOpRegion &read_ror,
                        uint64_t add, uint64_t boundary,
                        CoroContext *ctx = nullptr);

  void CasMask(GlobalAddress gaddr, int log_sz, uint64_t equal, uint64_t val,
               uint64_t *rdma_buffer, uint64_t mask = ~(0ull),
               bool signal = true, CoroContext *ctx = nullptr);
  bool CasMaskSync(GlobalAddress gaddr, int log_sz, uint64_t equal,
                   uint64_t val, uint64_t *rdma_buffer, uint64_t mask = ~(0ull),
                   CoroContext *ctx = nullptr);

  void CasMaskWrite(RdmaOpRegion &cas_ror, uint64_t equal, uint64_t swap,
                    uint64_t mask, RdmaOpRegion &write_ror, bool signal = true,
                    CoroContext *ctx = nullptr);
  bool CasMaskWriteSync(RdmaOpRegion &cas_ror, uint64_t equal, uint64_t swap,
                        uint64_t mask, RdmaOpRegion &write_ror,
                        CoroContext *ctx = nullptr);

  void FaaBound(GlobalAddress gaddr, int log_sz, uint64_t add_val,
                uint64_t *rdma_buffer, uint64_t mask, bool signal = true,
                CoroContext *ctx = nullptr);
  void FaaBoundSync(GlobalAddress gaddr, int log_sz, uint64_t add_val,
                    uint64_t *rdma_buffer, uint64_t mask,
                    CoroContext *ctx = nullptr);

  // for on-chip device memory
  void ReadDm(char *buffer, GlobalAddress gaddr, size_t size,
              bool signal = true, CoroContext *ctx = nullptr);
  void ReadDmSync(char *buffer, GlobalAddress gaddr, size_t size,
                  CoroContext *ctx = nullptr);

  void WriteDm(const char *buffer, GlobalAddress gaddr, size_t size,
               bool signal = true, CoroContext *ctx = nullptr);
  void WriteDmSync(const char *buffer, GlobalAddress gaddr, size_t size,
                   CoroContext *ctx = nullptr);

  void CasDm(GlobalAddress gaddr, uint64_t equal, uint64_t val,
             uint64_t *rdma_buffer, bool signal = true,
             CoroContext *ctx = nullptr);
  bool CasDmSync(GlobalAddress gaddr, uint64_t equal, uint64_t val,
                 uint64_t *rdma_buffer, CoroContext *ctx = nullptr);

  void CasDmMask(GlobalAddress gaddr, int log_sz, uint64_t equal, uint64_t val,
                 uint64_t *rdma_buffer, uint64_t mask = ~(0ull),
                 bool signal = true, CoroContext *ctx = nullptr);
  bool CasDmMaskSync(GlobalAddress gaddr, int log_sz, uint64_t equal,
                     uint64_t val, uint64_t *rdma_buffer,
                     uint64_t mask = ~(0ull), CoroContext *ctx = nullptr);

  void FaaDmBound(GlobalAddress gaddr, int log_sz, uint64_t add_val,
                  uint64_t *rdma_buffer, uint64_t mask, bool signal = true,
                  CoroContext *ctx = nullptr);
  void FaaDmBoundSync(GlobalAddress gaddr, int log_sz, uint64_t add_val,
                      uint64_t *rdma_buffer, uint64_t mask,
                      CoroContext *ctx = nullptr);

  uint64_t PollRdmaCq(int count = 1);
  bool PollRdmaCqOnce(uint64_t &wr_id);

  uint64_t Sum(uint64_t value) {
    static uint64_t count = 0;
    return keeper_->Sum(std::string("sum-") + std::to_string(count++), value,
                        my_client_id_, conf_.num_client);
  }

  GlobalAddress Alloc(size_t size);
  void Free(GlobalAddress addr) { local_allocator_.free(addr); }

  void RpcCallDir(const RawMessage &m, uint16_t node_id, uint16_t dir_id = 0);
  RawMessage *RpcWait();

 private:
  DSMConfig conf_;
  std::atomic_int app_id_;
  Cache cache_;
  uint32_t my_client_id_;

  static thread_local int thread_id_;
  static thread_local char *rdma_buffer_;
  static thread_local LocalAllocator local_allocator_;
  static thread_local RdmaBuffer rbuf_[define::kMaxCoro];
  static thread_local uint64_t thread_tag_;

  Keeper *keeper_;

#ifdef USE_RDMA
  static thread_local ThreadConnection *i_con_;
  RemoteConnectionToServer *conn_to_server_;
  ThreadConnection *th_con_[MAX_APP_THREAD];
  Directory *dir_agent_[NR_DIRECTORY];

  void InitRdmaConnection();
  void FillKeysDest(RdmaOpRegion &ror, GlobalAddress addr, bool is_chip);
#endif

#ifdef USE_CXL
  cxl::SharedRegion dsm_region_;
  cxl::SharedRegion lock_region_;
  cxl::SharedRegion rpc_region_;

  void InitCxlConnection();
  void *ResolveAddr(GlobalAddress gaddr);
  void *ResolveLockAddr(GlobalAddress gaddr);

  // Temporary buffer for RPC replies
  static thread_local RawMessage rpc_reply_buf_;
#endif

  DSMClient(const DSMConfig &conf);
};

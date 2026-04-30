#ifdef USE_RDMA

#include "dsm_client.h"

thread_local int DSMClient::thread_id_ = -1;
thread_local ThreadConnection *DSMClient::i_con_ = nullptr;
thread_local char *DSMClient::rdma_buffer_ = nullptr;
thread_local LocalAllocator DSMClient::local_allocator_;
thread_local RdmaBuffer DSMClient::rbuf_[define::kMaxCoro];
thread_local uint64_t DSMClient::thread_tag_ = 0;

DSMClient::DSMClient(const DSMConfig &conf)
    : conf_(conf), app_id_(0), cache_(conf.cache_size) {
  Debug::notifyInfo("cache size: %dGB", conf_.cache_size);
  InitRdmaConnection();
  keeper_->Barrier("DSMClient-init", conf_.num_client, my_client_id_ == 0);
}

void DSMClient::InitRdmaConnection() {
  conn_to_server_ = new RemoteConnectionToServer[conf_.num_server];

  for (int i = 0; i < MAX_APP_THREAD; ++i) {
    // client thread to servers
    th_con_[i] =
        new ThreadConnection(i, (void *)cache_.data, cache_.size * define::GB,
                             conf_.num_server, conf_.rnic_id, conn_to_server_);
  }

  keeper_ = new DSMClientKeeper(th_con_, conn_to_server_, conf_.num_server);
  my_client_id_ = keeper_->get_my_client_id();
}

void DSMClient::RegisterThread() {
  static bool has_init[MAX_APP_THREAD];

  if (thread_id_ != -1) return;

  thread_id_ = app_id_.fetch_add(1);
  thread_tag_ = thread_id_ + (((uint64_t)get_my_client_id()) << 32) + 1;

  i_con_ = th_con_[thread_id_];

  if (!has_init[thread_id_]) {
    i_con_->message->initRecv();
    i_con_->message->initSend();

    has_init[thread_id_] = true;
  }

  rdma_buffer_ = (char *)cache_.data + thread_id_ * define::kPerThreadRdmaBuf;

  for (int i = 0; i < define::kMaxCoro; ++i) {
    rbuf_[i].set_buffer(rdma_buffer_ + i * define::kPerCoroRdmaBuf);
  }
}

void DSMClient::Read(char *buffer, GlobalAddress gaddr, size_t size,
                     bool signal, CoroContext *ctx) {
  if (ctx == nullptr) {
    rdmaRead(i_con_->data[0][gaddr.nodeID], (uint64_t)buffer,
             conn_to_server_[gaddr.nodeID].dsm_base + gaddr.offset, size,
             i_con_->cacheLKey, conn_to_server_[gaddr.nodeID].dsm_rkey[0],
             signal);
  } else {
    rdmaRead(i_con_->data[0][gaddr.nodeID], (uint64_t)buffer,
             conn_to_server_[gaddr.nodeID].dsm_base + gaddr.offset, size,
             i_con_->cacheLKey, conn_to_server_[gaddr.nodeID].dsm_rkey[0], true,
             ctx->coro_id);
    (*ctx->yield)(*ctx->master);
  }
}

void DSMClient::ReadSync(char *buffer, GlobalAddress gaddr, size_t size,
                         CoroContext *ctx) {
  Read(buffer, gaddr, size, true, ctx);

  if (ctx == nullptr) {
    ibv_wc wc;
    pollWithCQ(i_con_->cq, 1, &wc);
  }
}

void DSMClient::Write(const char *buffer, GlobalAddress gaddr, size_t size,
                      bool signal, CoroContext *ctx) {
  if (ctx == nullptr) {
    rdmaWrite(i_con_->data[0][gaddr.nodeID], (uint64_t)buffer,
              conn_to_server_[gaddr.nodeID].dsm_base + gaddr.offset, size,
              i_con_->cacheLKey, conn_to_server_[gaddr.nodeID].dsm_rkey[0], -1,
              signal);
  } else {
    rdmaWrite(i_con_->data[0][gaddr.nodeID], (uint64_t)buffer,
              conn_to_server_[gaddr.nodeID].dsm_base + gaddr.offset, size,
              i_con_->cacheLKey, conn_to_server_[gaddr.nodeID].dsm_rkey[0], -1,
              true, ctx->coro_id);
    (*ctx->yield)(*ctx->master);
  }
}

void DSMClient::WriteSync(const char *buffer, GlobalAddress gaddr, size_t size,
                          CoroContext *ctx) {
  Write(buffer, gaddr, size, true, ctx);

  if (ctx == nullptr) {
    ibv_wc wc;
    pollWithCQ(i_con_->cq, 1, &wc);
  }
}

void DSMClient::FillKeysDest(RdmaOpRegion &ror, GlobalAddress gaddr,
                             bool is_chip) {
  ror.lkey = i_con_->cacheLKey;
  if (is_chip) {
    ror.dest = conn_to_server_[gaddr.nodeID].lock_base + gaddr.offset;
    ror.remoteRKey = conn_to_server_[gaddr.nodeID].lock_rkey[0];
  } else {
    ror.dest = conn_to_server_[gaddr.nodeID].dsm_base + gaddr.offset;
    ror.remoteRKey = conn_to_server_[gaddr.nodeID].dsm_rkey[0];
  }
}

void DSMClient::ReadBatch(RdmaOpRegion *rs, int k, bool signal,
                          CoroContext *ctx) {
  int node_id = -1;
  for (int i = 0; i < k; ++i) {
    GlobalAddress gaddr;
    gaddr.raw = rs[i].dest;
    node_id = gaddr.nodeID;
    FillKeysDest(rs[i], gaddr, rs[i].is_on_chip);
  }

  if (ctx == nullptr) {
    rdmaReadBatch(i_con_->data[0][node_id], rs, k, signal);
  } else {
    rdmaReadBatch(i_con_->data[0][node_id], rs, k, true, ctx->coro_id);
    (*ctx->yield)(*ctx->master);
  }
}

void DSMClient::ReadBatchSync(RdmaOpRegion *rs, int k, CoroContext *ctx) {
  ReadBatch(rs, k, true, ctx);

  if (ctx == nullptr) {
    ibv_wc wc;
    pollWithCQ(i_con_->cq, 1, &wc);
  }
}

void DSMClient::WriteBatch(RdmaOpRegion *rs, int k, bool signal,
                           CoroContext *ctx) {
  int node_id = -1;
  for (int i = 0; i < k; ++i) {
    GlobalAddress gaddr;
    gaddr.raw = rs[i].dest;
    node_id = gaddr.nodeID;
    FillKeysDest(rs[i], gaddr, rs[i].is_on_chip);
  }

  if (ctx == nullptr) {
    rdmaWriteBatch(i_con_->data[0][node_id], rs, k, signal);
  } else {
    rdmaWriteBatch(i_con_->data[0][node_id], rs, k, true, ctx->coro_id);
    (*ctx->yield)(*ctx->master);
  }
}

void DSMClient::WriteBatchSync(RdmaOpRegion *rs, int k, CoroContext *ctx) {
  WriteBatch(rs, k, true, ctx);

  if (ctx == nullptr) {
    ibv_wc wc;
    pollWithCQ(i_con_->cq, 1, &wc);
  }
}

void DSMClient::WriteFaa(RdmaOpRegion &write_ror, RdmaOpRegion &faa_ror,
                         uint64_t add_val, bool signal, CoroContext *ctx) {
  int node_id;
  {
    GlobalAddress gaddr;
    gaddr.raw = write_ror.dest;
    node_id = gaddr.nodeID;

    FillKeysDest(write_ror, gaddr, write_ror.is_on_chip);
  }
  {
    GlobalAddress gaddr;
    gaddr.raw = faa_ror.dest;

    FillKeysDest(faa_ror, gaddr, faa_ror.is_on_chip);
  }
  if (ctx == nullptr) {
    rdmaWriteFaa(i_con_->data[0][node_id], write_ror, faa_ror, add_val, signal);
  } else {
    rdmaWriteFaa(i_con_->data[0][node_id], write_ror, faa_ror, add_val, true,
                 ctx->coro_id);
    (*ctx->yield)(*ctx->master);
  }
}

void DSMClient::WriteFaaSync(RdmaOpRegion &write_ror, RdmaOpRegion &faa_ror,
                             uint64_t add_val, CoroContext *ctx) {
  WriteFaa(write_ror, faa_ror, add_val, true, ctx);
  if (ctx == nullptr) {
    ibv_wc wc;
    pollWithCQ(i_con_->cq, 1, &wc);
  }
}

void DSMClient::WriteCas(RdmaOpRegion &write_ror, RdmaOpRegion &cas_ror,
                         uint64_t equal, uint64_t val, bool signal,
                         CoroContext *ctx) {
  int node_id;
  {
    GlobalAddress gaddr;
    gaddr.raw = write_ror.dest;
    node_id = gaddr.nodeID;

    FillKeysDest(write_ror, gaddr, write_ror.is_on_chip);
  }
  {
    GlobalAddress gaddr;
    gaddr.raw = cas_ror.dest;

    FillKeysDest(cas_ror, gaddr, cas_ror.is_on_chip);
  }
  if (ctx == nullptr) {
    rdmaWriteCas(i_con_->data[0][node_id], write_ror, cas_ror, equal, val,
                 signal);
  } else {
    rdmaWriteCas(i_con_->data[0][node_id], write_ror, cas_ror, equal, val, true,
                 ctx->coro_id);
    (*ctx->yield)(*ctx->master);
  }
}

void DSMClient::WriteCasSync(RdmaOpRegion &write_ror, RdmaOpRegion &cas_ror,
                             uint64_t equal, uint64_t val, CoroContext *ctx) {
  WriteCas(write_ror, cas_ror, equal, val, true, ctx);
  if (ctx == nullptr) {
    ibv_wc wc;
    pollWithCQ(i_con_->cq, 1, &wc);
  }
}

void DSMClient::CasRead(RdmaOpRegion &cas_ror, RdmaOpRegion &read_ror,
                        uint64_t equal, uint64_t val, bool signal,
                        CoroContext *ctx) {
  int node_id;
  {
    GlobalAddress gaddr;
    gaddr.raw = cas_ror.dest;
    node_id = gaddr.nodeID;
    FillKeysDest(cas_ror, gaddr, cas_ror.is_on_chip);
  }
  {
    GlobalAddress gaddr;
    gaddr.raw = read_ror.dest;
    FillKeysDest(read_ror, gaddr, read_ror.is_on_chip);
  }

  if (ctx == nullptr) {
    rdmaCasRead(i_con_->data[0][node_id], cas_ror, read_ror, equal, val,
                signal);
  } else {
    rdmaCasRead(i_con_->data[0][node_id], cas_ror, read_ror, equal, val, true,
                ctx->coro_id);
    (*ctx->yield)(*ctx->master);
  }
}

bool DSMClient::CasReadSync(RdmaOpRegion &cas_ror, RdmaOpRegion &read_ror,
                            uint64_t equal, uint64_t val, CoroContext *ctx) {
  CasRead(cas_ror, read_ror, equal, val, true, ctx);

  if (ctx == nullptr) {
    ibv_wc wc;
    pollWithCQ(i_con_->cq, 1, &wc);
  }

  return equal == *(uint64_t *)cas_ror.source;
}

void DSMClient::FaaRead(RdmaOpRegion &faa_ror, RdmaOpRegion &read_ror,
                        uint64_t add, bool signal, CoroContext *ctx) {
  int node_id;
  {
    GlobalAddress gaddr;
    gaddr.raw = faa_ror.dest;
    node_id = gaddr.nodeID;
    FillKeysDest(faa_ror, gaddr, faa_ror.is_on_chip);
  }
  {
    GlobalAddress gaddr;
    gaddr.raw = read_ror.dest;
    FillKeysDest(read_ror, gaddr, read_ror.is_on_chip);
  }

  if (ctx == nullptr) {
    rdmaFaaRead(i_con_->data[0][node_id], faa_ror, read_ror, add, signal);
  } else {
    rdmaFaaRead(i_con_->data[0][node_id], faa_ror, read_ror, add, true,
                ctx->coro_id);
    (*ctx->yield)(*ctx->master);
  }
}

void DSMClient::FaaReadSync(RdmaOpRegion &faa_ror, RdmaOpRegion &read_ror,
                            uint64_t add, CoroContext *ctx) {
  FaaRead(faa_ror, read_ror, add, true, ctx);

  if (ctx == nullptr) {
    ibv_wc wc;
    pollWithCQ(i_con_->cq, 1, &wc);
  }
}

void DSMClient::FaaBoundRead(RdmaOpRegion &faab_ror, RdmaOpRegion &read_ror,
                             uint64_t add, uint64_t boundary, bool signal,
                             CoroContext *ctx) {
  int node_id;
  {
    GlobalAddress gaddr;
    gaddr.raw = faab_ror.dest;
    node_id = gaddr.nodeID;
    FillKeysDest(faab_ror, gaddr, faab_ror.is_on_chip);
  }
  {
    GlobalAddress gaddr;
    gaddr.raw = read_ror.dest;
    FillKeysDest(read_ror, gaddr, read_ror.is_on_chip);
  }

  if (ctx == nullptr) {
    rdmaFaaBoundRead(i_con_->data[0][node_id], faab_ror, read_ror, add,
                     boundary, signal);
  } else {
    rdmaFaaBoundRead(i_con_->data[0][node_id], faab_ror, read_ror, add,
                     boundary, true, ctx->coro_id);
    (*ctx->yield)(*ctx->master);
  }
}

void DSMClient::FaaBoundReadSync(RdmaOpRegion &faab_ror, RdmaOpRegion &read_ror,
                                 uint64_t add, uint64_t boundary,
                                 CoroContext *ctx) {
  FaaBoundRead(faab_ror, read_ror, add, boundary, true, ctx);

  if (ctx == nullptr) {
    ibv_wc wc;
    pollWithCQ(i_con_->cq, 1, &wc);
  }
}

void DSMClient::Cas(GlobalAddress gaddr, uint64_t equal, uint64_t val,
                    uint64_t *rdma_buffer, bool signal, CoroContext *ctx) {
  if (ctx == nullptr) {
    rdmaCompareAndSwap(i_con_->data[0][gaddr.nodeID], (uint64_t)rdma_buffer,
                       conn_to_server_[gaddr.nodeID].dsm_base + gaddr.offset,
                       equal, val, i_con_->cacheLKey,
                       conn_to_server_[gaddr.nodeID].dsm_rkey[0], signal);
  } else {
    rdmaCompareAndSwap(i_con_->data[0][gaddr.nodeID], (uint64_t)rdma_buffer,
                       conn_to_server_[gaddr.nodeID].dsm_base + gaddr.offset,
                       equal, val, i_con_->cacheLKey,
                       conn_to_server_[gaddr.nodeID].dsm_rkey[0], true,
                       ctx->coro_id);
    (*ctx->yield)(*ctx->master);
  }
}

bool DSMClient::CasSync(GlobalAddress gaddr, uint64_t equal, uint64_t val,
                        uint64_t *rdma_buffer, CoroContext *ctx) {
  Cas(gaddr, equal, val, rdma_buffer, true, ctx);

  if (ctx == nullptr) {
    ibv_wc wc;
    pollWithCQ(i_con_->cq, 1, &wc);
  }

  return equal == *rdma_buffer;
}

void DSMClient::CasMask(GlobalAddress gaddr, int log_sz, uint64_t equal,
                        uint64_t val, uint64_t *rdma_buffer, uint64_t mask,
                        bool signal, CoroContext *ctx) {
  if (ctx == nullptr) {
    rdmaCompareAndSwapMask(
        i_con_->data[0][gaddr.nodeID], (uint64_t)rdma_buffer,
        conn_to_server_[gaddr.nodeID].dsm_base + gaddr.offset, log_sz, equal,
        val, i_con_->cacheLKey, conn_to_server_[gaddr.nodeID].dsm_rkey[0], mask,
        signal);
  } else {
    rdmaCompareAndSwapMask(
        i_con_->data[0][gaddr.nodeID], (uint64_t)rdma_buffer,
        conn_to_server_[gaddr.nodeID].dsm_base + gaddr.offset, log_sz, equal,
        val, i_con_->cacheLKey, conn_to_server_[gaddr.nodeID].dsm_rkey[0], mask,
        true, ctx->coro_id);
    (*ctx->yield)(*ctx->master);
  }
}

bool DSMClient::CasMaskSync(GlobalAddress gaddr, int log_sz, uint64_t equal,
                            uint64_t val, uint64_t *rdma_buffer, uint64_t mask,
                            CoroContext *ctx) {
  CasMask(gaddr, log_sz, equal, val, rdma_buffer, mask, true, ctx);

  if (ctx == nullptr) {
    ibv_wc wc;
    pollWithCQ(i_con_->cq, 1, &wc);
  }

  if (log_sz <= 3) {
    return (equal & mask) == (*rdma_buffer & mask);
  } else {
    uint64_t *eq = (uint64_t *)equal;
    uint64_t *old = (uint64_t *)rdma_buffer;
    uint64_t *m = (uint64_t *)mask;
    for (int i = 0; i < (1 << (log_sz - 3)); i++) {
      if ((eq[i] & m[i]) != (__bswap_64(old[i]) & m[i])) {
        return false;
      }
    }
    return true;
  }
}

void DSMClient::CasMaskWrite(RdmaOpRegion &cas_ror, uint64_t equal,
                             uint64_t swap, uint64_t mask,
                             RdmaOpRegion &write_ror, bool signal,
                             CoroContext *ctx) {
  int node_id;
  {
    GlobalAddress gaddr;
    gaddr.raw = cas_ror.dest;
    node_id = gaddr.nodeID;
    FillKeysDest(cas_ror, gaddr, cas_ror.is_on_chip);
  }
  {
    GlobalAddress gaddr;
    gaddr.raw = write_ror.dest;
    FillKeysDest(write_ror, gaddr, write_ror.is_on_chip);
  }

  if (ctx == nullptr) {
    rdmaCasMaskWrite(i_con_->data[0][node_id], cas_ror, equal, swap, mask,
                     write_ror, signal);
  } else {
    rdmaCasMaskWrite(i_con_->data[0][node_id], cas_ror, equal, swap, mask,
                     write_ror, true, ctx->coro_id);
    (*ctx->yield)(*ctx->master);
  }
}

bool DSMClient::CasMaskWriteSync(RdmaOpRegion &cas_ror, uint64_t equal,
                                 uint64_t swap, uint64_t mask,
                                 RdmaOpRegion &write_ror, CoroContext *ctx) {
  CasMaskWrite(cas_ror, equal, swap, mask, write_ror, true, ctx);
  if (ctx == nullptr) {
    ibv_wc wc;
    pollWithCQ(i_con_->cq, 1, &wc);
  }

  if (cas_ror.log_sz <= 3) {
    return (equal & mask) == (*(uint64_t *)cas_ror.source & mask);
  } else {
    uint64_t *eq = (uint64_t *)equal;
    uint64_t *old = (uint64_t *)cas_ror.source;
    uint64_t *m = (uint64_t *)mask;
    for (int i = 0; i < (1 << (cas_ror.log_sz - 3)); ++i) {
      if ((eq[i] & m[i]) != (__bswap_64(old[i]) & m[i])) {
        return false;
      }
    }
    return true;
  }
}

void DSMClient::FaaBound(GlobalAddress gaddr, int log_sz, uint64_t add_val,
                         uint64_t *rdma_buffer, uint64_t mask, bool signal,
                         CoroContext *ctx) {
  if (ctx == nullptr) {
    rdmaFetchAndAddBoundary(
        i_con_->data[0][gaddr.nodeID], log_sz, (uint64_t)rdma_buffer,
        conn_to_server_[gaddr.nodeID].dsm_base + gaddr.offset, add_val,
        i_con_->cacheLKey, conn_to_server_[gaddr.nodeID].dsm_rkey[0], mask,
        signal);
  } else {
    rdmaFetchAndAddBoundary(
        i_con_->data[0][gaddr.nodeID], log_sz, (uint64_t)rdma_buffer,
        conn_to_server_[gaddr.nodeID].dsm_base + gaddr.offset, add_val,
        i_con_->cacheLKey, conn_to_server_[gaddr.nodeID].dsm_rkey[0], mask,
        true, ctx->coro_id);
    (*ctx->yield)(*ctx->master);
  }
}

void DSMClient::FaaBoundSync(GlobalAddress gaddr, int log_sz, uint64_t add_val,
                             uint64_t *rdma_buffer, uint64_t mask,
                             CoroContext *ctx) {
  FaaBound(gaddr, log_sz, add_val, rdma_buffer, mask, true, ctx);
  if (ctx == nullptr) {
    ibv_wc wc;
    pollWithCQ(i_con_->cq, 1, &wc);
  }
}

void DSMClient::ReadDm(char *buffer, GlobalAddress gaddr, size_t size,
                       bool signal, CoroContext *ctx) {
  if (ctx == nullptr) {
    rdmaRead(i_con_->data[0][gaddr.nodeID], (uint64_t)buffer,
             conn_to_server_[gaddr.nodeID].lock_base + gaddr.offset, size,
             i_con_->cacheLKey, conn_to_server_[gaddr.nodeID].lock_rkey[0],
             signal);
  } else {
    rdmaRead(i_con_->data[0][gaddr.nodeID], (uint64_t)buffer,
             conn_to_server_[gaddr.nodeID].lock_base + gaddr.offset, size,
             i_con_->cacheLKey, conn_to_server_[gaddr.nodeID].lock_rkey[0],
             true, ctx->coro_id);
    (*ctx->yield)(*ctx->master);
  }
}

void DSMClient::ReadDmSync(char *buffer, GlobalAddress gaddr, size_t size,
                           CoroContext *ctx) {
  ReadDm(buffer, gaddr, size, true, ctx);

  if (ctx == nullptr) {
    ibv_wc wc;
    pollWithCQ(i_con_->cq, 1, &wc);
  }
}

void DSMClient::WriteDm(const char *buffer, GlobalAddress gaddr, size_t size,
                        bool signal, CoroContext *ctx) {
  if (ctx == nullptr) {
    rdmaWrite(i_con_->data[0][gaddr.nodeID], (uint64_t)buffer,
              conn_to_server_[gaddr.nodeID].lock_base + gaddr.offset, size,
              i_con_->cacheLKey, conn_to_server_[gaddr.nodeID].lock_rkey[0], -1,
              signal);
  } else {
    rdmaWrite(i_con_->data[0][gaddr.nodeID], (uint64_t)buffer,
              conn_to_server_[gaddr.nodeID].lock_base + gaddr.offset, size,
              i_con_->cacheLKey, conn_to_server_[gaddr.nodeID].lock_rkey[0], -1,
              true, ctx->coro_id);
    (*ctx->yield)(*ctx->master);
  }
}

void DSMClient::WriteDmSync(const char *buffer, GlobalAddress gaddr,
                            size_t size, CoroContext *ctx) {
  WriteDm(buffer, gaddr, size, true, ctx);

  if (ctx == nullptr) {
    ibv_wc wc;
    pollWithCQ(i_con_->cq, 1, &wc);
  }
}

void DSMClient::CasDm(GlobalAddress gaddr, uint64_t equal, uint64_t val,
                      uint64_t *rdma_buffer, bool signal, CoroContext *ctx) {
  if (ctx == nullptr) {
    rdmaCompareAndSwap(i_con_->data[0][gaddr.nodeID], (uint64_t)rdma_buffer,
                       conn_to_server_[gaddr.nodeID].lock_base + gaddr.offset,
                       equal, val, i_con_->cacheLKey,
                       conn_to_server_[gaddr.nodeID].lock_rkey[0], signal);
  } else {
    rdmaCompareAndSwap(i_con_->data[0][gaddr.nodeID], (uint64_t)rdma_buffer,
                       conn_to_server_[gaddr.nodeID].lock_base + gaddr.offset,
                       equal, val, i_con_->cacheLKey,
                       conn_to_server_[gaddr.nodeID].lock_rkey[0], true,
                       ctx->coro_id);
    (*ctx->yield)(*ctx->master);
  }
}

bool DSMClient::CasDmSync(GlobalAddress gaddr, uint64_t equal, uint64_t val,
                          uint64_t *rdma_buffer, CoroContext *ctx) {
  CasDm(gaddr, equal, val, rdma_buffer, true, ctx);

  if (ctx == nullptr) {
    ibv_wc wc;
    pollWithCQ(i_con_->cq, 1, &wc);
  }

  return equal == *rdma_buffer;
}

void DSMClient::CasDmMask(GlobalAddress gaddr, int log_sz, uint64_t equal,
                          uint64_t val, uint64_t *rdma_buffer, uint64_t mask,
                          bool signal, CoroContext *ctx) {
  if (ctx == nullptr) {
    rdmaCompareAndSwapMask(
        i_con_->data[0][gaddr.nodeID], (uint64_t)rdma_buffer,
        conn_to_server_[gaddr.nodeID].lock_base + gaddr.offset, log_sz, equal,
        val, i_con_->cacheLKey, conn_to_server_[gaddr.nodeID].lock_rkey[0],
        mask, signal);
  } else {
    rdmaCompareAndSwapMask(
        i_con_->data[0][gaddr.nodeID], (uint64_t)rdma_buffer,
        conn_to_server_[gaddr.nodeID].lock_base + gaddr.offset, log_sz, equal,
        val, i_con_->cacheLKey, conn_to_server_[gaddr.nodeID].lock_rkey[0],
        mask, true, ctx->coro_id);
    (*ctx->yield)(*ctx->master);
  }
}

bool DSMClient::CasDmMaskSync(GlobalAddress gaddr, int log_sz, uint64_t equal,
                              uint64_t val, uint64_t *rdma_buffer,
                              uint64_t mask, CoroContext *ctx) {
  CasDmMask(gaddr, log_sz, equal, val, rdma_buffer, mask, true, ctx);
  if (ctx == nullptr) {
    ibv_wc wc;
    pollWithCQ(i_con_->cq, 1, &wc);
  }

  if (log_sz <= 3) {
    return (equal & mask) == (*rdma_buffer & mask);
  } else {
    uint64_t *eq = (uint64_t *)equal;
    uint64_t *old = (uint64_t *)rdma_buffer;
    uint64_t *m = (uint64_t *)mask;
    for (int i = 0; i < (1 << (log_sz - 3)); i++) {
      if ((eq[i] & m[i]) != (__bswap_64(old[i]) & m[i])) {
        return false;
      }
    }
    return true;
  }
}

void DSMClient::FaaDmBound(GlobalAddress gaddr, int log_sz, uint64_t add_val,
                           uint64_t *rdma_buffer, uint64_t mask, bool signal,
                           CoroContext *ctx) {
  if (ctx == nullptr) {
    rdmaFetchAndAddBoundary(
        i_con_->data[0][gaddr.nodeID], log_sz, (uint64_t)rdma_buffer,
        conn_to_server_[gaddr.nodeID].lock_base + gaddr.offset, add_val,
        i_con_->cacheLKey, conn_to_server_[gaddr.nodeID].lock_rkey[0], mask,
        signal);
  } else {
    rdmaFetchAndAddBoundary(
        i_con_->data[0][gaddr.nodeID], log_sz, (uint64_t)rdma_buffer,
        conn_to_server_[gaddr.nodeID].lock_base + gaddr.offset, add_val,
        i_con_->cacheLKey, conn_to_server_[gaddr.nodeID].lock_rkey[0], mask,
        true, ctx->coro_id);
    (*ctx->yield)(*ctx->master);
  }
}

void DSMClient::FaaDmBoundSync(GlobalAddress gaddr, int log_sz,
                               uint64_t add_val, uint64_t *rdma_buffer,
                               uint64_t mask, CoroContext *ctx) {
  FaaDmBound(gaddr, log_sz, add_val, rdma_buffer, mask, true, ctx);
  if (ctx == nullptr) {
    ibv_wc wc;
    pollWithCQ(i_con_->cq, 1, &wc);
  }
}

uint64_t DSMClient::PollRdmaCq(int count) {
  ibv_wc wc;
  pollWithCQ(i_con_->cq, count, &wc);

  return wc.wr_id;
}

bool DSMClient::PollRdmaCqOnce(uint64_t &wr_id) {
  ibv_wc wc;
  int res = pollOnce(i_con_->cq, 1, &wc);

  wr_id = wc.wr_id;

  return res == 1;
}

GlobalAddress DSMClient::Alloc(size_t size) {
  thread_local int next_target_node =
      (get_my_thread_id() + get_my_client_id()) % conf_.num_server;
  thread_local int next_target_dir_id =
      (get_my_thread_id() + get_my_client_id()) % NR_DIRECTORY;

  bool need_chunk = false;
  auto addr = local_allocator_.malloc(size, need_chunk);
  if (need_chunk) {
    RawMessage m;
    m.type = RpcType::MALLOC;
    this->RpcCallDir(m, next_target_node, next_target_dir_id);
    local_allocator_.set_chunck(RpcWait()->addr);

    if (++next_target_dir_id == NR_DIRECTORY) {
      next_target_node = (next_target_node + 1) % conf_.num_server;
      next_target_dir_id = 0;
    }

    // retry
    addr = local_allocator_.malloc(size, need_chunk);
  }

  return addr;
}

void DSMClient::RpcCallDir(const RawMessage &m, uint16_t node_id,
                           uint16_t dir_id) {
  auto buffer = (RawMessage *)i_con_->message->getSendPool();
  memcpy(reinterpret_cast<void *>(buffer), &m, sizeof(RawMessage));
  buffer->node_id = my_client_id_;
  buffer->app_id = thread_id_;
  i_con_->sendMessage2Dir(buffer, node_id, dir_id);
}

RawMessage *DSMClient::RpcWait() {
  ibv_wc wc;
  pollWithCQ(i_con_->rpc_cq, 1, &wc);
  return (RawMessage *)i_con_->message->getMessage();
}

#endif  // USE_RDMA

// =========================================================================
// CXL client implementation
// =========================================================================
#ifdef USE_CXL

#include "dsm_client.h"

// --- Thread-local static definitions ---
thread_local int DSMClient::thread_id_ = -1;
thread_local char *DSMClient::rdma_buffer_ = nullptr;
thread_local LocalAllocator DSMClient::local_allocator_;
thread_local RdmaBuffer DSMClient::rbuf_[define::kMaxCoro];
thread_local uint64_t DSMClient::thread_tag_ = 0;
thread_local RawMessage DSMClient::rpc_reply_buf_;

// --- Constructor ---
DSMClient::DSMClient(const DSMConfig &conf)
    : conf_(conf), app_id_(0), cache_(conf.cache_size) {
  Debug::notifyInfo("CXL DSMClient: cache size %d GB", conf_.cache_size);

  InitCxlConnection();
  keeper_->Barrier("DSMClient-init", conf_.num_client, my_client_id_ == 0);
}

void DSMClient::InitCxlConnection() {
  // 1. Set up memcached keeper for coordination
  keeper_ = new Keeper();
  if (!keeper_->ConnectMemcached()) {
    Debug::notifyError("CXL DSMClient: could not connect to memcached");
  }

  // Register as client and get ID
  uint64_t client_num;
  while (true) {
    memcached_return rc = memcached_increment(
        keeper_->memc, "ClientNum", strlen("ClientNum"), 1, &client_num);
    if (rc == MEMCACHED_SUCCESS) {
      my_client_id_ = client_num - 1;
      break;
    }
    usleep(10000);
  }
  Debug::notifyInfo("CXL DSMClient: I am client %d", my_client_id_);

  // 2. Wait for server to publish region info, then read sizes
  //    (for now we use the same fixed shm names as the server)
  std::string key;
  size_t val_len;
  uint32_t flags;
  memcached_return rc;

  // Read DSM region size from memcached
  key = "cxl_dsm_size_0";
  uint64_t dsm_sz = 0;
  char *val = nullptr;
  while (dsm_sz == 0) {
    val = memcached_get(keeper_->memc, key.c_str(), key.size(),
                        &val_len, &flags, &rc);
    if (rc == MEMCACHED_SUCCESS && val && val_len == sizeof(uint64_t)) {
      dsm_sz = *(uint64_t *)val;
      free(val);
    } else {
      if (val) free(val);
      usleep(10000);
    }
  }

  // Read lock region size
  key = "cxl_lock_size_0";
  uint64_t lock_sz = 0;
  while (lock_sz == 0) {
    val = memcached_get(keeper_->memc, key.c_str(), key.size(),
                        &val_len, &flags, &rc);
    if (rc == MEMCACHED_SUCCESS && val && val_len == sizeof(uint64_t)) {
      lock_sz = *(uint64_t *)val;
      free(val);
    } else {
      if (val) free(val);
      usleep(10000);
    }
  }

  // Read RPC region size
  key = "cxl_rpc_size_0";
  uint64_t rpc_sz = 0;
  while (rpc_sz == 0) {
    val = memcached_get(keeper_->memc, key.c_str(), key.size(),
                        &val_len, &flags, &rc);
    if (rc == MEMCACHED_SUCCESS && val && val_len == sizeof(uint64_t)) {
      rpc_sz = *(uint64_t *)val;
      free(val);
    } else {
      if (val) free(val);
      usleep(10000);
    }
  }

  // 3. Open the shared-memory regions created by the server
  dsm_region_  = cxl::open_region("/deft_dsm",  dsm_sz);
  lock_region_ = cxl::open_region("/deft_lock", lock_sz);
  rpc_region_  = cxl::open_region("/deft_rpc",  rpc_sz);

  Debug::notifyInfo("CXL DSMClient: opened regions — dsm=%p (%lu MB), "
                    "lock=%p (%lu KB), rpc=%p (%lu KB)",
                    dsm_region_.base_addr, dsm_sz / (1024 * 1024),
                    lock_region_.base_addr, lock_sz / 1024,
                    rpc_region_.base_addr, rpc_sz / 1024);
}

// --- Thread Registration ---
void DSMClient::RegisterThread() {
  if (thread_id_ != -1) return;

  thread_id_ = app_id_.fetch_add(1);
  thread_tag_ = thread_id_ + (((uint64_t)get_my_client_id()) << 32) + 1;

  // Scratch buffer from local cache pool (same layout as RDMA path,
  // but no ibv_reg_mr needed — it's just local memory).
  rdma_buffer_ = (char *)cache_.data + thread_id_ * define::kPerThreadRdmaBuf;

  for (int i = 0; i < define::kMaxCoro; ++i) {
    rbuf_[i].set_buffer(rdma_buffer_ + i * define::kPerCoroRdmaBuf);
  }

  Debug::notifyInfo("CXL DSMClient: thread %d registered (tag=0x%lx)",
                    thread_id_, thread_tag_);
}

// --- Address Resolution ---
void *DSMClient::ResolveAddr(GlobalAddress gaddr) {
  return (char *)dsm_region_.base_addr + gaddr.offset;
}

void *DSMClient::ResolveLockAddr(GlobalAddress gaddr) {
  return (char *)lock_region_.base_addr + gaddr.offset;
}

// --- Placeholder stubs (Groups 3-9, implemented in later tasks) ---
// These will be replaced with real implementations incrementally.
// For now they abort so missing coverage is immediately visible.

#define CXL_STUB(name) \
  Debug::notifyError("CXL DSMClient::" #name " not yet implemented"); \
  std::abort();

void DSMClient::Read(char *buffer, GlobalAddress gaddr, size_t size,
                     bool /*signal*/, CoroContext * /*ctx*/) {
  cxl::read(buffer, ResolveAddr(gaddr), size);
}

void DSMClient::ReadSync(char *buffer, GlobalAddress gaddr, size_t size,
                         CoroContext * /*ctx*/) {
  cxl::read(buffer, ResolveAddr(gaddr), size);
}

void DSMClient::Write(const char *buffer, GlobalAddress gaddr, size_t size,
                      bool /*signal*/, CoroContext * /*ctx*/) {
  cxl::write(buffer, ResolveAddr(gaddr), size);
}

void DSMClient::WriteSync(const char *buffer, GlobalAddress gaddr, size_t size,
                          CoroContext * /*ctx*/) {
  cxl::write(buffer, ResolveAddr(gaddr), size);
}

// --- Group 7: Batch / Compound Operations ---
// Helper: resolve an RdmaOpRegion dest to a raw pointer.
static inline void *CxlResolveRor(const RdmaOpRegion &ror,
                                   void *dsm_base, void *lock_base) {
  GlobalAddress gaddr;
  gaddr.raw = ror.dest;
  if (ror.is_on_chip) {
    return (char *)lock_base + gaddr.offset;
  } else {
    return (char *)dsm_base + gaddr.offset;
  }
}

void DSMClient::ReadBatch(RdmaOpRegion *rs, int k, bool /*signal*/,
                          CoroContext * /*ctx*/) {
  for (int i = 0; i < k; ++i) {
    void *remote = CxlResolveRor(rs[i], dsm_region_.base_addr,
                                  lock_region_.base_addr);
    cxl::read((char *)rs[i].source, remote, rs[i].size);
  }
}

void DSMClient::ReadBatchSync(RdmaOpRegion *rs, int k, CoroContext *ctx) {
  ReadBatch(rs, k, true, ctx);
}

void DSMClient::WriteBatch(RdmaOpRegion *rs, int k, bool /*signal*/,
                           CoroContext * /*ctx*/) {
  for (int i = 0; i < k; ++i) {
    void *remote = CxlResolveRor(rs[i], dsm_region_.base_addr,
                                  lock_region_.base_addr);
    cxl::write((const char *)rs[i].source, remote, rs[i].size);
  }
}

void DSMClient::WriteBatchSync(RdmaOpRegion *rs, int k, CoroContext *ctx) {
  WriteBatch(rs, k, true, ctx);
}

void DSMClient::WriteFaa(RdmaOpRegion &write_ror, RdmaOpRegion &faa_ror,
                         uint64_t add_val, bool /*signal*/, CoroContext * /*ctx*/) {
  void *w_remote = CxlResolveRor(write_ror, dsm_region_.base_addr,
                                  lock_region_.base_addr);
  cxl::write((const char *)write_ror.source, w_remote, write_ror.size);
  void *f_remote = CxlResolveRor(faa_ror, dsm_region_.base_addr,
                                  lock_region_.base_addr);
  *(uint64_t *)faa_ror.source = cxl::fetch_and_add(f_remote, add_val);
}

void DSMClient::WriteFaaSync(RdmaOpRegion &write_ror, RdmaOpRegion &faa_ror,
                             uint64_t add_val, CoroContext *ctx) {
  WriteFaa(write_ror, faa_ror, add_val, true, ctx);
}

void DSMClient::WriteCas(RdmaOpRegion &write_ror, RdmaOpRegion &cas_ror,
                         uint64_t equal, uint64_t val, bool /*signal*/,
                         CoroContext * /*ctx*/) {
  void *w_remote = CxlResolveRor(write_ror, dsm_region_.base_addr,
                                  lock_region_.base_addr);
  cxl::write((const char *)write_ror.source, w_remote, write_ror.size);
  void *c_remote = CxlResolveRor(cas_ror, dsm_region_.base_addr,
                                  lock_region_.base_addr);
  cxl::cas(c_remote, equal, val, (uint64_t *)cas_ror.source);
}

void DSMClient::WriteCasSync(RdmaOpRegion &write_ror, RdmaOpRegion &cas_ror,
                             uint64_t equal, uint64_t val, CoroContext *ctx) {
  WriteCas(write_ror, cas_ror, equal, val, true, ctx);
}
void DSMClient::Cas(GlobalAddress gaddr, uint64_t equal, uint64_t val,
                    uint64_t *rdma_buffer, bool /*signal*/, CoroContext * /*ctx*/) {
  // cxl::cas writes the old value into rdma_buffer (same as RDMA CAS)
  cxl::cas(ResolveAddr(gaddr), equal, val, rdma_buffer);
}

bool DSMClient::CasSync(GlobalAddress gaddr, uint64_t equal, uint64_t val,
                        uint64_t *rdma_buffer, CoroContext * /*ctx*/) {
  cxl::cas(ResolveAddr(gaddr), equal, val, rdma_buffer);
  return equal == *rdma_buffer;
}

void DSMClient::CasMask(GlobalAddress gaddr, int log_sz, uint64_t equal,
                        uint64_t val, uint64_t *rdma_buffer, uint64_t mask,
                        bool /*signal*/, CoroContext * /*ctx*/) {
  // Masked CAS: only compare bits selected by mask.
  // For log_sz <= 3 (8 bytes): software CAS loop on a single 64-bit word.
  void *remote = ResolveAddr(gaddr);
  auto *target = reinterpret_cast<std::atomic<uint64_t> *>(remote);
  (void)log_sz;

  uint64_t old_val = target->load(std::memory_order_acquire);
  *rdma_buffer = old_val;

  // CAS loop: succeed only when masked bits match
  while ((old_val & mask) == (equal & mask)) {
    // Build new value: keep unmasked bits from old, take masked bits from val
    uint64_t desired = (old_val & ~mask) | (val & mask);
    if (target->compare_exchange_weak(old_val, desired,
                                       std::memory_order_acq_rel,
                                       std::memory_order_acquire)) {
      *rdma_buffer = old_val;
      return;
    }
    *rdma_buffer = old_val;  // old_val updated by compare_exchange_weak
  }
}

bool DSMClient::CasMaskSync(GlobalAddress gaddr, int log_sz, uint64_t equal,
                            uint64_t val, uint64_t *rdma_buffer, uint64_t mask,
                            CoroContext * /*ctx*/) {
  CasMask(gaddr, log_sz, equal, val, rdma_buffer, mask, true);

  if (log_sz <= 3) {
    return (equal & mask) == (*rdma_buffer & mask);
  } else {
    // Extended atomics (multi-word) — match RDMA path's byte-swap logic
    uint64_t *eq = (uint64_t *)equal;
    uint64_t *old = (uint64_t *)rdma_buffer;
    uint64_t *m = (uint64_t *)mask;
    for (int i = 0; i < (1 << (log_sz - 3)); i++) {
      if ((eq[i] & m[i]) != (old[i] & m[i])) {
        return false;
      }
    }
    return true;
  }
}

void DSMClient::CasRead(RdmaOpRegion &cas_ror, RdmaOpRegion &read_ror,
                        uint64_t equal, uint64_t val, bool /*signal*/,
                        CoroContext * /*ctx*/) {
  void *c_remote = CxlResolveRor(cas_ror, dsm_region_.base_addr,
                                  lock_region_.base_addr);
  cxl::cas(c_remote, equal, val, (uint64_t *)cas_ror.source);
  void *r_remote = CxlResolveRor(read_ror, dsm_region_.base_addr,
                                  lock_region_.base_addr);
  cxl::read((char *)read_ror.source, r_remote, read_ror.size);
}

bool DSMClient::CasReadSync(RdmaOpRegion &cas_ror, RdmaOpRegion &read_ror,
                            uint64_t equal, uint64_t val, CoroContext *ctx) {
  CasRead(cas_ror, read_ror, equal, val, true, ctx);
  return equal == *(uint64_t *)cas_ror.source;
}

void DSMClient::FaaRead(RdmaOpRegion &faa_ror, RdmaOpRegion &read_ror,
                        uint64_t add, bool /*signal*/, CoroContext * /*ctx*/) {
  void *f_remote = CxlResolveRor(faa_ror, dsm_region_.base_addr,
                                  lock_region_.base_addr);
  *(uint64_t *)faa_ror.source = cxl::fetch_and_add(f_remote, add);
  void *r_remote = CxlResolveRor(read_ror, dsm_region_.base_addr,
                                  lock_region_.base_addr);
  cxl::read((char *)read_ror.source, r_remote, read_ror.size);
}

void DSMClient::FaaReadSync(RdmaOpRegion &faa_ror, RdmaOpRegion &read_ror,
                            uint64_t add, CoroContext *ctx) {
  FaaRead(faa_ror, read_ror, add, true, ctx);
}

void DSMClient::FaaBoundRead(RdmaOpRegion &faab_ror, RdmaOpRegion &read_ror,
                             uint64_t add, uint64_t /*boundary*/, bool /*signal*/,
                             CoroContext * /*ctx*/) {
  void *f_remote = CxlResolveRor(faab_ror, dsm_region_.base_addr,
                                  lock_region_.base_addr);
  *(uint64_t *)faab_ror.source = cxl::fetch_and_add(f_remote, add);
  void *r_remote = CxlResolveRor(read_ror, dsm_region_.base_addr,
                                  lock_region_.base_addr);
  cxl::read((char *)read_ror.source, r_remote, read_ror.size);
}

void DSMClient::FaaBoundReadSync(RdmaOpRegion &faab_ror, RdmaOpRegion &read_ror,
                                 uint64_t add, uint64_t boundary,
                                 CoroContext *ctx) {
  FaaBoundRead(faab_ror, read_ror, add, boundary, true, ctx);
}

void DSMClient::CasMaskWrite(RdmaOpRegion &cas_ror, uint64_t equal,
                             uint64_t swap, uint64_t mask,
                             RdmaOpRegion &write_ror, bool /*signal*/,
                             CoroContext * /*ctx*/) {
  void *c_remote = CxlResolveRor(cas_ror, dsm_region_.base_addr,
                                  lock_region_.base_addr);
  auto *target = reinterpret_cast<std::atomic<uint64_t> *>(c_remote);
  uint64_t old_val = target->load(std::memory_order_acquire);
  *(uint64_t *)cas_ror.source = old_val;
  while ((old_val & mask) == (equal & mask)) {
    uint64_t desired = (old_val & ~mask) | (swap & mask);
    if (target->compare_exchange_weak(old_val, desired,
                                       std::memory_order_acq_rel,
                                       std::memory_order_acquire)) {
      *(uint64_t *)cas_ror.source = old_val;
      break;
    }
    *(uint64_t *)cas_ror.source = old_val;
  }
  void *w_remote = CxlResolveRor(write_ror, dsm_region_.base_addr,
                                  lock_region_.base_addr);
  cxl::write((const char *)write_ror.source, w_remote, write_ror.size);
}

bool DSMClient::CasMaskWriteSync(RdmaOpRegion &cas_ror, uint64_t equal,
                                 uint64_t swap, uint64_t mask,
                                 RdmaOpRegion &write_ror, CoroContext *ctx) {
  CasMaskWrite(cas_ror, equal, swap, mask, write_ror, true, ctx);
  return (equal & mask) == (*(uint64_t *)cas_ror.source & mask);
}
// --- Group 5: FAA on DSM pool ---

void DSMClient::FaaBound(GlobalAddress gaddr, int /*log_sz*/, uint64_t add_val,
                         uint64_t *rdma_buffer, uint64_t /*mask*/, bool /*signal*/,
                         CoroContext * /*ctx*/) {
  uint64_t old = cxl::fetch_and_add(ResolveAddr(gaddr), add_val);
  if (rdma_buffer) *rdma_buffer = old;
}

void DSMClient::FaaBoundSync(GlobalAddress gaddr, int log_sz, uint64_t add_val,
                             uint64_t *rdma_buffer, uint64_t mask,
                             CoroContext * /*ctx*/) {
  FaaBound(gaddr, log_sz, add_val, rdma_buffer, mask, true);
}

// --- Group 6: Device Memory (Lock) Operations ---
// Same as Groups 3-5 but targeting the lock region via ResolveLockAddr.

void DSMClient::ReadDm(char *buffer, GlobalAddress gaddr, size_t size,
                       bool /*signal*/, CoroContext * /*ctx*/) {
  cxl::read(buffer, ResolveLockAddr(gaddr), size);
}

void DSMClient::ReadDmSync(char *buffer, GlobalAddress gaddr, size_t size,
                           CoroContext * /*ctx*/) {
  cxl::read(buffer, ResolveLockAddr(gaddr), size);
}

void DSMClient::WriteDm(const char *buffer, GlobalAddress gaddr, size_t size,
                        bool /*signal*/, CoroContext * /*ctx*/) {
  cxl::write(buffer, ResolveLockAddr(gaddr), size);
}

void DSMClient::WriteDmSync(const char *buffer, GlobalAddress gaddr, size_t size,
                            CoroContext * /*ctx*/) {
  cxl::write(buffer, ResolveLockAddr(gaddr), size);
}

void DSMClient::CasDm(GlobalAddress gaddr, uint64_t equal, uint64_t val,
                      uint64_t *rdma_buffer, bool /*signal*/, CoroContext * /*ctx*/) {
  cxl::cas(ResolveLockAddr(gaddr), equal, val, rdma_buffer);
}

bool DSMClient::CasDmSync(GlobalAddress gaddr, uint64_t equal, uint64_t val,
                          uint64_t *rdma_buffer, CoroContext * /*ctx*/) {
  cxl::cas(ResolveLockAddr(gaddr), equal, val, rdma_buffer);
  return equal == *rdma_buffer;
}

void DSMClient::CasDmMask(GlobalAddress gaddr, int log_sz, uint64_t equal,
                          uint64_t val, uint64_t *rdma_buffer, uint64_t mask,
                          bool /*signal*/, CoroContext * /*ctx*/) {
  // Same masked CAS logic as CasMask, but on the lock region
  void *remote = ResolveLockAddr(gaddr);
  auto *target = reinterpret_cast<std::atomic<uint64_t> *>(remote);
  (void)log_sz;

  uint64_t old_val = target->load(std::memory_order_acquire);
  *rdma_buffer = old_val;

  while ((old_val & mask) == (equal & mask)) {
    uint64_t desired = (old_val & ~mask) | (val & mask);
    if (target->compare_exchange_weak(old_val, desired,
                                       std::memory_order_acq_rel,
                                       std::memory_order_acquire)) {
      *rdma_buffer = old_val;
      return;
    }
    *rdma_buffer = old_val;
  }
}

bool DSMClient::CasDmMaskSync(GlobalAddress gaddr, int log_sz, uint64_t equal,
                              uint64_t val, uint64_t *rdma_buffer, uint64_t mask,
                              CoroContext * /*ctx*/) {
  CasDmMask(gaddr, log_sz, equal, val, rdma_buffer, mask, true);

  if (log_sz <= 3) {
    return (equal & mask) == (*rdma_buffer & mask);
  } else {
    uint64_t *eq = (uint64_t *)equal;
    uint64_t *old = (uint64_t *)rdma_buffer;
    uint64_t *m = (uint64_t *)mask;
    for (int i = 0; i < (1 << (log_sz - 3)); i++) {
      if ((eq[i] & m[i]) != (old[i] & m[i])) {
        return false;
      }
    }
    return true;
  }
}

void DSMClient::FaaDmBound(GlobalAddress gaddr, int /*log_sz*/, uint64_t add_val,
                           uint64_t *rdma_buffer, uint64_t /*mask*/, bool /*signal*/,
                           CoroContext * /*ctx*/) {
  uint64_t old = cxl::fetch_and_add(ResolveLockAddr(gaddr), add_val);
  if (rdma_buffer) *rdma_buffer = old;
}

void DSMClient::FaaDmBoundSync(GlobalAddress gaddr, int log_sz, uint64_t add_val,
                               uint64_t *rdma_buffer, uint64_t mask,
                               CoroContext * /*ctx*/) {
  FaaDmBound(gaddr, log_sz, add_val, rdma_buffer, mask, true);
}


// --- Group 8: CQ Polling (No-ops under CXL) ---

uint64_t DSMClient::PollRdmaCq(int /*count*/) {
  // No completion queue under CXL — all ops are synchronous
  return 0;
}

bool DSMClient::PollRdmaCqOnce(uint64_t & /*wr_id*/) {
  // No CQ to poll
  return false;
}

// --- Group 9: RPC — Alloc / RpcCallDir / RpcWait ---

GlobalAddress DSMClient::Alloc(size_t size) {
  // Same allocation logic as RDMA path: try local first, RPC for new chunk
  thread_local int next_target_node =
      (get_my_thread_id() + get_my_client_id()) % conf_.num_server;
  thread_local int next_target_dir_id =
      (get_my_thread_id() + get_my_client_id()) % NR_DIRECTORY;

  bool need_chunk = false;
  auto addr = local_allocator_.malloc(size, need_chunk);
  if (need_chunk) {
    RawMessage m;
    m.type = RpcType::MALLOC;
    this->RpcCallDir(m, next_target_node, next_target_dir_id);
    local_allocator_.set_chunck(RpcWait()->addr);

    if (++next_target_dir_id == NR_DIRECTORY) {
      next_target_node = (next_target_node + 1) % conf_.num_server;
      next_target_dir_id = 0;
    }

    // retry
    addr = local_allocator_.malloc(size, need_chunk);
  }

  return addr;
}

void DSMClient::RpcCallDir(const RawMessage &m, uint16_t /*node_id*/,
                           uint16_t dir_id) {
  // Build the message with our identity so the server knows where to reply
  RawMessage buf = m;
  buf.node_id = my_client_id_;
  buf.app_id = thread_id_;

  // Send to the request queue for (this thread, dir_id)
  auto *req_q = cxl::get_request_queue(rpc_region_.base_addr,
                                        thread_id_, dir_id);
  cxl::rpc_send(req_q, &buf, sizeof(buf));
}

RawMessage *DSMClient::RpcWait() {
  // Block on our reply queue until the server responds
  auto *rep_q = cxl::get_reply_queue(rpc_region_.base_addr, thread_id_);
  cxl::rpc_recv(rep_q, &rpc_reply_buf_, sizeof(rpc_reply_buf_));
  return &rpc_reply_buf_;
}

#undef CXL_STUB

#endif  // USE_CXL

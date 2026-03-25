#include "ThreadConnection.h"

#include "connection.h"
#include <cstdlib>

ThreadConnection::ThreadConnection(uint16_t threadID, void *cachePool,
                                   uint64_t cacheSize, uint32_t machineNR,
                                   uint16_t rnic_id,
                                   RemoteConnectionToServer *remote_conn)
    : threadID(threadID), conn_to_server(remote_conn) {
  if (!createContext(&ctx, rnic_id)) {
    Debug::notifyError("createContext failed on client (rnic_id=%u)", rnic_id);
    std::abort();
  }

  cq = ibv_create_cq(ctx.ctx, RAW_RECV_CQ_COUNT, NULL, NULL, 0);
  if (!cq) {
    Debug::notifyError("ibv_create_cq failed on client");
    std::abort();
  }
  // rpc_cq = cq;
  rpc_cq = ibv_create_cq(ctx.ctx, RAW_RECV_CQ_COUNT, NULL, NULL, 0);
  if (!rpc_cq) {
    Debug::notifyError("ibv_create_cq (rpc_cq) failed on client");
    std::abort();
  }

  message = new RawMessageConnection(ctx, rpc_cq, APP_MESSAGE_NR);

  this->cachePool = cachePool;
  cacheMR = createMemoryRegion((uint64_t)cachePool, cacheSize, &ctx);
  cacheLKey = cacheMR->lkey;

  // dir, RC
  for (int i = 0; i < NR_DIRECTORY; ++i) {
    data[i] = new ibv_qp *[machineNR];
    for (size_t k = 0; k < machineNR; ++k) {
      createQueuePair(&data[i][k], IBV_QPT_RC, cq, &ctx);
    }
  }
}

void ThreadConnection::sendMessage2Dir(RawMessage *m, uint16_t node_id,
                                       uint16_t dir_id) {
  message->sendRawMessage(
      m, conn_to_server[node_id].dir_message_qpn[dir_id],
      conn_to_server[node_id].app_to_dir_ah[threadID][dir_id]);
}

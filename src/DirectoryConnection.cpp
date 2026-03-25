#include "DirectoryConnection.h"

#include "connection.h"
#include <cstdlib>

DirectoryConnection::DirectoryConnection(uint16_t dirID, void *dsmPool,
                                         uint64_t dsmSize, uint32_t num_client,
                                         uint16_t rnic_id,
                                         RemoteConnectionToClient *remote_con)
    : dirID(dirID), remote_con_(remote_con) {
  if (!createContext(&ctx, rnic_id)) {
    Debug::notifyError("createContext failed on server (rnic_id=%u)", rnic_id);
    std::abort();
  }
  cq = ibv_create_cq(ctx.ctx, RAW_RECV_CQ_COUNT, NULL, NULL, 0);
  if (!cq) {
    Debug::notifyError("ibv_create_cq failed on server");
    std::abort();
  }
  message = new RawMessageConnection(ctx, cq, DIR_MESSAGE_NR);

  message->initRecv();
  message->initSend();

  // dsm memory
  this->dsmPool = dsmPool;
  this->dsmSize = dsmSize;
  this->dsmMR = createMemoryRegion((uint64_t)dsmPool, dsmSize, &ctx);
  this->dsmLKey = dsmMR->lkey;

  // on-chip lock memory
  if (dirID == 0) {
    this->lockPool = (void *)define::kLockStartAddr;
    this->lockSize = define::kLockChipMemSize;
    this->lockMR = createMemoryRegionOnChip((uint64_t)this->lockPool,
                                            this->lockSize, &ctx);
    this->lockLKey = lockMR->lkey;
  }

  // app, RC
  for (int i = 0; i < MAX_APP_THREAD; ++i) {
    data2app[i] = new ibv_qp *[num_client];
    // client
    for (size_t k = 0; k < num_client; ++k) {
      createQueuePair(&data2app[i][k], IBV_QPT_RC, cq, &ctx);
    }
  }
}

void DirectoryConnection::sendMessage2App(RawMessage *m, uint16_t node_id,
                                          uint16_t th_id) {
  message->sendRawMessage(m, remote_con_[node_id].app_message_qpn[th_id],
                          remote_con_[node_id].dir_to_app_ah[dirID][th_id]);
}

#include "DirectoryConnection.h"

#include "HugePageAlloc.h"
#include "connection.h"
#include <cstdlib>
#include <cstring>

DirectoryConnection::DirectoryConnection(uint16_t dirID, void *dsmPool,
                                         uint64_t dsmSize, uint32_t num_client,
                                         uint16_t rnic_id,
                                         RemoteConnectionToClient *remote_con)
    : dirID(dirID), remote_con_(remote_con) {
  Debug::notifyInfo(
      "DirectoryConnection init: dirID=%u rnic_id=%u dsmPool=%p dsmSize=%llu "
      "num_client=%u",
      dirID, rnic_id, dsmPool, static_cast<unsigned long long>(dsmSize),
      num_client);
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
  this->dsmMR =
      createMemoryRegion((uint64_t)dsmPool, dsmSize, &ctx,
                         IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_READ |
                             IBV_ACCESS_REMOTE_WRITE | IBV_ACCESS_REMOTE_ATOMIC,
                         "dsm");
  this->dsmLKey = dsmMR->lkey;
  Debug::notifyInfo("DirectoryConnection: dirID=%u dsm MR lkey=0x%x", dirID,
                    dsmLKey);

  // on-chip lock memory
  if (dirID == 0) {
    this->lockPool = (void *)define::kLockStartAddr;
    this->lockSize = define::kLockChipMemSize;
    this->lockMR = createMemoryRegionOnChip((uint64_t)this->lockPool,
                                            this->lockSize, &ctx);
    if (!this->lockMR) {
      Debug::notifyInfo(
          "on-chip lock memory unavailable; falling back to host memory");
      this->lockPool = hugePageAlloc(this->lockSize);
      memset(this->lockPool, 0, this->lockSize);
      this->lockMR = createMemoryRegion(
          (uint64_t)this->lockPool, this->lockSize, &ctx,
          IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_READ |
              IBV_ACCESS_REMOTE_WRITE | IBV_ACCESS_REMOTE_ATOMIC,
          "lock");
      if (!this->lockMR) {
        Debug::notifyError("failed to register fallback host lock memory");
        std::abort();
      }
    }
    this->lockLKey = lockMR->lkey;
    Debug::notifyInfo("DirectoryConnection: dirID=%u lock MR lkey=0x%x", dirID,
                      lockLKey);
  }

  // app, RC
  for (int i = 0; i < MAX_APP_THREAD; ++i) {
    data2app[i] = new ibv_qp *[num_client];
    // client
    for (size_t k = 0; k < num_client; ++k) {
      if (!createQueuePair(&data2app[i][k], IBV_QPT_RC, cq, &ctx)) {
        Debug::notifyError("createQueuePair failed on server");
        std::abort();
      }
      Debug::notifyInfo("DirectoryConnection: dirID=%u appThread=%d client=%zu "
                        "qpn=%u",
                        dirID, i, k, data2app[i][k]->qp_num);
    }
  }
}

void DirectoryConnection::sendMessage2App(RawMessage *m, uint16_t node_id,
                                          uint16_t th_id) {
  message->sendRawMessage(m, remote_con_[node_id].app_message_qpn[th_id],
                          remote_con_[node_id].dir_to_app_ah[dirID][th_id]);
}

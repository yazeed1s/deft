#ifndef __RAWMESSAGECONNECTION_H__
#define __RAWMESSAGECONNECTION_H__

#include "GlobalAddress.h"

#include <cstdint>
#include <thread>

// ----- Transport-agnostic message types -----
// These are used by both RDMA and CXL paths (Directory, DSMClient, etc.)

enum RpcType : uint8_t {
  MALLOC,
  FREE,
  NEW_ROOT,
  TERMINATE,
  NOP,
};

struct RawMessage {
  RpcType type;
  
  uint16_t node_id;
  uint16_t app_id;

  GlobalAddress addr; // for malloc
  int level;
} __attribute__((packed));

// ----- RDMA-specific message connection class -----
#ifdef USE_RDMA

#include "AbstractMessageConnection.h"

class RawMessageConnection : public AbstractMessageConnection {

public:
  RawMessageConnection(RdmaContext &ctx, ibv_cq *cq, uint32_t messageNR);

  void initSend();
  void sendRawMessage(RawMessage *m, uint32_t remoteQPN, ibv_ah *ah);
};

#endif  // USE_RDMA

#endif /* __RAWMESSAGECONNECTION_H__ */

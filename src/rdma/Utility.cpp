#include "Rdma.h"
#include <cerrno>
#include <cstring>

int kMaxDeviceMemorySize = 0;

void rdmaQueryQueuePair(ibv_qp *qp) {
  struct ibv_qp_attr attr;
  struct ibv_qp_init_attr init_attr;
  ibv_query_qp(qp, &attr, IBV_QP_STATE, &init_attr);
  switch (attr.qp_state) {
  case IBV_QPS_RESET:
    printf("QP state: IBV_QPS_RESET\n");
    break;
  case IBV_QPS_INIT:
    printf("QP state: IBV_QPS_INIT\n");
    break;
  case IBV_QPS_RTR:
    printf("QP state: IBV_QPS_RTR\n");
    break;
  case IBV_QPS_RTS:
    printf("QP state: IBV_QPS_RTS\n");
    break;
  case IBV_QPS_SQD:
    printf("QP state: IBV_QPS_SQD\n");
    break;
  case IBV_QPS_SQE:
    printf("QP state: IBV_QPS_SQE\n");
    break;
  case IBV_QPS_ERR:
    printf("QP state: IBV_QPS_ERR\n");
    break;
  case IBV_QPS_UNKNOWN:
    printf("QP state: IBV_QPS_UNKNOWN\n");
    break;
  }
}

void checkDMSupported(struct ibv_context *ctx) {
  struct ibv_exp_device_attr attrs;
  memset(&attrs, 0, sizeof(attrs));
  attrs.comp_mask = IBV_EXP_DEVICE_ATTR_UMR;
  attrs.comp_mask |= IBV_EXP_DEVICE_ATTR_MAX_DM_SIZE;

  if (ibv_exp_query_device(ctx, &attrs)) {
    Debug::notifyError("RDMA device query failed errno=%d (%s)", errno,
                       strerror(errno));
    kMaxDeviceMemorySize = 0;
    return;
  }

  if (!(attrs.comp_mask & IBV_EXP_DEVICE_ATTR_MAX_DM_SIZE)) {
    Debug::notifyInfo("RDMA device memory unsupported on this RNIC");
    kMaxDeviceMemorySize = 0;
    return;
  } else if (!(attrs.max_dm_size)) {
    Debug::notifyInfo("RDMA device memory supported but max_dm_size=0");
    kMaxDeviceMemorySize = 0;
  } else {
    kMaxDeviceMemorySize = attrs.max_dm_size;
    Debug::notifyInfo("The RNIC has %dKB device memory",
                      kMaxDeviceMemorySize / 1024);
  }
}

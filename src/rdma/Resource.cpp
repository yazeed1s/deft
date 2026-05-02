#include "Rdma.h"
#include <arpa/inet.h>
#include <cctype>
#include <cerrno>
#include <cinttypes>
#include <cstring>

namespace {

const char *qpTypeToStr(ibv_qp_type t) {
  switch (t) {
  case IBV_QPT_RC:
    return "RC";
  case IBV_QPT_UC:
    return "UC";
  case IBV_QPT_UD:
    return "UD";
  case IBV_QPT_RAW_PACKET:
    return "RAW_PACKET";
  default:
    return "UNKNOWN";
  }
}

void gidToStr(const union ibv_gid &gid, char *out, size_t out_len) {
  if (!inet_ntop(AF_INET6, gid.raw, out, out_len)) {
    snprintf(out, out_len, "<invalid-gid>");
  }
}

} // namespace

bool createContext(RdmaContext *context, int rnic_id, uint8_t port,
                   int gidIndex) {
  ibv_device *dev = NULL;
  ibv_context *ctx = NULL;
  ibv_pd *pd = NULL;
  ibv_port_attr portAttr;

  // get device names in the system
  int devicesNum;
  int devIndex = -1;
  struct ibv_device **deviceList = ibv_get_device_list(&devicesNum);
  if (!deviceList) {
    Debug::notifyError("failed to get IB devices list");
    goto CreateResourcesExit;
  }
  Debug::notifyInfo(
      "RDMA createContext: requested rnic_id=%d port=%u gidIndex=%d", rnic_id,
      port, gidIndex);

  // if there isn't any IB device in host
  if (!devicesNum) {
    Debug::notifyInfo("found %d device(s)", devicesNum);
    goto CreateResourcesExit;
  }
  Debug::notifyInfo("RDMA createContext: found %d IB device(s)", devicesNum);
  for (int i = 0; i < devicesNum; ++i) {
    Debug::notifyInfo("RDMA device[%d]=%s", i,
                      ibv_get_device_name(deviceList[i]));
  }

  for (int i = 0; i < devicesNum; ++i) {
    const char *name = ibv_get_device_name(deviceList[i]);

    // Old OFED naming style: mlx5_0, mlx5_1, ...
    const char *uscore = strrchr(name, '_');
    if (uscore && std::isdigit(*(uscore + 1)) && *(uscore + 2) == '\0') {
      if ((*(uscore + 1) - '0') == rnic_id) {
        devIndex = i;
        break;
      }
    }

    // New naming style: rocep1s0f0, rocep1s0f1, ...
    size_t len = strlen(name);
    if (len >= 2 && name[len - 2] == 'f' && std::isdigit(name[len - 1])) {
      if ((name[len - 1] - '0') == rnic_id) {
        devIndex = i;
        break;
      }
    }
  }

  // Fallback: treat rnic_id as the verbs device index.
  if (devIndex < 0 && rnic_id < devicesNum) {
    devIndex = rnic_id;
    Debug::notifyInfo("RDMA createContext: no name match for rnic_id=%d, "
                      "falling back to device index %d (%s)",
                      rnic_id, devIndex,
                      ibv_get_device_name(deviceList[devIndex]));
  }

  if (devIndex < 0 || devIndex >= devicesNum) {
    for (int i = 0; i < devicesNum; ++i) {
      Debug::notifyInfo("ib device %d: %s", i,
                        ibv_get_device_name(deviceList[i]));
    }
    Debug::notifyError("ib device wasn't found");
    goto CreateResourcesExit;
  }

  dev = deviceList[devIndex];
  Debug::notifyInfo("RDMA createContext: selecting device index=%d name=%s",
                    devIndex, ibv_get_device_name(dev));

  // get device handle
  ctx = ibv_open_device(dev);
  if (!ctx) {
    Debug::notifyError("failed to open device");
    goto CreateResourcesExit;
  }
  /* We are now done with device list, free it */
  ibv_free_device_list(deviceList);
  deviceList = NULL;

  // query port properties
  if (ibv_query_port(ctx, port, &portAttr)) {
    Debug::notifyError("ibv_query_port failed");
    goto CreateResourcesExit;
  }
  Debug::notifyInfo(
      "RDMA createContext: queried port=%u state=%u active_mtu=%u lid=%u", port,
      portAttr.state, portAttr.active_mtu, portAttr.lid);

  ibv_device_attr devAttr;
  memset(&devAttr, 0, sizeof(devAttr));
  if (!ibv_query_device(ctx, &devAttr)) {
    Debug::notifyInfo(
        "RDMA createContext: fw=%s max_mr_size=%" PRIu64
        " max_qp=%d max_cq=%d max_pd=%d max_qp_rd_atom=%d max_res_rd_atom=%d",
        devAttr.fw_ver, devAttr.max_mr_size, devAttr.max_qp, devAttr.max_cq,
        devAttr.max_pd, devAttr.max_qp_rd_atom, devAttr.max_res_rd_atom);
  } else {
    Debug::notifyError(
        "RDMA createContext: ibv_query_device failed errno=%d (%s)", errno,
        strerror(errno));
  }

  // allocate Protection Domain
  // Debug::notifyInfo("Allocate Protection Domain");
  pd = ibv_alloc_pd(ctx);
  if (!pd) {
    Debug::notifyError("ibv_alloc_pd failed");
    goto CreateResourcesExit;
  }

  if (ibv_query_gid(ctx, port, gidIndex, &context->gid)) {
    Debug::notifyError("could not get gid for port: %d, gidIndex: %d", port,
                       gidIndex);
    goto CreateResourcesExit;
  }
  char gidBuf[INET6_ADDRSTRLEN];
  gidToStr(context->gid, gidBuf, sizeof(gidBuf));
  Debug::notifyInfo("RDMA createContext: gid[%d]=%s", gidIndex, gidBuf);

  // Success :)
  context->devIndex = devIndex;
  context->gidIndex = gidIndex;
  context->port = port;
  context->ctx = ctx;
  context->pd = pd;
  context->lid = portAttr.lid;

  // check device memory support
  if (kMaxDeviceMemorySize == 0) {
    checkDMSupported(ctx);
  }
  Debug::notifyInfo(
      "RDMA createContext: success dev=%s(%d) port=%u gidIndex=%d dm=%dKB",
      ibv_get_device_name(dev), devIndex, context->port, context->gidIndex,
      kMaxDeviceMemorySize / 1024);

  return true;

/* Error encountered, cleanup */
CreateResourcesExit:
  Debug::notifyError("Error Encountered, Cleanup ...");

  if (pd) {
    ibv_dealloc_pd(pd);
    pd = NULL;
  }
  if (ctx) {
    ibv_close_device(ctx);
    ctx = NULL;
  }
  if (deviceList) {
    ibv_free_device_list(deviceList);
    deviceList = NULL;
  }

  return false;
}

bool destoryContext(RdmaContext *context) {
  bool rc = true;
  if (context->pd) {
    if (ibv_dealloc_pd(context->pd)) {
      Debug::notifyError("Failed to deallocate PD");
      rc = false;
    }
  }
  if (context->ctx) {
    if (ibv_close_device(context->ctx)) {
      Debug::notifyError("failed to close device context");
      rc = false;
    }
  }

  return rc;
}

ibv_mr *createMemoryRegion(uint64_t mm, uint64_t mmSize, RdmaContext *ctx,
                           int access_flags, const char *caller) {

  ibv_mr *mr = NULL;
  Debug::notifyInfo("RDMA MR: register caller=%s addr=0x%" PRIx64
                    " size=%" PRIu64
                    " flags=0x%x devIndex=%u port=%u gidIndex=%d",
                    caller, mm, mmSize, access_flags, ctx->devIndex, ctx->port,
                    ctx->gidIndex);
  mr = ibv_reg_mr(ctx->pd, (void *)mm, mmSize, access_flags);

  if (!mr) {
    Debug::notifyError("RDMA MR: registration failed caller=%s addr=0x%" PRIx64
                       " size=%" PRIu64 " flags=0x%x errno=%d (%s)",
                       caller, mm, mmSize, access_flags, errno,
                       strerror(errno));
    exit(-1);
  }
  Debug::notifyInfo("RDMA MR: success caller=%s lkey=0x%x rkey=0x%x", caller,
                    mr->lkey, mr->rkey);

  return mr;
}

ibv_mr *createMemoryRegionOnChip(uint64_t mm, uint64_t mmSize,
                                 RdmaContext *ctx) {

  /* Device memory allocation request */
  struct ibv_exp_alloc_dm_attr dm_attr;
  memset(&dm_attr, 0, sizeof(dm_attr));
  dm_attr.length = mmSize;
  Debug::notifyInfo("RDMA DM: alloc length=%" PRIu64, mmSize);
  struct ibv_exp_dm *dm = ibv_exp_alloc_dm(ctx->ctx, &dm_attr);
  if (!dm) {
    Debug::notifyError("RDMA DM: alloc failed errno=%d (%s)", errno,
                       strerror(errno));
    return nullptr;
  }

  /* Device memory registration as memory region */
  struct ibv_exp_reg_mr_in mr_in;
  memset(&mr_in, 0, sizeof(mr_in));
  mr_in.pd = ctx->pd, mr_in.addr = (void *)mm, mr_in.length = mmSize,
  mr_in.exp_access = IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_READ |
                     IBV_ACCESS_REMOTE_WRITE | IBV_ACCESS_REMOTE_ATOMIC,
  mr_in.create_flags = 0;
  mr_in.dm = dm;
  mr_in.comp_mask = IBV_EXP_REG_MR_DM;
  Debug::notifyInfo("RDMA DM: register addr=0x%" PRIx64 " size=%" PRIu64
                    " exp_access=0x%x",
                    mm, mmSize, mr_in.exp_access);
  struct ibv_mr *mr = ibv_exp_reg_mr(&mr_in);
  if (!mr) {
    Debug::notifyError("RDMA DM: registration failed errno=%d (%s)", errno,
                       strerror(errno));
    return nullptr;
  }
  Debug::notifyInfo("RDMA DM: success lkey=0x%x rkey=0x%x", mr->lkey, mr->rkey);

  // init zero
  char *buffer = (char *)malloc(mmSize);
  memset(buffer, 0, mmSize);

  struct ibv_exp_memcpy_dm_attr cpy_attr;
  memset(&cpy_attr, 0, sizeof(cpy_attr));
  cpy_attr.memcpy_dir = IBV_EXP_DM_CPY_TO_DEVICE;
  cpy_attr.host_addr = (void *)buffer;
  cpy_attr.length = mmSize;
  cpy_attr.dm_offset = 0;
  ibv_exp_memcpy_dm(dm, &cpy_attr);

  free(buffer);

  return mr;
}

bool createQueuePair(ibv_qp **qp, ibv_qp_type mode, ibv_cq *send_cq,
                     ibv_cq *recv_cq, RdmaContext *context,
                     uint32_t qpsMaxDepth, uint32_t maxInlineData) {

  struct ibv_exp_qp_init_attr attr;
  memset(&attr, 0, sizeof(attr));

  attr.qp_type = mode;
  attr.sq_sig_all = 0;
  attr.send_cq = send_cq;
  attr.recv_cq = recv_cq;
  attr.pd = context->pd;

  if (mode == IBV_QPT_RC) {
    attr.comp_mask = IBV_EXP_QP_INIT_ATTR_CREATE_FLAGS |
                     IBV_EXP_QP_INIT_ATTR_PD | IBV_EXP_QP_INIT_ATTR_ATOMICS_ARG;
    attr.max_atomic_arg = 32;
  } else {
    attr.comp_mask = IBV_EXP_QP_INIT_ATTR_PD;
  }

  attr.cap.max_send_wr = qpsMaxDepth;
  attr.cap.max_recv_wr = qpsMaxDepth;
  attr.cap.max_send_sge = 1;
  attr.cap.max_recv_sge = 1;
  attr.cap.max_inline_data = maxInlineData;
  Debug::notifyInfo("RDMA QP: create mode=%s depth=%u inline=%u comp_mask=0x%x "
                    "atomics_arg=%u",
                    qpTypeToStr(mode), qpsMaxDepth, maxInlineData,
                    attr.comp_mask, attr.max_atomic_arg);

  *qp = ibv_exp_create_qp(context->ctx, &attr);
  if (!(*qp)) {
    Debug::notifyError("RDMA QP: create failed mode=%s errno=%d (%s)",
                       qpTypeToStr(mode), errno, strerror(errno));
    if (mode == IBV_QPT_RC) {
      // Some stacks reject extended-atomics args; retry with a minimal RC QP.
      attr.comp_mask = IBV_EXP_QP_INIT_ATTR_PD;
      Debug::notifyInfo("RDMA QP: retry RC create without extended atomics");
      *qp = ibv_exp_create_qp(context->ctx, &attr);
    }
    if (!(*qp)) {
      Debug::notifyError("RDMA QP: retry failed mode=%s errno=%d (%s)",
                         qpTypeToStr(mode), errno, strerror(errno));
      return false;
    }
  }

  Debug::notifyInfo("RDMA QP: created qpn=%u mode=%s", (*qp)->qp_num,
                    qpTypeToStr(mode));

  return true;
}

bool createQueuePair(ibv_qp **qp, ibv_qp_type mode, ibv_cq *cq,
                     RdmaContext *context, uint32_t qpsMaxDepth,
                     uint32_t maxInlineData) {
  return createQueuePair(qp, mode, cq, cq, context, qpsMaxDepth, maxInlineData);
}

bool createDCTarget(ibv_exp_dct **dct, ibv_cq *cq, RdmaContext *context,
                    uint32_t qpsMaxDepth, uint32_t maxInlineData) {

  // construct SRQ fot DC Target :)
  struct ibv_srq_init_attr attr;
  memset(&attr, 0, sizeof(attr));
  attr.attr.max_wr = qpsMaxDepth;
  attr.attr.max_sge = 1;
  ibv_srq *srq = ibv_create_srq(context->pd, &attr);

  ibv_exp_dct_init_attr dAttr;
  memset(&dAttr, 0, sizeof(dAttr));
  dAttr.pd = context->pd;
  dAttr.cq = cq;
  dAttr.srq = srq;
  dAttr.dc_key = DCT_ACCESS_KEY;
  dAttr.port = context->port;
  dAttr.access_flags = IBV_ACCESS_REMOTE_READ | IBV_ACCESS_REMOTE_READ |
                       IBV_ACCESS_REMOTE_ATOMIC;
  dAttr.min_rnr_timer = 2;
  dAttr.tclass = 0;
  dAttr.flow_label = 0;
  dAttr.mtu = IBV_MTU_4096;
  dAttr.pkey_index = 0;
  dAttr.hop_limit = 1;
  dAttr.create_flags = 0;
  dAttr.inline_size = maxInlineData;

  *dct = ibv_exp_create_dct(context->ctx, &dAttr);
  if (dct == NULL) {
    Debug::notifyError("RDMA DCT: create failed errno=%d (%s)", errno,
                       strerror(errno));
    return false;
  }

  return true;
}

void fillAhAttr(ibv_ah_attr *attr, uint32_t remoteLid, uint8_t *remoteGid,
                RdmaContext *context) {

  (void)remoteGid;

  memset(attr, 0, sizeof(ibv_ah_attr));
  attr->dlid = remoteLid;
  attr->sl = 0;
  attr->src_path_bits = 0;
  attr->port_num = context->port;

  // attr->is_global = 0;

  // fill ah_attr with GRH
  attr->is_global = 1;
  memcpy(&attr->grh.dgid, remoteGid, 16);
  attr->grh.flow_label = 0;
  attr->grh.hop_limit = 1;
  attr->grh.sgid_index = context->gidIndex;
  attr->grh.traffic_class = 0;
}

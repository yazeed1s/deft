#include "CxlTransport.h"

#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "Debug.h"

namespace cxl {

// ---------------------------------------------------------------------------
// Shared-memory region management
// ---------------------------------------------------------------------------

SharedRegion create_region(const std::string &name, uint64_t size) {
  SharedRegion r;
  r.shm_name = name;
  r.size = size;

  // Clean up any stale region from a previous run
  shm_unlink(name.c_str());

  r.fd = shm_open(name.c_str(), O_CREAT | O_RDWR, 0666);
  if (r.fd < 0) {
    Debug::notifyError("cxl::create_region: shm_open(%s) failed: %s",
                       name.c_str(), strerror(errno));
    std::abort();
  }

  if (ftruncate(r.fd, (off_t)size) != 0) {
    Debug::notifyError("cxl::create_region: ftruncate(%s, %lu) failed: %s",
                       name.c_str(), size, strerror(errno));
    std::abort();
  }

  r.base_addr =
      mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED, r.fd, 0);
  if (r.base_addr == MAP_FAILED) {
    Debug::notifyError("cxl::create_region: mmap(%s, %lu) failed: %s",
                       name.c_str(), size, strerror(errno));
    std::abort();
  }

  // Zero-initialize
  std::memset(r.base_addr, 0, size);

  Debug::notifyInfo("cxl::create_region: name=%s size=%lu addr=%p", name.c_str(),
                    size, r.base_addr);
  return r;
}

SharedRegion open_region(const std::string &name, uint64_t size) {
  SharedRegion r;
  r.shm_name = name;
  r.size = size;

  // Spin until the server has created the region
  int retries = 0;
  while (true) {
    r.fd = shm_open(name.c_str(), O_RDWR, 0666);
    if (r.fd >= 0) break;
    if (errno != ENOENT) {
      Debug::notifyError("cxl::open_region: shm_open(%s) failed: %s",
                         name.c_str(), strerror(errno));
      std::abort();
    }
    if (++retries % 1000 == 0) {
      Debug::notifyInfo(
          "cxl::open_region: waiting for region '%s' to appear...",
          name.c_str());
    }
    usleep(1000);  // 1 ms
  }

  r.base_addr =
      mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED, r.fd, 0);
  if (r.base_addr == MAP_FAILED) {
    Debug::notifyError("cxl::open_region: mmap(%s, %lu) failed: %s",
                       name.c_str(), size, strerror(errno));
    std::abort();
  }

  Debug::notifyInfo("cxl::open_region: name=%s size=%lu addr=%p", name.c_str(),
                    size, r.base_addr);
  return r;
}

void close_region(SharedRegion &region) {
  if (region.base_addr && region.base_addr != MAP_FAILED) {
    munmap(region.base_addr, region.size);
  }
  if (region.fd >= 0) {
    ::close(region.fd);
  }
  region.base_addr = nullptr;
  region.fd = -1;
  Debug::notifyInfo("cxl::close_region: %s", region.shm_name.c_str());
}

void destroy_region(SharedRegion &region) {
  close_region(region);
  if (!region.shm_name.empty()) {
    shm_unlink(region.shm_name.c_str());
    Debug::notifyInfo("cxl::destroy_region: unlinked %s",
                      region.shm_name.c_str());
  }
}

// ---------------------------------------------------------------------------
// RPC message queue
// ---------------------------------------------------------------------------

uint64_t rpc_region_size(uint32_t num_clients, uint32_t num_app_threads,
                         uint32_t num_directories) {
  // One queue = header (128 B) + capacity * MessageSlot (128 B each)
  const uint64_t per_queue =
      128 + (uint64_t)kRpcSlotCapacity * sizeof(MessageSlot);

  // Request queues: num_clients * num_app_threads * num_directories
  // Reply   queues: num_clients * num_app_threads
  uint64_t num_queues =
      (uint64_t)num_clients * num_app_threads * num_directories +
      (uint64_t)num_clients * num_app_threads;

  // Meta header (aligned to 4 KB for cleanliness)
  const uint64_t meta_size = 4096;

  return meta_size + num_queues * per_queue;
}

void init_rpc_region(void *base, uint32_t num_clients, uint32_t num_app_threads,
                     uint32_t num_directories) {
  auto *meta = reinterpret_cast<RpcRegionMeta *>(base);
  meta->num_clients = num_clients;
  meta->num_app_threads = num_app_threads;
  meta->num_directories = num_directories;
  meta->slot_capacity = kRpcSlotCapacity;

  const uint64_t per_queue =
      128 + (uint64_t)kRpcSlotCapacity * sizeof(MessageSlot);
  const uint64_t meta_size = 4096;
  uint64_t offset = meta_size;

  // Request queues
  for (uint32_t c = 0; c < num_clients; ++c) {
    for (uint32_t t = 0; t < num_app_threads; ++t) {
      for (uint32_t d = 0; d < num_directories; ++d) {
        meta->req_queue_offset[c][t][d] = offset;
        auto *q =
            reinterpret_cast<RpcQueueHeader *>((char *)base + offset);
        q->capacity = kRpcSlotCapacity;
        q->head.store(0, std::memory_order_relaxed);
        q->tail.store(0, std::memory_order_relaxed);
        // Zero all slots
        for (uint32_t s = 0; s < kRpcSlotCapacity; ++s) {
          q->slots()[s].valid.store(0, std::memory_order_relaxed);
        }
        offset += per_queue;
      }
    }
  }

  // Reply queues
  for (uint32_t c = 0; c < num_clients; ++c) {
    for (uint32_t t = 0; t < num_app_threads; ++t) {
      meta->rep_queue_offset[c][t] = offset;
      auto *q = reinterpret_cast<RpcQueueHeader *>((char *)base + offset);
      q->capacity = kRpcSlotCapacity;
      q->head.store(0, std::memory_order_relaxed);
      q->tail.store(0, std::memory_order_relaxed);
      for (uint32_t s = 0; s < kRpcSlotCapacity; ++s) {
        q->slots()[s].valid.store(0, std::memory_order_relaxed);
      }
      offset += per_queue;
    }
  }

  std::atomic_thread_fence(std::memory_order_release);

  Debug::notifyInfo("cxl::init_rpc_region: %u clients, %u app_threads, %u dirs, "
                    "total %lu bytes, %lu queues",
                    num_clients, num_app_threads, num_directories, offset,
                    (uint64_t)num_clients * num_app_threads * num_directories +
                        (uint64_t)num_clients * num_app_threads);
}

void rpc_send(RpcQueueHeader *q, const void *msg, size_t msg_size) {
  uint32_t h = q->head.load(std::memory_order_relaxed);
  uint32_t idx = h % q->capacity;
  MessageSlot *slot = &q->slots()[idx];

  // Spin if the slot is still occupied (consumer hasn't drained it yet).
  while (slot->valid.load(std::memory_order_acquire) != 0) {
    // busy-wait
  }

  std::memcpy(slot->payload, msg,
              msg_size <= sizeof(slot->payload) ? msg_size
                                                : sizeof(slot->payload));
  slot->valid.store(1, std::memory_order_release);
  q->head.store(h + 1, std::memory_order_relaxed);
}

bool rpc_try_recv(RpcQueueHeader *q, void *msg_out, size_t msg_size) {
  uint32_t t = q->tail.load(std::memory_order_relaxed);
  uint32_t idx = t % q->capacity;
  MessageSlot *slot = &q->slots()[idx];

  if (slot->valid.load(std::memory_order_acquire) == 0) {
    return false;
  }

  std::memcpy(msg_out, slot->payload,
              msg_size <= sizeof(slot->payload) ? msg_size
                                                : sizeof(slot->payload));
  slot->valid.store(0, std::memory_order_release);
  q->tail.store(t + 1, std::memory_order_relaxed);
  return true;
}

void rpc_recv(RpcQueueHeader *q, void *msg_out, size_t msg_size) {
  while (!rpc_try_recv(q, msg_out, msg_size)) {
    // busy-wait
  }
}

}  // namespace cxl

#ifndef __CXL_TRANSPORT_H__
#define __CXL_TRANSPORT_H__

#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>

#include "Debug.h"

// Forward-declare RawMessage so we can embed it without pulling in
// the full RDMA header chain.  The struct itself is defined in
// RawMessageConnection.h (which is transport-agnostic).
struct RawMessage;

namespace cxl {

// ---------------------------------------------------------------------------
// Shared memory region
// ---------------------------------------------------------------------------

struct SharedRegion {
  std::string shm_name;    // POSIX shm name (e.g. "/deft_dsm")
  void       *base_addr;   // mmap'd base pointer
  uint64_t    size;         // region size in bytes
  int         fd;           // shm file descriptor

  SharedRegion() : base_addr(nullptr), size(0), fd(-1) {}
};

/// Create a new POSIX shared-memory region (server side).
/// Calls shm_open(O_CREAT|O_RDWR) + ftruncate + mmap(MAP_SHARED).
SharedRegion create_region(const std::string &name, uint64_t size);

/// Open an existing POSIX shared-memory region (client side).
/// Calls shm_open(O_RDWR) + mmap(MAP_SHARED).  Spins until the region
/// exists (the server may not have created it yet).
SharedRegion open_region(const std::string &name, uint64_t size);

/// Unmap and close (does NOT shm_unlink — the server owns the lifetime).
void close_region(SharedRegion &region);

/// Unmap, close, AND unlink.  Only the server should call this.
void destroy_region(SharedRegion &region);

// ---------------------------------------------------------------------------
// CXL data-plane primitives
// ---------------------------------------------------------------------------
// These operate directly on pointers inside an mmap'd SharedRegion.
// They mirror the semantics of RDMA one-sided verbs but are just
// load/store/atomic on cache-coherent shared memory.

/// Read `size` bytes from `remote_addr` (in shared region) into
/// `local_buf`.  Equivalent to RDMA READ.
inline void read(void *local_buf, const void *remote_addr, size_t size) {
  std::memcpy(local_buf, remote_addr, size);
  // Full fence so subsequent dependent reads see consistent data,
  // analogous to polling the CQ after an RDMA READ.
  std::atomic_thread_fence(std::memory_order_acquire);
}

/// Write `size` bytes from `local_buf` into `remote_addr` (in shared
/// region).  Equivalent to RDMA WRITE.
inline void write(const void *local_buf, void *remote_addr, size_t size) {
  std::memcpy(remote_addr, local_buf, size);
  // Release fence to make the write visible to other processes.
  std::atomic_thread_fence(std::memory_order_release);
}

/// 64-bit compare-and-swap on `remote_addr`.
/// Returns true if the swap succeeded (old value == expected).
/// `*old_val` is always set to the value found at remote_addr before
/// the operation (like RDMA CAS returning the old value in the buffer).
inline bool cas(void *remote_addr, uint64_t expected, uint64_t desired,
                uint64_t *old_val) {
  // We must operate on the shared region atomically.  reinterpret_cast
  // to std::atomic is safe on x86-64 for naturally aligned 64-bit words.
  auto *target = reinterpret_cast<std::atomic<uint64_t> *>(remote_addr);
  uint64_t exp = expected;
  bool ok = target->compare_exchange_strong(exp, desired,
                                            std::memory_order_acq_rel,
                                            std::memory_order_acquire);
  if (old_val) *old_val = exp;
  return ok;
}

/// 64-bit fetch-and-add on `remote_addr`.  Returns the value BEFORE
/// the addition (same semantics as RDMA FAA).
inline uint64_t fetch_and_add(void *remote_addr, uint64_t add_val) {
  auto *target = reinterpret_cast<std::atomic<uint64_t> *>(remote_addr);
  return target->fetch_add(add_val, std::memory_order_acq_rel);
}

// ---------------------------------------------------------------------------
// RPC message queue  (replaces RDMA UD send/recv)
// ---------------------------------------------------------------------------
//
// Layout in shared memory (inside the "rpc" SharedRegion):
//
//   ┌────────────────────────────────────────────────────────────┐
//   │  RpcQueueHeader  (one per direction, per thread/dir pair) │
//   │  MessageSlot[capacity]                                    │
//   └────────────────────────────────────────────────────────────┘
//
// We allocate one request queue per (app_thread, directory) pair
// and one reply queue per app_thread.
//
// Client writes a request into the next slot and sets `valid = 1`.
// Server polls, processes, writes the reply into the reply queue,
// sets `valid = 1`.  Client spins on the reply slot.

// Cache-line-padded message slot
struct alignas(128) MessageSlot {
  std::atomic<uint8_t> valid;  // 0 = empty, 1 = has message
  uint8_t _pad0[7];
  // We store the raw bytes here rather than including RawMessage
  // directly, to avoid pulling in the full header chain into this
  // transport-level header.  Callers cast via rpc_msg().
  char payload[96];  // >= sizeof(RawMessage)

  MessageSlot() : valid(0) { std::memset(payload, 0, sizeof(payload)); }
};

static_assert(sizeof(MessageSlot) == 128,
              "MessageSlot must be exactly 128 bytes (2 cache lines)");

/// A fixed-capacity, single-producer/single-consumer message queue.
/// Stored inline in the shared-memory region.
struct RpcQueueHeader {
  uint32_t capacity;               // number of MessageSlot entries
  std::atomic<uint32_t> head;      // next slot to write (producer)
  std::atomic<uint32_t> tail;      // next slot to read  (consumer)
  char _pad[128 - 12];             // pad to cache line

  MessageSlot *slots() {
    return reinterpret_cast<MessageSlot *>(
        reinterpret_cast<char *>(this) + 128);
  }

  /// Total bytes consumed by this queue (header + slots).
  uint64_t byte_size() const {
    return 128 + (uint64_t)capacity * sizeof(MessageSlot);
  }
};

// ---------------------------------------------------------------------------
// RPC region layout helpers
// ---------------------------------------------------------------------------

/// How many bytes are needed for the entire RPC shared-memory region?
/// Layout:
///   [0]                 : RpcRegionMeta
///   [meta.req_offset[t][d]] : request queue for app thread t → dir d
///   [meta.rep_offset[t]]    : reply queue for app thread t
///
/// We pre-compute offsets once when the server creates the region.

constexpr uint32_t kRpcSlotCapacity = 64;  // slots per queue (power of 2)

// Max dimensions — must match Common.h
// We can't include Common.h here (circular), so we mirror the constants.
constexpr uint32_t kCxlMaxAppThread  = 32;
constexpr uint32_t kCxlMaxDirectory  = 1;   // NR_DIRECTORY

/// Metadata stored at the start of the RPC shared region so both
/// server and client can locate queues by (thread, dir) indices.
struct RpcRegionMeta {
  uint32_t num_app_threads;
  uint32_t num_directories;
  uint32_t slot_capacity;  // kRpcSlotCapacity
  uint32_t _pad;

  /// Byte offset (from region base) for the request queue
  /// from app thread `t` to directory `d`.
  uint64_t req_queue_offset[kCxlMaxAppThread][kCxlMaxDirectory];

  /// Byte offset (from region base) for the reply queue
  /// for app thread `t`.
  uint64_t rep_queue_offset[kCxlMaxAppThread];
};

/// Compute the total byte size needed for the RPC region.
uint64_t rpc_region_size(uint32_t num_app_threads, uint32_t num_directories);

/// Initialize the RPC region metadata and all queues (server side).
void init_rpc_region(void *base, uint32_t num_app_threads,
                     uint32_t num_directories);

/// Get a pointer to a specific request queue.
inline RpcQueueHeader *get_request_queue(void *rpc_base, uint32_t thread_id,
                                         uint32_t dir_id) {
  auto *meta = reinterpret_cast<RpcRegionMeta *>(rpc_base);
  uint64_t off = meta->req_queue_offset[thread_id][dir_id];
  return reinterpret_cast<RpcQueueHeader *>(
      reinterpret_cast<char *>(rpc_base) + off);
}

/// Get a pointer to a specific reply queue.
inline RpcQueueHeader *get_reply_queue(void *rpc_base, uint32_t thread_id) {
  auto *meta = reinterpret_cast<RpcRegionMeta *>(rpc_base);
  uint64_t off = meta->rep_queue_offset[thread_id];
  return reinterpret_cast<RpcQueueHeader *>(
      reinterpret_cast<char *>(rpc_base) + off);
}

/// Enqueue a message (producer side).
/// Spins if the queue is full (should not happen in practice).
void rpc_send(RpcQueueHeader *q, const void *msg, size_t msg_size);

/// Try to dequeue a message (consumer side).
/// Returns true if a message was available (copied into `msg_out`).
bool rpc_try_recv(RpcQueueHeader *q, void *msg_out, size_t msg_size);

/// Blocking receive — spins until a message is available.
void rpc_recv(RpcQueueHeader *q, void *msg_out, size_t msg_size);

}  // namespace cxl

#endif /* __CXL_TRANSPORT_H__ */

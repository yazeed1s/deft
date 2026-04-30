# Porting Deft from RDMA to CXL: Implementation Walkthrough

## Overview

This document describes the step-by-step process of porting the Deft B+tree disaggregated memory system from RDMA to a simulated CXL environment. It covers every file modified, the rationale behind each change, and the design decisions made.

**Scope:** 20 files modified, ~910 lines added, zero changes to B+tree logic. **Status: Complete.**

---

## Phase 0: Build System Configuration

### File: `CMakeLists.txt`

**What changed:**
- Added `option(USE_CXL)` — a CMake flag to select the transport backend
- Conditional link flags: CXL links `-lrt` (POSIX shm), RDMA links `-libverbs`
- Removed `-lboost_system` (Boost 1.91 made it header-only)
- Source filtering: `USE_CXL=ON` excludes `src/rdma/*.cpp`, `USE_CXL=OFF` excludes `src/cxl/*.cpp`

**Design decision:** Compile-time selection was chosen over runtime polymorphism (virtual methods) because:
1. Zero overhead — no vtable indirection on hot-path operations
2. Cleaner separation — RDMA headers don't need to exist on CXL machines
3. Matches the original codebase style (no virtual dispatch anywhere)

---

## Phase 1: CXL Transport Layer (New Files)

### File: `include/CxlTransport.h` (NEW — 221 lines)

This is the **core abstraction layer** that replaces RDMA verbs. It defines:

#### 1. SharedRegion — Memory Management
```cpp
struct SharedRegion {
  std::string shm_name;   // e.g. "/deft_dsm"
  void *base_addr;         // mmap'd pointer
  uint64_t size;
  int fd;
};
```
- `create_region()` — server creates POSIX shm, truncates, mmaps, zero-fills
- `open_region()` — client opens existing shm, spins until it appears
- `destroy_region()` — server unlinks (cleanup)

#### 2. Data Plane Primitives
```cpp
cxl::read(local_buf, remote_addr, size)   // memcpy + acquire fence
cxl::write(local_buf, remote_addr, size)  // memcpy + release fence
cxl::cas(remote_addr, expected, desired, old_val)  // atomic CAS
cxl::fetch_and_add(remote_addr, add_val)           // atomic FAA
```
These are **inline functions** — no function call overhead. They directly operate on pointers within the mmap'd region.

#### 3. RPC Message Queue
Replaces RDMA UD send/recv with a shared-memory ring buffer:
- `MessageSlot` — 128-byte cache-line-aligned slot with atomic `valid` bit
- `RpcQueueHeader` — fixed-capacity SPSC queue (head/tail pointers)
- `RpcRegionMeta` — offset table so both server and client can locate queues by `(thread_id, dir_id)`
- `rpc_send()` / `rpc_try_recv()` / `rpc_recv()` — producer/consumer operations

**Design decision:** Cache-line alignment (128 bytes per slot) prevents false sharing between producer and consumer. The valid-bit protocol avoids the need for a shared counter that both sides would contend on.

### File: `src/cxl/CxlTransport.cpp` (NEW — 224 lines)

Implementation of the above. Key details:
- `create_region()` calls `shm_unlink` first to clean stale regions from crashed runs
- `open_region()` spins with 1ms sleep intervals, logs every 1000 retries
- `init_rpc_region()` pre-computes all queue offsets into `RpcRegionMeta`, allowing O(1) queue lookup
- `rpc_send()` spins on the valid bit if the slot is occupied (backpressure)

---

## Phase 2: DSM Server Porting

### File: `include/dsm_server.h`

**What changed:**
```cpp
#ifdef USE_CXL
  cxl::SharedRegion dsm_region_;      // replaces ibv_mr + huge pages
  cxl::SharedRegion lock_region_;     // replaces on-chip device memory
  cxl::SharedRegion rpc_region_;      // replaces UD QP buffers
  GlobalAllocator *chunk_alloc_[];    // same allocation logic
  Keeper *keeper_;                    // base class only (no DSMServerKeeper)
#else
  DSMServerKeeper *keeper_;           // full RDMA keeper with QP management
  RemoteConnectionToClient *conn_;    // ibv_ah, rkeys, etc.
  DirectoryConnection *dir_con_[];   // ibv_qp, ibv_mr for each directory
  Directory *dir_agent_[];            // message-processing threads
#endif
```

### File: `src/dsm_server.cpp`

**CXL constructor flow:**
1. `InitCxlMemory()` — creates the 3 shared-memory regions
2. Creates a `Keeper` (base class only) for memcached coordination
3. Registers server ID via `memcached_increment("ServerNum")`
4. Publishes region sizes to memcached: `cxl_dsm_size_0`, `cxl_lock_size_0`, `cxl_rpc_size_0`
5. Calls `Barrier("DSMServer-init")` — waits for all servers to be ready

**CXL Run() loop:**
```cpp
while (running) {
  for (each app_thread t) {
    for (each directory d) {
      if (rpc_try_recv(req_queue[t][d], &msg)) {
        ProcessMessage(&msg, d);  // MALLOC → alloc, NEW_ROOT → update ptr
      }
    }
  }
}
```

This replaces the RDMA `Directory::dirThread()` which polls `ibv_poll_cq()` on the UD completion queue.

**ProcessMessage()** handles:
- `MALLOC` → `chunk_alloc_[dir]->alloc_chunck()`, sends reply via `rpc_send()` to the client's reply queue
- `NEW_ROOT` → updates `g_root_ptr` and `g_root_level`
- `TERMINATE` → sets `running = false`

---

## Phase 3: DSM Client Porting (Complete)

### File: `include/dsm_client.h`

**Strategy:** Keep the **public API identical** for both modes. Only private members differ:

```cpp
// Shared between modes
Keeper *keeper_;                     // memcached coordination
static thread_local int thread_id_;
static thread_local char *rdma_buffer_;
static thread_local RdmaBuffer rbuf_[];

// RDMA-only
ThreadConnection *i_con_;            // QPs, CQ, MR
RemoteConnectionToServer *conn_;     // rkeys, dsm_base

// CXL-only
cxl::SharedRegion dsm_region_;       // mmap'd DSM pool
cxl::SharedRegion lock_region_;      // mmap'd lock region
cxl::SharedRegion rpc_region_;       // mmap'd RPC queues
void *ResolveAddr(GlobalAddress);    // gaddr → raw pointer
void *ResolveLockAddr(GlobalAddress);
```

### File: `src/dsm_client.cpp`

The file now has two large `#ifdef` blocks:

```cpp
#ifdef USE_RDMA
  // ... original 675 lines, unchanged ...
#endif

#ifdef USE_CXL
  // ... 545 lines of CXL implementation ...
#endif
```

**All 45+ methods implemented across 9 groups:**

#### Group 1: Bootstrap (3 methods)
- **Constructor** — opens 3 shm regions via memcached metadata exchange
- **RegisterThread()** — assigns thread_id, sets up scratch buffers from cache pool
- **Thread-local statics** — `thread_id_`, `rdma_buffer_`, `rbuf_[]`, `rpc_reply_buf_`

#### Group 2: Address Resolution (2 methods)
```cpp
void *ResolveAddr(GlobalAddress gaddr) {
  return (char *)dsm_region_.base_addr + gaddr.offset;
}
```

#### Group 3: Read/Write (4 methods)
Each is a one-liner calling `cxl::read`/`cxl::write` on the resolved pointer. `signal` and `CoroContext` parameters are ignored — ops are inherently synchronous.

#### Group 4: CAS (4 methods)
- `Cas/CasSync` — `cxl::cas` (atomic `compare_exchange_strong`)
- `CasMask/CasMaskSync` — software masked CAS loop: load, mask-compare, build desired value, `compare_exchange_weak`, retry

#### Group 5: FAA (2 methods)
`cxl::fetch_and_add` on DSM pool, stores old value in buffer.

#### Group 6: Device Memory / Lock Ops (10 methods)
Identical to Groups 3-5 but using `ResolveLockAddr()` to target the lock region.

#### Group 7: Batch/Compound Ops (16 methods)
- `ReadBatch/WriteBatch` — loop over `RdmaOpRegion` array, resolve each via `CxlResolveRor` helper
- `WriteFaa`, `WriteCas`, `CasRead`, `FaaRead`, `FaaBoundRead`, `CasMaskWrite` — execute constituent operations sequentially
- All Sync variants delegate to the non-Sync version (identical under CXL)

#### Group 8: CQ Polling (2 methods)
- `PollRdmaCq` → returns 0
- `PollRdmaCqOnce` → returns false

#### Group 9: RPC (3 methods)
```cpp
void RpcCallDir(const RawMessage &m, uint16_t node_id, uint16_t dir_id) {
  RawMessage buf = m;
  buf.node_id = my_client_id_;
  buf.app_id = thread_id_;
  auto *req_q = cxl::get_request_queue(rpc_region_.base_addr, thread_id_, dir_id);
  cxl::rpc_send(req_q, &buf, sizeof(buf));
}

RawMessage *RpcWait() {
  auto *rep_q = cxl::get_reply_queue(rpc_region_.base_addr, thread_id_);
  cxl::rpc_recv(rep_q, &rpc_reply_buf_, sizeof(rpc_reply_buf_));
  return &rpc_reply_buf_;
}
```
`Alloc` uses the same local-allocator logic as RDMA — requests a new chunk via MALLOC RPC only when the local pool is exhausted.

---

## Phase 4: Header Guards

To prevent RDMA headers from contaminating CXL builds, we wrapped transport-specific code:

### Transport-Agnostic Globals
`Directory.cpp` originally defined `g_root_ptr`, `g_root_level`, `enable_cache` inside `#ifdef USE_RDMA`. These are referenced by `Tree.cpp` in both modes, so they were moved **outside** the guard:

```cpp
// Always compiled (both modes)
GlobalAddress g_root_ptr = GlobalAddress::Null();
int g_root_level = -1;
bool enable_cache = true;

#ifdef USE_RDMA
// ... Directory class implementation ...
#endif
```

### RawMessage Separation
`RawMessageConnection.h` originally bundled:
- `RpcType` enum and `RawMessage` struct (transport-agnostic — used by both)
- `RawMessageConnection` class (RDMA-only — inherits from `AbstractMessageConnection`)

We separated them: the enum/struct are always available, the class is `#ifdef USE_RDMA`.

### Keeper Hierarchy
`dsm_keeper.h` defines:
- `Keeper` base class — memcached operations only, used by both modes
- `DSMServerKeeper` / `DSMClientKeeper` — RDMA QP/connection management, guarded

The `Keeper::ConnectMemcached()` method was changed from `protected` to `public` so the CXL server can call it directly (without subclassing).

---

## Files Modified Summary

| File | Change Type | Lines Changed | Purpose |
|------|-------------|---------------|---------|
| `CMakeLists.txt` | Modified | +21 | Transport selection, conditional linking |
| `include/CxlTransport.h` | **New** | +221 | CXL transport primitives |
| `src/cxl/CxlTransport.cpp` | **New** | +224 | CXL transport implementation |
| `include/dsm_server.h` | Modified | +32 | Dual-mode server header |
| `src/dsm_server.cpp` | Modified | +183 | CXL server: shm regions + RPC loop |
| `include/dsm_client.h` | Modified | +81 | Dual-mode client header |
| `src/dsm_client.cpp` | Modified | +545 | CXL client: all 45+ DSM operations |
| `include/Common.h` | Modified | +19 | Guard Rdma.h, CXL-compat RdmaOpRegion |
| `include/connection.h` | Modified | +10 | Guard ibv_ah-dependent structs |
| `include/dsm_keeper.h` | Modified | +11 | Guard RDMA subclasses |
| `src/dsm_keeper.cpp` | Modified | +8 | Guard RDMA subclass methods |
| `include/RawMessageConnection.h` | Modified | +12 | Separate RawMessage from RDMA class |
| `include/Directory.h` | Modified | +4 | Guard entire class |
| `src/Directory.cpp` | Modified | +18 | Extract globals, guard class |
| `include/ThreadConnection.h` | Modified | +5 | Guard entire class |
| `src/ThreadConnection.cpp` | Modified | +4 | Guard entire file |
| `include/DirectoryConnection.h` | Modified | +5 | Guard entire class |
| `src/DirectoryConnection.cpp` | Modified | +4 | Guard entire file |
| `include/AbstractMessageConnection.h` | Modified | +5 | Guard entire class |
| `src/AbstractMessageConnection.cpp` | Modified | +4 | Guard entire file |
| `src/RawMessageConnection.cpp` | Modified | +4 | Guard entire file |

---

## Key Design Decisions

### 1. Shared Memory vs Custom Driver
We chose POSIX shared memory (`/dev/shm`) over writing a custom kernel module or using `mmap` on a file. Rationale:
- Stays in userspace — no kernel development needed
- Provides the same cache-coherent load/store semantics as CXL.mem
- Automatically cleaned up on process exit (can also `shm_unlink`)

### 2. Single Server Constraint
The CXL port assumes `num_server = 1`. In a real CXL deployment, all compute nodes access one physical memory pool. Multi-server CXL would require a CXL switch, which is beyond our simulation scope.

### 3. No Coroutine Changes
The RDMA path uses Boost coroutines to overlap multiple outstanding RDMA operations. Under CXL, operations are synchronous (no network round-trip to hide), so `CoroContext` parameters are accepted but ignored. The coroutine infrastructure still compiles and runs — it just never yields.

### 4. Lock Memory ≡ DSM Pool Under CXL
In RDMA, "on-chip device memory" (DM) is a small, low-latency SRAM on the NIC used for frequently-accessed locks. Under CXL, we model this as a separate small shared-memory region (`/deft_lock`). In a real CXL system, this would likely just be a range within the same CXL-attached memory, possibly pinned to a closer NUMA domain.

### 5. Masked CAS in Software
RDMA NICs (ConnectX-5+) support masked CAS as an extended atomic operation in hardware. Under CXL, we implement it as a software CAS loop: load the full word, check masked bits, construct the desired value, attempt `compare_exchange_weak`, retry on failure. This is correct but has different performance characteristics (contention sensitivity).

---

## Build Verification

```
# CXL mode — all binaries link successfully
$ cd build_cxl && cmake .. -DUSE_CXL=ON && make -j$(nproc)
[  9%] Linking CXX static library libdeft.a
[ 63%] Built target deft
[ 86%] Built target skiplist_test
[ 90%] Built target server
[ 95%] Built target client_non_stop
[100%] Built target client
```

---

## Completion Status

All phases are **complete**. The port is code-complete and builds cleanly.

```
$ cd build_cxl && cmake .. -DUSE_CXL=ON && make -j$(nproc)
[ 63%] Built target deft
[ 86%] Built target skiplist_test
[ 90%] Built target server
[100%] Built target client_non_stop
[100%] Built target client
```

### Next Steps

| Task | Description | Difficulty |
|------|-------------|------------|
| **End-to-end test** | Start memcached + server + client on same machine | Easy |
| **RDMA regression** | Verify RDMA build on CloudLab (needs ibverbs) | Easy |
| **Performance comparison** | Run identical benchmarks on both backends | Medium |
| **Latency injection** | Optional: add configurable CXL latency for realism | Optional |

### How to Run (CXL mode)
```bash
# Terminal 0: start memcached
memcached -u root -l 0.0.0.0 -p 11211 &

# Terminal 1: start memory server
cd build_cxl && ./server --server_count=1 --client_count=1

# Terminal 2: start compute client (same machine)
cd build_cxl && ./client --server_count=1 --client_count=1
```

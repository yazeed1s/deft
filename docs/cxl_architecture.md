# CXL Transport Architecture for Deft B+Tree

## 1. Background: What Is Deft?

Deft is a **disaggregated B+tree index** designed for systems where compute and memory are physically separated. In the original design, compute nodes (clients) access a remote memory pool on a memory node (server) through **RDMA** (Remote Direct Memory Access), a hardware NIC-based technology that allows one machine to read/write another machine's memory without involving its CPU.

The B+tree itself runs entirely on the compute side — all traversals, splits, and merges happen in client code. The server is a "dumb" memory pool that only responds to two control-plane requests: **MALLOC** (allocate a new memory chunk) and **NEW_ROOT** (update the root pointer).

## 2. Motivation: Why CXL?

**CXL (Compute Express Link)** is an emerging interconnect standard that, like RDMA, enables remote memory access. However, CXL provides **cache-coherent load/store access** to remote memory — it looks like local memory to the CPU. This removes the need for queue pairs, completion queues, and memory registration.

The goal of this port is to:
1. **Simulate CXL** on a single machine using POSIX shared memory (`/dev/shm`)
2. **Compare performance** between RDMA and CXL transport layers
3. Keep the B+tree logic **completely unchanged** (transport-agnostic)

## 3. Original RDMA Architecture

```
┌─────────────────────────────────┐     RDMA NIC     ┌─────────────────────────────┐
│         COMPUTE NODE            │ ◄══════════════► │       MEMORY NODE           │
│                                 │   ibv_post_send   │                             │
│  ┌─────────┐    ┌────────────┐  │   ibv_poll_cq     │  ┌──────────────────────┐   │
│  │  Tree    │───►│ DSMClient  │  │                   │  │  DSMServer           │   │
│  │ (B+tree) │    │            │  │                   │  │  ├─ DSM memory pool  │   │
│  └─────────┘    │ ┌────────┐ │  │                   │  │  ├─ Lock memory (DM) │   │
│                 │ │Thread  │ │  │  One-sided verbs  │  │  └─ Directory (RPC)  │   │
│                 │ │Conn    │ │  │  ───────────────► │  │                      │   │
│                 │ │ - QPs  │ │  │  READ/WRITE/CAS   │  └──────────────────────┘   │
│                 │ │ - CQ   │ │  │                   │                             │
│                 │ │ - MR   │ │  │  UD messages      │  ┌──────────────────────┐   │
│                 │ │ - UD   │ │  │  ───────────────► │  │  Directory thread    │   │
│                 │ └────────┘ │  │  MALLOC/NEW_ROOT  │  │  (polls UD CQ)       │   │
│                 └────────────┘  │                   │  └──────────────────────┘   │
└─────────────────────────────────┘                   └─────────────────────────────┘
```

### Key RDMA Components

| Component | Role |
|-----------|------|
| **Queue Pair (QP)** | A pair of send/receive queues for RDMA operations. One RC QP per (client thread, server directory) pair |
| **Completion Queue (CQ)** | Clients poll the CQ to know when an RDMA operation has finished |
| **Memory Region (MR)** | Memory registered with the NIC. Both the DSM pool and the client cache are MRs |
| **Remote Key (rkey)** | Authorizes remote access to an MR. Exchanged during connection setup |
| **UD (Unreliable Datagram)** | Used for the RPC control plane (MALLOC/NEW_ROOT messages) |

### RDMA Data Flow (e.g., ReadSync)

1. Client calls `rdmaRead()` → posts a READ work request to the QP
2. NIC DMA-reads from server memory into client buffer (zero-copy, no server CPU)
3. Client calls `pollWithCQ()` → spins until the CQ reports completion
4. Client reads the buffer — data is now locally available

### RDMA Control Flow (e.g., Alloc)

1. Client builds a `RawMessage{type=MALLOC}` 
2. Sends via UD QP → `sendMessage2Dir()`
3. Server's `Directory` thread polls its UD CQ, receives the message
4. Server allocates from `GlobalAllocator`, sends reply back via UD
5. Client polls its `rpc_cq` → receives the chunk address

## 4. CXL Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                        SINGLE MACHINE (SAME HOST)                    │
│                                                                      │
│  ┌─────────────────────────┐       ┌────────────────────────────┐   │
│  │     COMPUTE PROCESS     │       │    MEMORY PROCESS          │   │
│  │                         │       │                            │   │
│  │  ┌─────────┐            │       │  ┌──────────────────────┐  │   │
│  │  │  Tree   │            │       │  │  DSMServer           │  │   │
│  │  │(B+tree) │            │       │  │  (creates shm)       │  │   │
│  │  └────┬────┘            │       │  └──────┬───────────────┘  │   │
│  │       │                 │       │         │                  │   │
│  │  ┌────▼────────────┐    │       │         │ creates          │   │
│  │  │   DSMClient     │    │       │         ▼                  │   │
│  │  │                 │    │       │  ┌──────────────┐          │   │
│  │  │  ResolveAddr()──┼────┼───mmap──►│ /deft_dsm    │          │   │
│  │  │  memcpy / CAS   │    │       │  │ (DSM pool)   │ POSIX    │   │
│  │  │                 │    │       │  ├──────────────┤ shared   │   │
│  │  │  ResolveLock()──┼────┼───mmap──►│ /deft_lock   │ memory   │   │
│  │  │  atomic ops     │    │       │  │ (lock mem)   │ regions  │   │
│  │  │                 │    │       │  ├──────────────┤          │   │
│  │  │  RPC queue ─────┼────┼───mmap──►│ /deft_rpc    │          │   │
│  │  │  rpc_send/recv  │    │       │  │ (msg queues) │          │   │
│  │  └─────────────────┘    │       │  └──────────────┘          │   │
│  └─────────────────────────┘       └────────────────────────────┘   │
│                                                                      │
│  ════════════════════════  /dev/shm  ════════════════════════════    │
└──────────────────────────────────────────────────────────────────────┘
```

### CXL Simulation via POSIX Shared Memory

CXL.mem provides **cache-coherent load/store** semantics to remote memory — meaning a CPU can directly dereference a pointer to CXL-attached memory as if it were local DRAM. On a real CXL system, the hardware handles cache coherence across the interconnect.

We simulate this with **POSIX shared memory** (`shm_open` + `mmap` with `MAP_SHARED`):
- Both server and client processes `mmap` the same shared file into their address spaces
- Loads and stores become ordinary memory operations visible to both processes
- The kernel's virtual memory subsystem + x86 cache coherence protocol ensures consistency
- This is a **faithful simulation** of CXL.mem semantics: both processes see a flat, cache-coherent memory region

### Three Shared-Memory Regions

| Region | POSIX Name | Purpose | Size | RDMA Equivalent |
|--------|-----------|---------|------|-----------------|
| **DSM Pool** | `/deft_dsm` | B+tree data (nodes, pages) | 62 GB (configurable) | `ibv_reg_mr` on huge-page buffer |
| **Lock Memory** | `/deft_lock` | Concurrency control locks | 256 KB (`kLockChipMemSize`) | On-chip device memory (ConnectX DM) |
| **RPC Region** | `/deft_rpc` | Message queues for control ops | ~300 KB | UD QP send/recv buffers |

## 5. Primitive-Level Mapping: RDMA → CXL

This table shows exactly how each RDMA operation maps to a CXL primitive:

| RDMA Operation | RDMA Implementation | CXL Implementation | Notes |
|----------------|--------------------|--------------------|-------|
| **READ** | `ibv_post_send(IBV_WR_RDMA_READ)` + `poll_cq` | `memcpy(dst, src, size)` + `acquire fence` | NIC DMA → plain load |
| **WRITE** | `ibv_post_send(IBV_WR_RDMA_WRITE)` + `poll_cq` | `memcpy(dst, src, size)` + `release fence` | NIC DMA → plain store |
| **CAS** | `ibv_post_send(IBV_WR_ATOMIC_CMP_AND_SWP)` + `poll_cq` | `std::atomic::compare_exchange_strong` | HW atomic → CPU atomic |
| **FAA** | `ibv_post_send(IBV_WR_ATOMIC_FETCH_AND_ADD)` + `poll_cq` | `std::atomic::fetch_add` | HW atomic → CPU atomic |
| **Masked CAS** | `rdmaCompareAndSwapMask()` (extended atomic) | Software CAS loop with mask | Compare only masked bits |
| **CQ Polling** | `ibv_poll_cq()` — spin until WC appears | **No-op** — all ops are synchronous | No asynchrony under CXL |
| **UD Send** | `sendRawMessage()` via UD QP | `rpc_send()` — write to shared-memory queue | Network message → shared-memory slot |
| **UD Recv** | `ibv_poll_cq()` on UD CQ | `rpc_try_recv()` — read from shared-memory queue | Polling CQ → polling queue slot |
| **Memory Registration** | `ibv_reg_mr()` — pin memory, get rkey/lkey | **Not needed** — mmap gives direct access | CXL doesn't need registration |
| **Address Resolution** | `dsm_base + gaddr.offset` (from exchanged metadata) | `mmap_base + gaddr.offset` | Identical offset calculation |
| **Coroutines** | `boost::coroutine yield/resume` for async pipelining | **Ignored** — ops are synchronous | No latency to hide |

## 6. RPC Message Queue Design

The RDMA path uses **UD (Unreliable Datagram)** QPs for RPC messages. Under CXL, we replace this with a **shared-memory message queue** system:

```
RPC Shared Memory Region Layout:
┌─────────────────────────────────────────────────────────┐
│ RpcRegionMeta (4 KB)                                    │
│   - num_app_threads, num_directories, slot_capacity     │
│   - req_queue_offset[thread][dir]                       │
│   - rep_queue_offset[thread]                            │
├─────────────────────────────────────────────────────────┤
│ Request Queue [thread=0, dir=0]                         │
│   ┌─ RpcQueueHeader (128 B) ──────────────────────┐    │
│   │  capacity, head (atomic), tail (atomic)        │    │
│   ├─ MessageSlot[0] (128 B, cache-line aligned) ──┤    │
│   │  valid (atomic u8), payload[96]                │    │
│   ├─ MessageSlot[1] ─────────────────────────────┤    │
│   │  ...                                          │    │
│   ├─ MessageSlot[63] ────────────────────────────┤    │
│   └───────────────────────────────────────────────┘    │
├─────────────────────────────────────────────────────────┤
│ ... more request queues ...                             │
├─────────────────────────────────────────────────────────┤
│ Reply Queue [thread=0]                                  │
│   (same structure as request queue)                     │
├─────────────────────────────────────────────────────────┤
│ ... more reply queues ...                               │
└─────────────────────────────────────────────────────────┘
```

### Queue Properties
- **SPSC** (Single-Producer, Single-Consumer) — one client thread writes, one server dir reads
- **Fixed-capacity ring buffer** (64 slots) — no dynamic allocation
- **Cache-line aligned slots** (128 bytes) — prevents false sharing
- **Atomic valid bit** — `release` on write, `acquire` on read

### Message Flow (MALLOC Example)

```
Client Thread 0                    Server (polling loop)
      │                                   │
      ├─ Build RawMessage{MALLOC}         │
      ├─ rpc_send(req_queue[0][0], msg)   │
      │    └─ write payload to slot       │
      │    └─ valid.store(1, release)     │
      │                                   ├─ rpc_try_recv(req_queue[0][0])
      │                                   │    └─ valid.load(acquire) == 1
      │                                   │    └─ copy payload out
      │                                   │    └─ valid.store(0, release)
      │                                   ├─ ProcessMessage(MALLOC)
      │                                   │    └─ chunk_alloc_->alloc_chunck()
      │                                   ├─ rpc_send(rep_queue[0], reply)
      ├─ rpc_recv(rep_queue[0])           │
      │    └─ spin until valid == 1       │
      │    └─ read reply.addr             │
      ├─ local_allocator_.set_chunck()    │
      │                                   │
```

## 7. Memory Ordering & Correctness

CXL provides **cache coherence**, but we still need proper **memory ordering** to ensure visibility across processes. Our approach:

| Operation | Fence | Rationale |
|-----------|-------|-----------|
| `cxl::read()` | `acquire` fence after memcpy | Ensures subsequent dependent reads see the data — mirrors RDMA CQ polling semantics |
| `cxl::write()` | `release` fence after memcpy | Ensures the write is visible to other processes before any later operation |
| `cxl::cas()` | `acq_rel` on the atomic itself | Standard CAS ordering — acquires on read, releases on write |
| `cxl::fetch_and_add()` | `acq_rel` on the atomic itself | Same as CAS |
| Queue `valid` bit | `release` on store, `acquire` on load | Producer-consumer synchronization |

On x86-64, most of these are "free" (x86 has Total Store Ordering), but we use the C++ memory model to be correct on all architectures.

## 8. Build System Design

The build system uses a **compile-time macro** to select the transport:

```cmake
option(USE_CXL "Build with simulated CXL backend instead of RDMA" OFF)

if(USE_CXL)
  add_definitions(-DUSE_CXL)
  set(LINKS_FLAGS "... -lrt")          # POSIX shm requires -lrt
  # Exclude src/rdma/*.cpp
else()
  add_definitions(-DUSE_RDMA)
  set(LINKS_FLAGS "... -libverbs")     # RDMA verbs library
  # Exclude src/cxl/*.cpp
endif()
```

**Build commands:**
```bash
# CXL mode (local machine simulation)
mkdir build_cxl && cd build_cxl
cmake .. -DUSE_CXL=ON && make -j$(nproc)

# RDMA mode (CloudLab cluster)
mkdir build_rdma && cd build_rdma
cmake .. -DUSE_CXL=OFF && make -j$(nproc)
```

The same binary layout (`server`, `client`, `client_non_stop`) is produced in both modes. The Tree code is **identical** — only the DSMClient/DSMServer internals differ.

## 9. Header Guard Strategy

To prevent RDMA headers (`<infiniband/verbs.h>`) from leaking into CXL builds, we applied `#ifdef USE_RDMA` guards to:

| Header | Strategy |
|--------|----------|
| `Common.h` | Guards `#include "Rdma.h"`, provides CXL-compat `RdmaOpRegion` struct |
| `connection.h` | Wraps `RemoteConnectionToClient/Server` (contain `ibv_ah*`) |
| `ThreadConnection.h` | Entire content RDMA-only |
| `DirectoryConnection.h` | Entire content RDMA-only |
| `AbstractMessageConnection.h` | Entire content RDMA-only |
| `RawMessageConnection.h` | Separates transport-agnostic `RawMessage`/`RpcType` from RDMA-specific `RawMessageConnection` class |
| `dsm_keeper.h` | `Keeper` base (memcached) is shared; `DSMServerKeeper`/`DSMClientKeeper` subclasses are RDMA-only |
| `Directory.h` | Entire content RDMA-only (CXL server inlines the message handling) |

## 10. What Stays the Same

The following components are **completely transport-agnostic** and required zero changes:

- `Tree.h` / `Tree.cpp` — all B+tree logic (search, insert, delete, split, merge)
- `GlobalAddress.h` — the {nodeID, offset} addressing scheme
- `GlobalAllocator.h` — chunk-based memory allocation
- `LocalAllocator.h` — thread-local allocation
- `RdmaBuffer.h` — thread-local scratch buffer pool (name is misleading — no RDMA dependency)
- `Cache.h` / `Cache.cpp` — client-side cache pool
- `Config.h` — configuration structs
- `HugePageAlloc.h` — huge page allocation utility

## 11. Implementation Statistics

| Metric | Value |
|--------|-------|
| Files modified | 20 |
| New files | 2 (`CxlTransport.h`, `CxlTransport.cpp`) |
| Lines added | ~910 |
| Lines removed | ~64 |
| DSMClient methods implemented | 46 |
| B+tree lines changed | 0 |
| Test file lines changed | 0 |

### DSMClient Method Breakdown

| Category | Count | Examples |
|----------|-------|---------|
| Bootstrap / lifecycle | 3 | Constructor, RegisterThread, statics |
| Address resolution | 2 | ResolveAddr, ResolveLockAddr |
| Read / Write | 4 | Read, ReadSync, Write, WriteSync |
| CAS (regular + masked) | 4 | Cas, CasSync, CasMask, CasMaskSync |
| FAA | 2 | FaaBound, FaaBoundSync |
| Device memory (lock) ops | 10 | ReadDm, WriteDm, CasDm, CasDmMask, FaaDmBound + Sync |
| Batch / compound ops | 16 | ReadBatch, WriteBatch, WriteFaa, WriteCas, CasRead, FaaRead, FaaBoundRead, CasMaskWrite + Sync |
| CQ polling (no-ops) | 2 | PollRdmaCq, PollRdmaCqOnce |
| RPC | 3 | Alloc, RpcCallDir, RpcWait |

### Status: Complete

All transport methods are implemented. The system compiles and links cleanly for both CXL and RDMA backends. No stubs remain.

```
$ cd build_cxl && make -j$(nproc)
[ 63%] Built target deft
[ 86%] Built target skiplist_test
[ 90%] Built target server
[100%] Built target client_non_stop
[100%] Built target client
```


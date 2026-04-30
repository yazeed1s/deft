# Phase 3: CXL DSM Client Implementation

All work is in `src/dsm_client.cpp` under `#ifdef USE_CXL` (plus minor header touchups).
The public API in `dsm_client.h` is already dual-mode — we just need the implementations.

## Overview

Under CXL, `DSMClient` operates on `mmap`'d shared-memory regions created by the server.
- **Data ops** → `memcpy` / `__atomic_*` on resolved pointers
- **Device memory ops** → same but on the lock region
- **RPC (Alloc/Free/RpcCallDir)** → shared-memory message queue
- **CQ polling** → no-op (everything is synchronous)
- **Coroutines** → `CoroContext` accepted but ignored (no yield needed)

## Task List

### Group 1: Bootstrap & Thread Registration
These must work first — everything else depends on them.

- [x] **1.1** `DSMClient::DSMClient(const DSMConfig&)` — CXL constructor
  - Open shared-memory regions (`cxl::open_region` for dsm, lock, rpc)
  - Initialize `Keeper` for memcached coordination
  - Register as client, get `my_client_id_`
  - Allocate thread-local cache pool
- [x] **1.2** `DSMClient::RegisterThread()`
  - Assign `thread_id_`, `thread_tag_`
  - Set up `rdma_buffer_` (just `malloc` a scratch buffer, no MR needed)
  - Initialize `rbuf_[]` (RdmaBuffer for page/cas buffers)
  - Initialize `local_allocator_`
- [x] **1.3** Thread-local static definitions
  - `thread_id_`, `rdma_buffer_`, `local_allocator_`, `rbuf_[]`, `thread_tag_`
  - `rpc_reply_buf_`

### Group 2: Address Resolution Helpers
- [x] **2.1** `ResolveAddr(GlobalAddress gaddr)` → `dsm_region_.base_addr + gaddr.offset`
- [x] **2.2** `ResolveLockAddr(GlobalAddress gaddr)` → `lock_region_.base_addr + gaddr.offset`

### Group 3: Core Data Plane — Read / Write
- [x] **3.1** `Read(buffer, gaddr, size, signal, ctx)` → `cxl::read(buffer, ResolveAddr(gaddr), size)`
- [x] **3.2** `ReadSync(buffer, gaddr, size, ctx)` → same as Read (already synchronous)
- [x] **3.3** `Write(buffer, gaddr, size, signal, ctx)` → `cxl::write(buffer, ResolveAddr(gaddr), size)`
- [x] **3.4** `WriteSync(buffer, gaddr, size, ctx)` → same as Write

### Group 4: Atomic Operations — CAS
- [x] **4.1** `Cas(gaddr, equal, val, rdma_buffer, signal, ctx)` → `cxl::cas(ResolveAddr, equal, val, rdma_buffer)`
- [x] **4.2** `CasSync(gaddr, equal, val, rdma_buffer, ctx)` → same, return success bool
- [x] **4.3** `CasMask(gaddr, log_sz, equal, val, rdma_buffer, mask, signal, ctx)`
  - Software masked CAS: load → apply mask to compare → CAS loop
- [x] **4.4** `CasMaskSync(...)` → same, return success bool

### Group 5: Atomic Operations — FAA
- [x] **5.1** `FaaBound(gaddr, log_sz, add_val, rdma_buffer, mask, signal, ctx)`
  - `cxl::fetch_and_add(ResolveAddr, add_val)`, store old value in rdma_buffer
- [x] **5.2** `FaaBoundSync(...)` → same

### Group 6: Device Memory (Lock) Operations
Same as Groups 3-5 but using `ResolveLockAddr` instead of `ResolveAddr`.

- [x] **6.1** `ReadDm(buffer, gaddr, size, signal, ctx)` → `cxl::read(buffer, ResolveLockAddr(gaddr), size)`
- [x] **6.2** `ReadDmSync(...)` → same
- [x] **6.3** `WriteDm(buffer, gaddr, size, signal, ctx)` → `cxl::write(buffer, ResolveLockAddr(gaddr), size)`
- [x] **6.4** `WriteDmSync(...)` → same
- [x] **6.5** `CasDm(gaddr, equal, val, rdma_buffer, signal, ctx)` → `cxl::cas(ResolveLockAddr, ...)`
- [x] **6.6** `CasDmSync(...)` → same
- [x] **6.7** `CasDmMask(...)` → masked CAS on lock region
- [x] **6.8** `CasDmMaskSync(...)` → same
- [x] **6.9** `FaaDmBound(...)` → FAA on lock region
- [x] **6.10** `FaaDmBoundSync(...)` → same

### Group 7: Batch / Compound Operations
- [x] **7.1** `ReadBatch(rs, k, signal, ctx)` → loop of `cxl::read` for each RdmaOpRegion
- [x] **7.2** `ReadBatchSync(...)` → same
- [x] **7.3** `WriteBatch(rs, k, signal, ctx)` → loop of `cxl::write`
- [x] **7.4** `WriteBatchSync(...)` → same
- [x] **7.5** `WriteFaa(write_ror, faa_ror, add_val, signal, ctx)` → write + FAA sequentially
- [x] **7.6** `WriteFaaSync(...)` → same
- [x] **7.7** `WriteCas(write_ror, cas_ror, equal, val, signal, ctx)` → write + CAS sequentially
- [x] **7.8** `WriteCasSync(...)` → same
- [x] **7.9** `CasRead(cas_ror, read_ror, equal, val, signal, ctx)` → CAS + read sequentially
- [x] **7.10** `CasReadSync(...)` → same
- [x] **7.11** `FaaRead(faa_ror, read_ror, add, signal, ctx)` → FAA + read sequentially
- [x] **7.12** `FaaReadSync(...)` → same
- [x] **7.13** `FaaBoundRead(faab_ror, read_ror, add, boundary, signal, ctx)` → FAA-bound + read
- [x] **7.14** `FaaBoundReadSync(...)` → same
- [x] **7.15** `CasMaskWrite(cas_ror, equal, swap, mask, write_ror, signal, ctx)` → masked CAS + write
- [x] **7.16** `CasMaskWriteSync(...)` → same

### Group 8: CQ Polling (No-ops under CXL)
- [x] **8.1** `PollRdmaCq(count)` → return 0 (no CQ to poll, ops are synchronous)
- [x] **8.2** `PollRdmaCqOnce(wr_id)` → return false

### Group 9: RPC — Alloc / Free / RpcCallDir
- [x] **9.1** `Alloc(size)` → send MALLOC RPC via `cxl::rpc_send` on request queue, wait for reply on reply queue
- [x] **9.2** `RpcCallDir(m, node_id, dir_id)` → `cxl::rpc_send` to the right request queue
- [x] **9.3** `RpcWait()` → `cxl::rpc_recv` on this thread's reply queue, return RawMessage*

### Group 10: Build & Link Verification
- [x] **10.1** CXL build: `client` links successfully
- [x] **10.2** CXL build: `client_non_stop` links successfully
- [x] **10.3** CXL build: all warnings clean

---

## Implementation Order

Recommended order to get an end-to-end test working fastest:

1. **Groups 1-2** (bootstrap) — nothing works without these
2. **Groups 3-4** (read/write/CAS) — needed for tree search + insert
3. **Group 6** (lock ops) — needed for concurrency control
4. **Group 5** (FAA) — used in lock release
5. **Group 8** (CQ no-ops) — trivial, unblocks coroutine master
6. **Group 9** (RPC/Alloc) — needed for tree page allocation
7. **Group 7** (batch/compound) — used in optimized tree paths
8. **Group 10** (verification)

## Notes

- All `signal` parameters are ignored under CXL (no WR signaling)
- All `CoroContext *ctx` parameters are ignored (no coroutine yield)
- `is_on_chip` field in `RdmaOpRegion` determines whether to use `ResolveAddr` vs `ResolveLockAddr` in batch ops
- The `Sync` variant of each method is identical to the non-Sync version under CXL (ops are inherently synchronous)

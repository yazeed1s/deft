#include "Cache.h"

Cache::Cache(const CacheConfig &cache_config) {
  size = cache_config.cacheSize;
  data = (uint64_t)hugePageAlloc(size * define::GB);
  // Pre-fault huge pages so ibv_reg_mr does not fail on unmapped entries.
  for (uint64_t off = 0; off < size * define::GB; off += 2 * define::MB) {
    *(volatile char *)(data + off) = 0;
  }
}

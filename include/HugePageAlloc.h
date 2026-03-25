#ifndef __HUGEPAGEALLOC_H__
#define __HUGEPAGEALLOC_H__

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <memory.h>
#include <sys/mman.h>

char *getIP();
inline void *hugePageAlloc(size_t size) {

  void *res = mmap(NULL, size, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB, -1, 0);
  if (res == MAP_FAILED) {
    Debug::notifyError(
        "%s mmap failed! size=%zu bytes errno=%d (%s). Check hugepages.\n",
        getIP(), size, errno, strerror(errno));
    fflush(stdout);
    std::abort();
  }

  return res;
}

#endif /* __HUGEPAGEALLOC_H__ */

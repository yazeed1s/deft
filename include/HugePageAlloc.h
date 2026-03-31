#ifndef __HUGEPAGEALLOC_H__
#define __HUGEPAGEALLOC_H__

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <strings.h>

#include <memory.h>
#include <sys/mman.h>

char *getIP();
inline void *hugePageAlloc(size_t size) {
  const char *disable_hp = std::getenv("DEFT_DISABLE_HUGEPAGE");
  const bool use_hugetlb =
      !(disable_hp &&
        (strcmp(disable_hp, "1") == 0 || strcasecmp(disable_hp, "true") == 0));

  int flags = MAP_PRIVATE | MAP_ANONYMOUS;
  if (use_hugetlb) {
    flags |= MAP_HUGETLB;
  }
  void *res = mmap(NULL, size, PROT_READ | PROT_WRITE, flags, -1, 0);
  if (res != MAP_FAILED)
    return res;

  if (!use_hugetlb) {
    Debug::notifyError("%s mmap failed! size=%zu bytes errno=%d (%s).\n",
                       getIP(), size, errno, strerror(errno));
    fflush(stdout);
    std::abort();
  }

  // Fallback to normal pages for environments where hugetlb pinning is flaky.
  Debug::notifyInfo("%s hugetlb mmap failed (size=%zu, errno=%d %s), falling "
                    "back to normal pages",
                    getIP(), size, errno, strerror(errno));
  res = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS,
             -1, 0);
  if (res == MAP_FAILED) {
    Debug::notifyError(
        "%s fallback mmap failed! size=%zu bytes errno=%d (%s).\n", getIP(),
        size, errno, strerror(errno));
    fflush(stdout);
    std::abort();
  }

  return res;
}

#endif /* __HUGEPAGEALLOC_H__ */

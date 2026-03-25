#include "Common.h"
#include <string.h>
#include <pthread.h>

#include <sys/types.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <netinet/in.h>
#include <net/if.h>
#include <unistd.h>
#include <arpa/inet.h>

void bindCore(uint16_t core) {
  constexpr int CORE_PER_NUMA = 18;
  if (core >= CORE_PER_NUMA) {
    core += CORE_PER_NUMA;
  }

  cpu_set_t cpuset;
  CPU_ZERO(&cpuset);
  CPU_SET(core, &cpuset);
  int rc = pthread_setaffinity_np(pthread_self(), sizeof(cpu_set_t), &cpuset);
  if (rc != 0) {
    Debug::notifyError("can't bind core!");
  }
}

char *getIP() {
  struct ifreq ifr;
  int fd = socket(AF_INET, SOCK_DGRAM, 0);
  ifr.ifr_addr.sa_family = AF_INET;

  const char *ifaces[] = {"ib0", "eth1", "ens2", "eno1", "enp1s0f0"};
  for (const char *iface : ifaces) {
    strncpy(ifr.ifr_name, iface, IFNAMSIZ - 1);
    if (ioctl(fd, SIOCGIFADDR, &ifr) == 0) {
      close(fd);
      return inet_ntoa(((struct sockaddr_in *)&ifr.ifr_addr)->sin_addr);
    }
  }

  close(fd);
  return (char *)"0.0.0.0";
}

char *getMac() {
  static struct ifreq ifr;
  int fd = socket(AF_INET, SOCK_DGRAM, 0);

  ifr.ifr_addr.sa_family = AF_INET;
  strncpy(ifr.ifr_name, "ens2", IFNAMSIZ - 1);

  ioctl(fd, SIOCGIFHWADDR, &ifr);
  close(fd);

  return (char *)ifr.ifr_hwaddr.sa_data;
}

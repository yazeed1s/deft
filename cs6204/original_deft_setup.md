Your Markdown file detailing the hardware and testing setup for the DEFT paper is ready.

[file-tag: deft_experimental_setup_summary.md]

### Summary of Experimental Environment

The evaluation of **DEFT** was conducted on a high-performance cluster specifically designed to simulate disaggregated memory (DM) environments using RDMA.

#### **Hardware Configuration**

[cite_start]The setup utilized a cluster of **10 servers** connected via a **100 Gbps InfiniBand (IB) switch**[cite: 447, 450]. Each server was equipped with:

- [cite_start]**CPU:** 2.6 GHz Intel Xeon 6240M with 18 physical cores[cite: 448].
- [cite_start]**Memory:** 96 GB of DRAM[cite: 448].
- [cite_start]**Networking:** 100 Gbps Mellanox ConnectX-5 NIC, running OFED-4.9-5.1.0.0 drivers[cite: 448, 449].
- [cite_start]**Software:** Ubuntu 18.04 LTS with Linux kernel 4.15[cite: 448].

#### **Testing Methodology**

- [cite_start]**Resource Management:** Due to cluster size limits, each Memory Node (MN) was colocated with a Compute Node (CN)[cite: 451]. [cite_start]Compute nodes were allocated **1 GB of DRAM** specifically for an index cache[cite: 462].
- [cite_start]**Workload Diversity:** Tests were performed using standard **YCSB workloads** (Load, A, B, C, D, and E) and **Twitter workloads** (Storage, Computation, Transient) to test various read/write/scan ratios and object sizes[cite: 452, 454, 713, 714].
- [cite_start]**Scalability:** The researchers used **coroutines** to simulate high levels of concurrency, scaling up to **1,800 client threads** to stress the system[cite: 472, 474].
- [cite_start]**Comparative Baseline:** DEFT was evaluated against three state-of-the-art DM indexes: **Sherman** (write-optimized B+Tree), **dLSM** (LSM-based), and **SMART** (adaptive radix tree)[cite: 457, 458].

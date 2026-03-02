# High-Performance NVMe Storage: Resource Allocation Best Practices

## 목차
1. [개요](#1-개요)
2. [I/O Stack 기술 비교: Libaio vs SPDK vs io_uring](#2-io-stack-기술-비교)
3. [CPU NUMA 토폴로지 기반 자원 할당](#3-cpu-numa-토폴로지-기반-자원-할당)
4. [PCIe 토폴로지와 NVMe 디바이스 배치](#4-pcie-토폴로지와-nvme-디바이스-배치)
5. [NVMe Queue Pair(SQ/CQ) 최적 매핑](#5-nvme-queue-pairsqcq-최적-매핑)
6. [IRQ Affinity 최적화](#6-irq-affinity-최적화)
7. [NIC 자원 연동 최적화](#7-nic-자원-연동-최적화)
8. [GPU Direct Storage 고려사항](#8-gpu-direct-storage-고려사항)
9. [통합 자원 할당 전략](#9-통합-자원-할당-전략)
10. [체크리스트](#10-체크리스트)

---

## 1. 개요

### 1.1 배경
NVMe SSD의 성능이 단일 디바이스 기준 **1M+ IOPS**, 시스템 레벨에서 **100M IOPS**를 넘어서면서,
더 이상 스토리지 디바이스가 병목이 아닌 **소프트웨어 스택과 시스템 자원 할당**이 성능 병목의 핵심이 되었다.

### 1.2 핵심 목표
```
최대 IOPS/Throughput 달성 = 최소 Latency + 최대 병렬성 + 최소 Cross-NUMA 트래픽
```

### 1.3 성능 병목 계층 (위에서 아래로 심각도 순)
```
┌─────────────────────────────────────────────┐
│ 1. Cross-NUMA memory access (최대 ~40% 성능 저하) │
│ 2. IRQ & CPU affinity mismatch              │
│ 3. I/O Stack overhead (kernel vs userspace)  │
│ 4. Queue contention & lock overhead          │
│ 5. PCIe bandwidth saturation                 │
│ 6. Interrupt coalescing misconfiguration     │
└─────────────────────────────────────────────┘
```

---

## 2. I/O Stack 기술 비교

### 2.1 기술별 특성 비교표

| 항목 | Kernel I/O (Libaio) | SPDK | io_uring |
|------|---------------------|------|----------|
| **처리 위치** | Kernel space | User space | Kernel space (ring buffer) |
| **Context Switch** | 있음 (syscall) | 없음 | 최소화 (SQ/CQ ring) |
| **최대 IOPS (단일코어)** | ~200K-400K | ~1M+ | ~500K-800K |
| **Latency** | ~10-20μs | ~2-5μs | ~5-10μs |
| **CPU 사용 방식** | Interrupt-driven | Polling (busy-wait) | Hybrid (polling 지원) |
| **커널 바이패스** | 아니오 | 예 (UIO/VFIO) | 아니오 |
| **멀티테넌시** | 용이 | 어려움 | 용이 |
| **운영 복잡도** | 낮음 | 높음 | 중간 |

### 2.2 사용 시나리오별 권장 기술

```
┌──────────────────────────────────────────────────────────────┐
│ 시나리오                          │ 권장 기술               │
├──────────────────────────────────────────────────────────────┤
│ 최극단 Low-latency (금융/HFT)    │ SPDK                   │
│ 범용 고성능 스토리지 서비스       │ io_uring               │
│ 레거시 호환 필요                  │ Libaio + io_uring 마이그│
│ 컨테이너/VM 환경                  │ io_uring (SQPOLL)      │
│ 분산 스토리지 (Ceph, etc.)       │ SPDK bdev 또는 io_uring│
└──────────────────────────────────────────────────────────────┘
```

### 2.3 io_uring 주요 최적화 파라미터

```c
// 최적 설정 예시
struct io_uring_params params = {
    .flags = IORING_SETUP_SQPOLL |     // Submission Queue Polling
             IORING_SETUP_SQ_AFF |      // SQ thread CPU affinity
             IORING_SETUP_COOP_TASKRUN, // 협력적 task 실행
    .sq_thread_cpu = <NUMA-local CPU>,  // NUMA-local CPU 지정
    .sq_thread_idle = 2000,             // 2ms idle timeout
};

// Ring 크기: QD와 맞춤
io_uring_queue_init_params(QD, &ring, &params);

// Fixed buffers/files 등록 (syscall 오버헤드 제거)
io_uring_register_buffers(&ring, iovecs, nr_iovecs);
io_uring_register_files(&ring, fds, nr_fds);
```

### 2.4 SPDK 핵심 아키텍처 고려사항

```
┌─────────────────────────────────────────────────┐
│                SPDK Application                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐      │
│  │ Reactor 0│  │ Reactor 1│  │ Reactor N│      │
│  │ (Core 0) │  │ (Core 1) │  │ (Core N) │      │
│  │  ┌─────┐ │  │  ┌─────┐ │  │  ┌─────┐ │      │
│  │  │QP #0│ │  │  │QP #1│ │  │  │QP #N│ │      │
│  │  └─────┘ │  │  └─────┘ │  │  └─────┘ │      │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘      │
│       │              │              │            │
│  ┌────▼──────────────▼──────────────▼────┐      │
│  │        NVMe Controller (PCIe)          │      │
│  │     Admin Q + I/O Queue Pairs          │      │
│  └────────────────────────────────────────┘      │
└─────────────────────────────────────────────────┘

핵심 원칙:
- 1 Reactor = 1 Core = 1 Thread (run-to-completion)
- Core당 전용 Queue Pair → Lock-free I/O
- Reactor는 반드시 NUMA-local core에 pin
```

---

## 3. CPU NUMA 토폴로지 기반 자원 할당

### 3.1 NUMA의 성능 영향

```
 ┌─────────────────────────────────────────────────────┐
 │               Dual-Socket NUMA System                │
 │                                                      │
 │  NUMA Node 0                 NUMA Node 1             │
 │  ┌──────────────┐           ┌──────────────┐        │
 │  │ CPU 0-31     │◄─ UPI ──►│ CPU 32-63    │        │
 │  │ (Local Mem)  │  ~100ns  │ (Local Mem)  │        │
 │  │  DDR5 Ch 0-7 │  penalty │  DDR5 Ch 0-7 │        │
 │  └──────┬───────┘           └──────┬───────┘        │
 │         │                          │                 │
 │    PCIe Root 0              PCIe Root 1              │
 │    ├── NVMe 0               ├── NVMe 4              │
 │    ├── NVMe 1               ├── NVMe 5              │
 │    ├── NVMe 2               ├── NIC 1               │
 │    └── NIC 0                └── GPU 0               │
 └─────────────────────────────────────────────────────┘
```

### 3.2 NUMA 할당 원칙 (Golden Rules)

| 순번 | 원칙 | 설명 |
|------|------|------|
| **1** | **Device-NUMA Affinity** | NVMe/NIC/GPU가 연결된 NUMA 노드의 CPU에서 I/O 처리 |
| **2** | **Memory Locality** | I/O 버퍼는 반드시 디바이스의 NUMA 노드 로컬 메모리에 할당 |
| **3** | **Cross-NUMA 회피** | Remote NUMA 접근 시 latency 40-100ns 추가, BW 30-40% 감소 |
| **4** | **NUMA Balancing 비활성화** | 고성능 워크로드에서 automatic NUMA balancing은 비활성화 |

### 3.3 NUMA 메모리 할당 전략

```bash
# 방법 1: numactl을 이용한 프로세스 바인딩
numactl --cpunodebind=0 --membind=0 ./storage_app

# 방법 2: 프로그래밍 방식 (C/C++)
#include <numa.h>
numa_set_preferred(target_node);
void *buf = numa_alloc_onnode(size, target_node);

# 방법 3: cgroup v2를 이용한 NUMA 제어
echo 0 > /sys/fs/cgroup/storage_service/cpuset.mems
echo "0-15" > /sys/fs/cgroup/storage_service/cpuset.cpus

# NUMA balancing 비활성화 (고성능 워크로드)
echo 0 > /proc/sys/kernel/numa_balancing
```

### 3.4 Hyper-Threading 고려사항

```
물리 코어 할당 우선:
- I/O-intensive 워크로드: HT 비활성화 또는 물리코어만 사용 권장
- 이유: HT 코어 간 L1/L2 캐시 경합 → 지터 증가
- SPDK/DPDK: 반드시 물리코어(sibling의 첫 번째)에 pin

확인 방법:
  cat /sys/devices/system/cpu/cpu0/topology/thread_siblings_list
  → "0,32" → CPU 0과 32는 같은 물리 코어
```

---

## 4. PCIe 토폴로지와 NVMe 디바이스 배치

### 4.1 PCIe 계층 구조 이해

```
 CPU Socket 0
 └── PCIe Root Complex 0
     ├── PCIe Switch/Bridge (x16)
     │   ├── Slot 1: NVMe SSD (x4) ─ nvme0
     │   ├── Slot 2: NVMe SSD (x4) ─ nvme1
     │   ├── Slot 3: NVMe SSD (x4) ─ nvme2
     │   └── Slot 4: NVMe SSD (x4) ─ nvme3
     ├── Direct Slot (x16): NIC (x16) ─ eth0
     └── Direct Slot (x16): GPU (x16) ─ gpu0

 대역폭 계산:
 - PCIe Gen4 x4 = 약 8 GB/s (NVMe SSD 1개)
 - PCIe Gen4 x16 = 약 32 GB/s
 - PCIe Gen5 x4 = 약 16 GB/s
 - PCIe Gen5 x16 = 약 64 GB/s

 주의: PCIe Switch 하위 디바이스는 상위 링크 대역폭을 공유
```

### 4.2 PCIe 토폴로지 최적화 원칙

| 원칙 | 상세 |
|------|------|
| **같은 Root Complex** | NVMe와 NIC가 같은 PCIe Root Complex에 연결 → DMA 경로 최적 |
| **Switch 공유 회피** | 고대역폭 디바이스(GPU, NIC)는 PCIe Switch 공유 최소화 |
| **NUMA 일치** | PCIe Root Complex의 NUMA 노드와 처리 CPU 일치 필수 |
| **ACS 설정** | P2P DMA 사용 시 Access Control Services 설정 확인 |

### 4.3 P2P (Peer-to-Peer) DMA 경로

```
최적 경로 (같은 PCIe Switch):
  NVMe SSD ──► PCIe Switch ──► NIC/GPU
  (CPU/메모리 바이패스, 최소 latency)

차선 경로 (같은 Root Complex):
  NVMe SSD ──► Root Complex ──► NIC/GPU

최악 경로 (Cross-NUMA):
  NVMe SSD ──► Root Complex 0 ──► UPI ──► Root Complex 1 ──► NIC/GPU
  (최대 latency, 대역폭 50% 이상 감소 가능)
```

---

## 5. NVMe Queue Pair(SQ/CQ) 최적 매핑

### 5.1 NVMe Queue 아키텍처

```
┌──────────────────────────────────────────────────────┐
│                NVMe Controller                        │
│                                                       │
│  Admin Queue (AQ)     ← 관리 명령 전용 (1쌍)         │
│  ┌─────────────────┐                                  │
│  │ Admin SQ → Admin CQ                               │
│  └─────────────────┘                                  │
│                                                       │
│  I/O Queue Pairs     ← 데이터 I/O (최대 64K-1 쌍)    │
│  ┌─────────────────┐                                  │
│  │ I/O SQ #1 → I/O CQ #1  ←→ CPU Core 0            │
│  │ I/O SQ #2 → I/O CQ #2  ←→ CPU Core 1            │
│  │ I/O SQ #3 → I/O CQ #3  ←→ CPU Core 2            │
│  │     ...                                            │
│  │ I/O SQ #N → I/O CQ #N  ←→ CPU Core N            │
│  └─────────────────┘                                  │
│                                                       │
│  Queue Depth: 각 SQ/CQ는 최대 64K entries            │
└──────────────────────────────────────────────────────┘
```

### 5.2 Queue Pair 매핑 전략

#### 전략 1: 1:1 매핑 (권장 - 기본)
```
CPU Core 0 ──► QP #0 (SQ #0 + CQ #0)
CPU Core 1 ──► QP #1 (SQ #1 + CQ #1)
...
CPU Core N ──► QP #N (SQ #N + CQ #N)

장점: Lock-free, 최소 contention
단점: Queue 수 = CPU 수 (리소스 소모)
적용: SPDK, 고성능 io_uring
```

#### 전략 2: N:1 CQ 공유 (고밀도 환경)
```
CPU Core 0 ──► SQ #0 ─┐
CPU Core 1 ──► SQ #1 ─┼──► CQ #0 (공유)
CPU Core 2 ──► SQ #2 ─┘

장점: CQ 리소스 절약
단점: CQ 처리 시 동기화 필요
적용: 많은 코어, 적은 I/O depth
```

#### 전략 3: NUMA-aware 파티셔닝 (대규모 시스템)
```
NUMA Node 0 (Core 0-15):
  NVMe0 (NUMA0): QP #0-15 ←→ Core 0-15

NUMA Node 1 (Core 16-31):
  NVMe1 (NUMA1): QP #0-15 ←→ Core 16-31

원칙: 각 NUMA 노드의 코어는 해당 NUMA의 NVMe만 접근
```

### 5.3 Queue Depth 튜닝

```bash
# 현재 Queue Depth 확인
cat /sys/block/nvme0n1/queue/nr_requests

# 워크로드별 권장 Queue Depth
# - Random 4K Read:   QD 32-128 (높은 병렬성 필요)
# - Random 4K Write:  QD 16-64
# - Sequential Read:  QD 4-16 (대역폭 중심)
# - Sequential Write: QD 4-8
# - Mixed (70R/30W):  QD 32-64

# 설정
echo 128 > /sys/block/nvme0n1/queue/nr_requests
```

### 5.4 Linux Kernel NVMe Queue 설정

```bash
# NVMe 드라이버 Queue 관련 파라미터
# /etc/modprobe.d/nvme.conf

# I/O Queue 수 제한 (0 = CPU 수만큼 자동)
options nvme io_queue_depth=128    # Queue당 depth
options nvme write_queues=2        # Write 전용 queue 수
options nvme poll_queues=4         # Polling queue 수 (io_uring IOPOLL용)

# Queue 수 확인
cat /sys/block/nvme0n1/device/queue_count

# 현재 I/O scheduler 확인/변경
cat /sys/block/nvme0n1/queue/scheduler
echo "none" > /sys/block/nvme0n1/queue/scheduler  # NVMe는 "none" 권장
```

---

## 6. IRQ Affinity 최적화

### 6.1 IRQ 처리 흐름

```
NVMe CQ Completion
       │
       ▼
MSI-X Interrupt ──► CPU Core (IRQ affinity에 의해 결정)
       │
       ▼
IRQ Handler (Top-Half) ──► 빠른 ACK
       │
       ▼
SoftIRQ/Threaded IRQ (Bottom-Half) ──► I/O completion 처리
       │
       ▼
Application에 결과 전달
```

### 6.2 IRQ Affinity 매핑 원칙

```
원칙 1: NVMe IRQ는 해당 디바이스의 NUMA-local CPU에 할당
원칙 2: QP #N의 IRQ는 QP #N을 사용하는 CPU에 할당 (1:1 대응)
원칙 3: 여러 IRQ가 같은 CPU를 공유하지 않도록 분산
원칙 4: IRQ 처리 CPU와 Application CPU를 분리하거나 일치시키는 전략 선택

┌────────────────────────────────────────────────────┐
│ 전략 A: IRQ CPU = App CPU (Same-Core)              │
│   장점: 캐시 locality 최대                          │
│   단점: IRQ 처리가 App을 방해                       │
│   적용: Low-latency 워크로드                        │
│                                                     │
│ 전략 B: IRQ CPU ≠ App CPU (Dedicated IRQ Core)     │
│   장점: App에 안정적 CPU 시간 보장                  │
│   단점: 추가 코어 소모, 캐시 miss 증가              │
│   적용: Throughput 중심 워크로드                     │
└────────────────────────────────────────────────────┘
```

### 6.3 IRQ Affinity 설정 방법

```bash
# 방법 1: 수동 설정
# NVMe IRQ 번호 확인
cat /proc/interrupts | grep nvme

# IRQ를 특정 CPU에 바인딩
echo <cpu_mask> > /proc/irq/<irq_number>/smp_affinity

# 예: IRQ 35를 CPU 0에 바인딩 (비트마스크)
echo 1 > /proc/irq/35/smp_affinity       # CPU 0
echo 2 > /proc/irq/36/smp_affinity       # CPU 1
echo 4 > /proc/irq/37/smp_affinity       # CPU 2

# 또는 CPU 리스트 형식
echo 0 > /proc/irq/35/smp_affinity_list  # CPU 0
echo 1 > /proc/irq/36/smp_affinity_list  # CPU 1

# 방법 2: irqbalance 서비스 비활성화 + 수동 관리
systemctl stop irqbalance
systemctl disable irqbalance

# 방법 3: irqbalance hint 사용 (부분 제어)
# /etc/default/irqbalance
IRQBALANCE_BANNED_CPULIST=0-3    # CPU 0-3은 irqbalance 제외
```

### 6.4 MSI-X Interrupt 최적화

```bash
# MSI-X 벡터 수 확인
lspci -vvv -s <NVMe_BDF> | grep "MSI-X"

# MSI-X 벡터 수 ≥ I/O Queue 수 + 1 (Admin Queue)
# 부족 시: Queue 수 줄이거나, Queue가 IRQ 공유

# Interrupt Coalescing 설정 (NVMe 컨트롤러 지원 시)
# - Aggregation Time: 완료 이벤트를 모아서 한 번에 인터럽트
# - Aggregation Threshold: N개 완료 시 인터럽트 발생
# nvme set-feature /dev/nvme0 -f 0x08 -v <value>
```

---

## 7. NIC 자원 연동 최적화

### 7.1 Storage + Network 연동 토폴로지

```
최적 구성:
┌─────────────────────────────────────┐
│         NUMA Node 0                  │
│  CPU: Core 0-15                      │
│  Memory: 256GB DDR5                  │
│  ┌─────────┐  ┌─────────┐          │
│  │ NVMe x4 │  │ NIC 100G│          │
│  │ (local)  │  │ (local) │          │
│  └─────────┘  └─────────┘          │
│       │              │               │
│  I/O Path: NVMe → Local Mem → NIC   │
│  (모든 경로가 NUMA 0 내부)           │
└─────────────────────────────────────┘

비효율 구성 (피해야 함):
┌──────────────┐    UPI    ┌──────────────┐
│  NUMA Node 0 │◄────────►│  NUMA Node 1 │
│  NVMe (local)│           │  NIC (local) │
│              │           │              │
│  I/O Path: NVMe(N0) → UPI → Mem(N1) → NIC(N1)
│  또는:      NVMe(N0) → Mem(N0) → UPI → NIC(N1)
│  (Cross-NUMA → 성능 30-40% 저하)
└──────────────┘           └──────────────┘
```

### 7.2 NIC Queue와 NVMe Queue 정렬

```bash
# NIC RSS(Receive Side Scaling) 큐를 NUMA-local CPU에 고정
ethtool -L eth0 combined 16                    # 큐 수 설정
ethtool -X eth0 equal 16                       # RSS 해시 분배

# NIC IRQ affinity를 NVMe와 같은 NUMA 노드 CPU에 설정
# → 네트워크 I/O 요청 수신 CPU = 스토리지 I/O 처리 CPU

# XPS (Transmit Packet Steering) 설정
echo <cpu_mask> > /sys/class/net/eth0/queues/tx-0/xps_cpus

# RFS (Receive Flow Steering) 활성화
echo 32768 > /proc/sys/net/core/rps_sock_flow_entries
echo 4096 > /sys/class/net/eth0/queues/rx-0/rps_flow_cnt
```

### 7.3 NVMe-oF (NVMe over Fabrics) 최적화

```
서버 (Target) 측:
- SPDK NVMe-oF Target: Reactor core = NUMA-local to NVMe + NIC
- 또는 Kernel target: IRQ affinity 일치 (NVMe IRQ ↔ NIC IRQ)

클라이언트 (Initiator) 측:
- io_uring + NVMe-oF: multipath + NUMA-aware queue 설정
- 연결당 Queue Pair 수 = CPU 수 (best case)
```

---

## 8. GPU Direct Storage 고려사항

### 8.1 GPUDirect Storage (GDS) 아키텍처

```
기존 경로 (Bounce Buffer):
  NVMe → PCIe → CPU Memory (bounce) → PCIe → GPU Memory
  (2회 PCIe 전송, CPU 개입)

GDS 경로:
  NVMe → PCIe → GPU Memory (Direct DMA)
  (1회 PCIe 전송, CPU 바이패스)

성능 차이: GDS는 대역폭 2x 향상, CPU 부하 제거
```

### 8.2 GDS 최적 토폴로지 배치

```
최적: NVMe와 GPU가 같은 PCIe Switch 하위
┌─────────────────────────────┐
│ PCIe Switch                  │
│  ├── NVMe SSD (x4)          │
│  └── GPU (x16)              │
│  → P2P DMA: Switch 내부     │
└─────────────────────────────┘

차선: 같은 NUMA / 같은 Root Complex
┌─────────────────────────────┐
│ Root Complex (NUMA 0)        │
│  ├── NVMe SSD               │
│  └── GPU                    │
│  → P2P DMA: Root Complex 경유│
└─────────────────────────────┘

최악: Cross-NUMA (GDS 효과 상당 부분 상쇄)
```

### 8.3 GDS 설정 가이드

```bash
# GDS 지원 확인
/usr/local/cuda/gds/tools/gdscheck -p

# nvidia-fs 모듈 로드
modprobe nvidia-fs

# GDS 가능한 파일시스템 마운트 (ext4, XFS)
mount -o data=ordered /dev/nvme0n1p1 /mnt/gds

# cuFile API로 Direct I/O
# cuFileDriverOpen() → cuFileBufRegister() → cuFileRead/Write()

# 대역폭 테스트
/usr/local/cuda/gds/tools/gdsio -f /mnt/gds/testfile -d 0 -w 4 -s 1G -x 0
```

---

## 9. 통합 자원 할당 전략

### 9.1 자원 할당 의사결정 흐름

```
Step 1: 하드웨어 토폴로지 파악
  └─► NUMA 구조, PCIe 배치, 디바이스 위치 확인

Step 2: 워크로드 특성 분석
  ├── Random vs Sequential
  ├── Read-heavy vs Write-heavy vs Mixed
  ├── Latency-sensitive vs Throughput-oriented
  └── 단일 vs 멀티 디바이스

Step 3: I/O Stack 선택
  ├── SPDK: 최저 latency, 전용 코어 가능할 때
  ├── io_uring: 범용, 커널 에코시스템 필요할 때
  └── Libaio: 레거시 호환

Step 4: CPU/Core 할당
  ├── NUMA-local core 선택
  ├── 물리코어 우선 (HT sibling 회피)
  ├── I/O core와 App core 분리 여부 결정
  └── OS/Management용 core 예약 (Core 0 등)

Step 5: Queue Pair 매핑
  ├── 1 Core : 1 QP 기본
  ├── NUMA 경계 넘지 않음
  └── Queue Depth 워크로드 맞춤 조정

Step 6: IRQ Affinity 설정
  ├── irqbalance 비활성화
  ├── QP-IRQ-Core 1:1:1 매핑
  └── NIC IRQ도 같은 NUMA에 정렬

Step 7: 메모리/버퍼 할당
  ├── NUMA-local 메모리 강제
  ├── Huge Pages 활성화
  └── I/O 버퍼 pre-allocate + pin

Step 8: 검증 및 모니터링
  ├── fio / SPDK perf 벤치마크
  ├── perf stat으로 cross-NUMA 접근 확인
  └── 지속적 모니터링 (IOPS, latency P99)
```

### 9.2 서버 자원 파티셔닝 예시 (2-Socket, 8 NVMe)

```
┌─────────────────────────────────────────────────────────────┐
│                    2-Socket Server Example                    │
│                                                              │
│  Socket 0 / NUMA 0                Socket 1 / NUMA 1         │
│  ┌─────────────────────┐         ┌─────────────────────┐    │
│  │ Core 0: OS/Mgmt     │         │ Core 32: OS/Mgmt    │    │
│  │ Core 1-4: NVMe0 I/O │         │ Core 33-36: NVMe4 IO│    │
│  │ Core 5-8: NVMe1 I/O │         │ Core 37-40: NVMe5 IO│    │
│  │ Core 9-12: NVMe2 I/O│         │ Core 41-44: NVMe6 IO│    │
│  │ Core 13-16: NVMe3 IO│         │ Core 45-48: NVMe7 IO│    │
│  │ Core 17-20: NIC0 RX │         │ Core 49-52: NIC1 RX │    │
│  │ Core 21-24: App     │         │ Core 53-56: App     │    │
│  │ Core 25-31: Reserve │         │ Core 57-63: Reserve │    │
│  │                      │         │                      │    │
│  │ Memory: 256GB (local)│         │ Memory: 256GB (local)│    │
│  │ NVMe: 0,1,2,3       │         │ NVMe: 4,5,6,7       │    │
│  │ NIC: eth0 (100G)    │         │ NIC: eth1 (100G)    │    │
│  └─────────────────────┘         └─────────────────────┘    │
│                                                              │
│  Huge Pages: 1GB x 128 per NUMA (총 256GB)                 │
│  I/O Scheduler: none (NVMe)                                 │
│  IRQbalance: disabled                                        │
│  NUMA Balancing: disabled                                    │
└─────────────────────────────────────────────────────────────┘
```

### 9.3 Kernel 파라미터 종합 튜닝

```bash
# /etc/sysctl.d/99-nvme-perf.conf

# NUMA balancing 비활성화
kernel.numa_balancing = 0

# 메모리 관련
vm.nr_hugepages = 8192          # 2MB HugePages (또는 1GB 페이지 사용)
vm.swappiness = 1               # 스왑 최소화
vm.dirty_ratio = 40
vm.dirty_background_ratio = 10
vm.zone_reclaim_mode = 0        # Cross-NUMA reclaim 허용 (OOM 방지)

# 네트워크 (NVMe-oF 사용 시)
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.netdev_max_backlog = 65536
net.core.busy_poll = 50
net.core.busy_read = 50

# Kernel boot parameters (GRUB)
# /etc/default/grub
# GRUB_CMDLINE_LINUX="default_hugepagesz=1G hugepagesz=1G hugepages=128
#   isolcpus=1-24,33-56 nohz_full=1-24,33-56 rcu_nocbs=1-24,33-56
#   intel_iommu=on iommu=pt"
```

---

## 10. 체크리스트

### 배포 전 검증 체크리스트

```
□ NUMA 토폴로지
  □ 모든 NVMe 디바이스의 NUMA 노드 확인 완료
  □ I/O 처리 프로세스가 NUMA-local CPU에 바인딩됨
  □ I/O 버퍼가 NUMA-local 메모리에 할당됨
  □ automatic NUMA balancing 비활성화 확인

□ PCIe 토폴로지
  □ NVMe-NIC 간 PCIe 경로 확인 (같은 NUMA 권장)
  □ PCIe 대역폭 병목 없음 확인
  □ GPU 사용 시 P2P DMA 경로 확인

□ Queue Pair 매핑
  □ I/O Queue 수가 I/O 처리 CPU 수와 일치
  □ Core:QP 1:1 매핑 설정 완료
  □ Queue Depth가 워크로드에 적합
  □ I/O Scheduler = "none" 설정

□ IRQ Affinity
  □ irqbalance 비활성화 또는 적절히 설정
  □ NVMe IRQ가 NUMA-local CPU에 할당
  □ NIC IRQ도 NUMA-local CPU에 할당
  □ IRQ-QP-Core 매핑 일관성 확인

□ NIC 설정
  □ RSS 큐가 올바른 CPU에 매핑
  □ XPS/RFS 설정 완료
  □ Ring buffer 크기 적절히 설정

□ 시스템 설정
  □ HugePages 설정 완료
  □ Kernel boot 파라미터 적용
  □ sysctl 파라미터 적용
  □ CPU frequency governor = "performance"
  □ C-State 비활성화 (초저지연 요구 시)

□ 벤치마크 검증
  □ fio로 기대 IOPS/BW/Latency 달성 확인
  □ perf stat으로 cross-NUMA 접근 비율 확인
  □ P99/P999 latency 목표치 달성 확인
```

---

## 참고 자료
- Linux NVMe Driver Documentation: https://www.kernel.org/doc/html/latest/nvme/
- SPDK Documentation: https://spdk.io/doc/
- io_uring man pages & liburing: https://github.com/axboe/liburing
- NVIDIA GPUDirect Storage: https://docs.nvidia.com/gpudirect-storage/
- Intel DPDK/SPDK Performance Tuning Guide
- PCIe Specification (PCI-SIG)

# CPU Data Access: Memory(DDR5) vs Storage(NVMe SSD) 비교 및 융합 기술

## 목차
1. [CPU 관점의 데이터 접근 아키텍처](#1-cpu-관점의-데이터-접근-아키텍처)
2. [DDR5 Memory vs NVMe SSD 정량 비교](#2-ddr5-memory-vs-nvme-ssd-정량-비교)
3. [접근 경로 상세 분석](#3-접근-경로-상세-분석)
4. [Memory-Storage Gap 문제](#4-memory-storage-gap-문제)
5. [Storage를 Memory처럼: 융합 기술 총정리](#5-storage를-memory처럼-융합-기술-총정리)
6. [CXL (Compute Express Link)](#6-cxl-compute-express-link)
7. [DAX (Direct Access) & Persistent Memory](#7-dax-direct-access--persistent-memory)
8. [NVMe CMB/PMR & P2P](#8-nvme-cmbpmr--p2p)
9. [mmap과 XIP](#9-mmap과-xip)
10. [SW 최적화: 극한의 Storage 접근](#10-sw-최적화-극한의-storage-접근)
11. [기술별 비교 및 선택 가이드](#11-기술별-비교-및-선택-가이드)

---

## 1. CPU 관점의 데이터 접근 아키텍처

### 1.1 전통적 메모리 계층 구조

```
               Access        Typical
               Latency       Bandwidth        Capacity     Addressing
  ┌──────────┐
  │ CPU Reg  │  ~0.3ns       N/A              KB           Register
  ├──────────┤
  │ L1 Cache │  ~1ns         ~1 TB/s          32-64KB      Byte (cache line)
  ├──────────┤
  │ L2 Cache │  ~3-5ns       ~500 GB/s        256KB-2MB    Byte (cache line)
  ├──────────┤
  │ L3 Cache │  ~10-20ns     ~200-400 GB/s    16-128MB     Byte (cache line)
  ├──────────┤
  │ DDR5 Mem │  ~60-100ns    ~50-80 GB/s      64GB-2TB     Byte (64B burst)
  ├──────────┤                                              ← Memory-Storage Gap
  │ NVMe SSD │  ~2,000-      ~7-14 GB/s       1-32TB       Block (512B/4KB)
  │          │  10,000ns
  ├──────────┤
  │ HDD      │  ~5,000,000ns ~0.2 GB/s        1-20TB       Block (512B)
  └──────────┘

  Gap: DDR5 → NVMe = ~20-100x latency, ~5-10x bandwidth 차이
```

### 1.2 CPU가 데이터를 접근하는 두 가지 근본적 방식

```
┌──────────────────────────────────────────────────────────────────┐
│                                                                   │
│  방식 1: Load/Store (Memory Access)                              │
│  ─────────────────────────────────                               │
│  CPU ──(load/store 명령)──► MMU ──► Cache ──► Memory Controller  │
│                                                    │              │
│                                                DDR5 DIMM          │
│                                                                   │
│  특징:                                                            │
│  - CPU ISA의 일부 (mov, ld, st 명령)                             │
│  - Byte-addressable (바이트 단위 접근)                           │
│  - 하드웨어가 자동으로 캐시 관리                                 │
│  - Latency: ~100ns (cache miss 기준)                             │
│  - CPU가 직접 Physical Address로 접근                            │
│  - 동기적 (명령 완료까지 CPU 대기 또는 파이프라인)               │
│                                                                   │
├──────────────────────────────────────────────────────────────────┤
│                                                                   │
│  방식 2: I/O (Storage Access)                                    │
│  ─────────────────────────                                       │
│  App ──(syscall)──► Kernel ──► Block Layer ──► NVMe Driver       │
│                                                    │              │
│                                  PCIe ──► NVMe Controller        │
│                                                    │              │
│                                               NAND Flash          │
│                                                                   │
│  특징:                                                            │
│  - OS I/O Stack 경유 (syscall → kernel → driver)                 │
│  - Block-addressable (512B/4KB 블록 단위)                        │
│  - 소프트웨어가 명시적으로 I/O 요청/완료 관리                    │
│  - Latency: ~2,000-10,000ns (스택 포함)                          │
│  - DMA로 데이터 전송 (CPU가 직접 접근하지 않음)                  │
│  - 비동기적 (요청 후 완료 대기/폴링)                             │
│                                                                   │
└──────────────────────────────────────────────────────────────────┘
```

---

## 2. DDR5 Memory vs NVMe SSD 정량 비교

### 2.1 핵심 지표 비교표

| 항목 | DDR5 Memory | NVMe SSD (Gen5) | 차이 배수 |
|------|-------------|------------------|-----------|
| **Latency (Random Read)** | 60-100ns | 2,000-10,000ns | **20-100x** |
| **Bandwidth (Sequential)** | 50-80 GB/s (per ch x8) | 12-14 GB/s (x4) | **4-6x** |
| **IOPS (4K Random)** | N/A (byte-access) | 1.5-2M IOPS | 개념 다름 |
| **접근 단위** | 64 Bytes (cache line) | 512B / 4KB (block) | **8-64x** |
| **Addressing** | Byte-addressable | Block-addressable | 근본 차이 |
| **인터페이스** | DDR5 Bus (288-pin) | PCIe Gen5 x4 | 다름 |
| **프로토콜** | DDR5 JEDEC | NVMe (PCIe TLP) | 다름 |
| **CPU 접근 방식** | load/store 명령 | Syscall → DMA | 근본 차이 |
| **캐시 통합** | L1/L2/L3 자동 캐싱 | 캐시 불가 (DMA) | 근본 차이 |
| **주소 공간** | Physical Memory Map | PCIe BAR / BLK | 다름 |
| **영속성** | Volatile (전원 off → 소멸) | Non-volatile (영구) | 반대 |
| **용량 단가** | ~$3-5/GB | ~$0.05-0.1/GB | **30-50x** |
| **최대 용량/서버** | 2-6 TB | 100+ TB | 다름 |
| **Write 내구성** | 무제한 | TBW 제한 (NAND) | 차이 |
| **전력** | ~5-8W/DIMM | ~5-25W/SSD | 유사 |
| **ECC** | On-die ECC | LDPC/ECC 내장 | 둘 다 |

### 2.2 Latency 상세 분해

```
── DDR5 Memory Read (CPU load 명령) ──

CPU core → L1 TLB lookup           :  ~1ns
L1 Cache lookup (miss)             :  ~1ns
L2 Cache lookup (miss)             :  ~3-5ns
L3 Cache lookup (miss)             :  ~10-20ns
Memory Controller queue            :  ~5-10ns
DDR5 Channel: tCL+tRCD+tRP        :  ~30-40ns  ← 실제 DRAM latency
Data return via memory bus         :  ~5-10ns
─────────────────────────────────────
Total (L3 miss, local NUMA):       ~60-100ns
Total (remote NUMA):               ~120-200ns


── NVMe SSD Read (단일 4KB I/O) ──

[Software Stack]
Application syscall overhead       :  ~100-500ns
Kernel block layer processing      :  ~200-500ns
NVMe driver: command build         :  ~100-300ns
Doorbell write (MMIO to SSD)       :  ~100-200ns

[Hardware: PCIe + NVMe Controller]
PCIe TLP 전송 (command)            :  ~100-200ns
NVMe Controller FW processing      :  ~500-1,000ns
NAND Flash read (page read)        :  ~5,000-50,000ns  ← 실제 NAND latency
                                      (SLC: ~5us, TLC: ~25us, QLC: ~50us)
DMA: SSD → Host Memory             :  ~200-500ns
PCIe TLP 전송 (completion)         :  ~100-200ns

[Completion Path]
MSI-X Interrupt → CPU              :  ~100-500ns
IRQ Handler + SoftIRQ              :  ~200-500ns
App notification                   :  ~100-300ns
─────────────────────────────────────
Total (io_uring, optimistic):       ~2,000-5,000ns (2-5μs)
Total (libaio, typical):           ~5,000-10,000ns (5-10μs)
Total (sync read, worst):          ~10,000-80,000ns (10-80μs)


── Latency Breakdown 비율 (io_uring, 4KB Read) ──

┌─────────────────────────────────────────────────────────┐
│ SW Stack     │████████░░░░░░░░░░░░░│ ~15-25%           │
│ PCIe + NVMe  │██░░░░░░░░░░░░░░░░░░░│ ~5-10%            │
│ NAND Flash   │████████████████░░░░░│ ~50-70%  ← 지배적  │
│ Completion   │████░░░░░░░░░░░░░░░░░│ ~10-15%           │
└─────────────────────────────────────────────────────────┘

핵심 인사이트:
- NAND Flash read 자체가 전체 latency의 50-70% 차지
- SW Stack overhead가 15-25% → 이것을 줄이는 것이 io_uring/SPDK
- Memory와 Storage gap의 주 원인 = NAND 물리적 한계
```

### 2.3 대역폭 비교

```
── Bandwidth 비교 (단일 채널 기준) ──

DDR5-5600 (1 Channel):
  이론: 5600 MT/s × 8 bytes = 44.8 GB/s
  실효: ~35-40 GB/s

DDR5 (8 Channel, 1 Socket):
  이론: ~358 GB/s
  실효: ~280-320 GB/s

NVMe Gen4 x4:
  이론: ~8 GB/s
  실효: ~6-7 GB/s

NVMe Gen5 x4:
  이론: ~16 GB/s
  실효: ~12-14 GB/s

비교:
  DDR5 1ch vs NVMe Gen5 = ~3x
  DDR5 8ch vs NVMe Gen5 = ~22x
  DDR5 8ch vs NVMe Gen5 x4 (4개 SSD) = ~5-6x
```

---

## 3. 접근 경로 상세 분석

### 3.1 DDR5 Memory 접근 경로

```
┌─────────────────────────────────────────────────────────────┐
│ CPU Core                                                     │
│  │                                                           │
│  │ mov rax, [address]    ← CPU ISA: load 명령               │
│  ▼                                                           │
│ ┌─────────┐                                                  │
│ │   MMU   │─── Virtual → Physical 주소 변환 (TLB)           │
│ └────┬────┘                                                  │
│      ▼                                                       │
│ ┌─────────┐  Hit                                             │
│ │L1 Cache │──────► Data Return (~1ns)                        │
│ └────┬────┘                                                  │
│      │ Miss                                                  │
│ ┌─────────┐  Hit                                             │
│ │L2 Cache │──────► Data Return (~5ns)                        │
│ └────┬────┘                                                  │
│      │ Miss                                                  │
│ ┌─────────┐  Hit                                             │
│ │L3 Cache │──────► Data Return (~15ns)                       │
│ └────┬────┘                                                  │
│      │ Miss                                                  │
│ ┌───────────────┐                                            │
│ │ Memory        │                                            │
│ │ Controller    │──► DDR5 Channel ──► DIMM ──► DRAM Cell    │
│ │ (IMC on CPU)  │                                            │
│ └───────────────┘          Data Return (~60-100ns)           │
│                                                              │
│ 특성:                                                        │
│ - 64 Byte cache line 단위 fetch (spatial locality 활용)     │
│ - Prefetcher가 자동으로 다음 데이터 미리 로드               │
│ - Write-back/Write-through 캐시 정책                         │
│ - Coherency protocol (MESI/MOESI)로 멀티코어 일관성         │
│ - NUMA: 로컬 vs 리모트 메모리 latency 차이                  │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 NVMe SSD 접근 경로

```
┌─────────────────────────────────────────────────────────────┐
│ Application                                                  │
│  │                                                           │
│  │ read(fd, buf, 4096)  또는  io_uring_submit()             │
│  ▼                                                           │
│ ┌──────────────┐                                             │
│ │ System Call  │ ← User → Kernel 전환 (~100-500ns)          │
│ └──────┬───────┘                                             │
│        ▼                                                     │
│ ┌──────────────┐                                             │
│ │ VFS Layer    │ ← 파일시스템 lookup, page cache 확인        │
│ └──────┬───────┘                                             │
│        ▼                                                     │
│ ┌──────────────┐                                             │
│ │ Block Layer  │ ← I/O Scheduler, merge, plug/unplug        │
│ │ (blk-mq)    │   Request queue → hardware dispatch queue   │
│ └──────┬───────┘                                             │
│        ▼                                                     │
│ ┌──────────────┐                                             │
│ │ NVMe Driver  │ ← NVMe Command (SQE) 작성                  │
│ │              │   SQ Tail Doorbell MMIO write               │
│ └──────┬───────┘                                             │
│        ▼                                                     │
│ ┌──────────────────────────────── PCIe Bus ──────────────┐   │
│ │                                                         │   │
│ │  ┌──────────────────┐                                   │   │
│ │  │ NVMe Controller  │ ← FTL, NAND 관리, Wear Leveling  │   │
│ │  │ (SSD 내장 CPU)   │   Read: page read from NAND      │   │
│ │  └────────┬─────────┘                                   │   │
│ │           ▼                                             │   │
│ │  ┌──────────────────┐                                   │   │
│ │  │ NAND Flash Array │ ← 실제 데이터 저장소              │   │
│ │  │ (SLC/TLC/QLC)    │   Page Read: 5-50μs              │   │
│ │  └──────────────────┘                                   │   │
│ │                                                         │   │
│ │  DMA Engine: SSD DRAM → Host Memory (PCIe TLP)         │   │
│ │  Completion: CQE 작성 + MSI-X Interrupt                │   │
│ └─────────────────────────────────────────────────────────┘   │
│        ▼                                                     │
│ ┌──────────────┐                                             │
│ │ IRQ Handler  │ ← CQ Processing, bio completion            │
│ └──────┬───────┘                                             │
│        ▼                                                     │
│ Application: 데이터 사용 가능                                │
└─────────────────────────────────────────────────────────────┘
```

### 3.3 핵심 차이 요약

| 관점 | Memory (DDR5) | Storage (NVMe) |
|------|--------------|----------------|
| **CPU 명령** | `mov`, `ld`, `st` (ISA) | `syscall` → driver → DMA |
| **주소 체계** | Virtual → Physical (MMU) | File offset → LBA → PBA (FTL) |
| **전송 단위** | 64B cache line | 512B/4KB block |
| **전송 방식** | CPU가 직접 fetch | DMA (SSD가 host mem에 write) |
| **캐시 계층** | L1→L2→L3 자동 | Page Cache (SW, 선택적) |
| **일관성** | HW coherency (MESI) | SW 관리 (fsync, O_DIRECT) |
| **인터럽트** | 불필요 | MSI-X (또는 polling) |
| **CPU 오버헤드** | 매우 낮음 (~수 ns) | 높음 (스택 ~1-2μs) |
| **병렬성 모델** | Superscalar + OoO | Queue Pair + async I/O |

---

## 4. Memory-Storage Gap 문제

### 4.1 The Latency Gap

```
Latency (log scale):

  1ns     10ns    100ns    1μs     10μs    100μs    1ms
  │        │        │       │        │        │       │
  ├────────┼────────┼───────┼────────┼────────┼───────┤
  │L1      │L3      │DDR5   │        │NVMe    │       │HDD
  │(1ns)   │(15ns)  │(80ns) │        │(3-10μs)│       │(5ms)
  │        │        │       │        │        │       │
  │◄─ CPU Cache ──►│◄ Mem ►│        │◄ SSD ─►│       │
                     │       │        │
                     └───────┘────────┘
                     Memory-Storage Gap
                     = 20-100x latency 차이
                     = "The Storage Wall"

문제: 이 Gap 때문에...
  - CPU가 Storage I/O를 기다리는 동안 idle
  - 대량의 메모리를 캐시로 사용해야 함 (비용↑)
  - Application 설계가 I/O-aware해야 함 (복잡도↑)
```

### 4.2 Gap을 줄이려는 시도들의 역사

```
시간순 기술 발전:

1. HDD → SSD (SATA)      : 1000x latency 개선 (ms → μs)
2. SATA → NVMe           : 5-10x latency 개선 (AHCI overhead 제거)
3. libaio → io_uring     : 30-50% SW overhead 감소
4. Kernel → SPDK         : 50-70% SW overhead 감소 (user space)
5. Interrupt → Polling   : 50% completion latency 감소
6. NAND → 3D NAND        : 용량↑, latency 유사
7. TLC → SLC caching     : Write latency 개선
8. PCIe Gen3 → Gen5      : BW 4x 향상

그러나... NAND Flash의 물리적 한계 (~5-50μs)가 존재
→ 이를 근본적으로 해결하려면 새로운 접근이 필요
```

---

## 5. Storage를 Memory처럼: 융합 기술 총정리

### 5.1 기술 지도

```
┌───────────────────────────────────────────────────────────────────┐
│              Storage를 Memory처럼 접근하는 기술 스펙트럼          │
│                                                                   │
│  ◄─── Memory에 가까움 ─────────────── Storage에 가까움 ───►      │
│                                                                   │
│  ┌─────────┐ ┌──────────┐ ┌─────────┐ ┌────────┐ ┌───────────┐ │
│  │  CXL    │ │ PMEM/DAX │ │ NVMe    │ │ mmap   │ │ io_uring  │ │
│  │ Memory  │ │ (Optane) │ │ CMB/PMR │ │ + XIP  │ │ + SPDK    │ │
│  │         │ │          │ │         │ │        │ │           │ │
│  │Load/    │ │Load/     │ │MMIO     │ │Page    │ │Block I/O  │ │
│  │Store    │ │Store     │ │Access   │ │Fault   │ │(async)    │ │
│  │         │ │          │ │         │ │driven  │ │           │ │
│  │~150-    │ │~200-     │ │~500-    │ │~2-10μs │ │~2-5μs    │ │
│  │300ns    │ │400ns     │ │1000ns   │ │(+ I/O) │ │           │ │
│  └─────────┘ └──────────┘ └─────────┘ └────────┘ └───────────┘ │
│                                                                   │
│  HW 기반 ◄──────────────────────────────────────► SW 기반        │
│  Byte-addressable ◄──────────────────► Block-addressable          │
│  CPU load/store ◄────────────────────► DMA + async I/O            │
└───────────────────────────────────────────────────────────────────┘
```

### 5.2 기술별 핵심 메커니즘

| 기술 | 접근 방식 | Latency | Byte-addr? | 영속성 | 성숙도 |
|------|-----------|---------|------------|--------|--------|
| **CXL Type 3 Memory** | load/store via CXL | 150-300ns | Yes | 선택적 | 초기 (Gen3 진행) |
| **Intel Optane PMEM** | load/store via DDR | 200-400ns | Yes | Yes | 단종(교훈 有) |
| **NVMe CMB** | MMIO (PCIe BAR) | 500-1000ns | Yes (제한적) | No | 제한적 지원 |
| **NVMe PMR** | MMIO (PCIe BAR) | 500-1000ns | Yes (제한적) | Yes | 제한적 지원 |
| **DAX (fsdax)** | load/store (mmap) | 미디어 의존 | Yes | Yes | 성숙 |
| **mmap + page fault** | page fault → I/O | 2-10μs | Yes (virtual) | Yes | 성숙 |
| **SPDK** | user-space polling | 2-3μs | No (block) | Yes | 성숙 |
| **io_uring** | async kernel I/O | 3-5μs | No (block) | Yes | 성숙 |

---

## 6. CXL (Compute Express Link)

### 6.1 CXL이 해결하는 문제

```
기존 문제:
  CPU ←(DDR5)→ Memory     : 빠르지만 용량 제한 (수 TB)
  CPU ←(PCIe)→ NVMe SSD   : 느리지만 대용량 (수백 TB)
  → Memory와 Storage 사이에 "중간 계층"이 없음

CXL 해결:
  CPU ←(DDR5)→ Local DRAM           : ~80ns, 수 TB
  CPU ←(CXL)──→ CXL Memory          : ~150-300ns, 수십 TB
  CPU ←(PCIe)→ NVMe SSD            : ~2,000-10,000ns, 수백 TB

  → CXL이 Memory-Storage Gap의 중간을 채움
```

### 6.2 CXL 프로토콜 유형

```
┌───────────────────────────────────────────────────────────────┐
│                    CXL Protocol Types                          │
│                                                                │
│  CXL.io   │ PCIe와 동일. 디바이스 발견, 설정, DMA            │
│           │ NVMe, NIC 등 기존 PCIe 디바이스 호환              │
│           │                                                    │
│  CXL.cache│ 디바이스가 호스트 메모리를 캐시 (GPU, SmartNIC)   │
│           │ 디바이스 → 호스트 방향의 캐시 coherency            │
│           │                                                    │
│  CXL.mem  │ 호스트가 디바이스 메모리를 load/store로 접근  ★   │
│           │ 호스트 → 디바이스 방향의 메모리 확장               │
│           │ HDM (Host-managed Device Memory)                   │
│           │ CPU의 memory map에 직접 매핑 → byte-addressable   │
└───────────────────────────────────────────────────────────────┘

Storage를 Memory처럼: CXL.mem이 핵심
  - CPU load/store 명령으로 디바이스 메모리 직접 접근
  - OS가 physical address space에 CXL 메모리 매핑
  - 기존 DDR DIMM과 동일한 방식으로 접근 가능
```

### 6.3 CXL Type 3 Memory Device

```
┌────────────────────────────────────────────────────────────┐
│                    Server System                            │
│                                                             │
│  CPU Socket                                                 │
│  ├── DDR5 DIMM Slots (Local DRAM, ~80ns)                   │
│  └── CXL Port (PCIe Gen5 physical layer)                   │
│       │                                                     │
│       └──► CXL Memory Expander (Type 3)                    │
│            ┌────────────────────────────┐                   │
│            │ CXL Controller             │                   │
│            │  - CXL.io + CXL.mem       │                   │
│            │  - HDM Decoder            │                   │
│            │  - Optional: Media Ctrl   │                   │
│            ├────────────────────────────┤                   │
│            │ Memory Media              │                   │
│            │  - DRAM (volatile)        │ → ~150ns          │
│            │  - NAND (persistent)      │ → ~2-5μs          │
│            │  - 또는 혼합              │                   │
│            └────────────────────────────┘                   │
│                                                             │
│  CPU 관점: CXL 메모리 = 추가 NUMA 노드                     │
│  접근: mov rax, [cxl_address] → 일반 load/store와 동일     │
│  Latency: DDR5 대비 ~1.5-3x (PCIe hop 추가)               │
│  BW: DDR5 1ch 대비 ~0.5-0.8x                              │
└────────────────────────────────────────────────────────────┘
```

### 6.4 CXL Memory의 Linux 지원

```bash
# CXL 디바이스 확인
ls /sys/bus/cxl/devices/

# CXL region을 DAX 디바이스로 설정
cxl create-region -m -d decoder0.0 -w 1 mem0

# NUMA 노드로 online
daxctl reconfigure-device --mode=system-ram dax0.0

# 확인: 새로운 NUMA 노드 생성됨
numactl --hardware
# node 2: cpus: (none)    ← CPU는 없고 메모리만 있는 NUMA 노드
# node 2 size: 128 GB

# 특정 프로세스를 CXL 메모리에 바인딩
numactl --membind=2 ./application

# 또는 DAX 파일시스템으로 사용
daxctl reconfigure-device --mode=devdax dax0.0
mount -t xfs -o dax=always /dev/dax0.0 /mnt/cxl

# Tiered memory: 자동으로 hot/cold 데이터를 DDR↔CXL 이동
echo 1 > /sys/kernel/mm/numa/demotion_enabled
```

---

## 7. DAX (Direct Access) & Persistent Memory

### 7.1 DAX의 핵심 아이디어

```
기존 Storage I/O:
  App → syscall → VFS → Block Layer → Driver → DMA → Device
                  ↓
  Page Cache (DRAM에 복사) → App은 Page Cache의 복사본을 읽음

DAX (Direct Access):
  App → mmap() → 직접 미디어 접근 (Page Cache 바이패스)

  - I/O Stack 전체를 건너뛰고
  - CPU load/store로 직접 persistent media에 접근
  - 데이터 복사 없음 (Zero-copy)
  - Latency = 미디어 latency + MMU overhead만
```

### 7.2 DAX 아키텍처

```
┌──────────────────────────────────────────────────────────┐
│ Application                                               │
│  │                                                        │
│  │ fd = open("/mnt/pmem/data", O_RDWR);                  │
│  │ ptr = mmap(NULL, size, PROT_RW, MAP_SHARED, fd, 0);   │
│  │                                                        │
│  │ // 이후 ptr을 통해 직접 읽기/쓰기                     │
│  │ value = *(ptr + offset);    // Direct load (no I/O!)  │
│  │ *(ptr + offset) = new_val;  // Direct store           │
│  │ // 영속성 보장                                         │
│  │ _mm_clwb(ptr + offset);     // Cache line write back  │
│  │ _mm_sfence();               // Store fence            │
│  ▼                                                        │
│ ┌──────────┐                                              │
│ │   MMU    │ Virtual → Physical 변환                      │
│ └────┬─────┘                                              │
│      │   ✗ Page Cache 경유하지 않음                       │
│      │   ✗ Block Layer 경유하지 않음                      │
│      │   ✗ Syscall 불필요 (최초 mmap 이후)               │
│      ▼                                                    │
│ ┌──────────────────┐                                      │
│ │ Persistent Media │ ← PMEM, CXL memory, etc.            │
│ │ (Physical Addr)  │                                      │
│ └──────────────────┘                                      │
│                                                           │
│ DAX 조건:                                                 │
│ 1. 미디어가 byte-addressable + CPU physical address space │
│ 2. 파일시스템이 DAX 지원 (ext4, XFS: -o dax)            │
│ 3. 또는 devdax 모드 (/dev/dax0.0)                       │
└──────────────────────────────────────────────────────────┘
```

### 7.3 DAX + NVMe 조합의 현실

```
문제: NVMe SSD는 기본적으로 DAX 불가
  - NVMe는 block-addressable (4KB 단위)
  - CPU physical address space에 NAND가 매핑되지 않음
  - DMA 기반 전송만 가능

해결 경로:
  1. NVMe CMB/PMR → PCIe BAR로 제한적 byte-access 가능
  2. CXL Memory (NAND-backed) → CXL.mem으로 CPU 접근 가능
  3. mmap + page fault → "유사 DAX" (실제로는 I/O 발생)

진정한 DAX가 가능한 미디어:
  - Intel Optane PMEM (단종)
  - CXL Type 3 Memory (DRAM-backed)
  - CXL Type 3 Memory (차세대 SCM-backed)
  - NVMe CMB/PMR (제한적, 소용량)
```

---

## 8. NVMe CMB/PMR & P2P

### 8.1 NVMe CMB (Controller Memory Buffer)

```
┌────────────────────────────────────────────────────────┐
│ NVMe SSD                                                │
│ ┌──────────────────────────────────────┐               │
│ │ NVMe Controller                       │               │
│ │  ┌──────────────────────────────┐    │               │
│ │  │ CMB (Controller Memory Buffer)│    │               │
│ │  │                               │    │               │
│ │  │ PCIe BAR에 매핑됨            │    │               │
│ │  │ → CPU가 MMIO로 직접 R/W 가능 │    │               │
│ │  │                               │    │               │
│ │  │ 용도:                         │    │               │
│ │  │  - SQ/CQ를 CMB에 배치        │    │               │
│ │  │  - I/O data buffer로 사용    │    │               │
│ │  │  - P2P DMA target            │    │               │
│ │  └──────────────────────────────┘    │               │
│ └──────────────────────────────────────┘               │
│                                                         │
│ 장점:                                                   │
│  - SQ를 CMB에 두면 doorbell + command 전송이 한 번에    │
│  - Host DRAM 사용 감소                                  │
│  - P2P DMA에서 중간 버퍼로 활용 가능                   │
│                                                         │
│ 제한:                                                   │
│  - 용량 작음 (수 MB ~ 수 GB)                           │
│  - Volatile (전원 off 시 소멸)                          │
│  - PCIe MMIO 성능 ≠ DDR 성능 (write combining 필요)    │
└────────────────────────────────────────────────────────┘
```

### 8.2 NVMe PMR (Persistent Memory Region)

```
CMB와 유사하지만 Persistent (전원 off에도 데이터 유지)

용도:
  - Metadata의 영속적 저장 (파일시스템 journal 등)
  - Write-ahead log를 PMR에 저장 → 빠른 commit
  - Byte-addressable persistent storage (소용량)

Linux 지원:
  # PMR 확인
  nvme id-ctrl /dev/nvme0 | grep pmr

  # PMR을 DAX 디바이스로 노출
  # /dev/dax 형태로 접근 가능
```

---

## 9. mmap과 XIP

### 9.1 mmap을 이용한 "유사 Memory" 접근

```
┌──────────────────────────────────────────────────────────┐
│ 일반 NVMe에서 mmap을 사용하는 경우                       │
│                                                           │
│ ptr = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);   │
│ value = *(ptr + offset);                                  │
│                                                           │
│ 내부 동작:                                                │
│                                                           │
│ 1. mmap() 호출 → 가상 주소 공간에 매핑 (아직 물리 X)    │
│                                                           │
│ 2. ptr 접근 시:                                           │
│    CPU load → MMU → Page Fault! (물리 페이지 없음)       │
│         │                                                 │
│         ▼                                                 │
│    Page Fault Handler                                     │
│         │                                                 │
│         ▼                                                 │
│    Block I/O 발생 (NVMe read, 4KB)  ← 여기서 ~2-10μs    │
│         │                                                 │
│         ▼                                                 │
│    Page Cache에 데이터 로드                               │
│         │                                                 │
│         ▼                                                 │
│    Page Table 업데이트 (VA → PA 매핑)                    │
│         │                                                 │
│         ▼                                                 │
│    CPU load 재실행 → 데이터 반환                         │
│                                                           │
│ 3. 이후 동일 페이지 재접근:                              │
│    CPU load → MMU → Page Table Hit → Page Cache에서 반환 │
│    (~ DDR 속도, ~100ns)                                  │
│                                                           │
│ 핵심: 첫 접근만 느리고 (Page Fault + I/O),              │
│       이후는 DRAM 속도 (Page Cache hit)                  │
│                                                           │
│ 단점:                                                     │
│  - 첫 접근 latency = Block I/O latency                  │
│  - Page Fault overhead (~1-2μs 추가)                     │
│  - DRAM을 Page Cache로 소비                              │
│  - 진정한 "Memory처럼"이 아님 (I/O가 숨겨져 있을 뿐)   │
└──────────────────────────────────────────────────────────┘
```

### 9.2 mmap 최적화 기법

```bash
# 1. MAP_POPULATE: mmap 시 미리 모든 페이지 fault 해결
ptr = mmap(..., MAP_POPULATE, ...);

# 2. madvise: 접근 패턴 힌트
madvise(ptr, size, MADV_SEQUENTIAL);   # Sequential access
madvise(ptr, size, MADV_RANDOM);       # Random access
madvise(ptr, size, MADV_WILLNEED);     # Prefetch
madvise(ptr, size, MADV_HUGEPAGE);     # THP 사용

# 3. readahead: 커널에게 미리 읽기 요청
readahead(fd, offset, length);

# 4. mlock: Page Cache에서 evict 방지
mlock(ptr, size);
```

### 9.3 XIP (Execute In Place)

```
XIP 개념:
  - 코드/데이터를 Storage에서 Memory로 복사하지 않고
  - 직접 Storage의 주소에서 실행/접근
  - 주로 NOR Flash, PMEM에서 사용

NVMe에서의 한계:
  - NVMe는 block I/O → 직접 XIP 불가
  - CMB/PMR 영역에서만 제한적 XIP 가능

DAX에서의 XIP:
  - DAX 가능 미디어 + DAX 파일시스템
  - mmap → CPU가 미디어 주소를 직접 접근
  - Page Cache 복사 없음 = 진정한 XIP 효과
```

---

## 10. SW 최적화: 극한의 Storage 접근

### 10.1 기술별 I/O 경로 비교

```
Latency 기여도 비교 (4KB Random Read):

                    Sync     libaio   io_uring  io_uring  SPDK
                    (read)            (basic)   (full)    (poll)
  ──────────────────────────────────────────────────────────────
  Syscall          ~400ns   ~200ns   ~50ns     0ns*      0ns
  Kernel Block     ~500ns   ~300ns   ~200ns    ~200ns    0ns
  NVMe Driver      ~300ns   ~200ns   ~200ns    ~200ns    ~50ns
  PCIe + NVMe HW   ~200ns   ~200ns   ~200ns    ~200ns    ~200ns
  NAND Flash        ~5000ns  ~5000ns  ~5000ns   ~5000ns   ~5000ns
  Completion        ~500ns   ~300ns   ~200ns    ~100ns**  ~50ns***
  ──────────────────────────────────────────────────────────────
  Total SW overhead ~1700ns  ~1000ns  ~650ns    ~500ns    ~100ns
  Total E2E        ~6900ns  ~6200ns  ~5850ns   ~5700ns   ~5300ns
  SW 비율           24.6%    16.1%    11.1%     8.8%      1.9%

  * SQPOLL: 커널 스레드가 SQ polling → syscall 불필요
  ** hipri: I/O polling → interrupt overhead 제거
  *** SPDK: 완전 user-space polling → interrupt/context switch 없음

  결론: SW 최적화로 줄일 수 있는 한계 = ~1.5μs (전체의 ~20%)
        나머지 ~5μs는 NAND 물리적 한계
```

### 10.2 각 기술이 제거하는 오버헤드

```
┌─────────────────────────────────────────────────────────────┐
│             I/O 오버헤드 제거 계층도                         │
│                                                              │
│  ┌──────────────┐                                            │
│  │ Application  │                                            │
│  └──────┬───────┘                                            │
│         │                                                    │
│    ┌────▼────┐   io_uring SQPOLL ────► Syscall 제거          │
│    │ Syscall │                                               │
│    └────┬────┘                                               │
│         │                                                    │
│    ┌────▼──────┐  SPDK ────────────► Kernel 전체 바이패스    │
│    │  Kernel   │  io_uring ────────► Block layer 최소화      │
│    │Block Layer│                                              │
│    └────┬──────┘                                             │
│         │                                                    │
│    ┌────▼──────┐  SPDK ────────────► User-space NVMe 직접   │
│    │NVMe Driver│  io_uring poll_q ─► Polling queue 사용      │
│    └────┬──────┘                                             │
│         │                                                    │
│    ┌────▼──────┐  hipri/polling ───► Interrupt 제거          │
│    │ Interrupt │  SPDK polling ────► 완전 polling 모드       │
│    └────┬──────┘                                             │
│         │                                                    │
│    ┌────▼──────┐                                             │
│    │ Hardware  │  ← 이 아래는 SW로 개선 불가                 │
│    │ (PCIe +   │     CXL/PMEM만이 근본 해결                 │
│    │  NAND)    │                                             │
│    └───────────┘                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 11. 기술별 비교 및 선택 가이드

### 11.1 종합 비교표

```
                 접근       Byte    Latency    BW       영속   용량    비용
                 방식       Addr?                       성            효율
─────────────────────────────────────────────────────────────────────────
DDR5 DRAM       load/store  Yes    ~80ns      ~50GB/s  No    ~TB    $$$
CXL DRAM        load/store  Yes    ~170ns     ~36GB/s  No    ~TB    $$
CXL Persistent  load/store  Yes    ~300ns+    ~20GB/s  Yes   ~TB    $$
Optane PMEM     load/store  Yes    ~300ns     ~6.6GB/s Yes   ~TB    $$ (단종)
NVMe CMB        MMIO        Yes    ~500ns     ~4GB/s   No    ~GB    (SSD 포함)
NVMe PMR        MMIO        Yes    ~500ns     ~4GB/s   Yes   ~GB    (SSD 포함)
NVMe (SPDK)     poll DMA    No     ~2-3μs    ~7GB/s   Yes   ~TB    $
NVMe (io_uring) async DMA   No     ~3-5μs    ~7GB/s   Yes   ~TB    $
NVMe (mmap)     page fault  (가상)  ~2-10μs   ~7GB/s   Yes   ~TB    $
─────────────────────────────────────────────────────────────────────────
```

### 11.2 사용 시나리오별 권장 기술

```
┌───────────────────────────────────────────────────────────────────┐
│ 시나리오                          │ 권장 기술                     │
├───────────────────────────────────┼───────────────────────────────┤
│ In-memory DB 확장 (Redis, etc.)  │ CXL DRAM > mmap+NVMe         │
│ 대용량 캐시 (CDN, Proxy)         │ CXL Memory > mmap+NVMe       │
│ Key-Value Store (RocksDB)        │ io_uring + DAX (가능시)       │
│ AI/ML 모델 로딩                   │ CXL > GDS > mmap+NVMe        │
│ 데이터베이스 WAL                   │ NVMe PMR > PMEM > io_uring   │
│ 실시간 분석 (OLAP)               │ CXL + NVMe tiering           │
│ 고성능 스토리지 서비스             │ SPDK (block) + CXL (metadata)│
│ 범용 서버                         │ io_uring + mmap               │
│ HPC / Scientific Computing       │ CXL Memory pooling            │
└───────────────────────────────────┴───────────────────────────────┘
```

### 11.3 미래 전망: Memory-Storage 통합

```
현재 (2024-2026):
  DDR5 ←80ns→ CPU ←PCIe→ NVMe SSD (~3-10μs)
  CXL 1.1/2.0 제품 초기 출시

근미래 (2026-2028):
  DDR5 ← CPU → CXL 2.0 Memory (~150-300ns) ← NVMe Gen5
  CXL Memory Pooling / Sharing
  CXL Switch로 다수 호스트가 메모리 풀 공유

중장기 (2028-2030+):
  DDR6? ← CPU → CXL 3.0/4.0 Memory → Fabric-attached Memory
  Memory Semantic Storage: 모든 Storage가 byte-addressable
  Compute near Memory/Storage 통합

궁극적 목표:
  ┌────────────────────────────────────────────┐
  │    Unified Memory-Storage Architecture      │
  │                                             │
  │    CPU ←(load/store)→ [ Memory Fabric ]    │
  │                         │    │    │         │
  │                        DRAM  CXL  Persistent│
  │                        (hot) (warm)(cold)   │
  │                                             │
  │    SW가 tiering/placement 자동 관리         │
  │    App은 단일 address space로 모든 데이터   │
  │    접근 (latency만 다름, 방식은 동일)       │
  └────────────────────────────────────────────┘
```

---

## 참고 자료
- CXL Specification: https://www.computeexpresslink.org/
- Intel Optane PMEM Architecture Guide
- NVMe Specification (CMB/PMR): https://nvmexpress.org/
- Linux DAX Documentation: https://www.kernel.org/doc/html/latest/filesystems/dax.html
- Linux CXL Subsystem: https://www.kernel.org/doc/html/latest/driver-api/cxl/
- SPDK Documentation: https://spdk.io/doc/
- "Bridging the Memory-Storage Gap" - USENIX ATC papers

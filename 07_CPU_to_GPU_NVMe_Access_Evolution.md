# NVMe SSD 접근 기술의 진화: CPU → GPU

## 목차
1. [전체 기술 진화 타임라인](#1-전체-기술-진화-타임라인)
2. [CPU → NVMe 접근 기술 진화](#2-cpu--nvme-접근-기술-진화)
3. [CPU 기술 세대별 상세 분석](#3-cpu-기술-세대별-상세-분석)
4. [GPU → NVMe 접근의 등장 배경](#4-gpu--nvme-접근의-등장-배경)
5. [GPU → NVMe 접근 기술 진화](#5-gpu--nvme-접근-기술-진화)
6. [GPU 기술 세대별 상세 분석](#6-gpu-기술-세대별-상세-분석)
7. [NVIDIA GPUDirect Storage (GDS) 심층 분석](#7-nvidia-gpudirect-storage-gds-심층-분석)
8. [GPU-Initiated I/O: BaM과 차세대 기술](#8-gpu-initiated-io-bam과-차세대-기술)
9. [AMD 및 Intel GPU의 Storage 접근](#9-amd-및-intel-gpu의-storage-접근)
10. [CPU vs GPU NVMe 접근 종합 비교](#10-cpu-vs-gpu-nvme-접근-종합-비교)
11. [Unified Memory + Storage 아키텍처](#11-unified-memory--storage-아키텍처)
12. [사용 시나리오별 권장 기술](#12-사용-시나리오별-권장-기술)

---

## 1. 전체 기술 진화 타임라인

```
                    CPU → NVMe                          GPU → NVMe
                    ──────────                          ──────────
 2010  ┌─ AHCI/SATA (sync I/O)
 2011  │  NVMe 1.0 spec 발표
 2012  ├─ NVMe over PCIe 등장
 2013  │  libaio + NVMe 조합 확산
 2014  │
 2015  ├─ SPDK 프로젝트 시작 (Intel)
 2016  │  SPDK 1.0 릴리즈                    ┌─ GPUDirect RDMA (network)
 2017  │  NVMe-oF 1.0                       │
 2018  │                                     ├─ GPUDirect Storage 개념 발표
 2019  ├─ io_uring 등장 (Linux 5.1)         │  (NVIDIA, Magnum IO)
 2020  │  io_uring SQPOLL, fixedbuf          ├─ GDS Beta (CUDA 11.4)
 2021  │  io_uring polling mode              │  cuFile API 공개
 2022  ├─ io_uring 성숙 (zerocopy, etc.)    ├─ GDS GA (CUDA 12.0)
 2023  │  SPDK + CXL 연동                   │  GDS Compatibility Mode
 2024  │  io_uring + NVMe passthrough        ├─ BaM (GPU-Initiated I/O) 연구
 2025  ├─ CXL Memory + NVMe tiering         │  GPU-SSD P2P DMA 최적화
 2026  │  io_uring + SQPOLL + zerocopy 통합  ├─ GDS 2.0 + NVMe-oF
       │                                     │  AMD ROCm + GDS 호환 논의
       ▼                                     ▼
   Memory Semantic I/O                  GPU-Native Storage Access
```

---

## 2. CPU → NVMe 접근 기술 진화

### 2.1 세대별 진화 요약

```
┌────────────────────────────────────────────────────────────────────────┐
│                   CPU → NVMe 기술 진화 로드맵                          │
│                                                                        │
│  Gen 0: Sync I/O          Gen 1: Async I/O       Gen 2: Optimized     │
│  (2010-2014)              (2013-2018)             Async (2019-현재)     │
│                                                                        │
│  ┌──────────┐            ┌──────────┐            ┌──────────┐         │
│  │ read()   │            │ libaio   │            │ io_uring │         │
│  │ write()  │            │ (AIO)    │            │          │         │
│  │ pread()  │            │          │            │ SQPOLL   │         │
│  │ pwrite() │            │          │            │ fixedbuf │         │
│  └──────────┘            └──────────┘            │ polling  │         │
│                                                   └──────────┘         │
│  - Syscall per I/O       - Batch submit          - Single syscall     │
│  - CPU blocked           - Async completion       - Kernel thread poll│
│  - Context switch        - Still syscall heavy    - Zero-copy         │
│  - ~10-80μs              - ~5-10μs               - ~3-5μs            │
│                                                                        │
│                                                                        │
│  Gen 3: User-Space       Gen 4: Kernel Bypass+   Gen 5: Memory       │
│  (2015-현재)              (2022-현재)              Semantic (미래)      │
│                                                                        │
│  ┌──────────┐            ┌──────────┐            ┌──────────┐         │
│  │ SPDK     │            │ io_uring │            │ CXL.mem  │         │
│  │          │            │ passthru │            │ + DAX    │         │
│  │ vfio-pci │            │          │            │          │         │
│  │ UIO      │            │ SPDK+CXL │            │ load/    │         │
│  └──────────┘            │ NVMe CMB │            │ store    │         │
│                           └──────────┘            └──────────┘         │
│  - No kernel at all      - NVMe cmd passthrough  - No I/O stack      │
│  - User-space driver     - HW queue direct       - Byte-addressable  │
│  - Polling only          - Hybrid approaches      - ~150-300ns        │
│  - ~2-3μs               - ~2-4μs                                     │
│                                                                        │
│  Latency 개선 추이:                                                    │
│  80μs → 10μs → 5μs → 3μs → 2μs → (0.15μs)                          │
│  Gen0    Gen0   Gen1   Gen2   Gen3   Gen5                              │
│  (sync)  (NVMe) (aio)  (uring)(spdk) (CXL)                           │
└────────────────────────────────────────────────────────────────────────┘
```

### 2.2 각 세대가 제거한 오버헤드

```
I/O Path 오버헤드 분해 (4KB Random Read):

                     Gen 0     Gen 1     Gen 2      Gen 3      Gen 4
                     sync      libaio    io_uring   SPDK       passthru
                     read()              (full opt) (poll)
─────────────────────────────────────────────────────────────────────────
User↔Kernel 전환     ~400ns    ~200ns    0ns ①      0ns ③      ~50ns
I/O Scheduler        ~300ns    ~200ns    ~100ns     0ns ③      0ns ④
Block Layer          ~200ns    ~100ns    ~100ns     0ns ③      0ns ④
NVMe Driver          ~300ns    ~200ns    ~200ns     ~50ns ③    ~50ns
Doorbell MMIO        ~100ns    ~100ns    ~100ns     ~100ns     ~100ns
PCIe round-trip      ~200ns    ~200ns    ~200ns     ~200ns     ~200ns
NVMe Controller      ~500ns    ~500ns    ~500ns     ~500ns     ~500ns
NAND Flash           ~5000ns   ~5000ns   ~5000ns    ~5000ns    ~5000ns
Completion (IRQ)     ~500ns    ~300ns    ~100ns ②   ~50ns ③    ~50ns
App Notification     ~300ns    ~200ns    ~50ns      0ns        ~50ns
─────────────────────────────────────────────────────────────────────────
Total               ~7800ns   ~6000ns   ~6350ns*   ~5900ns    ~6000ns*
SW Overhead         ~2100ns   ~1200ns    ~650ns     ~200ns     ~300ns
SW 비율              26.9%     20.0%     10.2%      3.4%       5.0%
─────────────────────────────────────────────────────────────────────────

① SQPOLL: 커널 스레드가 SQ polling → syscall 제거
② hipri: completion polling → interrupt 제거
③ SPDK: 커널 완전 바이패스, user-space NVMe driver
④ passthrough: io_uring에서 NVMe command 직접 전송

* io_uring full opt = SQPOLL + fixedbuf + hipri 모두 적용
```

---

## 3. CPU 기술 세대별 상세 분석

### 3.1 Gen 0: Synchronous I/O (POSIX read/write)

```
┌─────────────────────────────────────────────────────────────┐
│ Application Thread                                           │
│  │                                                           │
│  │ ret = read(fd, buf, 4096);  ← Thread BLOCKED until done │
│  ▼                                                           │
│ ┌──────────┐                                                 │
│ │ Syscall  │ ← User→Kernel 전환 (비용: ~400ns)             │
│ │ sys_read │                                                 │
│ └────┬─────┘                                                 │
│      ▼                                                       │
│ ┌──────────┐                                                 │
│ │ VFS      │ ← dentry/inode lookup, page cache 확인          │
│ └────┬─────┘                                                 │
│      ▼                                                       │
│ ┌──────────┐                                                 │
│ │ I/O Sched│ ← noop/deadline/cfq, merge, sort               │
│ └────┬─────┘                                                 │
│      ▼                                                       │
│ ┌──────────┐                                                 │
│ │ NVMe Drv │ ← SQE build, doorbell write                    │
│ └────┬─────┘                                                 │
│      ▼ ... (HW processing) ...                               │
│      ▼                                                       │
│ ┌──────────┐                                                 │
│ │ IRQ      │ ← MSI-X interrupt → CQ processing              │
│ └────┬─────┘                                                 │
│      ▼                                                       │
│ Application Thread RESUMES                                   │
│                                                              │
│ 문제점:                                                      │
│ ① 1 I/O = 1 syscall = 2 context switch                     │
│ ② Thread blocked → CPU idle 또는 다른 thread 스케줄링       │
│ ③ 높은 QD 불가 (thread 수 = QD, thread 생성 비용↑)         │
│ ④ I/O 당 overhead: ~2μs+ (SW만)                            │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 Gen 1: Linux AIO (libaio)

```
┌─────────────────────────────────────────────────────────────┐
│ Application Thread                                           │
│  │                                                           │
│  ├─ io_setup(nr_events, &ctx)        ← AIO context 생성     │
│  │                                                           │
│  ├─ io_submit(ctx, nr, &iocb[])      ← 다수 I/O 한번에 제출│
│  │   [iocb0][iocb1][iocb2]...                               │
│  │                                                           │
│  ├─ (do other work)                  ← Thread NOT blocked!  │
│  │                                                           │
│  └─ io_getevents(ctx, min, max, events[], timeout)          │
│       ← 완료된 I/O 수집 (batch)                             │
│                                                              │
│ 개선점:                                                      │
│ ✓ Async: submit 후 thread가 다른 일 가능                   │
│ ✓ Batch submit: 여러 I/O를 한 syscall로 제출               │
│ ✓ Batch completion: 여러 완료를 한 번에 수집                │
│ ✓ 높은 QD 가능 (thread 수 ≠ QD)                            │
│                                                              │
│ 남은 문제점:                                                 │
│ ✗ io_submit() 자체가 syscall → context switch               │
│ ✗ io_getevents()도 syscall → 또 context switch              │
│ ✗ O_DIRECT 필수 (buffered I/O 시 sync로 fallback)          │
│ ✗ AIO context가 per-process → 확장성 제한                   │
│ ✗ iocb 구조가 복잡, 에러 핸들링 어려움                      │
│ ✗ socket I/O 등 다른 I/O와 통합 불가                        │
│ ✗ I/O 당 overhead: ~1μs+ (SW만)                            │
└─────────────────────────────────────────────────────────────┘
```

### 3.3 Gen 2: io_uring (2019~)

```
┌─────────────────────────────────────────────────────────────┐
│ io_uring 혁신적 아키텍처                                     │
│                                                              │
│  User Space          │  Kernel Space                         │
│                      │                                       │
│  ┌──────────────┐    │    ┌──────────────┐                   │
│  │ SQ (Submit   │◄───┼───►│ Kernel       │                   │
│  │    Queue)    │ mmap    │ SQ Consumer  │                   │
│  │              │ shared  │              │                    │
│  │ [SQE][SQE]  │ memory  │ (또는 SQPOLL │                   │
│  │ [SQE][SQE]  │    │    │  kthread)    │                   │
│  └──────────────┘    │    └──────┬───────┘                   │
│                      │           │                           │
│  ┌──────────────┐    │    ┌──────▼───────┐                   │
│  │ CQ (Complet. │◄───┼───►│ Kernel       │                   │
│  │    Queue)    │ mmap    │ CQ Producer  │                   │
│  │              │ shared  │              │                    │
│  │ [CQE][CQE]  │ memory  │              │                   │
│  └──────────────┘    │    └──────────────┘                   │
│                      │                                       │
│  핵심 혁신:                                                  │
│                                                              │
│  ① Shared Memory Ring Buffer                                │
│     - SQ/CQ가 user↔kernel 공유 메모리                       │
│     - User가 SQE를 ring에 쓰고, kernel이 읽음               │
│     - Kernel이 CQE를 ring에 쓰고, user가 읽음               │
│     - 데이터 복사 없음 (zero-copy metadata)                  │
│                                                              │
│  ② SQPOLL Mode                                              │
│     - 커널 스레드가 SQ를 지속 polling                        │
│     - User는 SQE만 쓰면 됨 → syscall 완전 제거             │
│     - io_uring_enter() 불필요                                │
│                                                              │
│  ③ Fixed Buffers/Files                                      │
│     - io_uring_register()로 buffer/fd를 미리 등록            │
│     - I/O마다 buffer mapping 오버헤드 제거                   │
│                                                              │
│  ④ I/O Polling (hipri)                                      │
│     - Completion을 interrupt 대신 polling으로 감지            │
│     - IRQ overhead 제거                                      │
│     - NVMe poll queue 활용                                   │
│                                                              │
│  ⑤ Unified Interface                                        │
│     - Block I/O, network, file, timer 등 모두 통합           │
│     - 하나의 ring으로 모든 I/O 관리                          │
│                                                              │
│  성능: 4KB random read                                       │
│  - Basic io_uring: ~5μs (libaio 대비 ~20% 개선)            │
│  - SQPOLL + fixedbuf: ~4μs                                  │
│  - SQPOLL + fixedbuf + hipri: ~3μs (libaio 대비 ~50%)      │
└─────────────────────────────────────────────────────────────┘
```

### 3.4 Gen 3: SPDK (Storage Performance Development Kit)

```
┌─────────────────────────────────────────────────────────────┐
│ SPDK: 커널 완전 바이패스                                     │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ User Space                                           │    │
│  │                                                      │    │
│  │  Application                                         │    │
│  │      │                                               │    │
│  │      ▼                                               │    │
│  │  SPDK NVMe Driver (user-space)                       │    │
│  │      │                                               │    │
│  │      ├─ SQE 직접 작성 (NVMe command)                │    │
│  │      ├─ Doorbell MMIO 직접 write                    │    │
│  │      ├─ CQ Polling (busy-wait loop)                 │    │
│  │      └─ Completion callback 호출                     │    │
│  │                                                      │    │
│  │  vfio-pci / UIO                                      │    │
│  │      │ (PCIe BAR를 user-space에 매핑)               │    │
│  └──────┼──────────────────────────────────────────────┘    │
│         │                                                    │
│    ─────┼──── (No Kernel involvement) ────────              │
│         │                                                    │
│    ┌────▼──────────────────────────┐                        │
│    │ NVMe SSD (PCIe device)        │                        │
│    │  SQ/CQ ← SPDK이 직접 관리    │                        │
│    │  Doorbell ← MMIO로 직접 접근  │                        │
│    └───────────────────────────────┘                        │
│                                                              │
│  제거된 오버헤드:                                            │
│  ✓ Syscall overhead: 0ns (no kernel)                        │
│  ✓ Context switch: 0ns (no kernel)                          │
│  ✓ Block layer: 0ns (bypass)                                │
│  ✓ I/O scheduler: 0ns (bypass)                              │
│  ✓ Interrupt: 0ns (polling only)                            │
│  ✓ Lock contention: 최소 (lockless design)                  │
│                                                              │
│  대가 (Trade-offs):                                          │
│  ✗ 전용 CPU core 필요 (polling → 100% CPU 사용)            │
│  ✗ 커널 디바이스 관리 포기 (hotplug, power mgmt 등)        │
│  ✗ 파일시스템 사용 불가 → SPDK blobstore 또는 raw block    │
│  ✗ 일반 앱과 디바이스 공유 불가                              │
│  ✗ 러닝 커브 높음, SPDK 전용 프로그래밍 모델               │
│                                                              │
│  성능: 4KB random read                                       │
│  - ~2-3μs (SW overhead ~100-200ns)                          │
│  - NAND latency가 전체의 ~95% 이상                          │
│  - CPU 효율: 1 core로 ~400K-1M IOPS 가능                   │
└─────────────────────────────────────────────────────────────┘
```

### 3.5 Gen 4: io_uring NVMe Passthrough + 하이브리드

```
┌─────────────────────────────────────────────────────────────┐
│ io_uring NVMe Passthrough (Linux 6.x)                        │
│                                                              │
│  SPDK의 성능 + io_uring의 편의성 결합 시도                   │
│                                                              │
│  Application                                                 │
│      │                                                       │
│      ▼                                                       │
│  io_uring SQE (IORING_OP_URING_CMD)                         │
│      │                                                       │
│      ▼                                                       │
│  NVMe character device (/dev/ng0n1)                          │
│      │                                                       │
│      ▼  ← Block layer 바이패스!                             │
│  NVMe Driver (hw queue에 직접 dispatch)                      │
│      │                                                       │
│      ▼                                                       │
│  NVMe SSD                                                    │
│                                                              │
│  장점:                                                       │
│  ✓ Block layer 바이패스 → scheduler overhead 제거           │
│  ✓ NVMe command를 직접 구성 가능 (vendor specific 포함)     │
│  ✓ 커널 내에서 동작 → 디바이스 관리 유지                    │
│  ✓ SQPOLL과 결합 가능 → syscall도 제거                      │
│  ✓ 파일시스템과 공존 가능 (char device 사용)                │
│                                                              │
│  SPDK vs io_uring Passthrough:                               │
│  ┌──────────────┬─────────────────┬──────────────────┐      │
│  │              │ SPDK             │ uring passthru   │      │
│  ├──────────────┼─────────────────┼──────────────────┤      │
│  │ Kernel 의존  │ 없음             │ 있음 (최소)      │      │
│  │ Syscall      │ 없음             │ 선택적 (SQPOLL)  │      │
│  │ Block layer  │ 바이패스          │ 바이패스          │      │
│  │ 디바이스 공유│ 불가             │ 가능             │      │
│  │ 파일시스템   │ 불가             │ 공존 가능        │      │
│  │ 운영 편의성  │ 낮음             │ 높음             │      │
│  │ Latency      │ ~2-3μs          │ ~2-4μs          │      │
│  │ CPU 효율     │ 높음 (polling)   │ 높음 (SQPOLL)   │      │
│  └──────────────┴─────────────────┴──────────────────┘      │
└─────────────────────────────────────────────────────────────┘
```

### 3.6 CPU 기술 진화 요약 비교표

```
┌──────────────────────────────────────────────────────────────────────┐
│                    CPU→NVMe 기술 세대 종합 비교                       │
├──────────┬────────┬────────┬──────────┬────────┬────────────────────┤
│          │ Gen 0  │ Gen 1  │ Gen 2    │ Gen 3  │ Gen 4             │
│          │ sync   │ libaio │ io_uring │ SPDK   │ uring passthru    │
├──────────┼────────┼────────┼──────────┼────────┼────────────────────┤
│ 등장     │ ~2010  │ ~2013  │ 2019     │ 2015   │ 2022              │
│ Latency  │ ~10-80 │ ~5-10  │ ~3-5     │ ~2-3   │ ~2-4              │
│ (μs)     │        │        │          │        │                    │
│ IOPS/core│ ~50K   │ ~200K  │ ~400K    │ ~1M    │ ~600K             │
│ Syscall  │ per-IO │ batch  │ opt.     │ none   │ optional          │
│ Kernel   │ full   │ full   │ partial  │ none   │ minimal           │
│ Async    │ No     │ Yes    │ Yes      │ Yes    │ Yes               │
│ Polling  │ No     │ No     │ Yes      │ Yes    │ Yes               │
│ FS 호환  │ Yes    │ O_DIR  │ Yes      │ No     │ Yes               │
│ 난이도   │ Easy   │ Medium │ Medium   │ Hard   │ Medium-Hard       │
│ 주 사용처│ 범용   │ DB     │ 범용     │ 스토리 │ 고성능 + 범용     │
│          │        │        │ 고성능   │ 지 서비│                    │
│          │        │        │          │ 스     │                    │
└──────────┴────────┴────────┴──────────┴────────┴────────────────────┘
```

---

## 4. GPU → NVMe 접근의 등장 배경

### 4.1 왜 GPU가 직접 Storage에 접근해야 하는가?

```
문제 상황: AI/ML, HPC, 데이터 분석 워크로드

  데이터셋 크기:
  - LLM 학습 데이터: 수 TB ~ 수십 TB
  - 의료 영상 분석: 수백 GB ~ TB
  - 과학 시뮬레이션: TB ~ PB
  - 비디오 트랜스코딩: 연속 스트리밍 GB/s

  GPU 메모리 (VRAM):
  - H100: 80GB HBM3
  - A100: 80GB HBM2e
  - RTX 4090: 24GB GDDR6X

  Gap: 데이터 >> GPU 메모리
  → 반복적으로 Storage에서 GPU로 데이터 로딩 필요
  → 이 데이터 파이프라인이 전체 학습/추론의 병목!


전통적 데이터 경로 (CPU 경유):

  ┌─────────┐     ┌──────────┐     ┌──────────┐     ┌─────────┐
  │ NVMe SSD│────►│ CPU DRAM │────►│ CPU DRAM │────►│  GPU    │
  │         │ DMA │ (kernel  │copy │ (user    │DMA  │  VRAM   │
  │         │     │  buffer) │     │  buffer) │     │         │
  └─────────┘     └──────────┘     └──────────┘     └─────────┘
       ①               ②               ③               ④

  ① NVMe → CPU DRAM: DMA (NVMe read)
  ② Kernel → User: memcpy (or page cache)
  ③ User DRAM → GPU: cudaMemcpy (PCIe DMA)

  문제점:
  - 데이터가 CPU DRAM을 2번 경유 (bounce buffer)
  - CPU DRAM 대역폭을 소비 → CPU 작업에 영향
  - 3단계 복사 → latency 증가
  - CPU가 데이터 전송에 관여 → CPU cycle 낭비
  - PCIe 대역폭을 2번 사용 (SSD→DRAM, DRAM→GPU)
```

### 4.2 데이터 전송 병목의 정량 분석

```
예시: 1TB 데이터를 GPU로 로딩 (PCIe Gen4)

전통 경로 (CPU bounce buffer):
  NVMe → CPU DRAM: ~7 GB/s (NVMe Gen4 max)
  CPU DRAM → GPU:  ~25 GB/s (PCIe Gen4 x16)

  실효 처리량: min(7, 25) ≈ 7 GB/s (순차적이면 절반)
  But: bounce buffer로 인한 실효: ~3-5 GB/s
  소요 시간: 1TB / 4 GB/s ≈ ~250초 (4분+)

  CPU DRAM 사용량: bounce buffer ~수 GB 상시 점유
  CPU 사용량: memcpy + syscall로 CPU 코어 부하

직접 경로 (GPU Direct Storage):
  NVMe → GPU VRAM: ~7 GB/s (NVMe Gen4 max, P2P DMA)

  실효 처리량: ~6-7 GB/s (overhead 최소)
  소요 시간: 1TB / 6.5 GB/s ≈ ~154초 (2.5분)

  CPU DRAM 사용량: ~0 (바이패스)
  CPU 사용량: 최소 (제어 신호만)

개선: ~40-60% 처리량 향상, CPU/DRAM 해방
```

---

## 5. GPU → NVMe 접근 기술 진화

### 5.1 세대별 진화

```
┌────────────────────────────────────────────────────────────────────────┐
│                   GPU → NVMe 기술 진화 로드맵                          │
│                                                                        │
│  Phase 0: CPU 경유         Phase 1: P2P 도입       Phase 2: GDS       │
│  (전통적 방식)              (부분 바이패스)          (CPU 바이패스)      │
│                                                                        │
│  ┌──────────────┐          ┌──────────────┐        ┌──────────────┐   │
│  │ cudaMemcpy + │          │ GPUDirect    │        │ GPUDirect    │   │
│  │ POSIX I/O    │          │ RDMA (Net)   │        │ Storage(GDS) │   │
│  │              │          │              │        │              │   │
│  │ read()→DRAM  │          │ NIC→GPU 직접 │        │ NVMe→GPU 직접│   │
│  │ DRAM→GPU     │          │ (P2P DMA)    │        │ (P2P DMA)    │   │
│  └──────────────┘          └──────────────┘        │ cuFile API   │   │
│                                                     └──────────────┘   │
│  - Bounce buffer 2회       - Network P2P 성공       - Storage P2P     │
│  - CPU 병목                - GPU↔NIC 직접 통신      - cuFile API       │
│  - ~3-5 GB/s              - Storage는 여전히 CPU    - ~6-7 GB/s       │
│                             경유                     - CPU 바이패스     │
│                                                                        │
│                                                                        │
│  Phase 3: GPU-Initiated   Phase 4: Unified         Phase 5: Future    │
│  (GPU 자율 I/O)            (통합 메모리)             (CXL + GPU)       │
│                                                                        │
│  ┌──────────────┐          ┌──────────────┐        ┌──────────────┐   │
│  │ BaM          │          │ Unified Mem  │        │ CXL + GPU    │   │
│  │ (Big accel.  │          │ + Storage    │        │ Direct Mem   │   │
│  │  Memory)     │          │              │        │              │   │
│  │              │          │ GPU ld/st →  │        │ GPU load/    │   │
│  │ GPU thread가 │          │ Storage      │        │ store →      │   │
│  │ 직접 I/O     │          │              │        │ CXL Memory   │   │
│  │ 요청         │          │              │        │ + NVMe tier  │   │
│  └──────────────┘          └──────────────┘        └──────────────┘   │
│                                                                        │
│  - GPU warp이 직접         - HW 지원 통합 주소      - GPU↔CXL 직접    │
│    NVMe cmd 생성           - SW/HW 자동 tiering    - 확장된 GPU 메모리│
│  - CPU 완전 배제           - 페이지 마이그레이션    - Memory Semantic  │
│  - 연구 단계 (~2024)      - 연구 단계              - 표준화 진행중    │
└────────────────────────────────────────────────────────────────────────┘
```

### 5.2 기술별 데이터 경로 비교

```
◆ Phase 0: 전통적 CPU 경유

  NVMe ──DMA──► CPU DRAM ──memcpy──► CPU DRAM ──DMA──► GPU VRAM
       ①              ②                    ③
  PCIe 1회↑      CPU memcpy          PCIe 1회↑
  총 PCIe 사용: 2회 (SSD→DRAM + DRAM→GPU)
  CPU 관여: 높음 (I/O + memcpy + GPU 전송 관리)


◆ Phase 1: GPUDirect RDMA (네트워크 I/O만 해당)

  Remote NVMe ──RDMA──► NIC ──P2P DMA──► GPU VRAM
  (NVMe-oF)           ①         ②
  CPU DRAM 경유하지 않음 (NIC→GPU P2P DMA)
  But: 로컬 NVMe에는 미적용


◆ Phase 2: GPUDirect Storage (GDS)

  NVMe ──────── P2P DMA ────────► GPU VRAM
              ①
  CPU DRAM 바이패스! (최적 경로)
  PCIe 사용: 1회 (SSD→GPU 직접)
  CPU 관여: 최소 (제어 경로만)

  Compatibility Mode (PCIe 토폴로지가 P2P 불가 시):
  NVMe ──DMA──► CPU DRAM (bounce) ──DMA──► GPU VRAM
  GDS API는 동일, 내부적으로 bounce buffer 사용


◆ Phase 3: GPU-Initiated I/O (BaM)

  GPU Warp ──(PCIe MMIO)──► NVMe SSD Doorbell
                              │
  NVMe ──────── P2P DMA ─────┘──► GPU VRAM

  GPU 스레드가 직접 NVMe 커맨드 생성 + 제출!
  CPU 완전 배제 (control path도 GPU)


◆ Phase 5: CXL + GPU (미래)

  GPU ──(CXL.mem / load/store)──► CXL Memory ◄──── NVMe (tiered)

  GPU가 CXL 메모리를 직접 load/store
  Hot data = CXL DRAM, Cold data = NVMe → HW/SW 자동 tiering
```

---

## 6. GPU 기술 세대별 상세 분석

### 6.1 Phase 0: 전통적 CPU 경유 방식

```
┌─────────────────────────────────────────────────────────────┐
│ 코드 예시 (CUDA + POSIX I/O):                                │
│                                                              │
│   // 1. Host에서 파일 읽기                                   │
│   int fd = open("data.bin", O_RDONLY);                       │
│   void* host_buf = malloc(size);                             │
│   read(fd, host_buf, size);          // NVMe → CPU DRAM     │
│                                                              │
│   // 2. CPU DRAM → GPU VRAM 복사                             │
│   void* dev_buf;                                             │
│   cudaMalloc(&dev_buf, size);                                │
│   cudaMemcpy(dev_buf, host_buf,      // CPU DRAM → GPU      │
│              size, cudaMemcpyHostToDevice);                  │
│                                                              │
│   // 3. GPU 연산                                             │
│   kernel<<<grid, block>>>(dev_buf);                          │
│                                                              │
│ 데이터 경로:                                                 │
│   NVMe ─①─► Kernel Buffer ─②─► User Buffer ─③─► GPU VRAM  │
│                                                              │
│   ① read() syscall: NVMe DMA → page cache → user buf       │
│   ② (page cache hit 시 ② = memcpy만)                       │
│   ③ cudaMemcpy: PCIe DMA (pinned memory 시 직접 DMA)       │
│                                                              │
│ 오버헤드 분석 (1GB 전송):                                    │
│   read():      ~143ms (7 GB/s NVMe)                         │
│   memcpy:      ~33ms  (30 GB/s DDR5)   ← 불필요한 복사     │
│   cudaMemcpy:  ~77ms  (13 GB/s PCIe Gen4 x16)              │
│   총:          ~253ms                                        │
│   실효 BW:     ~3.9 GB/s                                    │
│                                                              │
│   주요 비효율:                                                │
│   - CPU DRAM 대역폭 낭비 (memcpy)                           │
│   - PCIe 대역폭 2회 사용                                    │
│   - CPU가 데이터 파이프라인에 묶임                           │
│   - GPU idle time 증가 (데이터 대기)                        │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 Phase 1: GPUDirect RDMA

```
┌─────────────────────────────────────────────────────────────┐
│ GPUDirect RDMA (2016~): NIC ↔ GPU 직접 통신                  │
│                                                              │
│  NVMe-oF (Remote Storage)                                    │
│      │                                                       │
│      ▼                                                       │
│  ┌────────┐    PCIe P2P DMA    ┌──────────┐                 │
│  │  NIC   │───────────────────►│   GPU    │                 │
│  │ (RDMA) │    no CPU DRAM     │  (VRAM)  │                 │
│  └────────┘                     └──────────┘                 │
│                                                              │
│  조건:                                                       │
│  - RDMA NIC (Mellanox/NVIDIA ConnectX)                       │
│  - GPU와 NIC가 동일 PCIe switch 하위 (P2P 가능)            │
│  - NVIDIA peer memory client 드라이버                        │
│                                                              │
│  한계:                                                       │
│  - 네트워크(원격) I/O만 해당                                │
│  - 로컬 NVMe → GPU 직접 전송은 미지원                      │
│  - NVMe-oF 인프라 필요                                      │
│                                                              │
│  이 기술이 GDS의 전신:                                       │
│  "NIC→GPU P2P가 되면, NVMe→GPU P2P도 가능하지 않을까?"     │
│  → 이 발상이 GPUDirect Storage로 발전                       │
└─────────────────────────────────────────────────────────────┘
```

### 6.3 Phase 2: GPUDirect Storage (GDS) 개요

```
┌─────────────────────────────────────────────────────────────┐
│ GPUDirect Storage (2020 Beta → 2022 GA)                      │
│                                                              │
│  cuFile API:                                                 │
│   CUfileHandle_t fh;                                         │
│   cuFileHandleRegister(&fh, &descr);                         │
│   cuFileBufRegister(dev_buf, size, 0);                       │
│   cuFileRead(fh, dev_buf, size, file_offset, 0);             │
│   //       NVMe ──── P2P DMA ────► GPU VRAM                │
│   //       CPU DRAM 바이패스!                                │
│                                                              │
│  아키텍처:                                                   │
│                                                              │
│  ┌───────────────────────────────────────────────┐           │
│  │ User Space                                     │           │
│  │  App → cuFile API                              │           │
│  └───────────┬───────────────────────────────────┘           │
│              │                                               │
│  ┌───────────▼───────────────────────────────────┐           │
│  │ Kernel Space                                   │           │
│  │  nvidia-fs.ko (GDS kernel module)              │           │
│  │      │                                         │           │
│  │      ├─ GPU BAR1 주소를 NVMe DMA target으로   │           │
│  │      │  등록                                   │           │
│  │      ├─ NVMe driver에 I/O 요청 (DMA addr =   │           │
│  │      │  GPU VRAM의 물리 주소)                  │           │
│  │      └─ P2P DMA 경로 설정                      │           │
│  │                                                │           │
│  │  NVMe Driver                                   │           │
│  │      │                                         │           │
│  │      └─ DMA 전송: src=NVMe, dst=GPU BAR1      │           │
│  └───────────────────────────────────────────────┘           │
│              │                                               │
│         ┌────▼────────────── PCIe Fabric ──────────┐        │
│         │                                           │        │
│    ┌────┴────┐                              ┌──────┴─────┐  │
│    │ NVMe SSD│ ════ P2P DMA ═══════════════►│ GPU VRAM   │  │
│    └─────────┘  (CPU DRAM bypass)           │ (BAR1)     │  │
│                                              └────────────┘  │
│                                                              │
│  P2P DMA 성공 조건:                                          │
│  - GPU와 NVMe가 동일 PCIe root complex 또는 switch 하위    │
│  - IOMMU가 P2P를 허용하는 설정                              │
│  - PCIe ACS (Access Control Services) 적절히 설정           │
│  - 최신 nvidia-fs.ko 드라이버                               │
└─────────────────────────────────────────────────────────────┘
```

---

## 7. NVIDIA GPUDirect Storage (GDS) 심층 분석

### 7.1 GDS 내부 동작 상세

```
┌─────────────────────────────────────────────────────────────────┐
│ cuFileRead(fh, gpu_buf, size, file_offset, buf_offset) 호출 시 │
│                                                                  │
│ Step 1: Buffer 등록 확인                                        │
│   - cuFileBufRegister()로 GPU buffer가 등록되었는지 확인        │
│   - GPU BAR1 physical address 조회                              │
│   - DMA mapping 생성 (GPU physical addr → PCIe address)        │
│                                                                  │
│ Step 2: P2P 경로 판단                                           │
│   ┌─────────────────────────────────────────────┐               │
│   │ nvidia-fs.ko 내부 P2P 토폴로지 검사         │               │
│   │                                              │               │
│   │ GPU와 NVMe가 P2P 가능한가?                  │               │
│   │   ├─ Yes: Direct P2P DMA 경로 사용          │               │
│   │   │   NVMe DMA target = GPU BAR1 addr       │               │
│   │   │                                          │               │
│   │   └─ No: Compatibility Mode (bounce buffer)  │               │
│   │       NVMe → CPU DRAM → GPU (2단계 DMA)     │               │
│   │       (API는 동일, 내부 경로만 다름)         │               │
│   └─────────────────────────────────────────────┘               │
│                                                                  │
│ Step 3: I/O 실행                                                │
│   ┌──── P2P Mode ────┐  ┌── Compatibility Mode ──┐             │
│   │                   │  │                         │             │
│   │ NVMe driver에     │  │ NVMe → bounce buf      │             │
│   │ I/O 제출:         │  │ (CPU DRAM)              │             │
│   │                   │  │     │                   │             │
│   │ DMA dest addr =   │  │ bounce buf → GPU VRAM  │             │
│   │ GPU BAR1 addr     │  │ (cudaMemcpy async)     │             │
│   │                   │  │                         │             │
│   │ NVMe controller   │  │ 2단계 DMA              │             │
│   │ → PCIe P2P TLP    │  │ (여전히 CPU 경유보다   │             │
│   │ → GPU BAR1에 직접 │  │  효율적: 관리 자동화)  │             │
│   │   DMA write       │  │                         │             │
│   └───────────────────┘  └─────────────────────────┘             │
│                                                                  │
│ Step 4: Completion                                              │
│   - DMA 완료 → cuFile callback/동기 반환                        │
│   - GPU에서 바로 데이터 사용 가능                               │
└─────────────────────────────────────────────────────────────────┘
```

### 7.2 PCIe 토폴로지와 P2P DMA

```
◆ 최적: GPU와 NVMe가 동일 PCIe Switch 하위

  ┌────────────┐
  │    CPU     │
  │ Root Cmplx │
  └─────┬──────┘
        │
  ┌─────┴──────┐
  │ PCIe Switch│
  ├────┬───────┤
  │    │       │
  ▼    ▼       ▼
 GPU  NVMe0  NVMe1

  P2P DMA: NVMe → Switch → GPU (CPU Root Complex 미경유)
  Latency: 최소, BW: PCIe link speed


◆ 차선: 동일 CPU Root Complex 하위

  ┌──────────────────┐
  │      CPU         │
  │   Root Complex   │
  │   ┌────┬────┐   │
  └───┤    │    ├───┘
      │    │    │
      ▼    ▼    ▼
     GPU  NVMe  NIC

  P2P DMA: NVMe → Root Complex → GPU
  Root Complex가 P2P를 지원해야 함 (최신 Intel/AMD 대부분 지원)


◆ 비최적: 다른 CPU Socket (Cross-NUMA)

  ┌─────────┐    QPI/UPI    ┌─────────┐
  │  CPU 0  │◄────────────►│  CPU 1  │
  │  Root 0 │               │  Root 1 │
  └──┬──────┘               └────┬────┘
     │                           │
    GPU                        NVMe

  P2P DMA: NVMe → Root1 → QPI → Root0 → GPU
  추가 latency: QPI hop (~100ns+)
  → GDS Compatibility Mode로 fallback할 수 있음


◆ P2P 지원 확인:

  # NVIDIA GDS 토폴로지 확인
  gdscheck -p

  # nvidia-smi topology
  nvidia-smi topo -m

  # PCIe P2P bandwidth 테스트
  /usr/local/cuda/samples/1_Utilities/p2pBandwidthLatencyTest/p2pBandwidthLatencyTest
```

### 7.3 GDS 프로그래밍 모델

```c
/* GDS cuFile API 사용 예시 */

#include <cufile.h>

int main() {
    // 1. GDS 드라이버 초기화
    CUfileError_t status;
    status = cuFileDriverOpen();

    // 2. 파일 열기 (O_DIRECT 필수)
    int fd = open("/mnt/nvme/data.bin", O_RDWR | O_DIRECT);

    // 3. cuFile 핸들 등록
    CUfileDescr_t descr;
    CUfileHandle_t fh;
    descr.handle.fd = fd;
    descr.type = CU_FILE_HANDLE_TYPE_OPAQUE_FD;
    cuFileHandleRegister(&fh, &descr);

    // 4. GPU 버퍼 할당 + GDS 등록
    void* gpu_buf;
    cudaMalloc(&gpu_buf, FILE_SIZE);
    cuFileBufRegister(gpu_buf, FILE_SIZE, 0);

    // 5. 직접 읽기: NVMe → GPU VRAM (P2P DMA)
    ssize_t bytes_read = cuFileRead(
        fh,           // cuFile handle
        gpu_buf,      // GPU device pointer (destination)
        FILE_SIZE,    // size
        0,            // file offset
        0             // buffer offset
    );

    // 6. GPU에서 바로 연산 가능!
    my_kernel<<<grid, block>>>((float*)gpu_buf);

    // 7. GPU → NVMe 쓰기도 가능
    ssize_t bytes_written = cuFileWrite(
        fh,           // cuFile handle
        gpu_buf,      // GPU device pointer (source)
        FILE_SIZE,    // size
        0,            // file offset
        0             // buffer offset
    );

    // Cleanup
    cuFileBufDeregister(gpu_buf);
    cudaFree(gpu_buf);
    cuFileHandleDeregister(fh);
    close(fd);
    cuFileDriverClose();

    return 0;
}
```

### 7.4 GDS Batch API와 비동기 I/O

```c
/* GDS Batch I/O: 다수 I/O를 한 번에 제출 */

#define BATCH_SIZE 128

CUfileIOParams_t io_params[BATCH_SIZE];
CUfileIOEvents_t io_events[BATCH_SIZE];

// Batch I/O 설정
for (int i = 0; i < BATCH_SIZE; i++) {
    io_params[i].mode = CUFILE_BATCH;
    io_params[i].fh = fh;
    io_params[i].u.batch.devPtr_base = gpu_buf;
    io_params[i].u.batch.devPtr_offset = i * CHUNK_SIZE;
    io_params[i].u.batch.size = CHUNK_SIZE;
    io_params[i].u.batch.file_offset = i * CHUNK_SIZE;
    io_params[i].opcode = CUFILE_READ;
}

// Batch 제출 (비동기)
cuFileBatchIOSetUp(&batch_handle, BATCH_SIZE);
cuFileBatchIOSubmit(batch_handle, BATCH_SIZE, io_params, 0);

// 완료 대기
int completed = 0;
while (completed < BATCH_SIZE) {
    int nr = cuFileBatchIOGetStatus(
        batch_handle, BATCH_SIZE - completed,
        &io_events[completed], NULL
    );
    completed += nr;
}

/*
 * Batch API 장점:
 * - 다수 I/O를 single API call로 제출
 * - NVMe queue depth를 효율적으로 활용
 * - GPU의 다수 스트림과 동시 사용 가능
 * - I/O 당 API call overhead 감소
 */
```

### 7.5 GDS 성능 특성

```
┌───────────────────────────────────────────────────────────────────┐
│ GDS 성능 비교 (PCIe Gen4, NVMe Gen4 x4 SSD)                      │
│                                                                    │
│ Sequential Read Throughput (1MB I/O):                              │
│                                                                    │
│   전통 (read+cudaMemcpy):   ████████████░░░░░░░░  ~3.5 GB/s      │
│   GDS Compat Mode:          ██████████████░░░░░░  ~4.5 GB/s      │
│   GDS P2P Mode:             ███████████████████░  ~6.2 GB/s      │
│                                                    │               │
│                                              NVMe HW limit        │
│                                                                    │
│ Random Read IOPS (4KB I/O):                                       │
│                                                                    │
│   전통 (read+cudaMemcpy):   ████████░░░░░░░░░░░  ~200K IOPS     │
│   GDS Compat Mode:          ███████████░░░░░░░░░  ~350K IOPS     │
│   GDS P2P Mode:             ████████████████░░░░  ~600K IOPS     │
│                                                                    │
│ CPU 사용률 (1GB/s 전송 중):                                       │
│                                                                    │
│   전통:       ████████████████████  ~45% (한 코어 기준)           │
│   GDS Compat: ████████████░░░░░░░░  ~25%                         │
│   GDS P2P:    ████░░░░░░░░░░░░░░░░  ~8%                          │
│                                                                    │
│ GPU Idle Time (학습 중 데이터 로딩 대기):                          │
│                                                                    │
│   전통:       ████████████████░░░░  ~35% idle                    │
│   GDS:        ████████░░░░░░░░░░░░  ~15% idle                    │
│                                                                    │
│ Multi-GPU Scaling (4x GPU, 4x NVMe):                             │
│                                                                    │
│   전통:       ██████████████░░░░░░  ~10 GB/s (CPU bottleneck)    │
│   GDS P2P:    ████████████████████  ~24 GB/s (near-linear)       │
│   → Multi-GPU 환경에서 GDS 효과가 극대화                         │
└───────────────────────────────────────────────────────────────────┘
```

---

## 8. GPU-Initiated I/O: BaM과 차세대 기술

### 8.1 BaM (Big accelerator Memory) 개념

```
┌─────────────────────────────────────────────────────────────────┐
│ 기존 GDS의 한계:                                                 │
│                                                                  │
│  CPU가 I/O를 제어 (cuFileRead 호출 = CPU에서 실행)              │
│    │                                                             │
│    ├─ GPU는 데이터 도착을 기다려야 함                           │
│    ├─ CPU-GPU 간 synchronization 오버헤드                       │
│    ├─ GPU 스레드의 데이터 접근 패턴을 CPU가 미리 알 수 없음    │
│    └─ Fine-grained I/O (작은 크기, 불규칙 패턴)에 비효율        │
│                                                                  │
│ BaM의 혁신:                                                      │
│                                                                  │
│  "GPU 스레드(warp)가 직접 NVMe에 I/O를 요청하자"               │
│                                                                  │
│  ┌──────────────────────────────────┐                            │
│  │ GPU                              │                            │
│  │                                  │                            │
│  │  Warp 0: load(addr)             │                            │
│  │    → addr가 SSD에 매핑된 주소   │                            │
│  │    → TLB miss → GPU page fault  │                            │
│  │    → BaM runtime이 NVMe cmd     │                            │
│  │      생성 + submit              │                            │
│  │    → NVMe → GPU VRAM으로 DMA   │                            │
│  │    → Warp resume                │                            │
│  │                                  │                            │
│  │  핵심: GPU 코드에서 포인터 역참조만 하면                    │
│  │        자동으로 SSD에서 데이터 로딩!                         │
│  │        (Demand paging과 유사)                                │
│  └──────────────────────────────────┘                            │
│                                                                  │
│  기존 방식:  CPU가 I/O 제출 → 데이터 도착 → GPU 연산           │
│  BaM:       GPU 연산 중 필요할 때 자동으로 I/O → 연산 계속     │
└─────────────────────────────────────────────────────────────────┘
```

### 8.2 BaM 아키텍처

```
┌─────────────────────────────────────────────────────────────────┐
│ BaM System Architecture                                          │
│                                                                  │
│  ┌───────────────────────────────────────────┐                   │
│  │ GPU                                        │                   │
│  │  ┌────────────────────────────────┐       │                   │
│  │  │ User Kernel (GPU compute)       │       │                   │
│  │  │  ptr = bam_array[index];        │       │                   │
│  │  └──────────┬─────────────────────┘       │                   │
│  │             │ page fault                   │                   │
│  │  ┌──────────▼─────────────────────┐       │                   │
│  │  │ BaM Runtime (GPU-side)          │       │                   │
│  │  │                                 │       │                   │
│  │  │  ① Virtual → SSD addr 변환     │       │                   │
│  │  │  ② NVMe SQE 작성 (on GPU)     │       │                   │
│  │  │  ③ Doorbell write (PCIe MMIO)  │       │                   │
│  │  │  ④ CQ Polling (GPU thread)     │       │                   │
│  │  │  ⑤ Page cache 관리 (GPU VRAM) │       │                   │
│  │  └──────────┬─────────────────────┘       │                   │
│  │             │                              │                   │
│  │  ┌──────────▼─────────────────────┐       │                   │
│  │  │ GPU-side NVMe Queue             │       │                   │
│  │  │  SQ/CQ in GPU VRAM or SSD CMB  │       │                   │
│  │  └──────────┬─────────────────────┘       │                   │
│  └─────────────┼─────────────────────────────┘                   │
│                │ PCIe                                             │
│  ┌─────────────▼─────────────────────────────┐                   │
│  │ NVMe SSD                                   │                   │
│  │  - GPU가 직접 doorbell write               │                   │
│  │  - P2P DMA: SSD → GPU VRAM                │                   │
│  │  - CQE를 GPU가 읽을 수 있는 위치에 작성   │                   │
│  └───────────────────────────────────────────┘                   │
│                                                                  │
│  CPU의 역할: 초기 설정만 (SQ/CQ 생성, BAR 매핑)                │
│  이후 I/O 경로에서 CPU 완전 배제!                               │
└─────────────────────────────────────────────────────────────────┘
```

### 8.3 BaM vs GDS 비교

```
┌──────────────────────────────────────────────────────────────────┐
│                    GDS vs BaM 비교                                 │
│                                                                   │
│  ┌───────────────┬──────────────────┬──────────────────────┐     │
│  │               │ GDS              │ BaM                   │     │
│  ├───────────────┼──────────────────┼──────────────────────┤     │
│  │ I/O 제어      │ CPU (cuFile API) │ GPU (warp-level)     │     │
│  │ I/O 제출      │ CPU → NVMe drv  │ GPU → NVMe doorbell  │     │
│  │ I/O 완료 감지 │ CPU (IRQ/poll)   │ GPU (CQ polling)     │     │
│  │ CPU 관여      │ 제어 경로        │ 초기 설정만          │     │
│  │ 데이터 경로   │ NVMe→GPU (P2P)  │ NVMe→GPU (P2P)      │     │
│  │ 접근 패턴     │ Bulk (대량 전송) │ Fine-grained (소량)  │     │
│  │ 프로그래밍    │ cuFile API       │ 포인터 역참조        │     │
│  │ I/O 크기      │ 대 (MB 단위)     │ 소~대 (KB~MB)       │     │
│  │ I/O 결정 시점 │ CPU 사전 결정    │ GPU 런타임 결정      │     │
│  │ 캐시 관리     │ 없음 (direct)    │ GPU VRAM 캐시        │     │
│  │ GPU idle      │ I/O 대기 가능    │ 최소 (on-demand)     │     │
│  │ 성숙도        │ GA (상용)        │ 연구/프로토타입      │     │
│  │ HW 요구사항   │ NVIDIA GPU       │ NVIDIA GPU + 수정    │     │
│  ├───────────────┼──────────────────┼──────────────────────┤     │
│  │ 최적 워크로드 │ 순차적, 대량     │ 불규칙, 데이터 의존  │     │
│  │               │ ETL, 학습 데이터 │ 그래프, 추천, 검색   │     │
│  └───────────────┴──────────────────┴──────────────────────┘     │
│                                                                   │
│  BaM이 특히 유리한 경우:                                          │
│  - Graph Analytics: 불규칙 접근 패턴, 접근 대상을 미리 알 수 없음│
│  - Recommender Systems: 임베딩 테이블 > GPU 메모리               │
│  - Database Queries: WHERE 조건에 따라 접근 범위 변동             │
│  - Hash Table Lookup: 키 기반 불규칙 접근                        │
└──────────────────────────────────────────────────────────────────┘
```

### 8.4 차세대 GPU-Storage 기술 연구

```
1. NVIDIA Unified Memory + Storage
   ─────────────────────────────────
   - cudaMallocManaged() 확장 → Storage까지 통합 주소 공간
   - GPU page fault → 자동으로 Storage에서 로딩
   - SW-managed: 드라이버 레벨 page migration
   - 현재: GPU↔CPU DRAM 간만 동작 (Storage 미포함)
   - 미래: GPU↔CPU DRAM↔NVMe 자동 tiering

2. SmartNIC/DPU + GPU 연동
   ────────────────────────
   - NVIDIA BlueField DPU가 NVMe-oF + GPU 전송 관리
   - DPU가 Storage I/O를 처리 → CPU 완전 해방
   - GPU에서 DPU로 직접 I/O 요청 (via GPUDirect RDMA)

3. NVMe CMB/PMR + GPU
   ────────────────────
   - NVMe CMB를 GPU-accessible하게 매핑
   - SQ/CQ를 GPU에서 직접 접근 → BaM의 HW 지원 버전
   - CMB를 GPU↔SSD 간 공유 scratch pad로 활용

4. CXL + GPU
   ──────────
   - CXL 3.0: GPU가 CXL.mem으로 확장 메모리 직접 접근
   - GPU Memory = Local HBM + CXL DRAM + CXL-backed NVMe
   - 단일 주소 공간에서 투명하게 tiering
   - 현재: 표준화 + 초기 HW 개발 중
```

---

## 9. AMD 및 Intel GPU의 Storage 접근

### 9.1 AMD ROCm 생태계

```
┌─────────────────────────────────────────────────────────────────┐
│ AMD GPU → NVMe 접근 기술 현황                                    │
│                                                                  │
│ 1. DirectGMA (Direct Graphics Memory Access)                    │
│    ─────────────────────────────────────────                    │
│    - GPUDirect RDMA의 AMD 대응 기술                             │
│    - GPU VRAM을 다른 PCIe 디바이스에 노출                       │
│    - P2P DMA 지원 (NIC ↔ GPU, NVMe ↔ GPU)                     │
│    - 주로 전문 GPU (Instinct MI 시리즈)에서 지원               │
│                                                                  │
│ 2. ROCm + XDNA/KFD                                             │
│    ──────────────────                                           │
│    - AMD GPU의 open-source compute stack                        │
│    - KFD (Kernel Fusion Driver)가 GPU 메모리 관리              │
│    - P2P DMA를 통한 NVMe → GPU 가능 (제한적)                  │
│    - GDS 수준의 통합 API는 아직 부재                            │
│                                                                  │
│ 3. AMD의 현재 접근법                                            │
│    ─────────────────                                            │
│    - hipMemcpy + POSIX I/O: 전통적 CPU bounce buffer           │
│    - P2P DMA: ROCm의 내부 메커니즘으로 부분 지원               │
│    - NVIDIA GDS 대비 성숙도 낮음                                │
│    - 커뮤니티/파트너 (Samsung 등)와 협력 중                    │
│                                                                  │
│ 4. AMD의 차별화 시도                                            │
│    ─────────────────                                            │
│    ┌─────────────────────────────────────────────┐              │
│    │ AMD Instinct MI300X                          │              │
│    │  - 192GB HBM3 (업계 최대)                   │              │
│    │  - 대용량 HBM → Storage 접근 빈도 감소      │              │
│    │  - "메모리를 크게 하여 I/O 문제를 줄이자"   │              │
│    │                                              │              │
│    │ AMD CXL 지원                                 │              │
│    │  - EPYC CPU의 CXL 지원으로 메모리 확장      │              │
│    │  - GPU ↔ CXL Memory 경로 개발 중           │              │
│    │  - MI300이 CXL-ready 아키텍처               │              │
│    └─────────────────────────────────────────────┘              │
│                                                                  │
│ AMD vs NVIDIA GPU-Storage 비교:                                  │
│  ┌────────────────┬─────────────────┬──────────────────┐        │
│  │                │ NVIDIA           │ AMD              │        │
│  ├────────────────┼─────────────────┼──────────────────┤        │
│  │ Direct Storage │ GDS (GA)        │ 공식 API 없음    │        │
│  │ P2P DMA       │ GPUDirect       │ DirectGMA        │        │
│  │ API           │ cuFile          │ hipFile (없음)   │        │
│  │ 성숙도        │ 높음            │ 낮음 (개발중)    │        │
│  │ 파트너 생태계 │ 넓음            │ 성장중           │        │
│  │ HBM 용량      │ 80GB (H100)     │ 192GB (MI300X)  │        │
│  │ 전략          │ SW 최적화       │ HW 용량 확장     │        │
│  └────────────────┴─────────────────┴──────────────────┘        │
└─────────────────────────────────────────────────────────────────┘
```

### 9.2 Intel GPU (Xe/Arc) 및 oneAPI

```
┌─────────────────────────────────────────────────────────────────┐
│ Intel GPU → NVMe 접근                                            │
│                                                                  │
│ 1. Intel oneAPI + Level Zero                                    │
│    ────────────────────────                                     │
│    - Level Zero API: 저수준 GPU 제어                            │
│    - P2P DMA 지원 (Intel GPU ↔ NVMe)                          │
│    - 아직 GDS 수준의 Storage API 없음                          │
│                                                                  │
│ 2. Intel의 차별화: CXL 리더십                                   │
│    ──────────────────────────                                   │
│    ┌─────────────────────────────────────────────┐              │
│    │ Intel Xeon + Gaudi + CXL                     │              │
│    │                                              │              │
│    │  Xeon CPU ──(CXL)──► CXL Memory Pool        │              │
│    │     │                    │                   │              │
│    │     └──(PCIe)─►     ◄───┘                   │              │
│    │              Gaudi GPU                       │              │
│    │                                              │              │
│    │  Gaudi가 CXL Memory에 접근 가능 (미래)      │              │
│    │  → GPU의 메모리 계층에 CXL 통합             │              │
│    │  → NVMe-backed CXL로 Storage 접근          │              │
│    └─────────────────────────────────────────────┘              │
│                                                                  │
│ 3. Windows DirectStorage (게임/클라이언트)                      │
│    ──────────────────────────────────────                       │
│    - Microsoft + GPU 벤더 협력                                  │
│    - NVMe → GPU VRAM 직접 전송 (GPU 디컴프레션)               │
│    - 게임 에셋 로딩 최적화                                     │
│    - NVIDIA RTX IO, AMD SmartAccess Storage                    │
│    - 서버용 GDS와 목적은 유사하나 클라이언트 특화              │
└─────────────────────────────────────────────────────────────────┘
```

---

## 10. CPU vs GPU NVMe 접근 종합 비교

### 10.1 기술 계보 대비표

```
┌────────────────────────────────────────────────────────────────────────┐
│           CPU → NVMe                    GPU → NVMe                     │
│           ──────────                    ──────────                     │
│ 문제 정의  SW stack overhead가 크다     CPU 경유 bounce buffer가 느리다│
│                                                                        │
│ Gen 0      Sync I/O (read/write)        CPU 경유 (read + cudaMemcpy)  │
│ 해결       "비동기로 하자"              "P2P DMA로 가자"              │
│                                                                        │
│ Gen 1      libaio (async batch)         GPUDirect RDMA (NIC↔GPU P2P) │
│ 해결       "syscall도 줄이자"           "NVMe도 P2P 하자"            │
│                                                                        │
│ Gen 2      io_uring (shared ring,       GDS (NVMe→GPU P2P DMA)       │
│            SQPOLL, polling)             cuFile API, nvidia-fs.ko       │
│ 해결       "커널을 아예 빼자"           "CPU 제어도 빼자"            │
│                                                                        │
│ Gen 3      SPDK (user-space driver)     BaM (GPU-initiated I/O)       │
│            커널 완전 바이패스            GPU warp이 직접 NVMe 제어     │
│ 해결       "Memory처럼 접근하자"        "CXL로 통합하자"             │
│                                                                        │
│ Gen 4+     CXL + DAX                    CXL + GPU Unified Memory      │
│            (load/store, ~150ns)         (GPU ld/st → CXL → NVMe)     │
│                                                                        │
│ 공통 흐름:                                                             │
│   중간 계층 제거 → 직접 접근 → 주소 공간 통합 → Memory Semantic      │
└────────────────────────────────────────────────────────────────────────┘
```

### 10.2 정량 비교표

```
┌──────────────────────────────────────────────────────────────────────┐
│ 4KB Random Read, PCIe Gen4, NVMe Gen4 x4 SSD 기준                    │
│                                                                       │
│                        Latency    BW (seq)    CPU      GPU     성숙   │
│                        (4KB rr)   (1MB seq)   사용량   idle    도     │
│ ─────────────────────────────────────────────────────────────────── │
│ CPU: sync read          ~10μs     ~3 GB/s    높음     N/A     ★★★  │
│ CPU: libaio             ~6μs      ~6 GB/s    중간     N/A     ★★★  │
│ CPU: io_uring (full)    ~3.5μs    ~6.5 GB/s  낮음     N/A     ★★★  │
│ CPU: SPDK              ~2.5μs    ~7 GB/s    1코어    N/A     ★★☆  │
│                                                                       │
│ GPU: read+cudaMemcpy   ~15μs     ~3.5 GB/s  높음     높음    ★★★  │
│ GPU: GDS compat        ~10μs     ~4.5 GB/s  중간     중간    ★★☆  │
│ GPU: GDS P2P           ~5μs      ~6.2 GB/s  낮음     낮음    ★★☆  │
│ GPU: BaM (연구)        ~4μs      ~5 GB/s    없음     최소    ★☆☆  │
│                                                                       │
│ 미래:                                                                 │
│ CPU: CXL load/store    ~0.3μs    ~20 GB/s   없음     N/A     ☆☆☆  │
│ GPU: CXL + Unified     ~0.5μs    ~20 GB/s   없음     없음    ☆☆☆  │
│ ─────────────────────────────────────────────────────────────────── │
│                                                                       │
│ Multi-Device Scaling (4x NVMe, 1/4 GPU):                            │
│                                                                       │
│ CPU: io_uring           ~25 GB/s   (CPU: 4+ cores 필요)              │
│ GPU: GDS P2P            ~24 GB/s   (CPU: 1 core 충분)               │
│ GPU: BaM                ~22 GB/s   (CPU: 0 core)                     │
│                                                                       │
│ → Multi-GPU + Multi-NVMe 환경에서 GDS 가치 극대화                   │
│ → CPU는 compute에, GPU는 compute + I/O에 전념 가능                  │
└──────────────────────────────────────────────────────────────────────┘
```

### 10.3 SW Stack 비교

```
┌───────────────────────────────────────────────────────────────────┐
│                                                                    │
│  CPU Path (io_uring)          │  GPU Path (GDS)                   │
│  ─────────────────            │  ──────────────                   │
│                               │                                    │
│  Application                  │  CUDA Application                 │
│      │                        │      │                             │
│  io_uring SQE                 │  cuFileRead()                     │
│      │                        │      │                             │
│  Kernel: io_uring worker      │  nvidia-fs.ko                     │
│      │                        │      │                             │
│  Block Layer (minimal)        │  (Block Layer bypass)             │
│      │                        │      │                             │
│  NVMe Driver                  │  NVMe Driver                      │
│      │                        │      │                             │
│  NVMe SSD                     │  NVMe SSD                         │
│      │                        │      │                             │
│  DMA → CPU DRAM              │  P2P DMA → GPU VRAM              │
│                               │                                    │
│                               │                                    │
│  CPU Path (SPDK)              │  GPU Path (BaM)                   │
│  ───────────────              │  ──────────────                   │
│                               │                                    │
│  Application                  │  GPU Kernel                       │
│      │                        │      │                             │
│  SPDK NVMe Driver             │  BaM Runtime (on GPU)             │
│  (user-space)                 │      │                             │
│      │                        │  GPU-side NVMe Queue              │
│  NVMe SSD                     │      │                             │
│  (vfio-pci)                   │  NVMe SSD                         │
│      │                        │  (PCIe BAR + doorbell)            │
│  DMA → User-space buffer     │      │                             │
│                               │  P2P DMA → GPU VRAM              │
│                               │                                    │
│  공통점:                       │                                    │
│  - 커널 바이패스              │  - 커널 바이패스                  │
│  - Polling 기반               │  - Polling 기반                   │
│  - NVMe HW queue 직접 관리   │  - NVMe HW queue 직접 관리       │
└───────────────────────────────────────────────────────────────────┘
```

---

## 11. Unified Memory + Storage 아키텍처

### 11.1 미래 비전: 단일 주소 공간

```
┌─────────────────────────────────────────────────────────────────────┐
│ 궁극적 목표: Unified Address Space                                   │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │                 Global Virtual Address Space                   │   │
│  │                                                               │   │
│  │  0x0000...     0x1000...     0x8000...     0xF000...         │   │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐       │   │
│  │  │ CPU DRAM │ │ GPU HBM  │ │ CXL Mem  │ │ NVMe SSD │       │   │
│  │  │ (DDR5)   │ │ (VRAM)   │ │ (DRAM/   │ │ (backing │       │   │
│  │  │          │ │          │ │  Persist) │ │  store)  │       │   │
│  │  └──────────┘ └──────────┘ └──────────┘ └──────────┘       │   │
│  │   ~80ns        ~100ns*      ~170-300ns    ~2,000-10,000ns   │   │
│  │                                                               │   │
│  │  * GPU HBM은 GPU core에서 ~100ns, CPU에서 ~300ns+            │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
│  CPU 코드:                                                          │
│    value = *(unified_ptr + offset);                                 │
│    // HW/SW가 자동으로 최적 메모리 계층에서 데이터 제공            │
│    // Hot → DDR5, Warm → CXL, Cold → NVMe (page migration)        │
│                                                                      │
│  GPU 코드:                                                          │
│    value = unified_ptr[tid];                                        │
│    // GPU page fault → HBM miss → CXL → NVMe 자동 fetch          │
│    // Frequently used → HBM으로 promote                             │
│                                                                      │
│  필요 기술:                                                          │
│  - CXL 3.0+ (GPU CXL 지원)                                        │
│  - Unified page table (CPU + GPU 공유)                              │
│  - HW-assisted page migration                                       │
│  - Intelligent tiering controller                                   │
│  - Coherent memory fabric                                           │
└─────────────────────────────────────────────────────────────────────┘
```

### 11.2 기술 수렴 로드맵

```
현재 (2024-2026):
──────────────────
  CPU ── DDR5 ── [CPU 전용]
  CPU ── PCIe ── NVMe SSD [io_uring/SPDK]
  GPU ── HBM ── [GPU 전용]
  GPU ── PCIe ── CPU ── NVMe [GDS로 개선 중]
  CXL 1.1/2.0 초기 제품 (CPU only)

근미래 (2026-2028):
──────────────────
  CPU ── DDR5 ────────── [CPU 전용]
  CPU ── CXL 2.0 ─────── CXL Memory Pool [공유 가능]
  CPU ── PCIe ── NVMe SSD [io_uring passthru]
  GPU ── HBM ────────── [GPU 전용]
  GPU ── PCIe ── NVMe [GDS 2.0, mature P2P]
  GPU ── PCIe ── CXL Memory [초기 연동]
  BaM-like GPU-initiated I/O 초기 상용화

중장기 (2028-2030+):
──────────────────
  ┌──────┐    ┌──────────────────────────────┐
  │ CPU  │    │      Memory Fabric           │
  │      ├────┤  DDR5 │ CXL DRAM │ CXL NVM  │
  └──────┘    │       │          │           │
  ┌──────┐    │       │ (shared) │ (tiered)  │
  │ GPU  ├────┤       │          │           │
  │      │    └──────────────────────────────┘
  └──────┘                │
                    ┌─────┴──────┐
                    │ NVMe SSD   │ (backing store)
                    └────────────┘

  - CPU와 GPU가 동일 Memory Fabric 공유
  - CXL Switch로 다대다 연결
  - NVMe는 cold data backing + burst capacity
  - 자동 tiering: HBM ↔ DDR ↔ CXL ↔ NVMe
```

---

## 12. 사용 시나리오별 권장 기술

### 12.1 워크로드별 최적 선택

```
┌──────────────────────────────────────────────────────────────────────┐
│ 워크로드                    │ CPU 기술           │ GPU 기술          │
├─────────────────────────────┼────────────────────┼───────────────────┤
│ AI/ML 학습 데이터 로딩       │ -                  │ GDS P2P (최우선) │
│ (순차, 대량, 반복)          │                    │ → BaM (미래)     │
│                             │                    │                   │
│ AI 추론 (모델 로딩)         │ -                  │ GDS + mmap       │
│                             │                    │                   │
│ 고성능 스토리지 서비스       │ SPDK (최우선)      │ -                │
│ (NVMe-oF target 등)        │ io_uring passthru  │                   │
│                             │                    │                   │
│ 데이터베이스 (OLTP)         │ io_uring           │ -                │
│                             │ (SQPOLL+poll)      │                   │
│                             │                    │                   │
│ 데이터 분석 (OLAP)          │ io_uring           │ GDS              │
│                             │                    │ (GPU 가속 분석)  │
│                             │                    │                   │
│ 비디오 트랜스코딩           │ -                  │ GDS              │
│ (실시간 스트리밍)           │                    │ (연속 데이터)    │
│                             │                    │                   │
│ 과학 시뮬레이션 (HPC)       │ SPDK / io_uring    │ GDS + BaM (미래) │
│ (체크포인트 + 데이터)       │                    │                   │
│                             │                    │                   │
│ 그래프 분석                  │ mmap + io_uring    │ BaM (미래)       │
│ (불규칙 접근)               │                    │ GDS + SW prefetch│
│                             │                    │                   │
│ CDN / 캐시 서버             │ io_uring + mmap    │ -                │
│ (많은 소형 파일)            │                    │                   │
│                             │                    │                   │
│ 범용 서버                    │ io_uring           │ -                │
│                             │                    │                   │
│ In-memory 확장              │ CXL Memory         │ CXL + GPU (미래) │
│ (메모리 용량 부족)          │                    │                   │
└──────────────────────────────────────────────────────────────────────┘
```

### 12.2 기술 선택 의사결정 트리

```
Q: GPU를 사용하는가?
├─ No → CPU-only 기술 선택
│   Q: 커널 디바이스 관리가 필요한가?
│   ├─ Yes → io_uring (SQPOLL + fixedbuf + polling)
│   └─ No  → SPDK (최대 성능, 전용 코어 투자 가능 시)
│
└─ Yes → GPU+Storage 기술 선택
    Q: 데이터 접근 패턴은?
    ├─ 순차/대량 (AI 학습, 비디오) → GDS P2P
    │   Q: PCIe 토폴로지가 P2P 가능?
    │   ├─ Yes → GDS P2P mode (최적)
    │   └─ No  → GDS Compat mode (차선) + 토폴로지 재설계 고려
    │
    ├─ 불규칙/소량 (그래프, 추천) → BaM (가능 시) 또는 GDS + SW prefetch
    │
    └─ 혼합 → GDS + cuFile Batch API
        Q: Multi-GPU?
        ├─ Yes → GDS + GPU-NVMe NUMA alignment 최적화
        └─ No  → GDS 기본 설정으로 충분
```

---

## 참고 자료

### CPU → NVMe
- io_uring: https://kernel.dk/io_uring.pdf
- SPDK: https://spdk.io/doc/
- io_uring NVMe Passthrough: https://lwn.net/Articles/889599/

### GPU → NVMe
- NVIDIA GPUDirect Storage: https://docs.nvidia.com/gpudirect-storage/
- cuFile API Reference: https://docs.nvidia.com/cuda/cufile-api/
- GDS Best Practices: https://docs.nvidia.com/gpudirect-storage/best-practices-guide/
- BaM Paper: "BaM: A Case for Enabling Fine-grain High Throughput GPU-Orchestrated Access to Storage" (ISCA 2022)
- AMD ROCm: https://rocm.docs.amd.com/
- Intel oneAPI: https://www.intel.com/content/www/us/en/developer/tools/oneapi/

### 통합 아키텍처
- CXL Specification: https://www.computeexpresslink.org/
- NVIDIA Magnum IO: https://developer.nvidia.com/magnum-io
- Microsoft DirectStorage: https://devblogs.microsoft.com/directx/directstorage-api-available-on-pc/

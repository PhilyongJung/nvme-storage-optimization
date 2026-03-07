# NVMe SSD 성능에 영향을 주는 숨은 요소들 (Hidden Performance Factors)

## 목차
1. [전체 요소 맵: 이미 다룬 것 vs 새로 발견한 것](#1-전체-요소-맵)
2. [심각도 순위: Top 20 숨은 성능 영향 요소](#2-심각도-순위)
3. [HW/BIOS 레벨 요소](#3-hwbios-레벨-요소)
4. [PCIe 레벨 요소](#4-pcie-레벨-요소)
5. [SSD 내부 요소](#5-ssd-내부-요소)
6. [OS/커널 레벨 요소](#6-os커널-레벨-요소)
7. [SW/Application 레벨 요소](#7-swapplication-레벨-요소)
8. [진단 스크립트: 숨은 요소 종합 점검](#8-진단-스크립트)
9. [최적화 원클릭 스크립트](#9-최적화-원클릭-스크립트)
10. [02번 스크립트 추가 권장 항목](#10-02번-스크립트-추가-권장-항목)

---

## 1. 전체 요소 맵

### 1.1 기존 프로젝트에서 이미 다룬 요소 (01~09)

```
┌─────────────────────────────────────────────────────────────────────┐
│ 이미 다룬 요소 (기존 문서/스크립트)                                │
│                                                                     │
│ ✅ I/O Engine (libaio, io_uring, SPDK)          → 01, 04          │
│ ✅ NUMA 토폴로지 & Affinity                      → 01, 02, 03     │
│ ✅ PCIe 토폴로지 & Link Speed                    → 02             │
│ ✅ PCIe MPS / MRRS                               → 02 (신규 추가)│
│ ✅ NVMe Queue Pair & IRQ 매핑                    → 01, 02, 03     │
│ ✅ I/O Scheduler (none, mq-deadline, kyber)      → 01, 03, 04     │
│ ✅ Block Device Settings (rq_affinity, nomerges) → 02, 03         │
│ ✅ CPU Governor (performance)                     → 02, 03         │
│ ✅ HugePages (2MB, 1GB)                          → 01, 02         │
│ ✅ Kernel sysctl Parameters                      → 02, 03         │
│ ✅ NVMe Module Parameters (poll/write queues)    → 02, 03         │
│ ✅ Kernel Version 영향                           → 09             │
│ ✅ Memory DIMM Configuration                     → 02 (신규 추가)│
│ ✅ irqbalance Service                            → 02, 03         │
│ ✅ GDS / GPUDirect Storage                       → 07             │
│ ✅ CXL / DAX / PMEM                             → 06             │
└─────────────────────────────────────────────────────────────────────┘
```

### 1.2 이번에 새로 발견한 숨은 요소 ★

```
┌─────────────────────────────────────────────────────────────────────┐
│ 새로 발견한 숨은 성능 영향 요소 ★                                  │
│                                                                     │
│  ── HW / BIOS 레벨 ──                                              │
│  ★ CPU C-States (Deep Sleep → 고 wakeup latency)                  │
│  ★ BIOS 설정 (Storage Mode, PCIe Gen, Above 4G Decoding 등)       │
│  ★ CPU Microcode (보안 패치 → 성능 영향)                          │
│                                                                     │
│  ── PCIe 레벨 ──                                                   │
│  ★ PCIe ASPM (Active State Power Management → latency 증가)       │
│  ★ PCIe ACS (Access Control Services → P2P DMA 차단)              │
│  ★ PCIe Relaxed Ordering (TLP 순서 완화 → throughput 향상)        │
│  ★ PCIe Completion Timeout (재전송 지연)                           │
│                                                                     │
│  ── SSD 내부 요소 ──                                               │
│  ★ NVMe APST (Autonomous Power State Transition → latency spike)  │
│  ★ Thermal Throttling (온도 → 50-75% 성능 저하)                   │
│  ★ SSD Fill Level (사용률 → 쓰기 성능 급락)                      │
│  ★ Steady-State Degradation (FOB vs 안정 상태)                    │
│  ★ Over-Provisioning (OP 비율 → GC 효율)                         │
│  ★ SSD Firmware Version (GC 알고리즘, bug fix)                    │
│  ★ Write Amplification Factor (WAF → 내구성 & 성능)              │
│  ★ TRIM/Discard 정책 (fstrim vs continuous discard)               │
│                                                                     │
│  ── OS / 커널 레벨 ──                                              │
│  ★ Kernel Security Mitigations (Spectre/Meltdown → 15-40% 오버헤드)│
│  ★ IOMMU / VT-d (DMA 주소 변환 → 3-8% 오버헤드)                 │
│  ★ Transparent Huge Pages (THP → latency spike)                   │
│  ★ KPTI (Kernel Page Table Isolation → syscall 오버헤드)          │
│  ★ vm.dirty_ratio / dirty pages writeback (쓰기 지연)             │
│  ★ SELinux / AppArmor (보안 모듈 → 추가 오버헤드)               │
│                                                                     │
│  ── SW / Application 레벨 ──                                       │
│  ★ cgroup v2 I/O Throttling (blk-throttle → 격리 비용)           │
│  ★ Filesystem 선택 (ext4 vs XFS vs raw block → 2-20% 차이)       │
│  ★ Encryption (dm-crypt/LUKS → 20-50% 오버헤드)                  │
│  ★ NVMe Interrupt Coalescing (병합 → CPU vs latency 트레이드오프)│
│  ★ Alignment (4K 정렬 미스 → 2x I/O 증폭)                       │
│  ★ NVMe Multipath (경로 관리 → 추가 latency)                    │
│  ★ Swap Configuration (스왑 활성 시 I/O 간섭)                    │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 2. 심각도 순위

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ Rank │ 요소                          │ 성능 영향      │ 쉬운 수정? │ 범주  │
├──────┼───────────────────────────────┼────────────────┼────────────┼───────┤
│  1   │ SSD Steady-State Degradation  │ 30-70% 쓰기↓  │ 중간       │ SSD   │
│  2   │ Thermal Throttling            │ 50-75% 전체↓  │ 쉬움(방열) │ SSD   │
│  3   │ Kernel Security Mitigations   │ 15-40% 누적   │ 쉬움(위험) │ 커널  │
│  4   │ CPU C-States                  │ 30-50% tail↑  │ 쉬움       │ HW    │
│  5   │ NVMe APST                     │ 1-8ms spike   │ 쉬움       │ SSD   │
│  6   │ SSD Fill Level (>95%)         │ 50-90% 쓰기↓  │ 쉬움       │ SSD   │
│  7   │ BIOS 설정 오류               │ 최대 50%↓     │ 쉬움       │ HW    │
│  8   │ THP (Transparent Huge Pages)  │ 30%+ spike    │ 쉬움       │ 커널  │
│  9   │ PCIe ASPM                     │ 5-15% (최대2x)│ 쉬움       │ PCIe  │
│ 10   │ IOMMU / VT-d                  │ 3-8% (최대90%)│ 쉬움       │ 커널  │
│ 11   │ Encryption (dm-crypt)         │ 20-50%        │ 중간       │ SW    │
│ 12   │ Filesystem 오버헤드           │ 2-20%         │ 중간       │ SW    │
│ 13   │ Interrupt Coalescing          │ 5-20% CPU/lat │ 중간       │ SSD   │
│ 14   │ cgroup I/O Throttling         │ 20-60% 격리   │ 중간       │ 커널  │
│ 15   │ Write Amplification (WAF)     │ 1.5-3x 쓰기↑ │ 어려움     │ SSD   │
│ 16   │ PCIe ACS (P2P 차단)          │ P2P 불가      │ 중간       │ PCIe  │
│ 17   │ PCIe Relaxed Ordering         │ 2-8%          │ 어려움     │ PCIe  │
│ 18   │ 4K Alignment 미스             │ 최대 2x I/O   │ 쉬움       │ SW    │
│ 19   │ SELinux/AppArmor              │ 2-5%          │ 쉬움       │ 커널  │
│ 20   │ Swap 간섭                     │ 가변          │ 쉬움       │ 커널  │
│ 21   │ CPU Microcode 패치            │ 5-15%         │ 불가       │ HW    │
│ 22   │ NVMe Multipath 오버헤드       │ 2-5%          │ 쉬움       │ 커널  │
│ 23   │ vm.dirty 설정                 │ burst 지연    │ 쉬움       │ 커널  │
│ 24   │ TRIM/Discard 정책             │ 장기 성능 유지│ 쉬움       │ SSD   │
│ 25   │ PCIe Completion Timeout       │ 에러 시 지연  │ 중간       │ PCIe  │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. HW/BIOS 레벨 요소

### 3.1 CPU C-States (★ 심각도 4위)

```
문제:
  CPU가 idle 상태에서 Deep C-State (C3, C6, C7)에 진입하면
  NVMe 인터럽트 도착 시 CPU가 깨어나는데 수십~수백 μs 소요

  ┌────────────┬──────────────┬────────────────────────────────────┐
  │ C-State    │ Wakeup Lat.  │ NVMe I/O 영향                     │
  ├────────────┼──────────────┼────────────────────────────────────┤
  │ C0 (Active)│ 0ns          │ 없음 (최적)                       │
  │ C1 (Halt)  │ ~1-2 μs     │ 미미                              │
  │ C1E        │ ~10 μs      │ 감지 가능                         │
  │ C3 (Sleep) │ ~30-50 μs   │ 유의미 (QD1에서 +50% latency)    │
  │ C6 (Deep)  │ ~100-150 μs │ 심각 (NVMe latency보다 클 수 있음)│
  │ C7+        │ ~150+ μs    │ 매우 심각                         │
  └────────────┴──────────────┴────────────────────────────────────┘

  NVMe 4K Random Read latency = ~3-10μs
  C6 wakeup latency = ~100-150μs
  → C6에서 깨어나는 것만으로 I/O latency가 10-50배 증가!

진단:
  # 현재 C-State 설정 확인
  cat /sys/devices/system/cpu/cpu0/cpuidle/state*/name
  cat /sys/devices/system/cpu/cpu0/cpuidle/state*/latency
  cat /sys/devices/system/cpu/cpu0/cpuidle/state*/disable

  # 각 C-State 체류 시간 (높은 C-State 비율이 높으면 문제)
  cat /sys/devices/system/cpu/cpu0/cpuidle/state*/time
  cat /sys/devices/system/cpu/cpu0/cpuidle/state*/usage

  # CPU idle driver
  cat /sys/devices/system/cpu/cpuidle/current_driver

  # turbostat으로 실시간 C-State 모니터링
  sudo turbostat --interval 1

최적화:
  # 방법 1: 커널 부트 파라미터 (권장)
  # /etc/default/grub → GRUB_CMDLINE_LINUX에 추가:
  intel_idle.max_cstate=1 processor.max_cstate=1

  # 방법 2: 런타임 설정 (재부팅 불필요)
  # C1 이상 비활성화
  for state in /sys/devices/system/cpu/cpu*/cpuidle/state[2-9]; do
      echo 1 > "$state/disable" 2>/dev/null
  done

  # 방법 3: PM QoS로 latency 제한 (애플리케이션에서)
  # /dev/cpu_dma_latency에 0 쓰면 C0만 사용
  exec 3>/dev/cpu_dma_latency
  echo -ne '\x00\x00\x00\x00' >&3
  # fd 3을 열어둔 채 유지 (닫으면 원복)

트레이드오프:
  - 전력 소비 증가: 서버당 10-50W+
  - max_cstate=1 권장: C1만 허용 (절충안)
```

### 3.2 BIOS/UEFI 설정 (★ 심각도 7위)

```
NVMe 성능에 영향을 주는 주요 BIOS 설정:

  ┌──────────────────────────────────────────────────────────────────┐
  │ BIOS 항목                │ 권장 값        │ 잘못된 값 시 영향   │
  ├──────────────────────────┼────────────────┼─────────────────────┤
  │ Storage Mode             │ AHCI 또는 NVMe │ RAID→에뮬레이션 오버│
  │                          │ (RAID 아닌)    │ 헤드, 성능 50%↓    │
  │ PCIe Generation          │ Auto 또는 Gen5 │ Gen3 고정→BW 절반  │
  │ PCIe Slot Bifurcation    │ 필요 시 x4x4x4│ x16→1개만 인식     │
  │ Above 4G Decoding        │ Enabled        │ Disabled→BAR 배치  │
  │                          │                │ 실패, 대용량 SSD 문제│
  │ Resizable BAR            │ Enabled        │ GPU P2P DMA 제한   │
  │ SR-IOV                   │ 필요 시 Enable │ NVMe VF 사용 시 필요│
  │ IOMMU / VT-d             │ 용도 따라      │ 아래 별도 설명      │
  │ C-States                 │ C1 only        │ Deep C→latency spike│
  │ Turbo Boost              │ Enabled        │ Disabled→처리량 감소│
  │ Hyper-Threading          │ Enabled        │ 워크로드 따라 다름  │
  │ NUMA Interleave          │ Disabled       │ Enabled→NUMA 무효화│
  │ Sub-NUMA Clustering(SNC) │ 워크로드 따라  │ 잘못 쓰면 성능 저하│
  │ PCIe ASPM                │ Disabled       │ 아래 별도 설명      │
  │ NVMe RAID Support        │ Disabled       │ VROC→추가 오버헤드 │
  │ Boot Order / Hot Plug    │ NVMe 포함      │ 미인식              │
  └──────────────────────────────────────────────────────────────────┘

진단:
  # BIOS 설정은 직접 BIOS 진입 필요
  # 일부 Linux에서 확인 가능:
  sudo dmidecode -t bios | head -20    # BIOS 버전
  sudo dmidecode -t system             # 시스템 정보

  # PCIe Gen 확인 (실제 동작 중인 속도)
  lspci -vvv -s <NVMe BDF> | grep -E "LnkSta:|LnkCap:"
  # LnkSta가 LnkCap보다 낮으면 BIOS나 케이블 문제

  # Above 4G Decoding 확인
  lspci -vvv | grep "Memory at" | grep -i "64-bit"
```

### 3.3 CPU Microcode (★ 심각도 21위)

```
문제:
  CPU 보안 패치 (microcode update)가 성능을 저하시킬 수 있음
  Spectre, Meltdown, Downfall, Zenbleed 등의 완화 조치

진단:
  # 현재 microcode 버전
  cat /proc/cpuinfo | grep microcode | head -1
  dmesg | grep microcode

  # microcode 패키지 버전
  dpkg -l | grep intel-microcode    # Intel
  dpkg -l | grep amd64-microcode    # AMD

영향:
  - 일반적으로 5-15% 오버헤드 (커널 mitigation과 누적)
  - 비활성화 불가 (하드웨어 레벨)
  - 하지만 커널 mitigation은 비활성화 가능 (아래 참조)
```

---

## 4. PCIe 레벨 요소

### 4.1 PCIe ASPM (★ 심각도 9위)

```
문제:
  PCIe 링크가 idle 시 저전력 상태 (L0s, L1, L1.1, L1.2)에 진입
  Active 상태 (L0)로 복귀 시 수 μs ~ 수십 μs 지연

  ┌──────────┬──────────────┬────────────────────────┐
  │ ASPM 상태│ Exit Latency │ 성능 영향              │
  ├──────────┼──────────────┼────────────────────────┤
  │ L0s      │ < 4 μs      │ 미미 (~5%)             │
  │ L1       │ 1-32 μs     │ 유의미 (5-15%)         │
  │ L1.1     │ > L1        │ 심각 (랜덤 I/O)        │
  │ L1.2     │ 최대        │ 매우 심각 (최대 2x)    │
  └──────────┴──────────────┴────────────────────────┘

진단:
  # 현재 ASPM 정책
  cat /sys/module/pcie_aspm/parameters/policy

  # 디바이스별 ASPM 상태 확인
  sudo lspci -vvv -s <BDF> | grep -A3 "ASPM"
  # LnkCtl: ASPM L1 Enabled ← 활성화 상태!

  # 커널 로그에서 ASPM 문제 확인
  dmesg | grep -i aspm

최적화:
  # 커널 부트 파라미터
  pcie_aspm=off pcie_port_pm=off

  # 또는 런타임
  echo performance > /sys/module/pcie_aspm/parameters/policy
```

### 4.2 PCIe ACS (★ 심각도 16위)

```
문제:
  Access Control Services가 활성화되면 PCIe P2P DMA가 차단됨
  → GDS (GPUDirect Storage)가 Compatibility Mode로 fallback
  → NVMe-to-GPU 직접 전송 불가 → CPU bounce buffer 경유

진단:
  # ACS 상태 확인
  sudo lspci -vvv | grep -i "ACSCtl"
  # ACSCtl: SrcValid+ TransBlk+ ReqRedir+ CmpltRedir+ ← ACS 활성화

  # NVIDIA GDS P2P 가능 여부 확인
  gdscheck -p 2>/dev/null || echo "GDS not installed"

최적화:
  # 커널 부트 파라미터 (P2P 필요 시)
  pcie_acs_override=downstream,multifunction

  # 주의: 보안 격리가 약해짐 → 신뢰할 수 있는 환경에서만
```

### 4.3 PCIe Relaxed Ordering (★ 심각도 17위)

```
문제:
  PCIe TLP의 순서 보장을 완화하면 throughput이 향상될 수 있음
  특히 NVMe와 RDMA NIC 간 P2P 전송에서 효과

진단:
  # DevCtl에서 Relaxed Ordering 확인
  sudo lspci -vvv -s <BDF> | grep -i "DevCtl"
  # DevCtl: ... RelaxOrd+ ← 활성화

영향: 2-8% throughput 향상 가능
  - 주로 대역폭 집약 워크로드에서 효과
  - latency에는 큰 영향 없음
```

### 4.4 PCIe Completion Timeout

```
문제:
  PCIe 트랜잭션이 timeout되면 재전송 발생 → 수백 ms 지연
  SSD 내부 GC 중 긴 I/O에서 발생 가능

진단:
  # AER (Advanced Error Reporting) 로그
  dmesg | grep -i "AER\|completion timeout\|pcie.*error"

  # DevCtl2에서 Completion Timeout 확인
  sudo lspci -vvv -s <BDF> | grep "DevCtl2"
```

---

## 5. SSD 내부 요소

### 5.1 Thermal Throttling (★ 심각도 2위)

```
문제:
  SSD 온도가 임계값을 초과하면 자동으로 성능 제한
  Gen5 NVMe SSD: 방열판 없이 수 초 만에 스로틀링 진입!

  ┌───────────────────────────────────────────────────────────────┐
  │ 온도 범위      │ 동작              │ 성능 영향              │
  ├─────────────────┼───────────────────┼────────────────────────┤
  │ < 50°C          │ 정상              │ 100% 성능             │
  │ 50-70°C         │ 주의              │ 정상 ~ 약간 저하      │
  │ 70-80°C         │ Throttle Zone 1   │ 20-40% 성능 저하      │
  │ 80-85°C         │ Throttle Zone 2   │ 50-75% 성능 저하      │
  │ > 85°C          │ Critical / 종료   │ 극심한 저하 또는 차단  │
  └───────────────────────────────────────────────────────────────┘

  Gen5 NVMe (14 GB/s급): 최대 전력 25W+ → 적극적 방열 필수

진단:
  # nvme-cli로 온도 확인
  sudo nvme smart-log /dev/nvme0n1 | grep -i temp
  #  temperature                         : 45 C
  #  warning_temp_time                   : 0       ← 주의 온도 초과 시간
  #  critical_comp_time                  : 0       ← 임계 온도 초과 시간
  #  Thermal Management T1 Transition Count: 0
  #  Thermal Management T2 Transition Count: 0     ← 0이 아니면 스로틀링 발생!

  # 실시간 모니터링
  watch -n 1 "nvme smart-log /dev/nvme0n1 2>/dev/null | grep temp"

  # sensors (lm-sensors)
  sensors | grep -i nvme

최적화:
  - M.2 히트싱크 또는 방열판 장착 (필수, 특히 Gen5)
  - U.2/EDSFF 폼팩터 사용 (방열 우수)
  - 에어플로우 확보
  - SSD 간 물리적 간격 유지
  - Fan speed 프로파일 조정 (BMC/IPMI)
```

### 5.2 SSD Steady-State Degradation (★ 심각도 1위)

```
문제:
  SSD 벤더가 공개하는 성능 = FOB (Fresh Out of Box) 상태
  실제 운영 환경 = Steady-State → 쓰기 성능이 30-70% 하락!

  ┌──────────────────────────────────────────────────────────────┐
  │                                                              │
  │  IOPS  ▲                                                    │
  │        │  ■ ■ ■ ■                                           │
  │  FOB   │━━━━━━━━■━■━                                        │
  │        │              ■                                      │
  │        │                ■                                    │
  │ Steady │─ ─ ─ ─ ─ ─ ─ ─■─■─■─■─■─■─■─■─■─■─              │
  │ State  │                                                     │
  │        └──────────────────────────────────────────► 시간     │
  │        │   FOB Phase   │  Transition  │  Steady State       │
  │        │  (minutes~hrs)│  (hrs~days)  │  (permanent)        │
  │                                                              │
  │  원인: NAND에 유효 데이터가 채워지면 GC(Garbage Collection) │
  │        이 상시 동작 → 쓰기 시 내부적으로 읽기+지우기 추가   │
  │                                                              │
  │  TLC 4K Random Write 예시:                                  │
  │    FOB:    ~500K IOPS                                       │
  │    Steady: ~150-200K IOPS (60-70% 하락)                     │
  └──────────────────────────────────────────────────────────────┘

진단:
  # SNIA PTS 방식의 Steady-State 도달 확인
  # 1. 전체 드라이브를 2회 Sequential Write로 채움
  sudo fio --name=precondition --filename=/dev/nvme0n1 \
       --ioengine=libaio --direct=1 --rw=write --bs=128k \
       --iodepth=64 --numjobs=1 --size=100% --loops=2

  # 2. 4K Random Write를 1시간 이상 실행 후 성능 측정
  # → FOB와 비교하면 steady-state 성능 차이 확인 가능

  # SSD 사용률 확인
  sudo nvme smart-log /dev/nvme0n1 | grep -E "percentage_used|data_units"

최적화:
  - Over-Provisioning 확보 (아래 참조)
  - 정기 TRIM 실행
  - 쓰기 워크로드 분산 (여러 SSD)
  - 벤치마크 시 반드시 steady-state에서 측정
```

### 5.3 SSD Fill Level (★ 심각도 6위)

```
문제:
  SSD 사용률이 높아질수록 쓰기 성능 급감
  → Free block 부족 → GC가 더 자주, 더 많이 동작

  ┌────────────────┬────────────────────────────────┐
  │ SSD 사용률     │ 쓰기 성능 영향                 │
  ├────────────────┼────────────────────────────────┤
  │ 0-50%          │ ~100% (정상)                   │
  │ 50-70%         │ ~90-100% (미미한 영향)         │
  │ 70-85%         │ ~60-80% (감지 가능)            │
  │ 85-95%         │ ~30-60% (유의미한 저하)        │
  │ > 95%          │ ~10-50% (심각한 저하)          │
  └────────────────┴────────────────────────────────┘

진단:
  # 파티션 사용률
  df -h /mount/point

  # SSD 실제 사용률 (NAND 레벨)
  sudo nvme smart-log /dev/nvme0n1 | grep percentage_used

최적화:
  - 용량의 70-80% 이하로 유지 권장
  - Over-Provisioning 예약 영역 설정 (아래 참조)
  - 불필요 데이터 정리, 정기 TRIM
```

### 5.4 Over-Provisioning (★ 심각도 6위 연관)

```
Over-Provisioning = SSD 내부에서 GC, Wear Leveling, Bad Block 대체용으로
                    예약하는 공간. 사용자에게 노출되지 않음.

  Enterprise SSD: 기본 OP ~7-28% (512GB NAND → 480/400GB 사용 가능)
  Consumer SSD:   기본 OP ~7% (1TB NAND → 931GB 사용 가능)

추가 OP 설정:
  # 방법 1: hdparm으로 HPA (Host Protected Area) 설정
  sudo hdparm -Np<MAX_SECTOR> /dev/nvme0n1

  # 방법 2: 파티션으로 남겨두기 (가장 간편)
  # 총 용량의 10-20%를 파티션하지 않고 남겨둠

  # 방법 3: NVMe Namespace 관리 (Enterprise SSD)
  sudo nvme create-ns /dev/nvme0 --nsze=<reduced_size> --ncap=<reduced_size>

효과:
  OP 7%  → baseline 성능
  OP 15% → steady-state 쓰기 ~20-30% 향상
  OP 28% → steady-state 쓰기 ~40-60% 향상
```

### 5.5 NVMe APST (★ 심각도 5위)

```
문제:
  NVMe Autonomous Power State Transition: idle 시 SSD 자체적으로
  저전력 상태에 진입 → 복귀 시 1-8ms latency spike

  특히 Consumer NVMe에서 많이 발생 (Enterprise는 보통 비활성화)

진단:
  # 현재 APST 설정 확인
  sudo nvme get-feature /dev/nvme0 -f 0x0c -H
  # 또는
  sudo nvme id-ctrl /dev/nvme0 | grep apsta

  # 현재 Power State
  sudo nvme get-feature /dev/nvme0 -f 0x02 -H

최적화:
  # APST 비활성화 (커널 파라미터)
  nvme_core.default_ps_max_latency_us=0

  # 또는 런타임으로 특정 디바이스만
  echo 0 | sudo tee /sys/class/nvme/nvme0/power/pm_qos_latency_tolerance_us

  # 또는 최대 Power State 고정
  sudo nvme set-feature /dev/nvme0 -f 0x02 -v 0  # PS0 (최고 성능)
```

### 5.6 TRIM/Discard 정책

```
TRIM = SSD에게 삭제된 블록을 알려줌 → GC 효율 향상 → 장기 성능 유지

  방법 1: 정기 TRIM (권장)
    sudo fstrim -av        # 마운트된 모든 파일시스템 TRIM
    # cron 또는 systemd timer로 주 1회 실행
    systemctl enable fstrim.timer

  방법 2: Continuous Discard (비권장 - 성능 오버헤드)
    mount -o discard /dev/nvme0n1p1 /mount/point
    # 매 삭제 시 즉시 TRIM → I/O 오버헤드 발생

  방법 3: O_DIRECT 워크로드 (raw block)
    # blkdiscard로 수동 TRIM
    sudo blkdiscard /dev/nvme0n1    # 전체 드라이브 TRIM (데이터 삭제!)
    sudo blkdiscard -o <offset> -l <length> /dev/nvme0n1  # 부분 TRIM
```

### 5.7 SSD Firmware Version

```
Firmware 업데이트가 성능에 미치는 영향:
  - GC 알고리즘 개선 → steady-state 성능 향상
  - Bug fix → latency spike 해결
  - Power management 최적화
  - 보안 패치

진단:
  sudo nvme id-ctrl /dev/nvme0 | grep "^fr "
  sudo nvme fw-log /dev/nvme0

주의: 펌웨어 업데이트 전 반드시 백업!
```

---

## 6. OS/커널 레벨 요소

### 6.1 Kernel Security Mitigations (★ 심각도 3위)

```
문제:
  Spectre, Meltdown, Retbleed, Downfall 등 CPU 취약점 완화 조치
  커널이 기본적으로 모든 mitigation을 활성화 → 누적 오버헤드 15-40%

  ┌────────────────────────────────────────────────────────────────┐
  │ Mitigation          │ 개별 영향   │ 특히 영향받는 경로        │
  ├─────────────────────┼─────────────┼───────────────────────────┤
  │ KPTI (Meltdown)     │ 5-15%       │ syscall heavy (sync I/O) │
  │ Retbleed            │ 8-19%       │ 간접 분기 (kernel code)  │
  │ Spectre v1/v2       │ 2-8%        │ 조건부 분기              │
  │ MDS/TAA/MMIO        │ 2-5%        │ SMT 관련                 │
  │ Downfall (GDS)      │ 5-15%       │ AVX 관련                 │
  │ SRSO/Inception(AMD) │ 5-10%       │ RET 명령                 │
  ├─────────────────────┼─────────────┼───────────────────────────┤
  │ 누적 합계           │ 15-40%      │ 모든 I/O 경로            │
  └────────────────────────────────────────────────────────────────┘

  NVMe에 특히 영향이 큰 이유:
  - 고빈도 syscall (io_submit, io_uring_enter)
  - 고빈도 인터럽트 (MSI-X)
  - 커널 ↔ 유저 전환이 매우 빈번
  - SW overhead가 전체 latency의 10-25% → mitigation으로 추가 증폭

진단:
  # 현재 활성화된 mitigation 확인
  cat /proc/cmdline | tr ' ' '\n' | grep mitig

  # 상세 mitigation 상태
  grep . /sys/devices/system/cpu/vulnerabilities/* 2>/dev/null
  # 각 취약점별 "Mitigation: xxx" 또는 "Vulnerable" 표시

  # 어떤 mitigation이 적용되었는지 정확히 보기
  journalctl -k | grep -i "spectre\|meltdown\|retbleed\|downfall\|vulnerability"

최적화 (주의: 보안 위험):
  # 전체 mitigation 비활성화 (격리된 환경에서만)
  mitigations=off
  # → 15-40% 성능 향상, 하지만 보안 취약

  # 선택적 비활성화 (덜 위험)
  # Retbleed만 (가장 큰 단일 영향)
  retbleed=off
  # KPTI만
  nopti
  # Spectre v2만
  spectre_v2=off

  # 권장: 벤치마크에서 mitigations=off로 순수 HW 성능 측정 후
  #       운영 환경에서는 필요한 mitigation만 유지
```

### 6.2 IOMMU / VT-d (★ 심각도 10위)

```
문제:
  IOMMU는 DMA 주소 변환을 수행 → 모든 NVMe DMA에 추가 latency
  IOTLB miss 시 page table walk → 심각한 오버헤드

  ┌────────────────────────────────────────────────────────────┐
  │ 모드               │ 오버헤드    │ 사용 사례              │
  ├────────────────────┼─────────────┼────────────────────────┤
  │ IOMMU off          │ 0%          │ 최대 성능 (격리 없음)  │
  │ IOMMU passthrough  │ ~1-2%       │ 절충안 (최소 오버헤드) │
  │ IOMMU strict       │ ~3-8%       │ 기본값 (완전 격리)     │
  │ IOMMU (IOTLB miss) │ 최대 90%    │ 비정상 (flush 빈번)    │
  └────────────────────────────────────────────────────────────┘

진단:
  # IOMMU 활성화 상태
  dmesg | grep -i "DMAR\|IOMMU"
  cat /proc/cmdline | grep iommu

  # IOMMU 그룹 확인
  find /sys/kernel/iommu_groups/ -type l | sort -V

최적화:
  # 방법 1: IOMMU passthrough (VM 미사용 시 권장)
  intel_iommu=on iommu=pt         # Intel
  amd_iommu=on iommu=pt           # AMD

  # 방법 2: 완전 비활성화 (최대 성능, VM/VFIO 불가)
  intel_iommu=off                  # Intel
  amd_iommu=off                    # AMD

  # 방법 3: VFIO 사용 시 (SPDK 등)
  intel_iommu=on iommu=pt vfio-pci.ids=<VID:DID>
```

### 6.3 Transparent Huge Pages (★ 심각도 8위)

```
문제:
  THP 활성화 시 커널이 백그라운드에서 메모리 compaction 수행
  → I/O 스레드가 수백 ms 동안 stall 될 수 있음!

  특히 데이터베이스, 스토리지 서비스에서 심각:
  - Redis: THP로 인한 latency spike 보고
  - MySQL: Oracle 공식 권장 = THP 비활성화
  - MongoDB: 공식 문서에서 THP 비활성화 권고

진단:
  # 현재 THP 상태
  cat /sys/kernel/mm/transparent_hugepage/enabled
  # [always] madvise never  ← always가 기본이면 문제!

  cat /sys/kernel/mm/transparent_hugepage/defrag
  # [always] defer defer+madvise madvise never

  # THP 관련 통계
  grep -i thp /proc/vmstat
  # thp_fault_alloc, thp_collapse_alloc, thp_split_page 등

최적화:
  # 런타임 비활성화
  echo never > /sys/kernel/mm/transparent_hugepage/enabled
  echo never > /sys/kernel/mm/transparent_hugepage/defrag

  # 영구 설정 (커널 부트 파라미터)
  transparent_hugepage=never

  # 또는 madvise 모드 (필요한 앱만 선택적 사용)
  echo madvise > /sys/kernel/mm/transparent_hugepage/enabled
```

### 6.4 SELinux / AppArmor (★ 심각도 19위)

```
진단:
  # SELinux
  getenforce    # Enforcing / Permissive / Disabled

  # AppArmor
  sudo aa-status

영향: I/O 경로에서 추가 보안 검사 → 2-5% 오버헤드
  - 벤치마크 시: permissive 또는 disabled 권장
  - 운영 시: Enforcing 유지 (보안 우선)
```

### 6.5 vm.dirty 설정 (★ 심각도 23위)

```
문제:
  dirty pages가 임계값에 도달하면 synchronous writeback 시작
  → 쓰기 작업이 burst로 발생하여 latency spike

진단:
  sysctl vm.dirty_ratio              # default: 20 (메모리의 20%)
  sysctl vm.dirty_background_ratio   # default: 10
  sysctl vm.dirty_expire_centisecs   # default: 3000 (30초)
  sysctl vm.dirty_writeback_centisecs # default: 500 (5초)

최적화 (NVMe 고성능 워크로드):
  sysctl -w vm.dirty_ratio=5              # 빨리 writeback 시작
  sysctl -w vm.dirty_background_ratio=2   # 백그라운드 일찍 시작
  sysctl -w vm.dirty_expire_centisecs=1000
```

---

## 7. SW/Application 레벨 요소

### 7.1 cgroup v2 I/O Throttling (★ 심각도 14위)

```
문제:
  Kubernetes, Docker 등이 cgroup으로 I/O를 제한하면 성능 저하
  blk-throttle 계층이 I/O 경로에 추가됨

진단:
  # cgroup v2 I/O 설정 확인
  cat /sys/fs/cgroup/*/io.max 2>/dev/null
  cat /sys/fs/cgroup/*/io.weight 2>/dev/null
  cat /sys/fs/cgroup/*/io.stat 2>/dev/null

  # cgroup v1 (레거시)
  cat /sys/fs/cgroup/blkio/blkio.throttle.read_bps_device 2>/dev/null

영향: I/O 격리 시 20-60% 오버헤드 (throttle 설정에 따라)
```

### 7.2 Filesystem 오버헤드 (★ 심각도 12위)

```
┌────────────────────────────────────────────────────────────────┐
│ Filesystem    │ 4K RR IOPS │ Seq Read BW │ 오버헤드 vs raw    │
├───────────────┼────────────┼─────────────┼────────────────────┤
│ Raw Block     │ 100%       │ 100%        │ 0% (기준)          │
│ XFS           │ ~93-97%    │ ~95-98%     │ 2-7%               │
│ ext4          │ ~90-95%    │ ~93-97%     │ 3-10%              │
│ Btrfs         │ ~80-90%    │ ~85-95%     │ 5-20%              │
│ ZFS           │ ~70-85%    │ ~80-90%     │ 10-30%             │
└────────────────────────────────────────────────────────────────┘

  O_DIRECT vs Buffered:
  - O_DIRECT: Page Cache 바이패스, NVMe 성능을 직접 활용
  - Buffered: Page Cache 경유, 작은 I/O에서 더 빠를 수 있으나
              dirty writeback으로 latency spike 가능
```

### 7.3 Encryption: dm-crypt / LUKS (★ 심각도 11위)

```
문제:
  디스크 암호화가 I/O 경로에 추가 CPU 연산을 삽입

  ┌────────────────────────┬──────────────┐
  │ 암호화 방식            │ 오버헤드     │
  ├────────────────────────┼──────────────┤
  │ dm-crypt (AES-NI HW)  │ 10-20%       │
  │ dm-crypt (SW only)    │ 30-50%       │
  │ SED (Self-Encrypting) │ ~0% (HW 내부)│
  │ OPAL SSD              │ ~0% (HW 내부)│
  └────────────────────────┴──────────────┘

진단:
  # dm-crypt 사용 여부
  lsblk -o NAME,TYPE,FSTYPE,MOUNTPOINT | grep crypt
  dmsetup table | grep crypt

  # AES-NI 지원 확인
  grep aes /proc/cpuinfo

권장: SSD가 SED/OPAL 지원 시 HW 암호화 사용 (성능 영향 없음)
```

### 7.4 4K Alignment (★ 심각도 18위)

```
문제:
  파티션이나 파일시스템이 4K boundary에 정렬되지 않으면
  단일 I/O가 2개의 물리 블록에 걸침 → 2x I/O 증폭

진단:
  # 파티션 정렬 확인
  sudo parted /dev/nvme0n1 align-check optimal 1
  # 또는
  cat /sys/class/block/nvme0n1p1/alignment_offset
  # 0이면 정렬됨

  # fdisk로 시작 섹터 확인 (2048 이상, 4096의 배수)
  sudo fdisk -l /dev/nvme0n1

최적화:
  - 파티션 생성 시 항상 1MiB 정렬 (parted, fdisk 최신 버전 기본)
  - mkfs 시 stride/stripe-width 설정
```

### 7.5 NVMe Multipath (★ 심각도 22위)

```
문제:
  nvme_core.multipath=Y 시 경로 관리 오버헤드 추가
  단일 경로 SSD에서도 multipath가 활성화되면 불필요한 오버헤드

진단:
  cat /sys/module/nvme_core/parameters/multipath
  # Y → 활성화됨

  # multipath 상태
  nvme list-subsys 2>/dev/null

최적화 (multipath 불필요 시):
  # 커널 부트 파라미터
  nvme_core.multipath=N
```

### 7.6 Swap 간섭 (★ 심각도 20위)

```
문제:
  Swap이 NVMe SSD에 있으면 메모리 압박 시 swap I/O가
  정상 I/O와 경합 → 성능 간섭

진단:
  swapon --show
  cat /proc/sys/vm/swappiness   # default: 60

최적화:
  # 스토리지 서버: swap 비활성화
  sudo swapoff -a
  sysctl -w vm.swappiness=0

  # 또는 별도 디바이스에 swap 배치
```

---

## 8. 진단 스크립트: 숨은 요소 종합 점검

```bash
#!/bin/bash
###############################################################################
# NVMe Hidden Performance Factor Checker
# 숨은 성능 영향 요소를 종합적으로 점검합니다.
###############################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

SCORE=0
MAX_SCORE=0
ISSUES=()

check() {
    local name="$1" status="$2" detail="$3"
    MAX_SCORE=$((MAX_SCORE + 1))
    case "$status" in
        PASS) echo -e "  ${GREEN}[PASS]${NC} $name: $detail"; SCORE=$((SCORE + 1)) ;;
        WARN) echo -e "  ${YELLOW}[WARN]${NC} $name: $detail"; ISSUES+=("$name") ;;
        FAIL) echo -e "  ${RED}[FAIL]${NC} $name: $detail"; ISSUES+=("$name") ;;
    esac
}

echo -e "${BOLD}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  NVMe Hidden Performance Factor Checker                     ║${NC}"
echo -e "${BOLD}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# 1. CPU C-States
echo -e "${BOLD}── CPU C-States ──${NC}"
max_cstate=$(cat /sys/devices/system/cpu/cpu0/cpuidle/state*/name 2>/dev/null | tail -1)
c6_disabled=true
for s in /sys/devices/system/cpu/cpu0/cpuidle/state[3-9]; do
    if [[ -f "$s/disable" ]] && [[ "$(cat $s/disable 2>/dev/null)" == "0" ]]; then
        c6_disabled=false
    fi
done
if $c6_disabled; then
    check "C-States" PASS "Deep C-States disabled"
else
    check "C-States" FAIL "Deep C-States enabled (max: $max_cstate) → +30-50% tail latency"
fi

# 2. PCIe ASPM
echo -e "${BOLD}── PCIe ASPM ──${NC}"
aspm_policy=$(cat /sys/module/pcie_aspm/parameters/policy 2>/dev/null || echo "N/A")
if [[ "$aspm_policy" == *"performance"* ]] || grep -q "pcie_aspm=off" /proc/cmdline 2>/dev/null; then
    check "PCIe ASPM" PASS "ASPM off or performance ($aspm_policy)"
else
    check "PCIe ASPM" WARN "ASPM policy: $aspm_policy → 5-15% latency overhead"
fi

# 3. Kernel Mitigations
echo -e "${BOLD}── Kernel Security Mitigations ──${NC}"
if grep -q "mitigations=off" /proc/cmdline 2>/dev/null; then
    check "Mitigations" PASS "All mitigations disabled"
else
    vulns=$(grep -c "Mitigation" /sys/devices/system/cpu/vulnerabilities/* 2>/dev/null || echo "0")
    check "Mitigations" WARN "${vulns} active mitigations → 15-40% cumulative overhead"
fi

# 4. IOMMU
echo -e "${BOLD}── IOMMU ──${NC}"
if grep -q "iommu=pt" /proc/cmdline 2>/dev/null; then
    check "IOMMU" PASS "Passthrough mode (minimal overhead)"
elif grep -q "iommu=off\|intel_iommu=off" /proc/cmdline 2>/dev/null; then
    check "IOMMU" PASS "IOMMU disabled"
elif dmesg 2>/dev/null | grep -qi "DMAR.*enabled\|IOMMU.*enabled"; then
    check "IOMMU" WARN "IOMMU enabled in strict mode → 3-8% overhead"
else
    check "IOMMU" PASS "IOMMU not detected"
fi

# 5. THP
echo -e "${BOLD}── Transparent Huge Pages ──${NC}"
thp=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)
if [[ "$thp" == *"[never]"* ]] || [[ "$thp" == *"[madvise]"* ]]; then
    check "THP" PASS "THP: $thp"
else
    check "THP" FAIL "THP: $thp → 30%+ latency spikes from compaction"
fi

# 6. NVMe APST
echo -e "${BOLD}── NVMe APST ──${NC}"
apst_val=$(cat /sys/module/nvme_core/parameters/default_ps_max_latency_us 2>/dev/null || echo "N/A")
if [[ "$apst_val" == "0" ]]; then
    check "NVMe APST" PASS "APST disabled (ps_max_latency=0)"
elif [[ "$apst_val" == "N/A" ]]; then
    check "NVMe APST" WARN "Cannot check APST parameter"
else
    check "NVMe APST" WARN "APST active (max_latency=${apst_val}μs) → 1-8ms spikes possible"
fi

# 7. Thermal
echo -e "${BOLD}── NVMe Thermal ──${NC}"
for dev in /dev/nvme[0-9]; do
    if [[ -c "$dev" ]]; then
        local temp
        temp=$(nvme smart-log "${dev}n1" 2>/dev/null | grep "^temperature" | awk '{print $3}')
        if [[ -n "$temp" ]]; then
            if [[ $temp -lt 60 ]]; then
                check "Thermal $(basename $dev)" PASS "${temp}°C (OK)"
            elif [[ $temp -lt 75 ]]; then
                check "Thermal $(basename $dev)" WARN "${temp}°C (warm) → potential throttling"
            else
                check "Thermal $(basename $dev)" FAIL "${temp}°C (hot!) → active throttling likely"
            fi
        fi
    fi
done 2>/dev/null

# 8. SSD Fill Level
echo -e "${BOLD}── SSD Usage ──${NC}"
for dev in /dev/nvme[0-9]n1; do
    if [[ -b "$dev" ]]; then
        local pct
        pct=$(nvme smart-log "$dev" 2>/dev/null | grep "percentage_used" | awk '{print $3}' | tr -d '%')
        if [[ -n "$pct" ]]; then
            if [[ $pct -lt 80 ]]; then
                check "Fill $(basename $dev)" PASS "${pct}% used"
            elif [[ $pct -lt 95 ]]; then
                check "Fill $(basename $dev)" WARN "${pct}% used → write perf may degrade"
            else
                check "Fill $(basename $dev)" FAIL "${pct}% used → severe write degradation"
            fi
        fi
    fi
done 2>/dev/null

# 9. SELinux/AppArmor
echo -e "${BOLD}── Security Modules ──${NC}"
if command -v getenforce &>/dev/null && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
    check "SELinux" WARN "SELinux Enforcing → 2-5% overhead"
elif command -v aa-status &>/dev/null && aa-status --enabled 2>/dev/null; then
    check "AppArmor" WARN "AppArmor enabled → 1-3% overhead"
else
    check "Security Module" PASS "No active security module overhead"
fi

# 10. Swap
echo -e "${BOLD}── Swap ──${NC}"
swap_on=$(swapon --show 2>/dev/null | grep -c nvme || echo "0")
swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "60")
if [[ "$swap_on" -gt 0 ]]; then
    check "Swap" WARN "Swap on NVMe device (swappiness=$swappiness) → I/O interference"
else
    check "Swap" PASS "No swap on NVMe (swappiness=$swappiness)"
fi

# 11. Encryption
echo -e "${BOLD}── Encryption ──${NC}"
if dmsetup table 2>/dev/null | grep -q crypt; then
    check "Encryption" WARN "dm-crypt active → 10-50% overhead"
else
    check "Encryption" PASS "No disk encryption detected"
fi

# 12. NVMe Multipath
echo -e "${BOLD}── NVMe Multipath ──${NC}"
mp=$(cat /sys/module/nvme_core/parameters/multipath 2>/dev/null || echo "N/A")
if [[ "$mp" == "N" ]]; then
    check "NVMe Multipath" PASS "Disabled"
elif [[ "$mp" == "Y" ]]; then
    check "NVMe Multipath" WARN "Enabled → 2-5% overhead if single-path SSD"
fi

# 13. vm.dirty
echo -e "${BOLD}── vm.dirty Settings ──${NC}"
dirty_ratio=$(sysctl -n vm.dirty_ratio 2>/dev/null || echo "20")
if [[ $dirty_ratio -le 10 ]]; then
    check "vm.dirty_ratio" PASS "=$dirty_ratio (appropriate)"
else
    check "vm.dirty_ratio" WARN "=$dirty_ratio (default=20, consider ≤10 for NVMe)"
fi

# ── Summary ──
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
local pct
if [[ $MAX_SCORE -gt 0 ]]; then
    pct=$((SCORE * 100 / MAX_SCORE))
else
    pct=0
fi
echo -e "  Score: ${BOLD}${SCORE}/${MAX_SCORE} (${pct}%)${NC}"

if [[ ${#ISSUES[@]} -gt 0 ]]; then
    echo ""
    echo -e "  ${YELLOW}Issues found:${NC}"
    for issue in "${ISSUES[@]}"; do
        echo "    - $issue"
    done
fi
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
```

---

## 9. 최적화 원클릭 스크립트

```bash
#!/bin/bash
# NVMe 성능 최적화 원클릭 적용 스크립트
# 사용: sudo bash apply_hidden_factor_optimizations.sh [/dev/nvme0n1]

DEVICE=${1:-nvme0n1}
DEV_NAME=$(basename "$DEVICE" | sed 's|/dev/||')

echo "=== NVMe Hidden Factor Optimization ==="
echo "Target: /dev/$DEV_NAME"
echo ""

# ── Runtime Optimizations ──

# 1. Disable deep C-States
echo "[1/12] Disabling deep C-States..."
for state in /sys/devices/system/cpu/cpu*/cpuidle/state[2-9]; do
    echo 1 > "$state/disable" 2>/dev/null
done

# 2. Disable THP
echo "[2/12] Disabling Transparent Huge Pages..."
echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null

# 3. ASPM off
echo "[3/12] Setting ASPM to performance..."
echo performance > /sys/module/pcie_aspm/parameters/policy 2>/dev/null

# 4. I/O Scheduler
echo "[4/12] Setting I/O scheduler to 'none'..."
echo none > /sys/block/$DEV_NAME/queue/scheduler 2>/dev/null

# 5. Block device tuning
echo "[5/12] Tuning block device settings..."
echo 2    > /sys/block/$DEV_NAME/queue/rq_affinity 2>/dev/null
echo 2    > /sys/block/$DEV_NAME/queue/nomerges 2>/dev/null
echo 128  > /sys/block/$DEV_NAME/queue/read_ahead_kb 2>/dev/null

# 6. NVMe APST disable
echo "[6/12] Disabling NVMe APST..."
for ctrl in /sys/class/nvme/nvme*; do
    echo 0 > "$ctrl/power/pm_qos_latency_tolerance_us" 2>/dev/null
done

# 7. Swap off
echo "[7/12] Disabling swap..."
swapoff -a 2>/dev/null
sysctl -w vm.swappiness=0 > /dev/null 2>&1

# 8. vm.dirty tuning
echo "[8/12] Tuning vm.dirty..."
sysctl -w vm.dirty_ratio=5 > /dev/null 2>&1
sysctl -w vm.dirty_background_ratio=2 > /dev/null 2>&1

# 9. CPU Governor
echo "[9/12] Setting CPU governor to performance..."
for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > "$gov" 2>/dev/null
done

# 10. NUMA balancing off
echo "[10/12] Disabling NUMA balancing..."
sysctl -w kernel.numa_balancing=0 > /dev/null 2>&1

# 11. Drop caches
echo "[11/12] Dropping page cache..."
sync
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null

# 12. irqbalance stop
echo "[12/12] Stopping irqbalance..."
systemctl stop irqbalance 2>/dev/null

echo ""
echo "=== Optimization Complete ==="
echo ""
echo "For persistent settings, add to /etc/default/grub GRUB_CMDLINE_LINUX:"
echo '  "intel_idle.max_cstate=1 processor.max_cstate=1 pcie_aspm=off'
echo '   transparent_hugepage=never nvme_core.default_ps_max_latency_us=0'
echo '   iommu=pt"'
echo ""
echo "Then: sudo update-grub && sudo reboot"
```

---

## 10. 02번 스크립트 추가 권장 항목

```
이번 조사에서 발견된 숨은 요소 중
02_system_topology_analyzer.sh에 추가하면 좋은 항목:

  ┌──────────────────────────────────────────────────────────┐
  │ 항목                    │ 우선도 │ 진단 명령             │
  ├─────────────────────────┼────────┼───────────────────────┤
  │ CPU C-State 상태         │ ★★★ │ cpuidle state check   │
  │ PCIe ASPM 상태           │ ★★★ │ lspci -vvv + policy   │
  │ Kernel Mitigations 목록  │ ★★★ │ vulnerabilities/*     │
  │ IOMMU 모드               │ ★★★ │ dmesg + /proc/cmdline│
  │ THP 상태                 │ ★★★ │ transparent_hugepage  │
  │ NVMe APST 상태           │ ★★  │ ps_max_latency_us    │
  │ NVMe 온도                │ ★★  │ nvme smart-log temp  │
  │ SSD percentage_used      │ ★★  │ nvme smart-log       │
  │ dm-crypt 활성화 여부     │ ★   │ dmsetup table        │
  │ NVMe Multipath 상태      │ ★   │ nvme_core multipath  │
  │ Swap on NVMe 여부        │ ★   │ swapon --show        │
  │ SELinux/AppArmor 상태    │ ★   │ getenforce/aa-status │
  └──────────────────────────────────────────────────────────┘
```

---

## 참고 자료
- SNIA: SSD Performance Testing Specification (PTS)
- Linux Kernel Documentation: PCIe ASPM, IOMMU, THP
- Phoronix: Retbleed/Downfall Performance Benchmarks
- Red Hat: CPU C-States Configuration Guide
- ArchWiki: NVMe APST, Solid State Drive Optimization
- PingCAP Blog: THP and Database Performance
- NVIDIA: GPUDirect Storage Best Practices (ACS/IOMMU)

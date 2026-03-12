# GPU의 SSD 접근 모델 심층 분석: BaM, GDS, GIDS 표 중심 정리

> **작성 원칙**: 표 70~80%, 서술은 표 해석·예외 설명 용도로 8줄 이내 제한

---

## 1. Executive Summary Table

| Question | Answer | Confidence | Evidence |
|----------|--------|------------|----------|
| NVIDIA 공식 오픈소스 중 SSD를 VRAM 확장처럼 다루는 대표 프로젝트는? | GDS(gds-nvidia-fs)가 유일한 NVIDIA org 소유. 단 VRAM "확장"이 아닌 GPU-direct DMA 경로 제공 | High | github.com/NVIDIA/gds-nvidia-fs — nvidia-fs.ko 커널 드라이버 |
| GDS는 memory semantic access인가? | **Confirmed No.** Block I/O semantic. CPU가 cuFileRead/Write를 호출하는 명시적 파일 I/O | High | nvfs-core.c: `nvfs_ioctl()` → `nvfs_direct_io()` → `vfs_read/write` with O_DIRECT |
| BaM은 memory semantic에 가까운가? | **Confirmed Yes.** GPU thread가 `operator[]`로 SSD 데이터 투명 접근, cache miss 시 자동 NVMe fetch | High | page_cache.h: `array_d_t<T>::operator[]` → acquire_page → NVMe read → 반환 |
| GPU가 SSD를 truly direct access 한다고 볼 수 있는가? | **GDS**: GPU는 수동적 DMA target. **BaM**: GPU가 NVMe 명령 직접 발행 → "direct access"에 가장 가까움 | High | BaM nvm_parallel_queue.h: PTX `st.mmio.relaxed.sys` doorbell write |
| CPU DRAM bounce buffer는 제거되는가? | GDS/BaM 모두 제거. DeepSpeed/FlashNeuron은 CPU DRAM bounce 사용 | High | GDS: nvfs-dma.c SGL GPU 주소 치환. BaM: module/map.c P2P DMA |
| "SSD를 VRAM처럼 쓴다"는 표현은 어디까지 맞는가? | BaM에서만 부분적 타당. 지연 100-1000x, 대역폭 100x+, 일관성 모델 다름 | High | BaM operator[] 투명 접근 제공하나 HBM ~100ns vs SSD ~10-100μs |
| Production-grade에 가까운 것은? | **GDS** (gds-nvidia-fs + cuFile) — CUDA Toolkit 포함, NVIDIA 공식 지원 | High | NVIDIA 공식 문서, CUDA 12.x 포함, 활발한 업데이트 |
| 연구용 prototype에 가까운 것은? | **BaM** — ASPLOS '23 논문, 커스텀 NVMe 드라이버, 표준 FS 미지원 | High | libnvm_helper.ko 필요, IOMMU OFF 필수, raw NVMe만 지원 |
| CPU 관점과 GPU 관점의 access model 차이에서 가장 중요한 포인트는? | CPU는 1개 thread가 I/O를 initiate→orchestrate→consume. GPU는 initiator(warp)≠orchestrator(runtime)≠data mover(DMA)≠consumer(thread)가 분리됨 | High | GDS: CPU thread가 전체 제어. BaM: GPU warp이 initiate, runtime이 orchestrate, DMA가 move |
| GPU storage access의 실질 주체를 무엇으로 보는 것이 가장 정확한가? | **GDS: CPU thread.** GPU는 수동적 수신자. **BaM: GPU warp.** `__match_any_sync()` coalescing이 warp 경계에서 발생 | High | GDS: nvfs-core.c ioctl. BaM: page_cache.h warp-level coalescing |

**요약 (10줄 이내)**

NVIDIA org 소유의 GPU-SSD 프로젝트는 GDS뿐이며, block I/O 최적화다. Memory semantic은 BaM만 제공하나 NVIDIA 공식이 아닌 공동 연구(NVIDIA+IBM+UIUC). 두 프로젝트 모두 CPU DRAM bounce buffer를 제거하고 NVMe→GPU P2P DMA를 사용하지만, I/O 주체(CPU vs GPU)와 접근 추상화(block I/O vs memory semantic)에서 근본적으로 다르다. GPU storage access 분석에서 가장 중요한 것은 initiator/orchestrator/data mover/consumer를 분리하는 것이며, "GPU가 SSD를 읽는다"는 표현은 이 네 역할을 혼동하게 만든다.

---

## 2. CPU vs GPU Access Model Comparison

### 2-1. CPU vs GPU 비교 표

| Dimension | CPU SSD Access Model | GPU SSD Access Model (GDS) | GPU SSD Access Model (BaM) | Why This Difference Matters |
|-----------|---------------------|---------------------------|---------------------------|---------------------------|
| Compute execution unit | CPU core/thread (1~128개, 독립 실행) | GPU kernel (수만 스레드 SIMT 동시 실행) | GPU kernel (동일) | GPU는 수천 스레드가 동시에 I/O 발생 가능 → 큐 관리 복잡도 증가 |
| Request initiator | CPU thread (syscall: read/pread/io_uring) | CPU thread (cuFileRead/Write) | **GPU thread/warp** (operator[] cache miss) | BaM만 GPU 스레드가 I/O의 실질적 시작자 |
| Orchestrator | OS kernel (VFS→block layer→NVMe driver) | CPU (cuFile→nvidia-fs.ko→VFS→NVMe driver) | **GPU runtime** (page_cache_t + QueuePair). CPU는 초기화만 | GDS는 CPU 전 과정 오케스트레이션, BaM은 GPU 자율적 |
| Data mover | NVMe DMA engine → CPU DRAM | NVMe DMA engine → GPU BAR1 (P2P) | NVMe DMA engine → GPU memory (P2P) | 두 GPU 모델 모두 DMA 엔진이 실제 데이터 이동 수행 |
| Final consumer | CPU thread (user buffer에서 처리) | GPU kernel (VRAM에서 연산) | GPU thread (캐시된 데이터로 즉시 연산) | BaM은 I/O 완료 후 동일 스레드가 즉시 소비 |
| Typical API surface | POSIX read/write, io_uring, SPDK | cuFileRead/Write (ioctl 기반) | `bam::array<T>[i]`, `bam_ptr<T>` (C++ 연산자) | BaM의 API가 메모리 접근과 구분 불가능 |
| Access abstraction | File descriptor + offset + length | File handle + GPU ptr + offset + length | **Array index / pointer dereference** | BaM은 파일 개념 없이 배열/포인터 접근 |
| Granularity | 512B~MB (block I/O) | 32KB~MB (cuFile 효율 구간) | **512B~4KB** (fine-grained, 캐시 coalescing) | BaM이 세밀한 랜덤 접근에서 압도적 효율 |
| Latency hiding method | 비동기 I/O (io_uring, AIO), 스레드 풀 | CPU 스레드 풀 + 비동기 cuFile batch | **GPU warp scheduling** — I/O 대기 warp을 SM이 자동 교체 | GPU의 대규모 병렬성이 I/O 지연을 자연스럽게 은닉 |
| Completion model | Interrupt / polling (io_uring CQ) | CPU kiocb 완료 콜백 | **GPU thread CQ polling** (NVMe CQ를 GPU에서 직접 폴링) | BaM은 CPU 인터럽트 없이 GPU가 완료 감지 |
| Page cache involvement | 기본 사용 (O_DIRECT로 우회 가능) | **없음** (O_DIRECT 강제) | **없음** (OS 우회, raw NVMe) | 두 GPU 모델 모두 OS page cache 미사용 |
| O_DIRECT relevance | 선택적 (성능 최적화용) | **필수** (nvfs-core.c에서 강제) | **해당 없음** (파일시스템 자체 미사용) | GDS는 O_DIRECT 필수, BaM은 FS 자체가 없음 |
| DMA path | NVMe → CPU DRAM (표준) | NVMe → GPU BAR1 (nvidia-fs SGL 리매핑) | NVMe → GPU memory (libnvm P2P 매핑) | 두 GPU 모델 모두 동일 nvidia_p2p_get_pages() API 사용 |
| Memory semantic 가능성 | Confirmed No (block I/O) | Confirmed No (block I/O, CPU 제어) | **Confirmed Yes** (operator[], demand paging, SW cache) | BaM만 진정한 memory semantic 제공 |
| Block I/O semantic 가능성 | Confirmed Yes | Confirmed Yes | Confirmed No (NVMe 명령 직접 발행, block layer 우회) | BaM은 Linux block layer를 완전히 우회 |

---

### 2-2. CPU core vs GPU thread/warp/block/SM 해석 표

| Term | What It Is | Storage Access Analysis Relevance | Common Misunderstanding | Correct Interpretation |
|------|-----------|----------------------------------|------------------------|----------------------|
| CPU core | 독립적 명령 스트림 실행 유닛, OoO 파이프라인, 독자적 L1/L2 | I/O syscall의 실행 주체이자 인터럽트 수신자. 1 core = 1 I/O 제어 흐름 단위 | "CPU core가 SSD를 읽는다" | CPU core는 I/O를 **요청(initiate)**하고 **오케스트레이션**하지만, 데이터 이동은 DMA 엔진이 수행 |
| CPU thread | CPU core 위의 논리적 실행 스트림 (HT/SMT 포함) | 각 thread가 독립적 I/O syscall 발행 가능. io_uring SQ 명령 삽입 단위 | "thread 수 = 동시 I/O 수" | I/O 큐 깊이와 thread 수는 독립적. 1 thread가 io_uring으로 다수 비동기 I/O 가능 |
| GPU thread | 최소 실행 단위. 단일 SIMT lane. 개별 레지스터 보유 | BaM에서 개별 thread가 `operator[]` 호출 → I/O trigger 가능 | "GPU thread = CPU thread 동급" | GPU thread 1개는 CPU thread보다 훨씬 가벼움. 수만 개 동시 존재, I/O 지연 중 SM이 다른 warp으로 전환 |
| GPU warp | 32개 thread의 SIMT 실행 그룹. 동일 명령 lock-step 실행 | **BaM 캐시 조회의 실질 단위.** `__match_any_sync()`로 warp 내 동일 페이지 접근 합체 | "각 thread가 독립적 I/O" | **Warp이 I/O coalescing의 자연 단위.** 32 thread 중 동일 페이지 접근 시 리더 1개만 캐시/NVMe 처리 |
| GPU block | 다수 warp 그룹. 공유 메모리(SMEM) 공유. 1 SM에 할당 | Block 내 warp들이 SMEM으로 I/O 결과 협력 가능 | "block = 스레드 풀" | Block은 SM 자원 할당 단위. I/O 분석에서는 warp 수준이 더 중요 |
| GPU SM | Streaming Multiprocessor. 다수 warp을 시분할 실행 | I/O 대기 warp과 연산 중 warp을 자동 전환하는 스케줄러 보유 | "SM이 I/O를 처리" | SM은 I/O를 처리하지 않음. warp scheduling으로 I/O **지연을 은닉** |
| CPU runtime/kernel | OS 커널: VFS, block layer, NVMe driver, 인터럽트 핸들러 | 전통적 I/O에서 전체 데이터 경로를 제어. GDS에서도 제어 경로 담당 | "커널이 데이터를 옮긴다" | 커널은 데이터 이동을 **명령(orchestrate)**, 실제 이동은 DMA 엔진 |
| GPU runtime/driver | CUDA runtime, GPU device driver, BaM의 page_cache_t + QueuePair | BaM에서 NVMe 큐/캐시 관리를 GPU 측에서 수행 | "GPU driver가 I/O 처리" | BaM GPU runtime은 NVMe 큐에 명령 삽입 + 완료 폴링. OS driver를 **대체** |
| DMA engine | NVMe 컨트롤러 내장 DMA 엔진. scatter-gather list 기반 데이터 전송 | **모든 경로에서 실제 데이터를 이동시키는 유일한 주체** | "CPU/GPU가 데이터를 옮긴다" | CPU도 GPU도 데이터를 직접 옮기지 않음. DMA 엔진이 PCIe 버스를 통해 전송 |
| NVMe controller | SSD 내부의 명령 처리기. SQ에서 명령 fetch, DMA 실행, CQ에 완료 기록 | I/O 명령의 최종 실행자이자 DMA 발생기 | "SSD가 수동적" | NVMe 컨트롤러가 SQ를 능동적으로 fetch하고 DMA를 주도함 |

---

### 2-3. Initiator / Orchestrator / Data Mover / Consumer 구분 표

| Scenario | Initiator | Orchestrator | Data Mover | Consumer | Notes |
|----------|-----------|-------------|------------|----------|-------|
| 전통적 CPU read() path | CPU thread (syscall 발행) | OS kernel (VFS→block layer→NVMe driver) | NVMe DMA engine → CPU DRAM | CPU thread (user buffer) | 가장 단순한 모델. initiator=consumer |
| CPU mmap/page cache path | CPU thread (page fault 발생) | OS kernel (page fault handler→readahead→block layer) | NVMe DMA engine → page cache → MMU 매핑 | CPU thread (가상 주소 접근) | demand paging: 첫 접근 시 fault로 I/O trigger |
| CPU O_DIRECT path | CPU thread (pread with O_DIRECT) | OS kernel (VFS→block layer, page cache 우회) | NVMe DMA engine → user buffer 직접 | CPU thread (user buffer) | page cache 제거, DMA가 user space로 직접 |
| CPU io_uring path | CPU thread (SQE 삽입) | io_uring kernel thread (SQ polling) | NVMe DMA engine → DRAM | CPU thread (CQE 소비) | initiator와 orchestrator가 분리됨 |
| CPU SPDK path | CPU thread (SPDK API 호출) | SPDK user-space driver (polling) | NVMe DMA engine → user buffer | CPU thread | kernel 우회, user-space NVMe 드라이버 |
| **GDS 기반 GPU path** | **CPU thread** (cuFileRead 호출) | **CPU** (cuFile→nvidia-fs.ko→VFS→NVMe driver) | **NVMe DMA engine → GPU BAR1** (SGL 리매핑) | **GPU kernel** | initiator(CPU)≠consumer(GPU). CPU가 orchestrate |
| **BaM GPU-initiated path** | **GPU warp** (operator[] cache miss) | **GPU runtime** (page_cache_t + QueuePair) | **NVMe DMA engine → GPU memory** (P2P) | **GPU thread** (동일 warp) | initiator≈consumer. GPU가 전체 자율 제어 |
| DeepSpeed ZeRO-Infinity | CPU thread (Python runtime) | CPU (DeepSpeed engine) | NVMe DMA→DRAM + cudaMemcpy→GPU | GPU kernel | 2단계 data move: NVMe→CPU→GPU |
| FlashNeuron | CPU thread (PyTorch allocator) | CPU (수정된 allocator) | SSD→DRAM(CPU DMA) + cudaMemcpy→GPU | GPU kernel | CPU-mediated swap |

이 표에서 핵심 구분: GDS와 BaM은 data mover(NVMe DMA→GPU)는 동일하지만, initiator와 orchestrator가 근본적으로 다르다. GDS는 CPU가 initiate+orchestrate, BaM은 GPU가 initiate+orchestrate.

---

### 2-4. 오해 바로잡기 표

| Statement | Strictly True Part | Misleading Part | Correct Technical Rephrasing |
|-----------|-------------------|-----------------|------------------------------|
| "CPU core가 SSD를 읽는다" | CPU core가 I/O syscall을 발행하고 NVMe driver를 통해 NVMe SQ에 명령 삽입 | CPU core가 데이터를 직접 이동시키지 않음. DMA 엔진이 SSD→DRAM 전송 | "CPU core가 NVMe I/O를 **initiate**하고, NVMe DMA 엔진이 데이터를 DRAM으로 **move**하며, CPU core가 결과를 **consume**한다" |
| "GPU thread가 SSD를 직접 읽는다" | BaM에서 GPU thread가 NVMe SQ에 명령 삽입+doorbell ring | GPU thread가 NAND에 직접 접근하는 것이 아님. NVMe 프로토콜 간접 접근. GDS에서는 GPU thread가 아예 I/O 미발행 | "**BaM**에서 GPU thread가 NVMe 명령을 **compose+submit**하고, NVMe DMA가 GPU 메모리로 **move**. **GDS**에서는 CPU가 submit, DMA가 GPU로 직접 move" |
| "SSD를 VRAM처럼 쓴다" | BaM의 operator[]가 SSD 데이터를 배열 인덱싱으로 투명 접근 | 지연 100~1000x (HBM ~100ns vs SSD ~10-100μs). 대역폭 100x+ (HBM 2-5TB/s vs SSD ~25GB/s). 캐시 일관성 모델 다름. 쓰기 수명 제한 | "SSD를 GPU 메모리 계층의 **최하위 demand-paging 티어**로 편입하여 소프트웨어 캐시를 통해 **투명 접근**을 제공. VRAM과 동일 성능·일관성은 미보장" |
| "GPU가 storage를 memory처럼 access한다" | BaM의 프로그래밍 모델이 load/store-like 추상화 제공 | HW 수준 memory semantic이 아닌 SW 에뮬레이션. CXL.mem과 달리 캐시 일관성 프로토콜 없음. NVMe 프로토콜은 block I/O 기반 | "BaM이 **소프트웨어 계층에서** memory-like 추상화를 제공하나, HW 프로토콜은 여전히 NVMe block I/O. 진정한 HW memory semantic은 CXL 3.0+ 통합 필요" |

---

### 2-5. 후속 프로젝트 판정 기준 표

| Criterion | What To Check | Why It Matters | Possible Values |
|-----------|--------------|----------------|-----------------|
| Access initiator | 누가 I/O를 요청하는가 | request ownership 구분 | CPU thread / CPU runtime / GPU runtime / GPU kernel(warp) / mixed |
| Orchestrator | 누가 전체 흐름을 제어하는가 | 제어권 분석 | CPU / GPU runtime / driver / mixed |
| Data mover | 누가 실제 데이터를 이동시키는가 | direct path 판정 | NVMe DMA engine / CPU copy+cudaMemcpy / mixed |
| Final consumer | 누가 최종 데이터를 사용하는가 | 소비자와 initiator 분리 | CPU thread / GPU kernel / mixed |
| Memory semantic 여부 | load/store형 추상화인가, 명시적 I/O 호출인가 | 진짜 memory-like인지 판정 | Confirmed Yes / Confirmed No / Likely Yes / Likely No / Unclear |
| GPU direct path 여부 | NVMe→GPU direct DMA인가, CPU DRAM 경유인가 | 핵심 데이터 경로 판정 | Confirmed Yes / Confirmed No / Likely Yes / Likely No / Unclear |
| CPU bounce buffer 제거 여부 | host DRAM 경유 제거 여부 | 성능·구조 핵심 | Confirmed Yes / Confirmed No / Likely Yes / Likely No / Unclear |
| On-demand faulting | fault/miss 기반 자동 fetch 구조가 있는가 | paging semantics 확인 | Confirmed Yes / Confirmed No / Likely Yes / Likely No / Unclear |
| Prefetch/cache | prefetcher/cache manager 존재 여부 | out-of-core 성격 확인 | Confirmed Yes / Confirmed No / Likely Yes / Likely No / Unclear |
| Granularity | 접근 단위 크기 | semantic 판단 (fine-grained=memory-like, coarse=block I/O) | byte / page(4KB) / block(32KB+) / extent(MB+) / object / mixed |
| Best execution abstraction | 분석 시 어떤 실행 단위로 보는 것이 가장 정확한가 | CPU/GPU 관점 오해 방지 | CPU thread / GPU warp / GPU runtime / DMA engine / mixed |
| Production vs Research | 실사용 성숙도 | 도입 가능성 평가 | production / prototype / experimental |

이 기준표는 섹션 4 (Project Classification Matrix)의 각 열을 채울 때 참조한다.

---

## 3. Candidate Project Discovery Table

| # | Project | GitHub URL | Owner Type | NVIDIA Official? | Related Keywords | Why It Is a Candidate | Last Update | Activity | Keep/Exclude | Exclusion Reason |
|---|---------|-----------|------------|-----------------|-----------------|----------------------|-------------|----------|-------------|-----------------|
| 1 | **GDS** (gds-nvidia-fs) | github.com/NVIDIA/gds-nvidia-fs | NVIDIA | **Confirmed Yes** | GDS, GPUDirect Storage, cuFile, NVMe P2P | GPU-SSD 직접 DMA 공식 커널 드라이버 | 2026-03 | Active | **Keep** | — |
| 2 | **BaM** | github.com/ZaidQureshi/bam | NVIDIA+IBM+UIUC | Confirmed No (공동연구) | BaM, GPU-initiated, memory semantic | GPU thread가 NVMe 직접 발행, memory semantic 추상화 | 2024 | Moderate | **Keep** | — |
| 3 | **GIDS** | github.com/jeongminpark417/GIDS | Academic | Confirmed No | GIDS, GPU-initiated, GNN, BaM-based | BaM 기반 GNN 데이터로더, 3계층 메모리 | 2024 | Moderate | **Keep** | — |
| 4 | **KvikIO** | github.com/rapidsai/kvikio | RAPIDS (NVIDIA-affiliated) | Likely Yes | cuFile, GDS, Python bindings | cuFile/GDS 고수준 C++/Python 래퍼 | 2026-03 | Active | **Keep** | — |
| 5 | **DeepSpeed** | github.com/deepspeedai/DeepSpeed | Microsoft | Confirmed No | ZeRO-Infinity, NVMe offload | SSD를 메모리 계층으로 활용 (CPU 경유) | 2026-03 | Very Active | **Keep** | — |
| 6 | **FlashNeuron** | github.com/SNU-ARC/flashneuron | Seoul Nat'l Univ | Confirmed No | GPU SSD offload, tensor swap | DNN 텐서 SSD 오프로드 VRAM 확장 | 2025-11 | Stale | **Keep** | — |
| 7 | **gdrcopy** | github.com/NVIDIA/gdrcopy | NVIDIA | **Confirmed Yes** | GPUDirect RDMA, BAR1, P2P | GPU 메모리 CPU 매핑 인프라, P2P 기반 기술 | 2026-03 | Active | **Keep** | — |
| 8 | **MagnumIO** | github.com/NVIDIA/MagnumIO | NVIDIA | **Confirmed Yes** | Magnum IO, GDS examples | GDS 상위 프레임워크, 예제/문서 | 2026-03 | Active | **Keep** | — |
| 9 | **GPUfs** | github.com/gpufs/gpufs | Academic | Confirmed No | GPU filesystem, kernel file API | GPU 커널에서 POSIX-like 파일 접근 (BaM 선행) | 2026-02 | Active | **Keep** | — |
| 10 | **gdsllm** | github.com/rscunha13/gdsllm | Individual | Confirmed No | GDS, LLM, weight streaming | GDS로 LLM weight NVMe→VRAM 스트리밍 | 2026-03 | Active | **Keep** | — |
| 11 | libgdsync | github.com/gpudirect/libgdsync | gpudirect org | Likely Yes (affiliated) | GPUDirect Async | GPU-initiated async I/O (InfiniBand) | 2026-01 | Moderate | **Exclude** | InfiniBand 중심, SSD/NVMe 무관 |
| 12 | cuda-samples | github.com/NVIDIA/cuda-samples | NVIDIA | Confirmed Yes | cuFile examples | GDS/cuFile 사용 예제 포함 | 2026-03 | Active | **Exclude** | 예제 코드, 새로운 추상화 없음 |
| 13 | gpu-out-of-core-xtx | github.com/duongtrongnguyen123/... | Individual | Confirmed No | out-of-core GPU matrix | Host memory 기반 out-of-core GPU 연산 | 2026-01 | Moderate | **Exclude** | SSD 아닌 CPU DRAM 기반 |

BaM은 NVIDIA 소속 연구자(Bill Dally 포함)가 참여했으나 NVIDIA org 소유가 아님. "NVIDIA 공식"과 "NVIDIA 참여"를 구분해야 한다.

---

## 4. Project Classification Matrix

| Dimension | GDS (gds-nvidia-fs) | BaM | GIDS | KvikIO | DeepSpeed ZeRO-∞ | FlashNeuron | gdrcopy | GPUfs | gdsllm |
|-----------|-------------------|-----|------|--------|------------------|-------------|---------|-------|--------|
| **Official Status** | NVIDIA Official | NVIDIA research collab | Academic | NVIDIA-affiliated | Microsoft | Academic | NVIDIA Official | Academic | Community |
| **Primary Goal** | NVMe→GPU direct DMA | GPU-initiated memory-semantic SSD | GNN dataloader (BaM-based) | GDS Python/C++ 래퍼 | Trillion-param NVMe offload | DNN tensor SSD offload | Low-latency CPU↔GPU copy | GPU-kernel file API | LLM weight streaming |
| **Access Initiator** | CPU thread | **GPU warp** | **GPU warp** | CPU thread | CPU thread | CPU thread | CPU thread | **GPU thread** | CPU thread |
| **Orchestrator** | CPU (VFS+NVMe driver) | **GPU runtime** (page_cache_t) | **GPU runtime** (BaM) | CPU (thread pool) | CPU (DeepSpeed engine) | CPU (PyTorch) | CPU | GPU runtime + CPU helper | CPU (scheduler) |
| **Data Mover** | NVMe DMA → GPU BAR1 | NVMe DMA → GPU mem (P2P) | NVMe DMA → GPU mem (P2P) | NVMe DMA → GPU or CPU memcpy | NVMe DMA→DRAM + cudaMemcpy→GPU | SSD→DRAM + cudaMemcpy→GPU | CPU load/store via BAR1 | CPU-mediated DMA | NVMe DMA → GPU (GDS) |
| **Final Consumer** | GPU kernel | GPU thread | GPU thread (DGL) | GPU kernel / RAPIDS | GPU (PyTorch) | GPU (training) | CPU thread | GPU thread | GPU (LLM inference) |
| **Access API Type** | Block I/O (cuFile) | **Memory semantic** (operator[]) | **Memory semantic** (bam_ptr) | File I/O (pread/pwrite) | File I/O + cudaMemcpy | Modified allocator | BAR mapping API | POSIX-like from GPU | cuFile (GDS) |
| **Memory Semantic?** | Confirmed No | **Confirmed Yes** | **Confirmed Yes** | Confirmed No | Confirmed No | Confirmed No | Confirmed No | Likely Yes | Confirmed No |
| **GPU Direct Data Path?** | Confirmed Yes | Confirmed Yes | Confirmed Yes | Confirmed Yes (GDS) | Confirmed No | Confirmed No | Confirmed No | Likely No | Confirmed Yes |
| **CPU Bounce Buffer Removed?** | Confirmed Yes | Confirmed Yes | Confirmed Yes | Confirmed Yes (GDS) / No (fallback) | Confirmed No | Confirmed No | N/A | Likely No | Confirmed Yes |
| **On-demand Faulting?** | Confirmed No | **Confirmed Yes** | **Confirmed Yes** | Confirmed No | Confirmed No | Confirmed No | Confirmed No | Likely Yes | Confirmed No |
| **Prefetch/Cache Layer?** | Confirmed No | **Confirmed Yes** (GPU SW cache, clock eviction) | **Confirmed Yes** (3-tier + lookahead) | Confirmed No | Confirmed Yes (CPU-side) | Confirmed Yes (proactive swap) | Confirmed No | Likely Yes | Confirmed Yes |
| **Granularity** | block (32KB~MB) | **page (512B~4KB)** | page (4KB) | block (variable) | extent (MB~GB) | extent (MB~GB) | byte (64B~MB) | page | extent (MB~GB) |
| **Read/Write** | R+W | R+W | R only (Likely) | R+W | R+W | R+W | R+W | R+W | R only (Likely) |
| **Best Execution Abstraction** | **CPU thread** | **GPU warp** | **GPU warp** | **CPU thread** | **CPU thread** | **CPU runtime** | **CPU thread** | **Mixed** (GPU thread + CPU) | **CPU thread** |
| **Production vs Research** | **Production** | **Research** | **Research** | **Production** | **Production** | **Research** | **Production** | **Research** | **Experimental** |
| **Confidence** | High | High | High | High | High | Medium | High | Medium | Medium-Low |

이 매트릭스에서 핵심 구분은 **Access Initiator**와 **Memory Semantic** 열이다. GPU warp이 직접 I/O를 시작하고 memory semantic을 제공하는 것은 BaM과 GIDS뿐이다. GDS는 data path에서 bounce buffer를 제거했으나 control path에서 CPU가 필수이므로 memory semantic이 아니다.

---

## 5. Data Path Table

| Dimension | GDS | BaM | GIDS | DeepSpeed ZeRO-∞ | KvikIO (GDS mode) | Confidence |
|-----------|-----|-----|------|-------------------|--------------------|------------|
| **Read Path** | CPU: cuFileRead→ioctl→VFS→NVMe driver→SGL remap→NVMe DMA→GPU BAR1 | GPU: operator[]→cache miss→NVMe cmd→SQ enqueue→doorbell MMIO→NVMe DMA→GPU mem→CQ poll | GPU: bam_ptr.read()→BaM cache→miss→BaM NVMe→GPU mem | CPU: aio_read→NVMe→DRAM→pin_memory→cudaMemcpyAsync→GPU | CPU: FileHandle.read()→cuFileRead→GDS path | High |
| **Write Path** | CPU: cuFileWrite→ioctl→VFS→NVMe driver→GPU BAR1 DMA read→NVMe write | GPU: dirty page writeback→NVMe write cmd→SQ→doorbell→DMA GPU→SSD | Likely No write | CPU: GPU→cudaMemcpy→DRAM→aio_write→NVMe | CPU: FileHandle.write()→cuFileWrite→GDS path | High |
| **Control Path** | CPU 전체 제어: ioctl→VFS→block→NVMe driver | GPU 자율: page_cache_t miss/hit/evict 판정, QueuePair NVMe 큐 관리 | GPU 자율(BaM) + GIDS 스케줄러 | CPU 전체: DeepSpeed offload/prefetch 스케줄링 | CPU 전체 (=GDS) | High |
| **CPU Involvement** | **High**: 모든 I/O에 CPU syscall 필요 | **None (runtime)**: 초기화 후 0% | **None (runtime)** | **High**: 모든 이동에 CPU 관여 | **High** | High |
| **GPU Involvement** | **Passive**: DMA target만 | **Active**: I/O 발행 + CQ 폴링 + 캐시 관리 | **Active** | **Passive**: cudaMemcpy 수신 | **Passive** | High |
| **DMA Path** | NVMe ctrl → PCIe P2P → GPU BAR1 (nvidia-fs SGL remap) | NVMe ctrl → PCIe P2P → GPU mem (libnvm P2P) | =BaM | NVMe ctrl → CPU DRAM (표준) | =GDS | High |
| **Uses cuFile/GDS?** | Yes (핵심) | **No** (커스텀 libnvm) | **No** (libnvm via BaM) | No (Linux AIO) | Yes (핵심) | High |
| **Uses Filesystem?** | Yes (XFS/EXT4 + O_DIRECT) | **No** (raw NVMe) | **No** | Yes (표준 FS) | Yes (=GDS) | High |
| **O_DIRECT?** | **필수** | **해당 없음** (FS 미사용) | **해당 없음** | 선택적 | **필수** | High |
| **Key Limitation** | CPU control path 상시 관여; fine-grained 비효율; GPU 커널 내 동적 접근 불가 | 커스텀 NVMe 드라이버; IOMMU OFF; 표준 FS 미지원; 연구 프로토타입 | BaM 한계 + DGL 종속 | CPU DRAM bounce; cudaMemcpy 오버헤드 | =GDS | High |

---

### 5-A. ASCII Path Classification Table

| Project | ASCII Path | Status | Evidence |
|---------|-----------|--------|----------|
| CPU Traditional | `App thread ──syscall──→ VFS ──→ block layer ──→ NVMe driver ──→ NVMe DMA ──→ CPU DRAM ──→ cudaMemcpy ──→ GPU HBM` | Confirmed | 표준 Linux I/O 경로 |
| CPU O_DIRECT | `App thread ──pread(O_DIRECT)──→ VFS ──→ block layer ──→ NVMe driver ──→ NVMe DMA ──→ user buffer(DRAM) ──→ cudaMemcpy ──→ GPU` | Confirmed | O_DIRECT: page cache 우회, user buffer 직접 |
| **GDS** | `App thread ──cuFileRead──→ ioctl(/dev/nvidia-fs) ──→ VFS(O_DIRECT) ──→ NVMe driver ──→ SGL remap(GPU addr) ──→ NVMe DMA ══P2P══→ GPU BAR1` | **Confirmed** | nvfs-core.c ioctl, nvfs-dma.c SGL remap |
| **BaM** | `GPU thread ──operator[]──→ page_cache_t ──miss──→ NVMe cmd build ──→ SQ enqueue(atomic ticket) ──→ doorbell MMIO(PTX) ──→ NVMe DMA ══P2P══→ GPU mem ──→ CQ poll ──→ return` | **Confirmed** | page_cache.h operator[], nvm_parallel_queue.h sq_enqueue, module/map.c P2P |
| **GIDS** | `GPU thread ──bam_ptr.read()──→ BaM cache ──miss──→ [BaM NVMe path] ──→ GPU mem ──→ DGL GNN kernel` | **Confirmed** | BaM submodule + read_feature_kernel |
| DeepSpeed | `CPU thread ──aio_read──→ NVMe ──→ CPU DRAM(pinned) ──cudaMemcpyAsync──→ GPU HBM` | Confirmed | ZeRO-Infinity 공식 문서 |
| FlashNeuron | `CPU allocator ──SSD read──→ CPU DRAM ──cudaMemcpy──→ GPU HBM (+ 압축 해제)` | Likely | ATC '21 논문 기반, 코드 상세 미확인 |
| gdsllm | `CPU scheduler ──cuFileRead──→ GDS path ──→ NVMe DMA ══P2P══→ GPU VRAM ──→ LLM inference` | Likely | GDS 기반 구현 추정, 상세 코드 미확인 |

핵심 차이: GDS path에서 `App thread`(CPU)가 시작점이고, BaM path에서 `GPU thread`가 시작점이다. Data mover(NVMe DMA ══P2P══→ GPU)는 동일하지만 initiator+orchestrator가 완전히 다르다.

---

## 6. Code Evidence Table

### 6-A. BaM (ZaidQureshi/bam)

| File | Symbol | Role | What It Proves | Confidence |
|------|--------|------|---------------|------------|
| `include/page_cache.h` | `array_d_t<T>::operator[](size_t i)` | `__device__` 연산자: 페이지 계산→캐시 조회→miss 시 NVMe read→반환 | **Memory semantic**: SSD를 배열 인덱싱으로 투명 접근 | High |
| `include/page_cache.h` | `data_page_t` states: INVALID/VALID/BUSY/DIRTY | 캐시 상태 머신, atomic CAS로 GPU 관리 | **GPU-resident cache coherence protocol** | High |
| `include/page_cache.h` | `find_slot()` clock-style eviction | Atomic ticket mod n_pages, CAS lock, dirty writeback | **GPU 스레드가 캐시 교체·writeback 직접 수행** | High |
| `include/page_cache.h` | `__device__ read_data()`, `write_data()` | QueuePair로 NVMe read/write 발행 | **GPU-initiated NVMe I/O 직접 증거** | High |
| `include/page_cache.h` | `__match_any_sync(0xFFFFFFFF, page_id)` | Warp 내 동일 페이지 접근 스레드 감지, 리더 선출 | **Warp이 I/O coalescing의 자연 단위** | High |
| `include/bafs_ptr.h` | `bafs_ptr<T>`: operator[], *, ++, -- | 포인터 산술+인덱스 접근, `__host__ __device__` | **완전한 memory-semantic 스마트 포인터** | High |
| `include/nvm_types.h` | `nvm_queue_t` with `simt::atomic` | SQ/CQ를 libcu++ GPU atomics로 관리 | **NVMe 큐가 GPU 스레드 호환 설계** | High |
| `include/nvm_parallel_queue.h` | `sq_enqueue()`: fetch_add ticket + PTX `st.mmio.relaxed.sys` doorbell | Lock-free 큐 삽입 + 인라인 PTX doorbell 쓰기 | **수천 GPU 스레드 동시 NVMe 명령 제출** | High |
| `include/nvm_parallel_queue.h` | `cq_poll()`: CQ 스캔, CID 매칭, phase bit | GPU CQ polling | **CPU 인터럽트 없이 GPU 완료 감지** | High |
| `include/buffer.h` | `createDma()` → `nvm_dma_map_device()` | GPU 메모리를 NVMe DMA 주소로 매핑 | **P2P DMA 설정 증거** | High |
| `module/map.c` | `map_gpu_memory()`: `nvidia_p2p_get_pages()` + `nvidia_p2p_dma_map_pages()` | GPU 메모리 핀 + NVMe용 DMA 매핑 생성 | **NVIDIA P2P API로 GPU↔NVMe 직접 DMA 구축** | High |
| `module/pci.c` | `add_pci_dev()`: `pci_set_master()` + BAR0 매핑 | NVMe bus mastering 활성화, 레지스터 매핑 | **커널 수준 P2P DMA 활성화** | High |

### 6-B. GDS (NVIDIA/gds-nvidia-fs)

| File | Symbol | Role | What It Proves | Confidence |
|------|--------|------|---------------|------------|
| `src/nvfs-dma.c` | `nvfs_blk_rq_map_sg_internal()` | bio_vec→`nvfs_get_gpu_page_info()`→`sg_set_page()` GPU addr SGL | **SGL 리매핑: CPU 주소→GPU BAR 주소 치환** | High |
| `src/nvfs-dma.c` | `nvfs_dma_map_sg_attrs_internal()` | 각 SG 엔트리에 `nvfs_get_dma()` → GPU DMA 주소 | **NVMe가 GPU BAR에 직접 DMA** | High |
| `src/nvfs-dma.c` | `struct nvfs_dma_rw_ops` | `.nvfs_blk_rq_map_sg`, `.nvfs_is_gpu_page` 콜백 | **Block layer hook: 스토리지 드라이버가 콜백 호출** | High |
| `src/nvfs-core.c` | `nvfs_ioctl()` | IOCTL_READ/WRITE/MAP/BATCH 디스패치 | **모든 GDS I/O가 CPU ioctl로 시작** | High |
| `src/nvfs-core.c` | `nvfs_direct_io()` | `vfs_read/write` with O_DIRECT | **표준 VFS 경로, O_DIRECT 강제** | High |
| `src/nvfs-core.c` | `nvfs_pin_gpu_pages()` | `nvidia_p2p_get_pages()` 호출 | **GPU 메모리 핀: P2P DMA 전제 조건** | High |
| `src/nvfs-core.c` | State: `IO_FREE→INIT→READY→IN_PROGRESS→...` | `nvfs_transit_state()` | **CPU가 I/O 생명주기 전체 관리** | High |
| `src/nvfs-mmap.c` | `nvfs_mgroup_get_gpu_physical_address()` | Shadow page→GPU 물리 주소 변환 | **Shadow buffer→GPU 주소 핵심 indirection** | High |
| `src/nvfs-mmap.c` | `nvfs_is_gpu_page()` | 페이지가 GPU mgroup에 속하는지 판별 | **Block layer의 GPU/CPU 페이지 구분 방법** | High |
| `src/nvfs-pci.c` | `__nvfs_get_gpu2peer_distance()` | PCIe bridge depth + NUMA distance 계산 | **P2P 경로 토폴로지 최적화** | High |
| `src/nvfs-core.h` | `GPU_PAGE_SIZE = 64KB` | GPU 페이지 단위 | **SGL 리매핑 기본 단위 64KB** | High |
| `src/nvfs-p2p.h` | 8개 `nvidia_p2p_*` 매크로 | NVIDIA P2P 커널 API 추상화 | **GDS와 BaM 모두 동일 P2P API 의존** | High |

### 6-C. KvikIO / GIDS

| Project | File | Symbol | Role | What It Proves | Confidence |
|---------|------|--------|------|---------------|------------|
| KvikIO | `file_handle.hpp` | `FileHandle` (O_DIRECT fd + cuFile handle) | 이중 fd 관리 | **O_DIRECT가 GDS 필수 조건** | High |
| KvikIO | `cufile.hpp` | `cuFileAPI` singleton (dlopen shim) | libcufile.so 런타임 로드 | **GDS 런타임 의존성 동적 해결** | High |
| KvikIO | `posix_io.hpp` | `posix_device_io()` pread→bounce→cudaMemcpy | GDS 미지원 시 CPU 폴백 | **GDS 없으면 CPU bounce 필요** | High |
| GIDS | `bam/` (submodule) | BaM 전체 코드 | I/O 기반 | **GIDS는 BaM 위에 구축** | High |
| GIDS | GPU kernel | `read_feature_kernel`: `bam_ptr<T>.read()` | GPU thread가 SSD 직접 읽기 | **GPU-initiated SSD 접근의 GNN 적용** | High |

GDS와 BaM의 코드 증거에서 공통점: 둘 다 `nvidia_p2p_get_pages()` + `nvidia_p2p_dma_map_pages()`를 사용하여 GPU 메모리를 NVMe DMA target으로 등록. 차이점: GDS는 표준 NVMe 드라이버의 SGL을 리매핑하고, BaM은 NVMe 컨트롤러를 GPU가 직접 제어.

---

## 7. CPU-style vs GPU-style Interpretation Table

| Project | CPU-style Interpretation | GPU-style Interpretation | Most Accurate Access Unit | Why |
|---------|-------------------------|-------------------------|--------------------------|-----|
| **GDS** | "CPU가 파일을 읽어서 GPU 메모리에 DMA로 넣어준다" — **정확함.** cuFileRead는 CPU syscall, CPU가 NVMe 제어 | "GPU가 스토리지에서 데이터를 가져온다" — **부정확.** GPU는 DMA target일 뿐, I/O 제어 무관여 | **CPU thread** (+NVMe DMA engine) | CPU thread가 cuFileRead로 I/O 발행, NVMe DMA가 move, GPU는 수동적 수신자 |
| **BaM** | "CPU가 NVMe를 초기화하고 GPU에 큐를 넘긴다" — 초기화에서만 정확 | "GPU warp이 NVMe 명령을 직접 발행하고 데이터를 가져온다" — 런타임에서 **정확** | **GPU warp** (coalescing 단위) | `__match_any_sync()` 기반 coalescing이 warp 경계에서 발생. 리더 thread가 캐시/NVMe 처리 |
| **GIDS** | "CPU가 GNN 학습을 오케스트레이션" — 학습 루프에서 부분적 맞음 | "GPU warp이 노드 특징을 SSD에서 on-demand로 가져온다" — I/O에서 **정확** | **GPU warp** (=BaM) | BaM runtime이 warp 단위 coalescing 수행 |
| **KvikIO** | "CPU thread pool이 파일 I/O 병렬 실행" — **정확** | "GPU는 데이터 소비자" — **정확** | **CPU thread** (pool) | CPU가 cuFile/POSIX 발행, GPU는 결과 소비 |
| **DeepSpeed** | "CPU가 NVMe에서 읽어 GPU에 복사" — **정확** | "GPU는 도착 데이터로 연산" — **정확** | **CPU thread** (+cudaMemcpy) | CPU 전체 제어, GPU 완전 수동적 |
| **FlashNeuron** | "CPU가 텐서를 SSD↔GPU swap" — **정확** | "GPU 연산 중 미사용 텐서가 SSD로 내려감" — 추상적 맞으나 GPU는 swap 무관여 | **CPU runtime** (PyTorch allocator) | 수정된 allocator가 swap 결정 |
| **GPUfs** | "CPU가 GPU의 파일 요청을 대리 처리" — 구현에서 맞음 | "GPU thread가 open/read/write 호출" — API에서 **정확** | **Mixed**: GPU thread(API) + CPU(실제 I/O) | GPU가 요청, CPU가 실행하는 협력 모델 |
| **gdrcopy** | "CPU가 GPU BAR1 매핑으로 직접 읽고 쓴다" — **정확** | N/A (SSD 무관) | **CPU thread** (BAR1 load/store) | CPU→GPU BAR1 직접 접근 |
| **gdsllm** | "CPU가 GDS로 weight를 GPU에 스트리밍" — **정확** | "GPU가 weight를 SSD에서 가져온다" — **부정확** (GDS는 CPU-initiated) | **CPU thread** (GDS 경유) | CPU cuFileRead → NVMe P2P → GPU |

---

## 8. Final Judgment Table

| Question | Best Answer | Best Matching Project(s) | Why | Confidence |
|----------|-----------|-------------------------|-----|------------|
| SSD를 truly memory semantic하게 다루는 NVIDIA 오픈소스가 있는가? | NVIDIA org 소유로는 **없다.** NVIDIA 연구자 참여 BaM이 가장 가까움 | BaM (ZaidQureshi/bam) | operator[], bam_ptr로 투명 접근 + cache miss 자동 NVMe fetch. NVIDIA org 소유 아닌 공동 연구 | High |
| SSD를 VRAM 확장처럼 가장 잘 설명하는 프로젝트는? | **BaM** — HBM과 SSD 사이에 SW 캐시 삽입, SSD를 GPU 메모리 최하위 티어로 편입 | BaM, GIDS | GPU thread가 data[i]로 접근하면 캐시→SSD 자동 fetch. BaM은 범용, GIDS는 GNN 특화 | High |
| Production-grade에 가장 가까운 것은? | **GDS** (gds-nvidia-fs + cuFile + KvikIO) | GDS, KvikIO | CUDA Toolkit 포함, NVIDIA 공식 지원, XFS/EXT4 호환, 활발한 업데이트 | High |
| 연구용 prototype에 가장 가까운 것은? | **BaM** | BaM, GIDS, GPUfs | 커스텀 NVMe 드라이버, IOMMU OFF 필수, raw NVMe만, 표준 FS 미지원 | High |
| GPU가 SSD를 direct access한다는 표현이 가장 정확한 경우는? | **BaM에서 GPU thread가 NVMe SQ에 명령 enqueue + doorbell MMIO ring 할 때** | BaM | PTX `st.mmio.relaxed.sys` 명령이 GPU→NVMe doorbell 직접 쓰기 증명. GDS에서는 GPU가 DMA target일 뿐 | High |
| CPU 관점에서 GPU storage access를 이해할 때 가장 흔한 오해는? | **initiator, orchestrator, data mover, consumer를 혼동하는 것.** "GPU가 읽는다"에서 4개 역할을 구분 못함 | 전체 | GDS: GPU=consumer만. BaM에서도 data mover=DMA 엔진. "읽는다=전체 제어"로 가정하면 아키텍처 오해 | High |
| GPU에서 storage access의 실질 주체를 무엇으로 보는 것이 가장 정확한가? | **GDS: CPU thread** (GPU 수동). **BaM: GPU warp** (warp-level coalescing이 자연 단위) | GDS→CPU thread; BaM→GPU warp | GDS: ioctl 시작. BaM: `__match_any_sync()` warp 내 합체 → 리더 thread가 캐시/NVMe 처리 | High |
| Thread/warp/block/SM 중 어떤 수준에서 이해해야 오해가 가장 적은가? | **GPU warp.** Thread 수준은 너무 세밀(coalescing 무시), block/SM은 너무 추상적(I/O 직접 무관) | BaM, GIDS | BaM의 `__match_any_sync()`가 warp 경계 coalescing. warp이 NVMe 명령 1개 단위와 자연 대응 | High |
| GDS와 BaM은 어떤 점에서 본질적으로 다른가? | **Initiator+Orchestrator의 위치가 다르다.** GDS: CPU(initiate+orchestrate), GPU(passive consume). BaM: GPU(initiate+orchestrate+consume), CPU(초기화만) | GDS, BaM | Data mover(NVMe DMA→GPU)는 동일. 제어권이 CPU↔GPU 어디에 있느냐가 본질적 차이 | High |
| "SSD를 VRAM처럼 쓴다"는 표현의 기술적 한계는? | 지연 100-1000x, 대역폭 100x+, HW 캐시 일관성 없음, 쓰기 수명 제한. "VRAM의 최하위 demand-paging 티어"가 정확 | BaM (부분 타당) | BaM operator[]가 투명 접근 제공하나 HBM ~100ns vs SSD ~10-100μs. VRAM "처럼"은 프로그래밍 모델 한정 | High |

---

### 필수 질문 10개 답변 종합표

| # | Question | Answer | Key Evidence | Confidence |
|---|----------|--------|-------------|------------|
| 1 | CPU에서 storage access의 실질 주체는? | **CPU thread**(initiator+consumer) + **OS kernel**(orchestrator) + **NVMe DMA**(data mover) | POSIX read→VFS→NVMe driver→DMA | High |
| 2 | GPU에서 storage access의 실질 주체는? | **GDS**: CPU thread 주체, GPU passive. **BaM**: GPU warp 주체(initiator+consumer), NVMe DMA=data mover | GDS: ioctl. BaM: operator[], sq_enqueue | High |
| 3 | GPU가 SSD 데이터를 가져오는 실제 경로는? | **GDS**: CPU→cuFile→ioctl→VFS→NVMe→SGL remap→DMA→GPU BAR1. **BaM**: GPU→cache miss→NVMe cmd→SQ→doorbell→DMA→GPU mem→CQ poll | 섹션 5 Data Path Table | High |
| 4 | NVMe→GPU direct DMA 가능한가? | **Confirmed Yes.** `nvidia_p2p_get_pages()` + `nvidia_p2p_dma_map_pages()`로 GPU를 DMA target 등록 | GDS: nvfs-core.c. BaM: module/map.c | High |
| 5 | CPU DRAM bounce buffer 제거되는가? | **GDS/BaM: 제거됨.** DeepSpeed/FlashNeuron: 사용됨 | GDS: SGL GPU 주소 치환. DeepSpeed: DRAM→cudaMemcpy | High |
| 6 | I/O API인가, memory API인가? | **GDS: I/O API** (cuFileRead/Write). **BaM: Memory API** (operator[], bam_ptr) | cuFile 함수 시그니처 vs page_cache.h operator[] | High |
| 7 | Page fault 기반인가, explicit read 기반인가? | **GDS: explicit read** (cuFileRead). **BaM: SW demand paging** (cache miss→자동 NVMe fetch, HW fault 아님) | BaM: INVALID→BUSY→NVMe read→VALID | High |
| 8 | GPU kernel이 직접 storage access trigger를 만드는가? | **GDS: No** (CPU trigger). **BaM: Yes** (operator[] cache miss가 NVMe 발행 trigger) | GDS: CPU ioctl. BaM: `__device__` read_data()→sq_enqueue() | High |
| 9 | SSD를 확장 VRAM이라 부르는 것이 기술적으로 타당한가? | **부분적 타당 (BaM 한정).** 프로그래밍 모델 유사하나 성능 특성(지연/대역폭/수명)이 근본적으로 다름 | HBM ~100ns vs SSD ~10-100μs. BW: 2-5TB/s vs ~25GB/s | High |
| 10 | Thread/warp/block/SM 중 어떤 수준이 가장 정확한가? | **GDS: CPU thread. BaM: GPU warp.** `__match_any_sync()` coalescing이 warp 경계에서 발생 | page_cache.h warp-level coalescing 코드 | High |

---

### 결론 (15줄 이내)

**1. NVIDIA "공식" vs "NVIDIA 참여"를 구분해야 한다.** NVIDIA org 소유 GPU-SSD 프로젝트는 GDS뿐이며 block I/O 최적화다. BaM은 NVIDIA 연구자 참여이나 공식이 아니다.

**2. Memory semantic 유일 구현은 BaM.** `operator[]`와 `bam_ptr<T>`로 SSD를 배열/포인터로 투명 접근하며, cache miss 시 GPU warp이 NVMe 명령을 직접 발행한다. GDS는 block I/O이다.

**3. "GPU가 SSD를 직접 접근"은 정확하지 않다.** GDS에서 GPU는 DMA target(수동 수신자). BaM에서만 GPU가 initiator이며, data mover는 항상 NVMe DMA 엔진이다.

**4. Initiator ≠ Orchestrator ≠ Data Mover ≠ Consumer.** CPU 경험으로 "읽는다"를 전체 제어로 이해하면 GPU storage access를 오해한다. BaM에서도 GPU warp=initiator+consumer, GPU runtime=orchestrator, NVMe DMA=data mover로 역할이 분리된다.

**5. Storage access 분석에서 GPU warp이 가장 정확한 단위.** BaM의 `__match_any_sync()` coalescing이 warp 경계에서 발생하므로, thread(너무 세밀) 또는 block/SM(너무 추상적)보다 warp이 I/O 동작의 자연 단위다.

**6. "SSD=VRAM 확장"은 마케팅적 단순화.** BaM이 투명 접근을 제공하지만 지연 100-1000x, 대역폭 100x+, 쓰기 수명 차이가 있다. **"GPU 메모리 계층의 최하위 demand-paging 티어"**가 기술적으로 더 정확하다.

---

## Appendix A. Search Log

| Step | Query / Keyword | Where | Results | Kept | Notes |
|------|----------------|-------|---------|------|-------|
| 1 | `nvidia bam big accelerator memory` | GitHub | 3 | 1 | ZaidQureshi/bam — NVIDIA org 아님 |
| 2 | `nvidia gpudirect storage` | GitHub | 8 | 2 | gds-nvidia-fs, kvikio |
| 3 | `nvidia gids gpu initiated` | GitHub | 2 | 1 | jeongminpark417/GIDS |
| 4 | `nvidia cufile examples` | GitHub | 5 | 1 | cuda-samples (예제만) |
| 5 | `nvidia magnum IO` | GitHub | 2 | 1 | MagnumIO |
| 6 | `nvidia gdrcopy` | GitHub | 3 | 1 | gdrcopy |
| 7 | `GPU out-of-core memory NVMe` | GitHub | 6 | 1 | gpu-out-of-core-xtx (Exclude) |
| 8 | `FlashNeuron GPU SSD` | GitHub | 2 | 1 | SNU-ARC/flashneuron |
| 9 | `DeepSpeed offload SSD NVMe` | GitHub | 3 | 1 | deepspeedai/DeepSpeed |
| 10 | `gpufs GPU filesystem` | GitHub | 4 | 1 | gpufs/gpufs |
| 11 | `GPUDirect async libgdsync` | GitHub | 3 | 0 | InfiniBand 중심 (Exclude) |
| 12 | `nvidia gds llm NVMe VRAM` | GitHub | 2 | 1 | rscunha13/gdsllm |
| 13 | BaM ArXiv (2203.04910) | ArXiv | 1 | — | ASPLOS '23, 핵심 아키텍처 근거 |
| 14 | GIDS ArXiv (2306.16384) | ArXiv | 1 | — | GNN 특화 BaM 확장 |
| 15 | GDS Overview Guide | NVIDIA Docs | 1 | — | cuFile API, 공식 문서 |

## Appendix B. Exclusion Table

| Project | Why Excluded | Mentioned? | Reason |
|---------|-------------|------------|--------|
| libgdsync | InfiniBand 중심, SSD/NVMe 무관 | No | 네트워크 I/O 특화 |
| cuda-samples | 예제 코드만, 새 추상화 없음 | No | GDS 사용법 데모 |
| gpu-out-of-core-xtx | SSD 아닌 CPU DRAM 기반 | No | 관련성 부족 |
| gdasync | InfiniBand 중심 | No | 네트워크 특화 |

## Appendix C. Evidence Quality Table

| Project | README | Docs | Code | Issue/PR | Paper | Overall |
|---------|--------|------|------|----------|-------|---------|
| GDS | Medium | **High** (NVIDIA 공식) | **High** (nvfs-dma/core/mmap/pci) | Medium | Medium | **High** |
| BaM | High | Medium (artifact eval) | **High** (page_cache/queue/ptr/module) | Low | **High** (ASPLOS '23) | **High** |
| GIDS | Medium | Low | Medium (BaM submodule) | Low | **High** (arXiv) | **Medium-High** |
| KvikIO | **High** | **High** (RAPIDS) | **High** (file_handle/cufile shim) | Medium | Low | **High** |
| DeepSpeed | **High** | **High** | Medium (대규모) | **High** | **High** (SC '21) | **High** |
| FlashNeuron | Medium | Low | Medium | Low | **High** (ATC '21) | **Medium** |
| gdrcopy | **High** | **High** | **High** (gdrdrv.c) | Medium | Medium | **High** |
| GPUfs | Medium | Low | Medium | Low | **High** (ASPLOS '13) | **Medium** |
| gdsllm | Medium | Low | Medium | Low | Low | **Medium-Low** |

## Appendix D. Interpretation Notes Table

| Topic | Key Distinction | Why It Matters for Final Analysis |
|-------|----------------|-----------------------------------|
| Initiator vs Consumer | GDS: initiator(CPU)≠consumer(GPU). BaM: initiator≈consumer(GPU warp) | "누가 읽는가"와 "누가 쓰는가"를 혼동하면 아키텍처를 오해 |
| Orchestrator vs Data Mover | 모든 경로에서 orchestrator≠data mover. CPU/GPU는 orchestrate, DMA 엔진이 move | "CPU가 데이터를 옮긴다"는 표현이 기술적으로 부정확한 이유 |
| GPU thread vs GPU warp | Thread는 최소 실행 단위이나, warp이 coalescing/scheduling 단위 | BaM 분석에서 thread 수준은 너무 세밀, warp이 I/O의 자연 단위 |
| Memory semantic vs Block I/O | Memory: operator[]/ptr deref로 투명 접근. Block: 명시적 read/write API | GDS=block I/O, BaM=memory semantic을 혼동하면 안됨 |
| NVIDIA Official vs NVIDIA Participated | Official: NVIDIA org 소유. Participated: NVIDIA 연구자 참여 but 외부 소유 | BaM을 "NVIDIA 프로젝트"로 단정하면 부정확 |
| SW demand paging vs HW page fault | BaM: SW 캐시 miss→NVMe fetch (GPU 제어). CPU mmap: HW page fault→OS handler | BaM을 HW demand paging으로 오해하면 안됨. SW 에뮬레이션이다 |
| O_DIRECT necessity | GDS: O_DIRECT 필수 (page cache 우회). BaM: 파일시스템 자체 미사용 | 두 프로젝트의 OS 의존도가 근본적으로 다름 |
| PCIe P2P topology | GPU-SSD가 PCIe 스위치로 직결 시 최적. Root Complex 경유 시 성능 저하 | HW 토폴로지가 실제 P2P 성능을 결정 |

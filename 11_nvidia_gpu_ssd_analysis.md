# NVIDIA GPU-SSD Memory Semantic Access: 오픈소스 심층 분석

> **작성 원칙**: 표 70% 이상, 서술은 표 해석 및 예외 설명으로 제한

---

## 1. Executive Summary Table

| Question | Answer | Confidence | Evidence |
|----------|--------|------------|----------|
| NVIDIA 공식 오픈소스 중 SSD를 VRAM 확장처럼 다루는 대표 프로젝트는? | **GDS** (NVIDIA/gds-nvidia-fs)가 유일한 공식 프로젝트. 단, VRAM "확장"이 아닌 GPU-direct DMA 경로 제공 | Confirmed | github.com/NVIDIA/gds-nvidia-fs — NVIDIA org 소유, nvidia-fs.ko 커널 드라이버 |
| GDS는 memory semantic access인가? | **아니다.** Block I/O semantic이다. CPU가 cuFileRead/Write를 호출하는 명시적 파일 I/O | Confirmed | nvfs-core.c: `nvfs_ioctl()` → `nvfs_direct_io()` → `vfs_read/vfs_write` with O_DIRECT |
| BaM은 memory semantic에 가까운가? | **그렇다.** GPU thread가 `operator[]`로 SSD 데이터에 접근, 캐시 miss 시 자동 NVMe fetch | Confirmed | page_cache.h: `array_d_t<T>::operator[]` → acquire_page → NVMe read → 데이터 반환 |
| GPU가 SSD를 truly direct access 한다고 볼 수 있는가? | **GDS**: GPU는 수동적 — DMA target일 뿐. **BaM**: GPU가 NVMe 명령을 직접 발행하므로 "direct access"에 가장 가까움 | Confirmed | BaM nvm_parallel_queue.h: GPU PTX `st.mmio.relaxed.sys` 로 doorbell 직접 write |
| CPU bounce buffer는 제거되는가? | **GDS/BaM 모두 제거됨.** NVMe DMA가 GPU BAR1에 직접 쓴다. 단, DeepSpeed/FlashNeuron은 CPU DRAM bounce 사용 | Confirmed | GDS: nvfs-dma.c SGL을 GPU 주소로 치환. BaM: module/map.c P2P DMA 직접 매핑 |
| "SSD를 VRAM처럼 쓴다"는 표현은 어디까지 맞는가? | **BaM에서만 부분적으로 타당.** GPU thread가 배열 인덱싱으로 SSD 접근 가능하나, 지연시간·대역폭·일관성 모델이 HBM과 다름 | Likely | BaM의 operator[]가 투명 접근 제공하나 10~100μs 지연 (HBM ~100ns 대비 100~1000x) |
| Production-grade에 가까운 것은? | **GDS** (gds-nvidia-fs + cuFile) — CUDA Toolkit에 포함, NVIDIA 공식 지원, XFS/EXT4 호환 | Confirmed | NVIDIA 공식 문서, CUDA 12.x 포함, 활발한 업데이트 (2026-03-12) |
| 연구용 prototype에 가까운 것은? | **BaM** — ASPLOS '23 논문, 커스텀 NVMe 드라이버 필요, 표준 파일시스템 사용 불가 | Confirmed | 커스텀 libnvm_helper.ko 필요, IOMMU 비활성화 필수, raw NVMe 접근만 지원 |

**요약 (10줄 이내)**

NVIDIA가 공식으로 운영하는 GPU-SSD 접근 프로젝트는 GDS(gds-nvidia-fs)이며, 이는 CPU가 제어하는 block I/O 최적화다. "SSD를 VRAM처럼 접근"하는 memory semantic에 가장 가까운 것은 BaM이며, GPU thread가 `operator[]`로 SSD 데이터에 투명하게 접근하고, cache miss 시 GPU가 NVMe 명령을 직접 발행한다. 다만 BaM은 NVIDIA+IBM+UIUC 공동 연구로 NVIDIA 공식 프로젝트가 아니며, 커스텀 NVMe 드라이버와 IOMMU 비활성화를 요구하는 연구 프로토타입이다. 두 프로젝트 모두 CPU DRAM bounce buffer를 제거하고 NVMe→GPU 직접 P2P DMA를 사용하지만, I/O 주체(CPU vs GPU)와 접근 추상화(block I/O vs memory semantic)에서 근본적으로 다르다.

---

## 2. CPU vs GPU Access Model Comparison Table

| Dimension | CPU SSD Access Model | GPU SSD Access Model (GDS) | GPU SSD Access Model (BaM) | Why This Difference Matters |
|-----------|---------------------|---------------------------|---------------------------|---------------------------|
| **Compute execution unit** | CPU core/thread (1~128개, 각각 독립적 실행 컨텍스트) | GPU kernel (수만 스레드가 SIMT로 동시 실행) | GPU kernel (동일) | GPU는 수천 스레드가 동시에 I/O를 발생시킬 수 있어 큐 관리 복잡도 증가 |
| **Request initiator** | CPU thread (syscall: read/pread/io_uring) | CPU thread (cuFileRead/Write 호출) | **GPU thread/warp** (operator[] cache miss 시) | BaM만이 GPU 스레드가 I/O의 실질적 시작자 |
| **Orchestrator** | OS kernel (VFS → block layer → NVMe driver) | CPU (cuFile → nvidia-fs.ko → VFS → NVMe driver) | **GPU runtime** (page_cache_t + QueuePair, CPU는 초기화만) | GDS는 CPU가 전 과정 오케스트레이션, BaM은 GPU가 자율적 |
| **Data mover** | NVMe DMA engine → CPU DRAM | NVMe DMA engine → GPU BAR1 (P2P) | NVMe DMA engine → GPU memory (P2P) | 두 GPU 모델 모두 DMA 엔진이 실제 데이터 이동 수행 |
| **Final consumer** | CPU thread (user buffer에서 처리) | GPU kernel (VRAM에서 연산 수행) | GPU thread (캐시된 데이터로 연산 즉시 수행) | BaM은 I/O 완료 후 동일 스레드가 즉시 데이터 소비 |
| **Typical API surface** | POSIX read/write, io_uring, SPDK | cuFileRead/Write (ioctl 기반) | `bam::array<T>[i]`, `bam_ptr<T>` (C++ 연산자) | BaM의 API가 메모리 접근과 구분 불가능한 수준 |
| **Access abstraction** | File descriptor + offset + length | File handle + GPU ptr + offset + length | **Array index / pointer dereference** | BaM은 파일 개념 없이 배열/포인터로 접근 |
| **Granularity** | 512B~MB (block I/O) | 32KB~MB (cuFile 효율 구간) | **512B~4KB** (fine-grained, 캐시 coalescing) | BaM이 세밀한 랜덤 접근에서 압도적 효율 |
| **Latency hiding method** | 비동기 I/O (io_uring, AIO), 스레드 풀 | CPU 스레드 풀 + 비동기 cuFile batch | **GPU warp scheduling** — I/O 대기 warp를 SM이 자동 교체 | GPU의 대규모 병렬성이 I/O 지연을 자연스럽게 은닉 |
| **Completion model** | Interrupt / polling (io_uring CQ) | CPU 측 kiocb 완료 콜백 | **GPU thread CQ polling** (NVMe CQ를 GPU에서 직접 폴링) | BaM은 CPU 인터럽트 없이 GPU가 완료 감지 |
| **Page cache involvement** | 기본 사용 (O_DIRECT로 우회 가능) | **없음** (O_DIRECT 강제) | **없음** (OS 우회, raw NVMe) | 두 GPU 모델 모두 OS page cache 미사용 |
| **O_DIRECT relevance** | 선택적 (성능 최적화용) | **필수** (nvfs-core.c에서 강제) | **해당 없음** (파일시스템 자체 미사용) | GDS는 O_DIRECT 필수, BaM은 파일시스템 자체가 없음 |
| **DMA path** | NVMe → CPU DRAM (표준) | NVMe → GPU BAR1 (nvidia-fs SGL 리매핑) | NVMe → GPU memory (libnvm P2P 매핑) | 두 GPU 모델 모두 동일한 nvidia_p2p_get_pages() API 사용 |
| **Memory semantic 가능성** | Confirmed No (block I/O) | Confirmed No (block I/O, CPU 제어) | **Confirmed Yes** (operator[], demand paging, SW cache) | BaM만이 진정한 memory semantic 제공 |
| **Block I/O semantic 가능성** | Confirmed Yes | Confirmed Yes | Confirmed No (NVMe 명령 직접 발행, block layer 우회) | BaM은 Linux block layer를 완전히 우회 |

---

### 2-A. CPU core vs GPU thread/warp/block/SM 해석 표

| Term | What It Is | Storage Access Analysis Relevance | Common Misunderstanding | Correct Interpretation |
|------|-----------|----------------------------------|------------------------|----------------------|
| **CPU core** | 독립적 명령 스트림 실행 유닛, OoO 파이프라인, 독자적 L1/L2 | I/O syscall의 실행 주체이자 인터럽트 수신자. 1 core = 1 I/O 제어 스레드 단위 | "CPU core가 SSD를 읽는다" | CPU core는 I/O를 **요청(initiate)**하고 **오케스트레이션**하지만, 데이터 이동은 DMA 엔진이 수행 |
| **CPU thread** | CPU core 위의 논리적 실행 스트림 (HT/SMT 포함) | 각 thread가 독립적 I/O syscall 발행 가능. io_uring SQ에 명령 삽입하는 단위 | "thread 수 = 동시 I/O 수" | I/O 큐 깊이와 thread 수는 독립적. 1 thread가 다수 비동기 I/O 가능 (io_uring) |
| **GPU thread** | 최소 실행 단위. 단일 SIMT lane. 개별 레지스터 보유 | BaM에서 개별 thread가 `operator[]` 호출 → I/O trigger 가능 | "GPU thread = CPU thread와 동급" | GPU thread 1개는 CPU thread보다 훨씬 가벼움. 수만 개가 동시 존재하며, I/O 지연 중 SM이 다른 warp으로 전환 |
| **GPU warp** | 32개 thread의 SIMT 실행 그룹. 동일 명령을 lock-step 실행 | BaM 캐시 조회의 실질적 단위. `__match_any_sync()` 로 warp 내 동일 페이지 접근 합체 | "각 thread가 독립적 I/O" | **Warp이 I/O coalescing의 자연 단위.** 32 thread 중 동일 페이지 접근 시 리더 1개만 캐시 조회 |
| **GPU block** | 다수 warp의 그룹. 공유 메모리(SMEM) 공유. 1개 SM에 할당 | Block 내 warp들이 공유 메모리로 I/O 결과 협력 가능 | "block = 스레드 풀" | Block은 SM 자원 할당 단위이며, I/O 분석에서는 warp 수준이 더 중요 |
| **GPU SM** | Streaming Multiprocessor. 다수 warp을 시분할 실행하는 하드웨어 유닛 | I/O 대기 중인 warp과 연산 중인 warp을 자동 전환하는 스케줄러 보유 | "SM이 I/O를 처리" | SM은 I/O를 처리하지 않음. warp scheduling으로 I/O **지연을 은닉**하는 역할 |
| **CPU runtime/kernel** | OS 커널: VFS, block layer, NVMe driver, 인터럽트 핸들러 | 전통적 I/O에서 전체 데이터 경로를 제어. GDS에서도 제어 경로 담당 | "커널은 데이터를 옮긴다" | 커널은 데이터 이동을 **명령(orchestrate)**하고, 실제 이동은 DMA 엔진이 수행 |
| **GPU runtime/driver** | CUDA runtime, GPU device driver, BaM의 page_cache_t + QueuePair | BaM에서 NVMe 큐 관리, 캐시 관리, P2P DMA 설정을 GPU 측에서 수행 | "GPU driver가 I/O를 처리" | BaM의 GPU runtime은 NVMe 큐에 명령을 삽입하고 완료를 폴링. OS driver를 **대체(replace)**함 |

---

### 2-B. 오해 바로잡기 표

| Statement | Strictly True Part | Misleading Part | Correct Technical Rephrasing |
|-----------|-------------------|-----------------|------------------------------|
| "CPU core가 SSD를 읽는다" | CPU core가 I/O syscall을 발행하고 NVMe driver를 통해 NVMe 명령을 NVMe SQ에 삽입한다 | CPU core가 데이터를 직접 이동시키지 않음. DMA 엔진이 SSD→DRAM 전송 수행 | "CPU core가 NVMe I/O를 **발행(initiate)**하고, NVMe DMA 엔진이 데이터를 DRAM으로 **전송(move)**하며, CPU core가 결과를 **소비(consume)**한다" |
| "GPU thread가 SSD를 직접 읽는다" | BaM에서 GPU thread가 NVMe SQ에 명령을 삽입하고 doorbell을 ring한다 | GPU thread가 SSD 내부 NAND에 직접 접근하는 것이 아님. NVMe 프로토콜을 통한 간접 접근. GDS에서는 GPU thread가 아예 I/O를 발행하지 않음 | "BaM에서 GPU thread가 NVMe 명령을 **구성하고 제출(compose and submit)**하며, NVMe DMA 엔진이 데이터를 GPU 메모리로 **전송(move)**한다. GDS에서는 CPU가 제출하고 DMA가 GPU로 직접 전송한다" |
| "SSD를 VRAM처럼 쓴다" | BaM의 `operator[]`가 SSD 데이터를 배열 인덱싱으로 투명 접근 가능하게 한다 | 지연시간 100~1000x 차이 (HBM ~100ns vs SSD ~10-100μs). 캐시 일관성 모델 다름. 대역폭 격차 (HBM 2-5TB/s vs SSD ~25GB/s). 쓰기 수명 제한 | "SSD를 GPU 메모리 계층의 **최하위 티어(lowest tier)**로 편입하여, 소프트웨어 캐시를 통해 **투명한 demand paging**을 제공한다. VRAM과 동일한 성능·일관성은 보장하지 않는다" |
| "GPU가 storage를 memory처럼 access한다" | BaM의 프로그래밍 모델이 load/store-like 추상화를 제공한다 | 하드웨어 수준 memory semantic이 아닌 소프트웨어 에뮬레이션. CXL.mem과 달리 캐시 일관성 프로토콜 없음. NVMe 프로토콜은 block I/O 기반 | "BaM이 **소프트웨어 계층에서** memory-like 추상화를 제공하나, 하드웨어 프로토콜은 여전히 NVMe block I/O이다. 진정한 hardware memory semantic은 CXL 3.0+ 통합을 요구한다" |

---

## 3. Candidate Project Discovery Table

| # | Project | GitHub URL | Owner Type | NVIDIA Official? | Related Keywords | Why It Is a Candidate | Last Update | Activity Level | Keep/Exclude | Exclusion Reason |
|---|---------|-----------|------------|-----------------|-----------------|----------------------|-------------|----------------|-------------|-----------------|
| 1 | **GDS** (gds-nvidia-fs) | github.com/NVIDIA/gds-nvidia-fs | NVIDIA | **Confirmed Yes** | GDS, GPUDirect Storage, cuFile, NVMe P2P | GPU-SSD 직접 DMA의 공식 커널 드라이버 | 2026-03-12 | Active | **Keep** | — |
| 2 | **BaM** | github.com/ZaidQureshi/bam | NVIDIA+IBM+UIUC research | Confirmed No (공동연구) | BaM, GPU-initiated, memory semantic, page cache | GPU thread가 NVMe 명령 직접 발행, memory semantic 추상화 | 2024 | Moderate | **Keep** | — |
| 3 | **GIDS** | github.com/jeongminpark417/GIDS | Academic | Confirmed No | GIDS, GPU-initiated, GNN, BaM-based | BaM 기반 GNN 데이터로더, 3계층 메모리 | 2024 | Moderate | **Keep** | — |
| 4 | **KvikIO** | github.com/rapidsai/kvikio | RAPIDS (NVIDIA-affiliated) | Likely Yes | cuFile, GDS, Python bindings, file I/O | cuFile/GDS 고수준 래퍼, GPU-direct file I/O | 2026-03-12 | Active | **Keep** | — |
| 5 | **DeepSpeed** | github.com/deepspeedai/DeepSpeed | Microsoft/DeepSpeed AI | Confirmed No | ZeRO-Infinity, NVMe offload, out-of-core | SSD를 메모리 계층으로 활용 (CPU 경유) | 2026-03-12 | Very Active | **Keep** | — |
| 6 | **FlashNeuron** | github.com/SNU-ARC/flashneuron | Seoul Nat'l Univ | Confirmed No | GPU SSD offload, tensor swap, compression | DNN 텐서를 SSD로 오프로드하여 VRAM 확장 | 2025-11 | Stale | **Keep** | — |
| 7 | **gdrcopy** | github.com/NVIDIA/gdrcopy | NVIDIA | **Confirmed Yes** | GPUDirect RDMA, BAR1 mapping, P2P | GPU 메모리 CPU 매핑 인프라, P2P 기반 기술 | 2026-03-12 | Active | **Keep** | — |
| 8 | **MagnumIO** | github.com/NVIDIA/MagnumIO | NVIDIA | **Confirmed Yes** | Magnum IO, GDS examples, GPU I/O | GDS 상위 프레임워크, 예제 및 문서 | 2026-03-09 | Active | **Keep** | — |
| 9 | **GPUfs** | github.com/gpufs/gpufs | Academic | Confirmed No | GPU filesystem, GPU-kernel file API | GPU 커널에서 POSIX-like 파일 접근, BaM 선행 연구 | 2026-02 | Active | **Keep** | — |
| 10 | **gdsllm** | github.com/rscunha13/gdsllm | Individual | Confirmed No | GDS, LLM, weight streaming, NVMe VRAM | GDS로 LLM weight를 NVMe→VRAM 스트리밍 | 2026-03 | Active | **Keep** | — |
| 11 | **libgdsync** | github.com/gpudirect/libgdsync | gpudirect org | Likely Yes (affiliated) | GPUDirect Async, GPU-initiated | GPU-initiated async I/O 프리미티브 (InfiniBand) | 2026-01 | Moderate | **Exclude** | InfiniBand 중심, SSD/NVMe 무관 |
| 12 | cuda-samples | github.com/NVIDIA/cuda-samples | NVIDIA | Confirmed Yes | cuFile examples | GDS/cuFile 사용 예제 포함 | 2026-03-12 | Active | **Exclude** | 예제 코드일 뿐, 새로운 추상화 없음 |
| 13 | gpu-out-of-core-xtx | github.com/duongtrongnguyen123/... | Individual | Confirmed No | out-of-core, GPU matrix | Host memory 기반 out-of-core GPU 연산 | 2026-01 | Moderate | **Exclude** | SSD가 아닌 CPU DRAM 기반 |
| 14 | gdasync | github.com/gpudirect/gdasync | gpudirect org | Likely Yes (affiliated) | GPUDirect Async | GPU-initiated async I/O suite | 2025-09 | Stale | **Exclude** | InfiniBand 중심, SSD 무관 |

> **Note**: BaM은 NVIDIA 소속 연구자(Bill Dally 포함)가 참여했으나 NVIDIA org 소유가 아님. "NVIDIA 공식"과 "NVIDIA 참여"를 구분해야 함.

---

## 4. Project Classification Matrix

| Dimension | GDS (gds-nvidia-fs) | BaM | GIDS | KvikIO | DeepSpeed ZeRO-∞ | FlashNeuron | gdrcopy | GPUfs | gdsllm |
|-----------|-------------------|-----|------|--------|------------------|-------------|---------|-------|--------|
| **Official Status** | NVIDIA Official | NVIDIA research collab | Academic | NVIDIA-affiliated | Microsoft | Academic | NVIDIA Official | Academic | Community |
| **Primary Goal** | NVMe→GPU direct DMA | GPU-initiated memory-semantic SSD access | GNN dataloader (BaM-based) | GDS Python/C++ 래퍼 | Trillion-param training via NVMe offload | DNN tensor SSD offload | Low-latency CPU↔GPU copy | GPU-kernel file API | LLM weight NVMe→VRAM streaming |
| **Access Initiator** | CPU thread | **GPU thread/warp** | **GPU thread/warp** | CPU thread | CPU thread | CPU thread | CPU thread | **GPU thread** | CPU thread |
| **Orchestrator** | CPU (VFS+NVMe driver) | **GPU runtime** (page_cache_t) | **GPU runtime** (BaM) + scheduler | CPU (thread pool) | CPU (DeepSpeed engine) | CPU (PyTorch) | CPU | GPU runtime + CPU helper | CPU (inference scheduler) |
| **Data Mover** | NVMe DMA → GPU BAR1 | NVMe DMA → GPU mem (P2P) | NVMe DMA → GPU mem (P2P) | NVMe DMA → GPU or CPU memcpy | NVMe DMA → CPU DRAM → cudaMemcpy → GPU | SSD → CPU DRAM → cudaMemcpy → GPU | CPU load/store via BAR1 | CPU-mediated DMA | NVMe DMA → GPU (GDS) |
| **Final Consumer** | GPU kernel | GPU thread | GPU thread (DGL GNN) | GPU kernel / RAPIDS | GPU (PyTorch training) | GPU (training) | CPU thread | GPU thread | GPU (LLM inference) |
| **Access API Type** | Block I/O (cuFile) | **Memory semantic** (operator[]) | **Memory semantic** (bam_ptr) | File I/O (pread/pwrite) | File I/O + cudaMemcpy | Modified allocator | BAR mapping API | POSIX-like from GPU | cuFile (GDS) |
| **Memory Semantic?** | Confirmed No | **Confirmed Yes** | **Confirmed Yes** | Confirmed No | Confirmed No | Confirmed No | Confirmed No | Likely Yes | Confirmed No |
| **GPU Direct Data Path?** | Confirmed Yes | Confirmed Yes | Confirmed Yes | Confirmed Yes (GDS) | Confirmed No | Confirmed No | Confirmed No (CPU-mediated) | Likely No | Confirmed Yes |
| **CPU Bounce Buffer Removed?** | Confirmed Yes | Confirmed Yes | Confirmed Yes | Confirmed Yes (GDS) / No (fallback) | Confirmed No | Confirmed No | N/A | Likely No | Confirmed Yes |
| **On-demand Faulting?** | Confirmed No | **Confirmed Yes** | **Confirmed Yes** | Confirmed No | Confirmed No | Confirmed No | Confirmed No | Likely Yes | Confirmed No |
| **Prefetch/Cache Layer?** | Confirmed No | **Confirmed Yes** (GPU SW cache, clock eviction) | **Confirmed Yes** (3-tier + lookahead) | Confirmed No | Confirmed Yes (CPU-side prefetch) | Confirmed Yes (proactive swap) | Confirmed No | Likely Yes | Confirmed Yes (layer prefetch) |
| **Granularity** | 32KB~MB | **512B~4KB** | Page-level (4KB) | Variable | Tensor-level (MB~GB) | Tensor-level (MB~GB) | 64B~MB | Page-level | Layer-level (MB~GB) |
| **Read Support** | Confirmed Yes | Confirmed Yes | Confirmed Yes | Confirmed Yes | Confirmed Yes | Confirmed Yes | Confirmed Yes | Confirmed Yes | Confirmed Yes |
| **Write Support** | Confirmed Yes | Confirmed Yes | Likely No | Confirmed Yes | Confirmed Yes | Confirmed Yes | Confirmed Yes | Confirmed Yes | Likely No |
| **Production vs Research** | **Production** | **Research** | **Research** | **Production** | **Production** | **Research** | **Production** | **Research** | **Experimental** |
| **Confidence** | High | High | High | High | High | Medium | High | Medium | Medium-Low |

**해설 (5줄)**

이 매트릭스에서 가장 중요한 구분은 **Access Initiator**와 **Memory Semantic** 열이다. GPU thread가 직접 I/O를 시작하는 것은 BaM, GIDS, GPUfs 세 프로젝트뿐이며, 이 중 memory semantic 추상화까지 제공하는 것은 BaM과 GIDS다. GDS는 data path에서 CPU bounce buffer를 제거했지만 control path에서 CPU가 여전히 필수적이므로 memory semantic이 아니다. DeepSpeed/FlashNeuron은 SSD를 메모리 계층으로 활용하지만 CPU DRAM bounce를 거치므로 GPU-direct data path가 없다.

---

## 5. Data Path Table

| Dimension | GDS | BaM | GIDS | DeepSpeed ZeRO-∞ | KvikIO (GDS mode) |
|-----------|-----|-----|------|-------------------|-------------------|
| **Read Path Summary** | CPU: cuFileRead → ioctl → VFS → NVMe driver → SGL remap → NVMe DMA → GPU BAR1 | GPU: operator[] → cache miss → NVMe cmd build → SQ enqueue → doorbell MMIO → NVMe DMA → GPU mem → CQ poll | GPU: bam_ptr.read() → BaM cache → (miss) → BaM NVMe path → GPU mem | CPU: aio_read → NVMe → CPU DRAM → pin_memory → cudaMemcpyAsync → GPU | CPU: FileHandle.read() → cuFileRead → GDS path |
| **Write Path Summary** | CPU: cuFileWrite → ioctl → VFS → NVMe driver → GPU BAR1 DMA read → NVMe write | GPU: dirty page writeback → NVMe write cmd → SQ → doorbell → NVMe DMA from GPU → SSD | Likely No write support | CPU: GPU → cudaMemcpy → CPU DRAM → aio_write → NVMe | CPU: FileHandle.write() → cuFileWrite → GDS path |
| **Control Path Summary** | CPU 전체 제어: ioctl → VFS → block layer → NVMe driver 전 과정 | GPU 자율 제어: page_cache_t가 miss/hit/evict 판정, QueuePair가 NVMe 큐 관리. CPU는 초기화만 | GPU 자율 (BaM) + GIDS 스케줄러 (배치 간 데이터 배치 결정) | CPU 전체 제어: DeepSpeed 엔진이 offload/prefetch 스케줄링 | CPU 전체 제어 (GDS와 동일) |
| **CPU Involvement** | **High**: 모든 I/O에 CPU syscall 필요 | **None** (runtime): 초기화 후 0% CPU | **None** (runtime): BaM과 동일 | **High**: 모든 데이터 이동에 CPU 관여 | **High**: GDS와 동일 |
| **GPU Involvement** | **Passive**: DMA target으로만 참여 | **Active**: I/O 발행 + 완료 폴링 + 캐시 관리 모두 GPU | **Active**: BaM과 동일 + GNN 연산 | **Passive**: cudaMemcpy 수신 + 연산 | **Passive**: GDS와 동일 |
| **DMA Path** | NVMe ctrl → PCIe P2P → GPU BAR1 (nvidia-fs SGL 리매핑) | NVMe ctrl → PCIe P2P → GPU mem (libnvm P2P 매핑) | BaM과 동일 | NVMe ctrl → CPU DRAM (표준) | GDS와 동일 |
| **Uses cuFile/GDS?** | Yes (핵심) | **No** (커스텀 libnvm) | **No** (커스텀 libnvm via BaM) | No (Linux AIO/libaio) | Yes (핵심) |
| **Uses Filesystem?** | Yes (XFS/EXT4 + O_DIRECT) | **No** (raw NVMe device) | **No** (raw NVMe via BaM) | Yes (표준 파일시스템) | Yes (GDS와 동일) |
| **O_DIRECT?** | **필수** (nvfs-core.c에서 강제) | **해당 없음** (파일시스템 미사용) | **해당 없음** | 선택적 | **필수** (GDS 요구) |
| **Key Limitation** | CPU가 control path에 항상 관여; fine-grained 접근 비효율; GPU 커널 내 동적 접근 불가 | 커스텀 NVMe 드라이버 필요; IOMMU OFF 필수; 표준 FS 미지원; 연구 프로토타입 | BaM 한계 + DGL 종속; GNN 전용 | CPU DRAM bounce buffer; cudaMemcpy 오버헤드; GPU-direct path 없음 | GDS 한계와 동일 |

### ASCII Data Path Diagrams

```
[CPU Traditional Path] — Confirmed
  App thread ──syscall──→ VFS ──→ block layer ──→ NVMe driver ──→ NVMe DMA ──→ CPU DRAM ──→ cudaMemcpy ──→ GPU HBM
  Initiator: CPU thread    Orchestrator: OS kernel    Data mover: NVMe DMA + cudaMemcpy    Consumer: GPU kernel

[GDS Path] — Confirmed (nvfs-core.c, nvfs-dma.c 근거)
  App thread ──cuFileRead──→ ioctl(/dev/nvidia-fs) ──→ VFS(O_DIRECT) ──→ NVMe driver ──→ SGL remap(GPU addr) ──→ NVMe DMA ══P2P══→ GPU BAR1
  Initiator: CPU thread    Orchestrator: CPU (cuFile+nvidia-fs+NVMe driver)    Data mover: NVMe DMA engine    Consumer: GPU kernel

[BaM Path] — Confirmed (page_cache.h, nvm_parallel_queue.h, module/map.c 근거)
  GPU thread ──operator[]──→ page_cache_t lookup ──cache miss──→ NVMe cmd build ──→ SQ enqueue(atomic ticket) ──→ doorbell MMIO(PTX st.mmio) ──→ NVMe DMA ══P2P══→ GPU mem ──→ CQ poll ──→ data return
  Initiator: GPU thread    Orchestrator: GPU runtime (page_cache_t + QueuePair)    Data mover: NVMe DMA engine    Consumer: 동일 GPU thread

[DeepSpeed ZeRO-Infinity Path] — Confirmed (공식 문서 근거)
  CPU thread ──aio_read──→ NVMe ──→ CPU DRAM(pinned) ──cudaMemcpyAsync──→ GPU HBM ──→ GPU training kernel
  Initiator: CPU thread    Orchestrator: DeepSpeed engine    Data mover: NVMe DMA + cudaMemcpy    Consumer: GPU kernel
```

---

## 6. Code Evidence Table

### 6-A. BaM (ZaidQureshi/bam)

| File | Function/Class/Symbol | Role | What It Proves | Confidence |
|------|----------------------|------|---------------|------------|
| `include/page_cache.h` | `array_d_t<T>::operator[](size_t i)` | `__device__` 연산자: 페이지 주소 계산 → 캐시 조회 → miss 시 NVMe read → 데이터 반환 | **Memory semantic 추상화**: SSD 데이터를 배열 인덱싱으로 투명 접근 | High |
| `include/page_cache.h` | `data_page_t` states: INVALID(0x0), VALID(0x80000000), BUSY(0x40000000), DIRTY(0x20000000) | 캐시 페이지 상태 머신, atomic CAS로 GPU에서 관리 | **GPU-resident cache coherence protocol** | High |
| `include/page_cache.h` | `page_cache_d_t::find_slot()` | Clock-style 교체: atomic ticket mod n_pages, CAS lock, dirty writeback | **GPU 스레드가 캐시 교체·writeback을 직접 수행** | High |
| `include/page_cache.h` | `__device__ read_data()`, `write_data()` | NVMe read/write 명령을 QueuePair를 통해 발행하는 GPU device 함수 | **GPU-initiated NVMe I/O의 직접 증거** | High |
| `include/bafs_ptr.h` | `bafs_ptr<T>` with `operator[]`, `operator*`, `operator++/--` | 포인터 산술 + 인덱스 접근, 모두 `__host__ __device__` | **완전한 memory-semantic 스마트 포인터**: C++ 포인터 문법으로 SSD 접근 | High |
| `include/nvm_types.h` | `nvm_queue_t` with `simt::atomic` head/tail | NVMe SQ/CQ를 `simt::atomic` (libcu++ GPU atomics)으로 관리 | **NVMe 큐가 GPU 스레드 호환으로 설계됨** | High |
| `include/nvm_parallel_queue.h` | `sq_enqueue()`: `fetch_add` ticket + PTX `st.mmio.relaxed.sys.global.u32` doorbell | Lock-free 티켓 기반 큐 삽입 + 인라인 PTX로 NVMe doorbell 직접 쓰기 | **수천 GPU 스레드의 동시 NVMe 명령 제출 메커니즘** | High |
| `include/nvm_parallel_queue.h` | `cq_poll()`: CQ 엔트리 스캔, CID 매칭, phase bit 검증 | GPU 스레드가 NVMe completion을 직접 폴링 | **CPU 인터럽트 없이 GPU가 I/O 완료 감지** | High |
| `include/buffer.h` | `createDma()` device variant: `nvm_dma_map_device()` | GPU에 할당된 메모리를 NVMe DMA 주소로 매핑 | **P2P DMA 설정: GPU mem → NVMe 접근 가능** | High |
| `module/map.c` | `map_gpu_memory()`: `nvidia_p2p_get_pages()` + `nvidia_p2p_dma_map_pages()` | GPU 메모리 핀 + NVMe 컨트롤러용 DMA 매핑 생성 | **NVIDIA P2P API로 GPU↔NVMe 직접 DMA 경로 구축** | High |
| `module/pci.c` | `add_pci_dev()`: `pci_set_master(dev)` + BAR0 매핑 | NVMe 디바이스 bus mastering 활성화, 레지스터 매핑 | **커널 수준 P2P DMA 활성화** | High |

### 6-B. GDS (NVIDIA/gds-nvidia-fs)

| File | Function/Class/Symbol | Role | What It Proves | Confidence |
|------|----------------------|------|---------------|------------|
| `src/nvfs-dma.c` | `nvfs_blk_rq_map_sg_internal()` | bio_vec 순회 → `nvfs_get_gpu_page_info()` → `sg_set_page()` GPU 주소로 SGL 구성 | **SGL 리매핑: CPU 주소를 GPU BAR 주소로 치환** | High |
| `src/nvfs-dma.c` | `nvfs_dma_map_sg_attrs_internal()` | 각 SG 엔트리에 `nvfs_get_dma()` 호출하여 GPU DMA 주소 획득 | **NVMe 컨트롤러가 GPU BAR 메모리에 직접 DMA** | High |
| `src/nvfs-dma.c` | `struct nvfs_dma_rw_ops` | `.nvfs_blk_rq_map_sg`, `.nvfs_is_gpu_page` 등 콜백 테이블 | **Block layer hook**: 스토리지 드라이버가 이 콜백을 호출 | High |
| `src/nvfs-core.c` | `nvfs_ioctl()` | NVFS_IOCTL_READ/WRITE/MAP/BATCH_IO 디스패치 | **모든 GDS I/O가 CPU ioctl로 시작됨** | High |
| `src/nvfs-core.c` | `nvfs_direct_io()` | `vfs_read/vfs_write` with O_DIRECT | **표준 VFS 경로 사용, O_DIRECT 강제** | High |
| `src/nvfs-core.c` | `nvfs_pin_gpu_pages()` | `nvidia_p2p_get_pages()` 또는 `nvidia_p2p_get_pages_persistent()` 호출 | **GPU 메모리 핀: P2P DMA의 전제 조건** | High |
| `src/nvfs-core.c` | State machine: `IO_FREE → IO_INIT → IO_READY → IO_IN_PROGRESS → ...` | `nvfs_transit_state()` 상태 전이 | **CPU가 I/O 생명주기 전체를 관리** | High |
| `src/nvfs-mmap.c` | `nvfs_mgroup_get_gpu_physical_address()` | Shadow page → GPU 페이지 인덱스 → P2P page table → GPU 물리 주소 | **Shadow buffer→GPU 주소 변환 (핵심 indirection)** | High |
| `src/nvfs-mmap.c` | `nvfs_is_gpu_page()` | 페이지가 등록된 GPU mgroup에 속하는지 판별 | **Block layer가 GPU/CPU 페이지를 구분하는 방법** | High |
| `src/nvfs-pci.c` | `__nvfs_get_gpu2peer_distance()` | PCIe bridge depth + NUMA distance로 GPU↔NVMe 토폴로지 거리 계산 | **P2P 경로 최적화를 위한 토폴로지 인식** | High |
| `src/nvfs-core.h` | `GPU_PAGE_SIZE = 64KB` | GPU 페이지 단위 상수 | **SGL 리매핑 기본 단위는 64KB** | High |
| `src/nvfs-p2p.h` | 8개 `nvidia_p2p_*` 함수 매크로 래핑 | NVIDIA P2P 커널 API 추상화 | **GDS와 BaM 모두 동일 NVIDIA P2P API에 의존** | High |

### 6-C. KvikIO (rapidsai/kvikio)

| File | Function/Class/Symbol | Role | What It Proves | Confidence |
|------|----------------------|------|---------------|------------|
| `cpp/include/kvikio/file_handle.hpp` | `FileHandle` class: O_DIRECT fd + cuFile handle | 이중 fd 관리 (O_DIRECT용 + 일반용) | **O_DIRECT가 GDS 경로의 필수 조건** | High |
| `cpp/include/kvikio/file_handle.hpp` | `read(devPtr, size, file_offset, devPtr_offset)` | CUDA device pointer로 직접 읽기 → cuFile 호출 | **cuFile API를 통한 GPU-direct I/O** | High |
| `cpp/include/kvikio/shim/cufile.hpp` | `cuFileAPI` singleton: dlopen shimming | libcufile.so 런타임 동적 로드, 19+ 함수 바인딩 | **GDS 런타임 의존성을 동적으로 해결** | High |
| `cpp/include/kvikio/posix_io.hpp` | `posix_device_io()`: pread → bounce buffer → cudaMemcpy | GDS 미지원 시 CPU DRAM bounce 경유 폴백 | **GDS 없이는 CPU bounce buffer가 필요함을 확인** | High |

### 6-D. GIDS (jeongminpark417/GIDS)

| File | Function/Class/Symbol | Role | What It Proves | Confidence |
|------|----------------------|------|---------------|------------|
| `bam/` (git submodule) | BaM 전체 코드 | GIDS의 I/O 기반 | **GIDS는 BaM 위에 구축됨** | High |
| `gids_module/` | pybind11 C++ extension | Python↔CUDA 바인딩 | **DGL Python 프레임워크와 BaM C++/CUDA 연동** | Medium |
| GPU kernel | `read_feature_kernel`: `bam_ptr<T> ptr(dr); out[idx] = ptr.read(...)` | GPU 스레드가 bam_ptr로 SSD 데이터 직접 읽기 | **GPU-initiated SSD 접근이 GNN 학습에 적용됨** | High |
| GIDS scheduler | PageRank 기반 핫 노드 분석 → CPU buffer 배치 | 3계층 데이터 배치 결정 | **노드 재사용 분석 기반 메모리 계층 최적화** | Medium |

---

## 7. CPU-style vs GPU-style Interpretation Table

| Project | CPU-style Interpretation | GPU-style Interpretation | Most Accurate Access Unit | Why |
|---------|-------------------------|-------------------------|--------------------------|-----|
| **GDS** | "CPU가 파일을 읽어서 GPU 메모리에 DMA로 넣어준다" — 이 해석이 **정확함**. cuFileRead는 CPU syscall이고, CPU가 NVMe 명령 제출을 제어한다 | "GPU가 스토리지에서 데이터를 가져온다" — **부정확**. GPU는 DMA target일 뿐, I/O 제어에 관여하지 않음 | **CPU thread** (+ NVMe DMA engine) | CPU thread가 cuFileRead로 I/O 발행, NVMe DMA가 데이터 이동, GPU는 수동적 수신자 |
| **BaM** | "CPU가 NVMe를 초기화하고 GPU에 큐를 넘겨준다" — 초기화 단계에서만 정확 | "GPU warp이 NVMe 명령을 직접 발행하고 데이터를 가져온다" — 런타임에서 **정확함** | **GPU warp** (coalescing 단위) | warp 내 `__match_any_sync()`로 동일 페이지 접근 합체. 리더 thread가 캐시 조회/NVMe 명령 발행 |
| **GIDS** | "CPU가 GNN 학습을 오케스트레이션한다" — 학습 루프 수준에서 부분적으로 맞음 | "GPU warp이 노드 특징을 SSD에서 on-demand로 가져온다" — I/O 수준에서 **정확** | **GPU warp** (BaM과 동일) | BaM runtime이 warp 단위 coalescing 수행 |
| **KvikIO** | "CPU thread pool이 파일 I/O를 병렬 실행한다" — **정확함** | "GPU는 데이터 소비자" — **정확함** | **CPU thread** (thread pool) | CPU가 cuFile/POSIX I/O 발행, GPU는 결과 소비 |
| **DeepSpeed** | "CPU가 NVMe에서 데이터를 읽어 GPU에 복사한다" — **정확함** | "GPU는 데이터가 도착하면 연산한다" — **정확함** | **CPU thread** (+ cudaMemcpy) | CPU가 전 과정 제어, GPU는 완전히 수동적 |
| **FlashNeuron** | "CPU가 텐서를 SSD와 GPU 사이에서 swap한다" — **정확함** | "GPU 연산 중 사용하지 않는 텐서가 SSD로 내려간다" — 추상적으로 맞으나 GPU는 swap에 관여 안함 | **CPU runtime** (PyTorch allocator) | 수정된 PyTorch allocator가 swap 결정, GPU는 무관 |
| **GPUfs** | "CPU가 GPU의 파일 요청을 대리 처리한다" — 구현 수준에서 맞음 | "GPU thread가 파일 open/read/write를 호출한다" — API 수준에서 **정확** | **Mixed**: GPU thread (API 발행) + CPU runtime (실제 I/O) | GPU thread가 요청하나 CPU가 실제 I/O 수행하는 협력 모델 |
| **gdrcopy** | "CPU가 GPU 메모리를 BAR1 매핑으로 직접 읽고 쓴다" — **정확함** | N/A (SSD 무관, CPU↔GPU 간 메모리 복사) | **CPU thread** (BAR1 load/store) | CPU가 GPU BAR1 매핑을 통해 GPU 메모리에 직접 접근 |

**해설 (3줄)**

Storage access 분석에서 가장 정확한 해석 단위는 프로젝트마다 다르다. GDS/KvikIO/DeepSpeed는 **CPU thread**가 올바른 분석 단위이고, BaM/GIDS는 **GPU warp**이 올바른 단위다. GPU warp이 중요한 이유는 `__match_any_sync()` 기반 coalescing이 warp 경계에서 발생하기 때문이다.

---

## 8. Final Judgment Table

| Question | Best Answer | Best Matching Project(s) | Why | Confidence |
|----------|-----------|-------------------------|-----|------------|
| SSD를 truly memory semantic하게 다루는 NVIDIA 오픈소스가 있는가? | **NVIDIA "공식" org 소유로는 없다.** NVIDIA 연구자 참여 프로젝트인 BaM이 가장 가까움 | BaM (ZaidQureshi/bam) | `operator[]`와 `bam_ptr<T>`로 SSD 데이터를 배열/포인터로 투명 접근. 캐시 miss 시 자동 NVMe fetch. 단, NVIDIA org 소유가 아닌 공동 연구 프로젝트 | High |
| SSD를 VRAM 확장처럼 가장 잘 설명하는 프로젝트는? | **BaM** — GPU HBM과 NVMe SSD 사이에 소프트웨어 캐시를 삽입하여 SSD를 GPU 메모리 계층의 최하위 티어로 편입 | BaM, GIDS | BaM은 범용, GIDS는 GNN 특화. 둘 다 GPU thread가 data[i]로 접근하면 캐시→SSD 자동 fetch | High |
| Production-grade에 가장 가까운 것은? | **GDS** (gds-nvidia-fs + cuFile + KvikIO) | GDS, KvikIO | CUDA Toolkit 포함, NVIDIA 공식 지원, XFS/EXT4 호환, 활발한 업데이트. 단, memory semantic이 아닌 block I/O | High |
| 연구용 prototype에 가장 가까운 것은? | **BaM** | BaM, GIDS, GPUfs | 커스텀 NVMe 드라이버, IOMMU 비활성화 필수, raw NVMe만 지원, 표준 파일시스템 미지원 | High |
| GPU가 SSD를 direct access한다는 표현이 가장 정확한 경우는? | **BaM에서 GPU thread가 NVMe SQ에 명령을 직접 enqueue하고 doorbell을 MMIO로 ring할 때** | BaM | nvm_parallel_queue.h의 PTX `st.mmio.relaxed.sys` 명령이 GPU→NVMe doorbell 직접 쓰기를 증명. GDS에서는 GPU가 DMA target일 뿐 "direct access"가 아님 | High |
| CPU 관점에서 GPU storage access를 이해할 때 가장 흔한 오해는? | **"GPU가 SSD를 읽는다"는 표현에서 initiator, orchestrator, data mover, consumer를 혼동하는 것** | 전체 | GDS에서 GPU는 consumer만 담당. BaM에서도 data mover는 NVMe DMA 엔진이며 GPU는 initiator+consumer. CPU 경험으로 "읽는다 = 전체 제어"라 가정하면 아키텍처를 오해함 | High |
| Storage access의 실질 주체를 GPU에서 무엇으로 보는 것이 가장 정확한가? | **GDS: CPU thread가 주체, GPU는 수동적 수신자. BaM: GPU warp이 주체 (warp-level coalescing이 I/O의 자연 단위)** | GDS → CPU thread; BaM → GPU warp | GDS: 모든 I/O가 CPU ioctl로 시작 (nvfs-core.c). BaM: warp 내 `__match_any_sync()`로 동일 페이지 접근을 합체하여 리더 thread 1개가 캐시/NVMe 처리 | High |

---

### 필수 질문 10개 답변 종합표

| # | Question | Answer | Key Evidence | Confidence |
|---|----------|--------|-------------|------------|
| 1 | CPU에서 storage access의 실질 주체는? | **CPU thread** (syscall 발행) + **OS kernel** (orchestration) + **NVMe DMA** (data move) | POSIX read → VFS → NVMe driver → DMA. CPU thread는 initiator이자 consumer | High |
| 2 | GPU에서 storage access의 실질 주체는? | **GDS**: CPU thread가 주체, GPU는 passive. **BaM**: GPU warp이 주체 (initiator+consumer), NVMe DMA가 data mover | GDS: nvfs-core.c ioctl. BaM: page_cache.h operator[], nvm_parallel_queue.h sq_enqueue | High |
| 3 | GPU가 SSD 데이터를 가져오는 실제 경로는? | **GDS**: CPU→cuFile→ioctl→VFS→NVMe driver→SGL remap→NVMe DMA→GPU BAR1. **BaM**: GPU→cache miss→NVMe cmd→SQ→doorbell MMIO→NVMe DMA→GPU mem→CQ poll | 섹션 5 Data Path Table 참조 | High |
| 4 | NVMe→GPU memory direct DMA가 가능한가? | **Confirmed Yes.** 두 프로젝트 모두 `nvidia_p2p_get_pages()` + `nvidia_p2p_dma_map_pages()`로 GPU 메모리를 NVMe DMA 타겟으로 등록 | GDS: nvfs-core.c. BaM: module/map.c | High |
| 5 | CPU DRAM bounce buffer는 제거되는가? | **GDS/BaM: 제거됨.** DeepSpeed/FlashNeuron: 사용됨 | GDS: SGL을 GPU 주소로 치환. BaM: P2P DMA 직접 매핑. DeepSpeed: aio→DRAM→cudaMemcpy | High |
| 6 | 이 모델은 I/O API인가, memory API인가? | **GDS: I/O API** (cuFileRead/Write, 명시적 파일 연산). **BaM: Memory API** (operator[], bam_ptr, 투명 접근) | GDS: cuFile 함수 시그니처. BaM: page_cache.h operator[] 오버로딩 | High |
| 7 | Page fault 기반인가, explicit read 기반인가? | **GDS: explicit read** (cuFileRead 호출). **BaM: software demand paging** (cache miss → 자동 NVMe fetch, HW page fault는 아님) | BaM page_cache.h: INVALID→BUSY→NVMe read→VALID 전이 | High |
| 8 | GPU kernel이 직접 storage access trigger를 만드는가? | **GDS: No** (CPU가 trigger). **BaM: Yes** (GPU thread의 operator[] cache miss가 NVMe 명령 발행을 trigger) | GDS: CPU ioctl 필수. BaM: __device__ read_data() → sq_enqueue() | High |
| 9 | SSD를 확장 VRAM이라고 부르는 것이 기술적으로 타당한가? | **부분적으로만 타당 (BaM에 한함).** 프로그래밍 모델은 유사하나 성능 특성(지연 100-1000x, 대역폭 100x+, 쓰기 수명)이 근본적으로 다름. "VRAM의 최하위 캐시 티어"가 더 정확한 표현 | BaM 성능: 10-100μs vs HBM ~100ns. 대역폭: ~25GB/s vs 2-5TB/s | High |
| 10 | Thread/warp/block/SM 중 어떤 수준에서 이해해야 가장 정확한가? | **GDS: CPU thread 수준. BaM: GPU warp 수준.** BaM의 `__match_any_sync()` coalescing이 warp 경계에서 발생하므로 warp이 I/O의 자연 단위 | page_cache.h: `__match_any_sync(0xFFFFFFFF, page_id)` → warp 내 동일 페이지 접근 리더 선출 | High |

---

### 결론 (15줄 이내)

**1. NVIDIA "공식" vs "NVIDIA 참여"를 구분해야 한다.** NVIDIA org 소유의 GPU-SSD 프로젝트는 GDS(gds-nvidia-fs)뿐이며, 이는 CPU-initiated block I/O 최적화다. BaM은 NVIDIA 연구자(Bill Dally 포함)가 공동 연구했으나 NVIDIA 공식이 아니다.

**2. Memory semantic의 유일한 구현은 BaM이다.** `operator[]`와 `bam_ptr<T>`로 SSD를 배열/포인터처럼 접근하며, cache miss 시 GPU warp이 NVMe 명령을 직접 발행한다. GDS는 block I/O이며 memory semantic이 아니다.

**3. "GPU가 SSD를 직접 접근한다"는 정확한 표현이 아니다.** GDS에서 GPU는 DMA target(수동적 수신자)이며, CPU가 전체 I/O를 제어한다. BaM에서만 GPU가 I/O initiator 역할을 하며, 그때도 data mover는 NVMe DMA 엔진이다.

**4. Initiator ≠ Orchestrator ≠ Data Mover ≠ Consumer를 구분해야 한다.** CPU 경험으로 "읽는다"를 전체 제어로 이해하면 GPU storage access 아키텍처를 오해하게 된다. BaM에서 GPU warp은 initiator+consumer이고, orchestrator는 GPU runtime(page_cache_t)이며, data mover는 NVMe DMA 엔진이다.

**5. "SSD = VRAM 확장"은 마케팅적 단순화다.** BaM이 투명한 접근 추상화를 제공하지만, 지연시간(100-1000x), 대역폭(100x+), 쓰기 수명에서 HBM과 근본적으로 다르다. "GPU 메모리 계층의 최하위 demand-paging 티어"가 기술적으로 더 정확한 표현이다.

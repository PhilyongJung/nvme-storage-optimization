# Research Log: NVIDIA GPU-SSD Memory Semantic Access Analysis

## Search Log Table

| Step | Query / Keyword | Where Searched | Results Found | Kept Candidates | Notes |
|------|----------------|----------------|---------------|-----------------|-------|
| 1 | `nvidia bam big accelerator memory` | GitHub Search | 3 | 1 (ZaidQureshi/bam) | BaM은 NVIDIA 공식이 아닌 NVIDIA+IBM+UIUC 공동 연구 프로젝트 |
| 2 | `nvidia gpudirect storage` | GitHub Search | 8 | 2 (gds-nvidia-fs, kvikio) | gds-nvidia-fs가 공식 커널 드라이버, kvikio가 유저스페이스 래퍼 |
| 3 | `nvidia gids gpu initiated direct storage` | GitHub Search | 2 | 1 (jeongminpark417/GIDS) | BaM 기반 GNN 특화 데이터로더 |
| 4 | `nvidia cufile examples` | GitHub Search | 5 | 1 (cuda-samples) | cuFile 예제는 cuda-samples에 포함 |
| 5 | `nvidia magnum IO` | GitHub Search | 2 | 1 (NVIDIA/MagnumIO) | GDS 상위 프레임워크, 예제 포함 |
| 6 | `nvidia gdrcopy` | GitHub Search | 3 | 1 (NVIDIA/gdrcopy) | GPU 메모리 CPU 매핑, GDS와 상보적 |
| 7 | `GPU out-of-core memory NVMe` | GitHub Search | 6 | 1 (gpu-out-of-core-xtx) | 개인 프로젝트, out-of-core GPU 매트릭스 연산 |
| 8 | `FlashNeuron GPU SSD` | GitHub Search | 2 | 1 (SNU-ARC/flashneuron) | 학술 연구, DNN 텐서 SSD 오프로드 |
| 9 | `DeepSpeed offload SSD NVMe` | GitHub Search | 3 | 1 (deepspeedai/DeepSpeed) | ZeRO-Infinity: SSD를 메모리 계층으로 활용, 프로덕션급 |
| 10 | `GPU direct NVMe access gpufs` | GitHub Search | 4 | 1 (gpufs/gpufs) | GPU 커널에서 파일시스템 접근, BaM의 학술 선행 연구 |
| 11 | `GPUDirect async libgdsync` | GitHub Search | 3 | 1 (gpudirect/libgdsync) | GPU-initiated async I/O 프리미티브 |
| 12 | `nvidia gds llm inference NVMe VRAM` | GitHub Search | 2 | 1 (rscunha13/gdsllm) | GDS로 LLM weight를 NVMe→VRAM 스트리밍 |
| 13 | `nvidia GPU SSD memory extension` | GitHub API | 4 | 0 | 기존 후보와 중복 |
| 14 | `GPU swap SSD` | GitHub Search | 3 | 0 | 관련 없는 프로젝트만 발견 |
| 15 | `GPU page cache NVMe demand paging` | GitHub Search | 2 | 0 | BaM/GIDS와 중복 |
| 16 | BaM ArXiv paper (2203.04910) | ArXiv | 1 | 해당 | ASPLOS '23 논문, 핵심 아키텍처 근거 |
| 17 | GIDS ArXiv paper (2306.16384) | ArXiv | 1 | 해당 | GNN 특화 BaM 확장 논문 |
| 18 | NVIDIA GDS Overview Guide | NVIDIA Docs | 1 | 해당 | cuFile API, 아키텍처 공식 문서 |
| 19 | Chris Newburn "GPUs as Data Access Engines" | FMS 2024 | 1 | 해당 | NVIDIA의 GPU-SSD 접근 비전 발표 자료 |

---

## Exclusion Table

| Project | Why Excluded | Still Mentioned in Final Report? | Reason |
|---------|-------------|----------------------------------|--------|
| gpu-out-of-core-xtx | 개인 프로젝트, SSD가 아닌 host memory 기반 out-of-core, NVIDIA 공식 아님 | Yes (Candidate Table) | 접근 패턴 비교 참고용 |
| GPU-Out-of-Core-Volume-Data | 개인 프로젝트, 볼륨 데이터 전용, 비활성 | No | 일반성 부족 |
| peterjk2/DirectGPUFS | 개인 프로젝트, 비활성, 문서 부족 | No | 근거 불충분 |
| jhlee508/nvidia-gds-benchmark | 벤치마크 도구만, 새로운 추상화 없음 | No | 분석 대상이 아닌 측정 도구 |
| gpudirect/gdasync | InfiniBand 중심, 스토리지 직접 무관 | No | 네트워크 I/O 특화 |
| nvidia-gds-feedstock (conda) | 패키지 메타데이터만, 코드 없음 | No | 배포 채널일 뿐 |

---

## Evidence Quality Table

| Project | README Evidence | Docs Evidence | Code Evidence | Issue/PR Evidence | Paper Evidence | Overall Reliability |
|---------|----------------|---------------|---------------|-------------------|----------------|---------------------|
| **BaM** (ZaidQureshi/bam) | High — 상세 빌드/사용 가이드 | Medium — ASPLOS artifact eval | **High** — page_cache.h, nvm_parallel_queue.h, bafs_ptr.h, module/map.c 전수 분석 | Low — 제한적 | **High** — ASPLOS '23 peer-reviewed | **High** |
| **GDS** (NVIDIA/gds-nvidia-fs) | Medium — 기본 설명 | **High** — NVIDIA 공식 문서 (Overview Guide, API Reference) | **High** — nvfs-dma.c, nvfs-core.c, nvfs-mmap.c, nvfs-pci.c 전수 분석 | Medium — GitHub issues 활성 | Medium — 발표 자료 다수 | **High** |
| **GIDS** (jeongminpark417/GIDS) | Medium — 설치 가이드 중심 | Low | Medium — BaM submodule 의존, pybind11 래퍼 | Low | **High** — arXiv 논문 상세 | **Medium-High** |
| **KvikIO** (rapidsai/kvikio) | **High** — 상세 API 문서 | **High** — RAPIDS 공식 문서 | **High** — file_handle.hpp, cufile shim, posix_io.hpp | Medium | Low | **High** |
| **DeepSpeed** (deepspeedai/DeepSpeed) | **High** — ZeRO-Infinity 상세 설명 | **High** — 공식 블로그, 튜토리얼 | Medium — 대규모 코드베이스 | **High** — 활발한 커뮤니티 | **High** — SC '21 논문 | **High** |
| **FlashNeuron** (SNU-ARC/flashneuron) | Medium | Low | Medium — PyTorch 수정 | Low — 비활성 | **High** — ATC '21 peer-reviewed | **Medium** |
| **gdrcopy** (NVIDIA/gdrcopy) | **High** | **High** | **High** — gdrdrv.c 분석 | Medium | Medium | **High** |
| **MagnumIO** (NVIDIA/MagnumIO) | Medium — 프레임워크 개요 | Medium | Low — 예제 위주 | Low | Low | **Medium** |
| **GPUfs** (gpufs/gpufs) | Medium | Low | Medium | Low | **High** — ASPLOS '13 논문 | **Medium** |
| **gdsllm** (rscunha13/gdsllm) | Medium — LLM 추론용 weight 스트리밍 | Low | Medium — GDS 기반 구현 | Low | Low | **Medium-Low** |
| **libgdsync** (gpudirect/libgdsync) | Medium | Low | Medium | Low | Medium | **Medium-Low** |

---

## Key Evidence Artifacts Found

| Artifact Type | Project | Location | Significance |
|---------------|---------|----------|-------------|
| GPU-initiated NVMe 명령 제출 코드 | BaM | `include/nvm_parallel_queue.h` — `sq_enqueue()` with PTX `st.mmio.relaxed.sys` | GPU 스레드가 NVMe doorbell을 직접 MMIO 쓰기하는 결정적 증거 |
| Memory semantic operator[] | BaM | `include/page_cache.h` — `array_d_t<T>::operator[]` | SSD 데이터를 배열 인덱싱으로 투명 접근 |
| SGL 리매핑 코드 | GDS | `src/nvfs-dma.c` — `nvfs_blk_rq_map_sg_internal()` | CPU 물리 주소를 GPU BAR 주소로 치환하는 핵심 메커니즘 |
| Shadow buffer→GPU 주소 변환 | GDS | `src/nvfs-mmap.c` — `nvfs_mgroup_get_gpu_physical_address()` | 표준 VFS bio 경로가 GPU 주소를 운반하는 방법 |
| CPU ioctl 제어 경로 | GDS | `src/nvfs-core.c` — `nvfs_ioctl()`, `nvfs_direct_io()` | 모든 GDS I/O가 CPU ioctl로 시작됨을 증명 |
| P2P DMA 설정 (BaM) | BaM | `module/map.c` — `map_gpu_memory()` calls `nvidia_p2p_get_pages()` | NVMe→GPU 직접 DMA 매핑 생성 |
| P2P DMA 설정 (GDS) | GDS | `src/nvfs-core.c` — `nvfs_pin_gpu_pages()`, `nvfs_get_p2p_dma_mapping()` | 동일 NVIDIA P2P API 사용 확인 |
| cuFile 동적 바인딩 | KvikIO | `cpp/include/kvikio/shim/cufile.hpp` — dlopen shimming | libcufile.so를 런타임 로드하여 GDS 활용 |
| CPU 폴백 경로 | KvikIO | `cpp/include/kvikio/posix_io.hpp` — `posix_device_io()` | GDS 미지원 시 bounce buffer 경유 경로 확인 |
| 64KB GPU 페이지 | GDS | `src/nvfs-core.h` — `GPU_PAGE_SIZE = 64KB` | GDS SGL 리매핑의 기본 단위 |
| Clock 교체 알고리즘 | BaM | `include/page_cache.h` — `find_slot()` with atomic ticket | GPU 스레드가 캐시 교체를 직접 수행 |
| NVIDIA P2P API 래핑 | GDS | `src/nvfs-p2p.h` — 8개 nvidia_p2p_* 함수 매크로 | GDS와 BaM 모두 동일 NVIDIA P2P 커널 API에 의존 |

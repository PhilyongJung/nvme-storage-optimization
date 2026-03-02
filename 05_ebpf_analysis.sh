#!/bin/bash
###############################################################################
# NVMe I/O Performance Analysis with eBPF
#
# eBPF/bpftrace를 사용한 NVMe I/O 경로의 정량적 성능 분석 도구
#
# 분석 항목:
#   1. Block I/O Latency Histogram (bio latency breakdown)
#   2. NVMe Command Latency (driver-level)
#   3. IRQ Latency & Distribution
#   4. Syscall Overhead (io_uring vs libaio)
#   5. Cross-NUMA Memory Access Detection
#   6. Queue Depth & Pending I/O Monitoring
#   7. Context Switch / CPU Migration Tracking
#   8. Full I/O Lifecycle Tracing (submit → complete)
#
# 사용법: sudo bash 05_ebpf_analysis.sh --probe <probe_name> [options]
#
# 요구사항: bpftrace (≥0.13), bcc-tools, linux-headers
###############################################################################

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

PROBE=""
DURATION=30
DEVICE=""
OUTPUT_DIR="./ebpf_results_$(date +%Y%m%d_%H%M%S)"
PID=""

usage() {
    cat << 'EOF'
Usage: sudo bash 05_ebpf_analysis.sh --probe <name> [options]

Probes:
  bio-latency       Block I/O latency histogram (per device)
  nvme-latency      NVMe driver command latency breakdown
  irq-latency       IRQ handler latency for NVMe interrupts
  syscall-overhead   Syscall overhead comparison (io_uring vs libaio)
  numa-access        Cross-NUMA memory access detection
  queue-depth        Real-time queue depth monitoring
  ctx-switch         Context switch & CPU migration tracking
  io-lifecycle       Full I/O lifecycle tracing (submit → complete)
  all                Run all probes sequentially
  dashboard          Run key probes in parallel (tmux)

Options:
  --duration <sec>   Tracing duration (default: 30)
  --device <dev>     Filter by device (e.g., nvme0n1)
  --pid <pid>        Filter by PID (e.g., fio process)
  --output <dir>     Output directory
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --probe)    PROBE="$2"; shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        --device)   DEVICE="$2"; shift 2 ;;
        --pid)      PID="$2"; shift 2 ;;
        --output)   OUTPUT_DIR="$2"; shift 2 ;;
        *) echo "Unknown: $1"; usage ;;
    esac
done

[[ -z "$PROBE" ]] && usage
[[ $EUID -ne 0 ]] && { echo "ERROR: Must run as root"; exit 1; }

mkdir -p "$OUTPUT_DIR"

check_bpftrace() {
    if ! command -v bpftrace &>/dev/null; then
        echo -e "${RED}bpftrace not found. Install:${NC}"
        echo "  apt install -y bpftrace"
        echo "  # or from source: https://github.com/iovisor/bpftrace"
        exit 1
    fi
    echo -e "${GREEN}bpftrace $(bpftrace --version 2>/dev/null)${NC}"
}

run_probe() {
    local name="$1"
    local script="$2"
    local out_file="$OUTPUT_DIR/${name}_$(date +%H%M%S).txt"

    echo -e "\n${BOLD}${CYAN}[PROBE] ${name}${NC} (${DURATION}s → ${out_file})"
    echo -e "  Press Ctrl+C or wait ${DURATION}s to stop\n"

    timeout "$DURATION" bpftrace -e "$script" 2>&1 | tee "$out_file" || true

    echo -e "\n${GREEN}Saved: ${out_file}${NC}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# PROBE 1: Block I/O Latency Histogram
# ═══════════════════════════════════════════════════════════════════════════════
probe_bio_latency() {
    echo -e "${BOLD}${BLUE}═══ Block I/O Latency Histogram ═══${NC}"
    echo "  커널 Block Layer에서 I/O 요청의 latency 분포를 측정"
    echo "  blk_account_io_start → blk_account_io_done 구간"

    local filter=""
    [[ -n "$DEVICE" ]] && filter="/ ((struct gendisk *)args.disk)->disk_name == \"${DEVICE}\" /"

    run_probe "bio_latency" "
/*
 * Block I/O Latency Histogram
 * bio 요청 ~ 완료까지의 latency를 us 단위로 히스토그램화
 */
BEGIN { printf(\"Tracing block I/O latency... Duration: ${DURATION}s\\n\"); }

tracepoint:block:block_io_start ${filter}
{
    @start[args.sector] = nsecs;
    @io_size[args.bytes] = count();
    @rw[(args.rwbs & 1) ? \"write\" : \"read\"] = count();
}

tracepoint:block:block_io_done ${filter}
/@start[args.sector]/
{
    \$lat_us = (nsecs - @start[args.sector]) / 1000;
    @lat_hist = hist(\$lat_us);
    @lat_avg = avg(\$lat_us);
    @lat_total = count();

    // Bucket by latency range
    if (\$lat_us < 10) {
        @lat_bucket[\"< 10us\"] = count();
    } else if (\$lat_us < 50) {
        @lat_bucket[\"10-50us\"] = count();
    } else if (\$lat_us < 100) {
        @lat_bucket[\"50-100us\"] = count();
    } else if (\$lat_us < 500) {
        @lat_bucket[\"100-500us\"] = count();
    } else if (\$lat_us < 1000) {
        @lat_bucket[\"500us-1ms\"] = count();
    } else {
        @lat_bucket[\"> 1ms\"] = count();
    }

    delete(@start[args.sector]);
}

END {
    printf(\"\\n=== Block I/O Latency Distribution (us) ===\\n\");
    print(@lat_hist);
    printf(\"\\n=== Latency Buckets ===\\n\");
    print(@lat_bucket);
    printf(\"\\n=== Average Latency: \"); print(@lat_avg);
    printf(\"=== Total I/Os: \"); print(@lat_total);
    printf(\"\\n=== I/O Size Distribution ===\\n\");
    print(@io_size);
    printf(\"\\n=== Read/Write Mix ===\\n\");
    print(@rw);
    clear(@start);
}
"
}

# ═══════════════════════════════════════════════════════════════════════════════
# PROBE 2: NVMe Driver Command Latency
# ═══════════════════════════════════════════════════════════════════════════════
probe_nvme_latency() {
    echo -e "${BOLD}${BLUE}═══ NVMe Driver Command Latency ═══${NC}"
    echo "  NVMe 드라이버 레벨에서 명령 submit → complete 구간 측정"

    run_probe "nvme_cmd_latency" '
/*
 * NVMe Command Latency
 * nvme_setup_cmd → nvme_complete_rq 구간
 * 커널 NVMe 드라이버 내부 latency 측정
 */
BEGIN { printf("Tracing NVMe command latency...\n"); }

kprobe:nvme_setup_cmd
{
    @cmd_start[tid] = nsecs;
    @submit_cpu[tid] = cpu;
}

kprobe:nvme_complete_rq
/@cmd_start[tid]/
{
    $lat_us = (nsecs - @cmd_start[tid]) / 1000;
    @nvme_lat = hist($lat_us);
    @nvme_avg = avg($lat_us);
    @nvme_min = min($lat_us);
    @nvme_max = max($lat_us);
    @nvme_cnt = count();

    // Track if completion is on same CPU as submission
    if (cpu == @submit_cpu[tid]) {
        @same_cpu = count();
    } else {
        @diff_cpu = count();
        @cpu_migration[@submit_cpu[tid], cpu] = count();
    }

    delete(@cmd_start[tid]);
    delete(@submit_cpu[tid]);
}

END {
    printf("\n=== NVMe Command Latency (us) ===\n");
    print(@nvme_lat);
    printf("\n--- Statistics ---\n");
    printf("Avg: "); print(@nvme_avg);
    printf("Min: "); print(@nvme_min);
    printf("Max: "); print(@nvme_max);
    printf("Count: "); print(@nvme_cnt);
    printf("\n--- CPU Affinity ---\n");
    printf("Same CPU (submit=complete): "); print(@same_cpu);
    printf("Different CPU: "); print(@diff_cpu);
    printf("\nCPU Migration [submit_cpu, complete_cpu]:\n");
    print(@cpu_migration);
}
'
}

# ═══════════════════════════════════════════════════════════════════════════════
# PROBE 3: IRQ Latency
# ═══════════════════════════════════════════════════════════════════════════════
probe_irq_latency() {
    echo -e "${BOLD}${BLUE}═══ NVMe IRQ Latency & Distribution ═══${NC}"
    echo "  NVMe 인터럽트 핸들러의 실행 시간 및 CPU 분포 측정"

    run_probe "irq_latency" '
/*
 * IRQ Handler Latency
 * hardirq 진입 ~ 종료까지의 시간 및 CPU 분포
 */
BEGIN { printf("Tracing IRQ latency...\n"); }

tracepoint:irq:irq_handler_entry
/str(args.name) == "nvme0q0" ||
 str(args.name) == "nvme0q1" ||
 str(args.name) == "nvme0q2" ||
 str(args.name) == "nvme0q3" ||
 str(args.name) == "nvme0q4" ||
 str(args.name) == "nvme0q5" ||
 str(args.name) == "nvme0q6" ||
 str(args.name) == "nvme0q7" ||
 str(args.name) == "nvme0q8" ||
 strcontains(str(args.name), "nvme")/
{
    @irq_start[tid] = nsecs;
    @irq_cpu[cpu] = count();
    @irq_name[str(args.name)] = count();
}

tracepoint:irq:irq_handler_exit
/@irq_start[tid]/
{
    $lat_ns = nsecs - @irq_start[tid];
    @irq_lat_ns = hist($lat_ns);
    @irq_avg_ns = avg($lat_ns);
    @irq_max_ns = max($lat_ns);
    delete(@irq_start[tid]);
}

/* SoftIRQ tracking (block completion often happens here) */
tracepoint:irq:softirq_entry
/args.vec == 4/  /* BLOCK_SOFTIRQ */
{
    @softirq_start[tid] = nsecs;
}

tracepoint:irq:softirq_exit
/args.vec == 4 && @softirq_start[tid]/
{
    $soft_lat = nsecs - @softirq_start[tid];
    @softirq_lat = hist($soft_lat / 1000);
    @softirq_avg = avg($soft_lat / 1000);
    delete(@softirq_start[tid]);
}

END {
    printf("\n=== Hard IRQ Latency (ns) ===\n");
    print(@irq_lat_ns);
    printf("Avg (ns): "); print(@irq_avg_ns);
    printf("Max (ns): "); print(@irq_max_ns);

    printf("\n=== IRQ per CPU Distribution ===\n");
    print(@irq_cpu);

    printf("\n=== IRQ per Queue Name ===\n");
    print(@irq_name);

    printf("\n=== Block SoftIRQ Latency (us) ===\n");
    print(@softirq_lat);
    printf("SoftIRQ Avg (us): "); print(@softirq_avg);
}
'
}

# ═══════════════════════════════════════════════════════════════════════════════
# PROBE 4: Syscall Overhead (io_uring vs libaio)
# ═══════════════════════════════════════════════════════════════════════════════
probe_syscall_overhead() {
    echo -e "${BOLD}${BLUE}═══ Syscall Overhead: io_uring vs libaio ═══${NC}"
    echo "  I/O 관련 syscall의 빈도, 소요 시간 비교"

    local pid_filter=""
    [[ -n "$PID" ]] && pid_filter="/ pid == ${PID} /"

    run_probe "syscall_overhead" "
/*
 * Syscall Overhead Comparison
 * io_uring: io_uring_enter, io_uring_setup, io_uring_register
 * libaio:   io_submit, io_getevents
 * sync:     pread64, pwrite64, read, write
 */
BEGIN { printf(\"Tracing I/O syscalls... Duration: ${DURATION}s\\n\"); }

/* io_uring syscalls */
tracepoint:syscalls:sys_enter_io_uring_enter ${pid_filter}
{
    @uring_enter_start[tid] = nsecs;
    @uring_enter_cnt = count();
}
tracepoint:syscalls:sys_exit_io_uring_enter
/@uring_enter_start[tid]/
{
    \$lat = (nsecs - @uring_enter_start[tid]) / 1000;
    @uring_enter_lat = hist(\$lat);
    @uring_enter_avg = avg(\$lat);
    delete(@uring_enter_start[tid]);
}

/* io_submit (libaio) */
tracepoint:syscalls:sys_enter_io_submit ${pid_filter}
{
    @aio_submit_start[tid] = nsecs;
    @aio_submit_cnt = count();
}
tracepoint:syscalls:sys_exit_io_submit
/@aio_submit_start[tid]/
{
    \$lat = (nsecs - @aio_submit_start[tid]) / 1000;
    @aio_submit_lat = hist(\$lat);
    @aio_submit_avg = avg(\$lat);
    delete(@aio_submit_start[tid]);
}

/* io_getevents (libaio) */
tracepoint:syscalls:sys_enter_io_getevents ${pid_filter}
{
    @aio_getev_start[tid] = nsecs;
    @aio_getev_cnt = count();
}
tracepoint:syscalls:sys_exit_io_getevents
/@aio_getev_start[tid]/
{
    \$lat = (nsecs - @aio_getev_start[tid]) / 1000;
    @aio_getev_lat = hist(\$lat);
    @aio_getev_avg = avg(\$lat);
    delete(@aio_getev_start[tid]);
}

/* pread64/pwrite64 (sync) */
tracepoint:syscalls:sys_enter_pread64 ${pid_filter}
{
    @pread_start[tid] = nsecs;
    @pread_cnt = count();
}
tracepoint:syscalls:sys_exit_pread64
/@pread_start[tid]/
{
    \$lat = (nsecs - @pread_start[tid]) / 1000;
    @pread_lat = hist(\$lat);
    @pread_avg = avg(\$lat);
    delete(@pread_start[tid]);
}

END {
    printf(\"\\n===== io_uring_enter =====\\n\");
    printf(\"Count: \"); print(@uring_enter_cnt);
    printf(\"Avg (us): \"); print(@uring_enter_avg);
    print(@uring_enter_lat);

    printf(\"\\n===== io_submit (libaio) =====\\n\");
    printf(\"Count: \"); print(@aio_submit_cnt);
    printf(\"Avg (us): \"); print(@aio_submit_avg);
    print(@aio_submit_lat);

    printf(\"\\n===== io_getevents (libaio) =====\\n\");
    printf(\"Count: \"); print(@aio_getev_cnt);
    printf(\"Avg (us): \"); print(@aio_getev_avg);
    print(@aio_getev_lat);

    printf(\"\\n===== pread64 (sync) =====\\n\");
    printf(\"Count: \"); print(@pread_cnt);
    printf(\"Avg (us): \"); print(@pread_avg);
    print(@pread_lat);
}
"
}

# ═══════════════════════════════════════════════════════════════════════════════
# PROBE 5: Cross-NUMA Memory Access Detection
# ═══════════════════════════════════════════════════════════════════════════════
probe_numa_access() {
    echo -e "${BOLD}${BLUE}═══ Cross-NUMA Memory Access Detection ═══${NC}"
    echo "  I/O 경로에서 발생하는 NUMA 노드별 메모리 할당 추적"

    run_probe "numa_access" '
/*
 * NUMA Memory Allocation Tracking
 * I/O 관련 메모리 할당이 어느 NUMA 노드에서 발생하는지 추적
 * + NVMe completion이 발생하는 CPU의 NUMA 노드 추적
 */
#include <linux/mmzone.h>

BEGIN { printf("Tracing NUMA memory access patterns...\n"); }

/* Track page allocation per NUMA node */
tracepoint:kmem:mm_page_alloc
{
    @page_alloc_cpu[cpu] = count();
}

/* NVMe completion CPU tracking */
kprobe:nvme_irq
{
    @nvme_irq_cpu[cpu] = count();
}

kprobe:nvme_complete_rq
{
    @nvme_complete_cpu[cpu] = count();
}

/* blk_mq request completion tracking */
kprobe:blk_mq_end_request
{
    @blk_complete_cpu[cpu] = count();
}

/* Track which CPUs submit I/O */
kprobe:blk_mq_submit_bio
{
    @blk_submit_cpu[cpu] = count();
}

interval:s:5
{
    printf("\n--- 5s snapshot ---\n");
    printf("Submit CPUs: "); print(@blk_submit_cpu);
    printf("Complete CPUs: "); print(@blk_complete_cpu);
}

END {
    printf("\n=== I/O Submit CPU Distribution ===\n");
    print(@blk_submit_cpu);
    printf("\n=== I/O Complete CPU Distribution ===\n");
    print(@blk_complete_cpu);
    printf("\n=== NVMe IRQ CPU Distribution ===\n");
    print(@nvme_irq_cpu);
    printf("\n=== NVMe Complete CPU Distribution ===\n");
    print(@nvme_complete_cpu);
    printf("\n=== Page Alloc per CPU ===\n");
    print(@page_alloc_cpu);
    printf("\n[TIP] Compare submit vs complete CPUs.\n");
    printf("[TIP] If they are on different NUMA nodes, there is cross-NUMA traffic.\n");
}
'
}

# ═══════════════════════════════════════════════════════════════════════════════
# PROBE 6: Queue Depth Monitoring
# ═══════════════════════════════════════════════════════════════════════════════
probe_queue_depth() {
    echo -e "${BOLD}${BLUE}═══ Real-time Queue Depth Monitoring ═══${NC}"
    echo "  Block layer에서 실시간 in-flight I/O 수 모니터링"

    run_probe "queue_depth" '
/*
 * Real-time Queue Depth Monitor
 * blk_mq_start_request → blk_mq_end_request 구간의 in-flight 수
 */
BEGIN {
    printf("Monitoring in-flight I/O queue depth...\n");
    @inflight = 0;
}

kprobe:blk_mq_start_request
{
    @inflight++;
    @qd_hist = hist(@inflight);
    @qd_max = max(@inflight);
}

kprobe:blk_mq_end_request
{
    @inflight--;
    if (@inflight < 0) { @inflight = 0; }
}

/* Periodic snapshot */
interval:s:1
{
    printf("In-flight: %d\n", @inflight);
    @qd_per_sec = hist(@inflight);
}

END {
    printf("\n=== Queue Depth Distribution ===\n");
    print(@qd_hist);
    printf("\nMax in-flight: "); print(@qd_max);
    printf("Final in-flight: %d\n", @inflight);
}
'
}

# ═══════════════════════════════════════════════════════════════════════════════
# PROBE 7: Context Switch & CPU Migration
# ═══════════════════════════════════════════════════════════════════════════════
probe_ctx_switch() {
    echo -e "${BOLD}${BLUE}═══ Context Switch & CPU Migration ═══${NC}"
    echo "  I/O 워크로드 중 컨텍스트 스위치 및 CPU 마이그레이션 추적"

    local pid_filter=""
    [[ -n "$PID" ]] && pid_filter="/ pid == ${PID} /"

    run_probe "ctx_switch" "
/*
 * Context Switch & CPU Migration Tracker
 * 스케줄러 이벤트: 컨텍스트 스위치 빈도, voluntary/involuntary
 * CPU 마이그레이션: 다른 CPU로 이동 횟수
 */
BEGIN { printf(\"Tracing context switches... Duration: ${DURATION}s\\n\"); }

tracepoint:sched:sched_switch ${pid_filter}
{
    @ctx_switch_total = count();
    @ctx_from_cpu[cpu] = count();

    /* Track if prev task is our workload */
    if (args.prev_state == 0) {
        @involuntary = count();   /* preempted while runnable */
    } else {
        @voluntary = count();     /* blocked/sleeping */
    }
}

tracepoint:sched:sched_migrate_task ${pid_filter}
{
    @migration_total = count();
    @migrate_path[args.orig_cpu, args.dest_cpu] = count();
}

/* Track which CPUs the workload runs on */
profile:hz:99 ${pid_filter}
{
    @on_cpu[cpu] = count();
    @on_cpu_comm[comm] = count();
}

END {
    printf(\"\\n=== Context Switch Summary ===\\n\");
    printf(\"Total: \"); print(@ctx_switch_total);
    printf(\"Voluntary: \"); print(@voluntary);
    printf(\"Involuntary: \"); print(@involuntary);

    printf(\"\\n=== CPU Migration ===\\n\");
    printf(\"Total migrations: \"); print(@migration_total);
    printf(\"\\nMigration paths [from_cpu → to_cpu]:\\n\");
    print(@migrate_path);

    printf(\"\\n=== CPU Time Distribution ===\\n\");
    print(@on_cpu);

    printf(\"\\n=== Process Distribution ===\\n\");
    print(@on_cpu_comm);
}
"
}

# ═══════════════════════════════════════════════════════════════════════════════
# PROBE 8: Full I/O Lifecycle Tracing
# ═══════════════════════════════════════════════════════════════════════════════
probe_io_lifecycle() {
    echo -e "${BOLD}${BLUE}═══ Full I/O Lifecycle Tracing ═══${NC}"
    echo "  I/O 요청의 전체 생명주기: App → Block → Driver → Device → Complete"

    run_probe "io_lifecycle" '
/*
 * Full I/O Lifecycle Tracer
 *
 * 측정 구간:
 *   T1: App submit → block layer (blk_mq_submit_bio)
 *   T2: Block layer → NVMe driver (nvme_setup_cmd)
 *   T3: NVMe driver → device complete (nvme_complete_rq)
 *   T4: Complete → app notification
 *
 * 각 구간의 latency를 분리하여 병목 식별
 */
BEGIN { printf("Tracing I/O lifecycle breakdown...\n"); }

/* Stage 1: Block layer submit */
kprobe:blk_mq_submit_bio
{
    @bio_submit[tid] = nsecs;
    @bio_submit_cpu[tid] = cpu;
}

/* Stage 2: NVMe command setup */
kprobe:nvme_setup_cmd
/@bio_submit[tid]/
{
    $t_block = (nsecs - @bio_submit[tid]) / 1000;
    @stage_block_to_driver = hist($t_block);
    @stage_block_avg = avg($t_block);
    @nvme_cmd_start[tid] = nsecs;
}

/* Stage 3: NVMe command complete (interrupt/poll) */
kprobe:nvme_complete_rq
{
    /* NVMe driver latency (HW time) */
    if (@nvme_cmd_start[tid]) {
        $t_hw = (nsecs - @nvme_cmd_start[tid]) / 1000;
        @stage_hw_latency = hist($t_hw);
        @stage_hw_avg = avg($t_hw);
        delete(@nvme_cmd_start[tid]);
    }

    @complete_start[tid] = nsecs;
    @complete_cpu[tid] = cpu;
}

/* Stage 4: Block request end */
kprobe:blk_mq_end_request
/@bio_submit[tid]/
{
    /* Total end-to-end */
    $t_total = (nsecs - @bio_submit[tid]) / 1000;
    @stage_total = hist($t_total);
    @stage_total_avg = avg($t_total);

    /* Completion processing time */
    if (@complete_start[tid]) {
        $t_complete = (nsecs - @complete_start[tid]) / 1000;
        @stage_completion = hist($t_complete);
        @stage_complete_avg = avg($t_complete);
    }

    /* CPU locality check */
    if (@bio_submit_cpu[tid] == cpu) {
        @same_cpu_complete = count();
    } else {
        @cross_cpu_complete = count();
    }

    delete(@bio_submit[tid]);
    delete(@bio_submit_cpu[tid]);
    delete(@complete_start[tid]);
    delete(@complete_cpu[tid]);
}

END {
    printf("\n╔══════════════════════════════════════════════╗\n");
    printf("║         I/O LIFECYCLE BREAKDOWN              ║\n");
    printf("╚══════════════════════════════════════════════╝\n");

    printf("\n=== Stage 1: Block → Driver (us) ===\n");
    printf("  (blk_mq_submit_bio → nvme_setup_cmd)\n");
    print(@stage_block_to_driver);
    printf("  Avg: "); print(@stage_block_avg);

    printf("\n=== Stage 2: Driver → Device Complete (us) ===\n");
    printf("  (nvme_setup_cmd → nvme_complete_rq)\n");
    printf("  This is the actual NVMe hardware + driver latency\n");
    print(@stage_hw_latency);
    printf("  Avg: "); print(@stage_hw_avg);

    printf("\n=== Stage 3: Completion Processing (us) ===\n");
    printf("  (nvme_complete_rq → blk_mq_end_request)\n");
    print(@stage_completion);
    printf("  Avg: "); print(@stage_complete_avg);

    printf("\n=== Total End-to-End (us) ===\n");
    printf("  (blk_mq_submit_bio → blk_mq_end_request)\n");
    print(@stage_total);
    printf("  Avg: "); print(@stage_total_avg);

    printf("\n=== CPU Locality ===\n");
    printf("  Same CPU (submit=complete): "); print(@same_cpu_complete);
    printf("  Cross CPU: "); print(@cross_cpu_complete);
}
'
}

# ═══════════════════════════════════════════════════════════════════════════════
# Combined Probes / Dashboard
# ═══════════════════════════════════════════════════════════════════════════════
run_all_probes() {
    echo -e "${BOLD}${BLUE}Running all probes sequentially (${DURATION}s each)...${NC}"

    probe_bio_latency
    probe_nvme_latency
    probe_irq_latency
    probe_syscall_overhead
    probe_numa_access
    probe_queue_depth
    probe_ctx_switch
    probe_io_lifecycle

    echo -e "\n${GREEN}All probes complete. Results in: ${OUTPUT_DIR}/${NC}"
}

run_dashboard() {
    echo -e "${BOLD}${BLUE}Starting eBPF Dashboard (parallel probes)...${NC}"

    if ! command -v tmux &>/dev/null; then
        echo -e "${YELLOW}tmux not found. Running sequentially instead.${NC}"
        run_all_probes
        return
    fi

    local session="nvme_ebpf"
    tmux kill-session -t "$session" 2>/dev/null || true
    tmux new-session -d -s "$session" -n "bio-lat"

    # Pane layout: 2x2
    tmux send-keys -t "$session" "sudo bpftrace -e 'tracepoint:block:block_io_start { @start[args.sector]=nsecs; } tracepoint:block:block_io_done /@start[args.sector]/ { @us=hist((nsecs-@start[args.sector])/1000); delete(@start[args.sector]); }'" C-m

    tmux split-window -h -t "$session"
    tmux send-keys -t "$session" "sudo bpftrace -e 'kprobe:nvme_setup_cmd { @s[tid]=nsecs; } kprobe:nvme_complete_rq /@s[tid]/ { @us=hist((nsecs-@s[tid])/1000); delete(@s[tid]); }'" C-m

    tmux split-window -v -t "$session"
    tmux send-keys -t "$session" "sudo bpftrace -e 'kprobe:blk_mq_start_request { @inflight++; } kprobe:blk_mq_end_request { @inflight--; } interval:s:1 { printf(\"QD: %d\\n\", @inflight); }'" C-m

    tmux select-pane -t "$session:0.0"
    tmux split-window -v -t "$session"
    tmux send-keys -t "$session" "sudo bpftrace -e 'tracepoint:irq:irq_handler_entry /strcontains(str(args.name),\"nvme\")/ { @s[tid]=nsecs; @cpu[cpu]=count(); } tracepoint:irq:irq_handler_exit /@s[tid]/ { @ns=hist(nsecs-@s[tid]); delete(@s[tid]); }'" C-m

    echo -e "${GREEN}Dashboard started in tmux session '${session}'${NC}"
    echo "  tmux attach -t $session"
    echo "  Ctrl+B then D to detach"

    tmux attach -t "$session"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Pre-made BCC Tool Commands (alternative to bpftrace)
# ═══════════════════════════════════════════════════════════════════════════════
show_bcc_commands() {
    echo -e "${BOLD}${BLUE}═══ BCC Tool Quick Commands ═══${NC}"
    echo ""
    echo "  # 기본 설치"
    echo "  apt install -y bpfcc-tools linux-headers-\$(uname -r)"
    echo ""
    echo "  # Block I/O latency histogram"
    echo "  biolatency-bpfcc -D 10        # 10초, 디바이스별"
    echo "  biolatency-bpfcc -d nvme0n1   # 특정 디바이스"
    echo ""
    echo "  # Block I/O snoop (개별 I/O 추적)"
    echo "  biosnoop-bpfcc -d nvme0n1     # 개별 I/O 레이턴시"
    echo ""
    echo "  # NVMe 명령 추적"
    echo "  trace-bpfcc 'nvme_setup_cmd' 'nvme_complete_rq'"
    echo ""
    echo "  # IRQ 처리 시간"
    echo "  hardirqs-bpfcc -d 10          # 10초, IRQ별 시간"
    echo "  softirqs-bpfcc -d 10          # SoftIRQ 시간"
    echo ""
    echo "  # CPU 스케줄링"
    echo "  runqlat-bpfcc -p <PID> 10     # run queue latency"
    echo "  cpudist-bpfcc -p <PID> 10     # on-CPU time distribution"
    echo ""
    echo "  # NUMA"
    echo "  numastat -p <PID>             # NUMA 메모리 통계"
    echo "  perf stat -e node-loads,node-load-misses -p <PID> sleep 10"
    echo ""
    echo "  # 시스템 콜 분석"
    echo "  syscount-bpfcc -p <PID> -d 10 # 시스템콜 빈도/시간"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    echo -e "${BOLD}${BLUE}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║     NVMe I/O Performance Analysis with eBPF                     ║"
    echo "║     Quantitative Measurement Toolkit                            ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    check_bpftrace

    case "$PROBE" in
        bio-latency)      probe_bio_latency ;;
        nvme-latency)     probe_nvme_latency ;;
        irq-latency)      probe_irq_latency ;;
        syscall-overhead) probe_syscall_overhead ;;
        numa-access)      probe_numa_access ;;
        queue-depth)      probe_queue_depth ;;
        ctx-switch)       probe_ctx_switch ;;
        io-lifecycle)     probe_io_lifecycle ;;
        all)              run_all_probes ;;
        dashboard)        run_dashboard ;;
        bcc-commands)     show_bcc_commands ;;
        *)
            echo -e "${RED}Unknown probe: ${PROBE}${NC}"
            usage
            ;;
    esac
}

main "$@"

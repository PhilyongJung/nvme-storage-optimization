#!/bin/bash
###############################################################################
# NVMe I/O Stack Benchmark Suite
#
# 단일 I/O 경로의 효과를 정량적으로 비교하기 위한 FIO 벤치마크 스위트
#
# 비교 항목:
#   A. I/O Engine:    libaio vs io_uring vs io_uring(SQPOLL) vs SPDK
#   B. NUMA Affinity: Local vs Remote (Cross-NUMA)
#   C. Queue Depth:   1, 4, 16, 32, 64, 128
#   D. IRQ Affinity:  Default vs NUMA-optimized
#   E. I/O Scheduler: none vs mq-deadline
#   F. Polling Mode:  Interrupt vs io_poll (hipri)
#
# 사용법: sudo bash 04_fio_benchmark_suite.sh --dev /dev/nvme0n1 [options]
#
# 옵션:
#   --dev <device>     NVMe 디바이스 (필수)
#   --output <dir>     결과 저장 디렉토리 (기본: ./fio_results_YYYYMMDD_HHMMSS)
#   --runtime <sec>    각 테스트 실행 시간 (기본: 30)
#   --quick            빠른 테스트 (runtime=10, 축소된 QD 범위)
#   --tests <list>     실행할 테스트 (쉼표 구분: engine,numa,qd,irq,sched,poll,all)
#   --skip-spdk        SPDK 테스트 스킵
#   --size <size>      테스트 파일 크기 (기본: 4G)
###############################################################################

set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ─── Defaults ─────────────────────────────────────────────────────────────────
DEVICE=""
OUTPUT_DIR=""
RUNTIME=30
RAMPTIME=5
SIZE="4G"
QUICK=false
TESTS="all"
SKIP_SPDK=false
BS="4k"          # Block size for IOPS tests
BS_BW="128k"     # Block size for BW tests
NUMJOBS=1        # 단일 I/O 경로 비교

# ─── Parse Args ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        --dev)       DEVICE="$2"; shift 2 ;;
        --output)    OUTPUT_DIR="$2"; shift 2 ;;
        --runtime)   RUNTIME="$2"; shift 2 ;;
        --quick)     QUICK=true; RUNTIME=10; RAMPTIME=3; shift ;;
        --tests)     TESTS="$2"; shift 2 ;;
        --skip-spdk) SKIP_SPDK=true; shift ;;
        --size)      SIZE="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "$DEVICE" ]]; then
    echo "Usage: sudo $0 --dev /dev/nvme0n1 [options]"
    echo "  --dev <device>   NVMe block device (required)"
    echo "  --runtime <sec>  Per-test runtime (default: 30)"
    echo "  --quick          Quick mode (10s, fewer QDs)"
    echo "  --tests <list>   Tests to run: engine,numa,qd,irq,sched,poll,all"
    echo "  --skip-spdk      Skip SPDK tests"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must run as root"; exit 1
fi

[[ -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="./fio_results_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTPUT_DIR"/{json,logs,summary}

# ─── System Info Collection ───────────────────────────────────────────────────
collect_system_info() {
    local info_file="$OUTPUT_DIR/system_info.txt"
    echo -e "${CYAN}Collecting system information...${NC}"

    {
        echo "=== System Info ==="
        echo "Date: $(date)"
        echo "Kernel: $(uname -r)"
        echo "CPU: $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
        echo "Sockets: $(grep 'physical id' /proc/cpuinfo | sort -u | wc -l)"
        echo "CPUs: $(nproc)"
        echo "Memory: $(free -h | grep Mem | awk '{print $2}')"

        echo ""
        echo "=== Target Device: $DEVICE ==="
        local nvme_ctrl
        nvme_ctrl=$(echo "$DEVICE" | grep -oP 'nvme\d+')
        echo "NVMe Controller: $nvme_ctrl"

        local numa_node
        numa_node=$(cat "/sys/class/nvme/${nvme_ctrl}/device/numa_node" 2>/dev/null || echo "N/A")
        echo "NUMA Node: $numa_node"

        local pci_bdf
        pci_bdf=$(readlink -f "/sys/class/nvme/${nvme_ctrl}/device" 2>/dev/null | xargs basename 2>/dev/null || echo "N/A")
        echo "PCIe BDF: $pci_bdf"

        local queue_count
        queue_count=$(cat "/sys/class/nvme/${nvme_ctrl}/queue_count" 2>/dev/null || echo "N/A")
        echo "Queue Count: $queue_count"

        echo "Scheduler: $(cat /sys/block/$(basename $DEVICE)/queue/scheduler 2>/dev/null || echo 'N/A')"
        echo "nr_requests: $(cat /sys/block/$(basename $DEVICE)/queue/nr_requests 2>/dev/null || echo 'N/A')"
        echo "rq_affinity: $(cat /sys/block/$(basename $DEVICE)/queue/rq_affinity 2>/dev/null || echo 'N/A')"

        echo ""
        echo "=== NUMA Topology ==="
        numactl --hardware 2>/dev/null || echo "numactl not available"

        echo ""
        echo "=== NVMe IRQ Mapping ==="
        grep "$nvme_ctrl" /proc/interrupts 2>/dev/null | head -20

        echo ""
        echo "=== FIO Version ==="
        fio --version 2>/dev/null || echo "fio not found"

    } > "$info_file"

    # Export key variables for tests
    NVME_CTRL=$(echo "$DEVICE" | grep -oP 'nvme\d+')
    DEV_NUMA=$(cat "/sys/class/nvme/${NVME_CTRL}/device/numa_node" 2>/dev/null || echo "0")
    DEV_CPUS=$(cat "/sys/devices/system/node/node${DEV_NUMA}/cpulist" 2>/dev/null || echo "0")

    # Find remote NUMA node
    local num_numas
    num_numas=$(ls -d /sys/devices/system/node/node* 2>/dev/null | wc -l)
    REMOTE_NUMA=0
    if [[ $num_numas -gt 1 ]]; then
        for n in $(seq 0 $((num_numas - 1))); do
            if [[ "$n" != "$DEV_NUMA" ]]; then
                REMOTE_NUMA=$n
                break
            fi
        done
    fi
    REMOTE_CPUS=$(cat "/sys/devices/system/node/node${REMOTE_NUMA}/cpulist" 2>/dev/null || echo "0")

    # First CPU from each NUMA
    LOCAL_CPU=$(echo "$DEV_CPUS" | cut -d',' -f1 | cut -d'-' -f1)
    REMOTE_CPU=$(echo "$REMOTE_CPUS" | cut -d',' -f1 | cut -d'-' -f1)

    echo "  Device NUMA: $DEV_NUMA (CPU: $LOCAL_CPU)"
    echo "  Remote NUMA: $REMOTE_NUMA (CPU: $REMOTE_CPU)"
}

# ─── FIO Runner ───────────────────────────────────────────────────────────────
run_fio_test() {
    local test_name="$1"
    local fio_args="$2"
    local description="$3"
    local cpu_pin="${4:-}"    # Optional CPU pinning

    local json_file="$OUTPUT_DIR/json/${test_name}.json"
    local log_file="$OUTPUT_DIR/logs/${test_name}.log"

    echo -e "\n${BOLD}[TEST] ${test_name}${NC}"
    echo -e "  ${CYAN}${description}${NC}"

    local numa_cmd=""
    if [[ -n "$cpu_pin" ]]; then
        numa_cmd="numactl --cpunodebind=${cpu_pin} --membind=${cpu_pin}"
        echo -e "  CPU Bind: NUMA ${cpu_pin}"
    fi

    local cmd="$numa_cmd fio \
        --name=${test_name} \
        --filename=${DEVICE} \
        --direct=1 \
        --runtime=${RUNTIME} \
        --ramp_time=${RAMPTIME} \
        --time_based \
        --numjobs=${NUMJOBS} \
        --group_reporting \
        --output-format=json+ \
        --output=${json_file} \
        ${fio_args} \
        2>&1"

    echo "  Command: $cmd" >> "$log_file"
    echo -e "  Running for ${RUNTIME}s..."

    local start_time
    start_time=$(date +%s%N)

    eval "$cmd" >> "$log_file" 2>&1
    local exit_code=$?

    local end_time
    end_time=$(date +%s%N)
    local elapsed=$(( (end_time - start_time) / 1000000 ))

    if [[ $exit_code -ne 0 ]]; then
        echo -e "  ${RED}FAILED (exit code: $exit_code)${NC}"
        echo "FAILED" >> "$OUTPUT_DIR/summary/${test_name}.txt"
        return 1
    fi

    # Extract key metrics from JSON
    local read_iops read_bw_kb read_lat_mean read_lat_p99
    local write_iops write_bw_kb write_lat_mean write_lat_p99

    read_iops=$(python3 -c "
import json, sys
try:
    data = json.load(open('${json_file}'))
    job = data['jobs'][0]
    r = job['read']
    w = job['write']
    print(f\"{r['iops']:.0f},{r['bw']:.0f},{r['lat_ns']['mean']/1000:.2f},{r['clat_ns']['percentile']['99.000000']/1000:.2f}\")
    print(f\"{w['iops']:.0f},{w['bw']:.0f},{w['lat_ns']['mean']/1000:.2f},{w['clat_ns']['percentile']['99.000000']/1000:.2f}\")
except Exception as e:
    print(f'0,0,0,0')
    print(f'0,0,0,0')
" 2>/dev/null)

    local read_line write_line
    read_line=$(echo "$read_iops" | head -1)
    write_line=$(echo "$read_iops" | tail -1)

    IFS=',' read -r r_iops r_bw r_lat_mean r_lat_p99 <<< "$read_line"
    IFS=',' read -r w_iops w_bw w_lat_mean w_lat_p99 <<< "$write_line"

    # Display results
    if [[ "${r_iops:-0}" != "0" ]]; then
        echo -e "  ${GREEN}Read:  IOPS=${r_iops}, BW=${r_bw}KB/s, Lat(avg)=${r_lat_mean}us, Lat(P99)=${r_lat_p99}us${NC}"
    fi
    if [[ "${w_iops:-0}" != "0" ]]; then
        echo -e "  ${GREEN}Write: IOPS=${w_iops}, BW=${w_bw}KB/s, Lat(avg)=${w_lat_mean}us, Lat(P99)=${w_lat_p99}us${NC}"
    fi

    # Save summary
    {
        echo "test_name=${test_name}"
        echo "description=${description}"
        echo "elapsed_ms=${elapsed}"
        echo "read_iops=${r_iops:-0}"
        echo "read_bw_kb=${r_bw:-0}"
        echo "read_lat_mean_us=${r_lat_mean:-0}"
        echo "read_lat_p99_us=${r_lat_p99:-0}"
        echo "write_iops=${w_iops:-0}"
        echo "write_bw_kb=${w_bw:-0}"
        echo "write_lat_mean_us=${w_lat_mean:-0}"
        echo "write_lat_p99_us=${w_lat_p99:-0}"
    } > "$OUTPUT_DIR/summary/${test_name}.txt"

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST A: I/O Engine Comparison
# ═══════════════════════════════════════════════════════════════════════════════
test_io_engines() {
    echo -e "\n${BOLD}${BLUE}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  TEST A: I/O Engine Comparison (libaio vs io_uring vs SQPOLL)${NC}"
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════════════════════════${NC}"

    local common="--bs=${BS} --size=${SIZE} --iodepth=32 --rw=randread"

    # A1: libaio
    run_fio_test "A1_libaio_randread" \
        "--ioengine=libaio ${common}" \
        "libaio engine, QD=32, 4K random read" \
        "$DEV_NUMA"

    # A2: io_uring (default)
    run_fio_test "A2_iouring_randread" \
        "--ioengine=io_uring ${common}" \
        "io_uring engine, QD=32, 4K random read" \
        "$DEV_NUMA"

    # A3: io_uring with SQPOLL
    run_fio_test "A3_iouring_sqpoll_randread" \
        "--ioengine=io_uring --sqthread_poll=1 ${common}" \
        "io_uring + SQPOLL, QD=32, 4K random read" \
        "$DEV_NUMA"

    # A4: io_uring with fixed buffers
    run_fio_test "A4_iouring_fixedbuf_randread" \
        "--ioengine=io_uring --fixedbufs=1 --registerfiles=1 ${common}" \
        "io_uring + fixed buffers + registered files, QD=32, 4K random read" \
        "$DEV_NUMA"

    # A5: io_uring full optimization
    run_fio_test "A5_iouring_fullopt_randread" \
        "--ioengine=io_uring --sqthread_poll=1 --fixedbufs=1 --registerfiles=1 --hipri=1 ${common}" \
        "io_uring SQPOLL+fixedbuf+regfiles+hipri, QD=32, 4K random read" \
        "$DEV_NUMA"

    # A6: psync (baseline - synchronous I/O)
    run_fio_test "A6_psync_randread" \
        "--ioengine=psync --bs=${BS} --size=${SIZE} --iodepth=1 --rw=randread" \
        "psync (synchronous baseline), QD=1, 4K random read" \
        "$DEV_NUMA"

    # Write tests
    echo -e "\n  ${YELLOW}--- Write engine comparison ---${NC}"

    run_fio_test "A7_libaio_randwrite" \
        "--ioengine=libaio --bs=${BS} --size=${SIZE} --iodepth=32 --rw=randwrite" \
        "libaio engine, QD=32, 4K random write" \
        "$DEV_NUMA"

    run_fio_test "A8_iouring_randwrite" \
        "--ioengine=io_uring --bs=${BS} --size=${SIZE} --iodepth=32 --rw=randwrite" \
        "io_uring engine, QD=32, 4K random write" \
        "$DEV_NUMA"

    run_fio_test "A9_iouring_sqpoll_randwrite" \
        "--ioengine=io_uring --sqthread_poll=1 --bs=${BS} --size=${SIZE} --iodepth=32 --rw=randwrite" \
        "io_uring + SQPOLL, QD=32, 4K random write" \
        "$DEV_NUMA"

    # Sequential BW tests
    echo -e "\n  ${YELLOW}--- Sequential BW engine comparison ---${NC}"

    run_fio_test "A10_libaio_seqread" \
        "--ioengine=libaio --bs=${BS_BW} --size=${SIZE} --iodepth=16 --rw=read" \
        "libaio engine, QD=16, 128K sequential read" \
        "$DEV_NUMA"

    run_fio_test "A11_iouring_seqread" \
        "--ioengine=io_uring --bs=${BS_BW} --size=${SIZE} --iodepth=16 --rw=read" \
        "io_uring engine, QD=16, 128K sequential read" \
        "$DEV_NUMA"
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST B: NUMA Affinity Effect
# ═══════════════════════════════════════════════════════════════════════════════
test_numa_affinity() {
    echo -e "\n${BOLD}${BLUE}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  TEST B: NUMA Affinity Effect (Local vs Remote)${NC}"
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════════════════════════${NC}"

    local num_numas
    num_numas=$(ls -d /sys/devices/system/node/node* 2>/dev/null | wc -l)

    if [[ $num_numas -lt 2 ]]; then
        echo -e "  ${YELLOW}SKIP: Single NUMA system, cannot compare cross-NUMA${NC}"
        return
    fi

    echo -e "  Device on NUMA $DEV_NUMA, Remote NUMA $REMOTE_NUMA"

    local common="--ioengine=io_uring --bs=${BS} --size=${SIZE} --iodepth=32"

    # B1: NUMA Local - Random Read
    run_fio_test "B1_numa_local_randread" \
        "${common} --rw=randread" \
        "NUMA-LOCAL: io_uring, QD=32, 4K random read on NUMA $DEV_NUMA" \
        "$DEV_NUMA"

    # B2: NUMA Remote - Random Read
    run_fio_test "B2_numa_remote_randread" \
        "${common} --rw=randread" \
        "NUMA-REMOTE: io_uring, QD=32, 4K random read from NUMA $REMOTE_NUMA" \
        "$REMOTE_NUMA"

    # B3: NUMA Local - Random Write
    run_fio_test "B3_numa_local_randwrite" \
        "${common} --rw=randwrite" \
        "NUMA-LOCAL: io_uring, QD=32, 4K random write on NUMA $DEV_NUMA" \
        "$DEV_NUMA"

    # B4: NUMA Remote - Random Write
    run_fio_test "B4_numa_remote_randwrite" \
        "${common} --rw=randwrite" \
        "NUMA-REMOTE: io_uring, QD=32, 4K random write from NUMA $REMOTE_NUMA" \
        "$REMOTE_NUMA"

    # B5: NUMA Local - Sequential Read (BW)
    run_fio_test "B5_numa_local_seqread" \
        "--ioengine=io_uring --bs=${BS_BW} --size=${SIZE} --iodepth=16 --rw=read" \
        "NUMA-LOCAL: io_uring, QD=16, 128K seq read on NUMA $DEV_NUMA" \
        "$DEV_NUMA"

    # B6: NUMA Remote - Sequential Read (BW)
    run_fio_test "B6_numa_remote_seqread" \
        "--ioengine=io_uring --bs=${BS_BW} --size=${SIZE} --iodepth=16 --rw=read" \
        "NUMA-REMOTE: io_uring, QD=16, 128K seq read from NUMA $REMOTE_NUMA" \
        "$REMOTE_NUMA"

    # B7-B8: libaio NUMA comparison (for cross-engine reference)
    run_fio_test "B7_libaio_numa_local" \
        "--ioengine=libaio --bs=${BS} --size=${SIZE} --iodepth=32 --rw=randread" \
        "libaio NUMA-LOCAL reference" \
        "$DEV_NUMA"

    run_fio_test "B8_libaio_numa_remote" \
        "--ioengine=libaio --bs=${BS} --size=${SIZE} --iodepth=32 --rw=randread" \
        "libaio NUMA-REMOTE reference" \
        "$REMOTE_NUMA"
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST C: Queue Depth Sweep
# ═══════════════════════════════════════════════════════════════════════════════
test_queue_depth() {
    echo -e "\n${BOLD}${BLUE}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  TEST C: Queue Depth Sweep${NC}"
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════════════════════════${NC}"

    local qd_list
    if [[ "$QUICK" == "true" ]]; then
        qd_list="1 4 16 64 128"
    else
        qd_list="1 2 4 8 16 32 64 128 256"
    fi

    # io_uring QD sweep (random read)
    for qd in $qd_list; do
        run_fio_test "C_iouring_qd${qd}_randread" \
            "--ioengine=io_uring --bs=${BS} --size=${SIZE} --iodepth=${qd} --rw=randread" \
            "io_uring, QD=${qd}, 4K random read" \
            "$DEV_NUMA"
    done

    # libaio QD sweep (random read) for comparison
    echo -e "\n  ${YELLOW}--- libaio QD sweep for comparison ---${NC}"
    for qd in $qd_list; do
        run_fio_test "C_libaio_qd${qd}_randread" \
            "--ioengine=libaio --bs=${BS} --size=${SIZE} --iodepth=${qd} --rw=randread" \
            "libaio, QD=${qd}, 4K random read" \
            "$DEV_NUMA"
    done

    # io_uring QD sweep (random write)
    echo -e "\n  ${YELLOW}--- Write QD sweep ---${NC}"
    for qd in 1 16 64 128; do
        run_fio_test "C_iouring_qd${qd}_randwrite" \
            "--ioengine=io_uring --bs=${BS} --size=${SIZE} --iodepth=${qd} --rw=randwrite" \
            "io_uring, QD=${qd}, 4K random write" \
            "$DEV_NUMA"
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST D: IRQ Affinity Effect
# ═══════════════════════════════════════════════════════════════════════════════
test_irq_affinity() {
    echo -e "\n${BOLD}${BLUE}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  TEST D: IRQ Affinity Effect${NC}"
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════════════════════════${NC}"

    local common="--ioengine=io_uring --bs=${BS} --size=${SIZE} --iodepth=32 --rw=randread"

    # Save original IRQ affinities
    local irq_backup="$OUTPUT_DIR/irq_backup.sh"
    echo "#!/bin/bash" > "$irq_backup"
    echo "# IRQ affinity restore script" >> "$irq_backup"

    grep "${NVME_CTRL}" /proc/interrupts 2>/dev/null | while read -r line; do
        local irq_num
        irq_num=$(echo "$line" | awk '{print $1}' | tr -d ':')
        local current_aff
        current_aff=$(cat "/proc/irq/${irq_num}/smp_affinity_list" 2>/dev/null || echo "")
        if [[ -n "$current_aff" ]]; then
            echo "echo '$current_aff' > /proc/irq/${irq_num}/smp_affinity_list" >> "$irq_backup"
        fi
    done

    # D1: Default IRQ affinity (whatever irqbalance/OS set)
    run_fio_test "D1_irq_default" \
        "${common}" \
        "Default IRQ affinity (OS-managed)" \
        "$DEV_NUMA"

    # D2: All NVMe IRQs pinned to NUMA-local CPUs (spread)
    echo -e "\n  ${YELLOW}Setting NUMA-local IRQ affinity...${NC}"
    local cpu_idx=1
    local local_cpus_arr
    local_cpus_arr=($(python3 -c "
for part in '${DEV_CPUS}'.split(','):
    part = part.strip()
    if '-' in part:
        a,b = part.split('-')
        for c in range(int(a),int(b)+1): print(c)
    elif part: print(int(part))
" 2>/dev/null))

    grep "${NVME_CTRL}" /proc/interrupts 2>/dev/null | while read -r line; do
        local irq_num
        irq_num=$(echo "$line" | awk '{print $1}' | tr -d ':')
        if [[ $cpu_idx -lt ${#local_cpus_arr[@]} ]]; then
            echo "${local_cpus_arr[$cpu_idx]}" > "/proc/irq/${irq_num}/smp_affinity_list" 2>/dev/null || true
            cpu_idx=$((cpu_idx + 1))
        fi
    done

    run_fio_test "D2_irq_numa_local" \
        "${common}" \
        "All NVMe IRQs pinned to NUMA-local CPUs (spread 1:1)" \
        "$DEV_NUMA"

    # D3: All NVMe IRQs pinned to single CPU (worst case contention)
    echo -e "\n  ${YELLOW}Setting single-CPU IRQ affinity...${NC}"
    grep "${NVME_CTRL}" /proc/interrupts 2>/dev/null | while read -r line; do
        local irq_num
        irq_num=$(echo "$line" | awk '{print $1}' | tr -d ':')
        echo "$LOCAL_CPU" > "/proc/irq/${irq_num}/smp_affinity_list" 2>/dev/null || true
    done

    run_fio_test "D3_irq_single_cpu" \
        "${common}" \
        "All NVMe IRQs pinned to single CPU $LOCAL_CPU (contention)" \
        "$DEV_NUMA"

    # D4: All NVMe IRQs pinned to REMOTE NUMA (worst case NUMA)
    local num_numas
    num_numas=$(ls -d /sys/devices/system/node/node* 2>/dev/null | wc -l)
    if [[ $num_numas -gt 1 ]]; then
        echo -e "\n  ${YELLOW}Setting cross-NUMA IRQ affinity...${NC}"
        grep "${NVME_CTRL}" /proc/interrupts 2>/dev/null | while read -r line; do
            local irq_num
            irq_num=$(echo "$line" | awk '{print $1}' | tr -d ':')
            echo "$REMOTE_CPU" > "/proc/irq/${irq_num}/smp_affinity_list" 2>/dev/null || true
        done

        run_fio_test "D4_irq_cross_numa" \
            "${common}" \
            "All NVMe IRQs pinned to REMOTE NUMA $REMOTE_NUMA CPU $REMOTE_CPU" \
            "$DEV_NUMA"
    fi

    # Restore original IRQ affinities
    echo -e "\n  ${YELLOW}Restoring original IRQ affinities...${NC}"
    bash "$irq_backup" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST E: I/O Scheduler Effect
# ═══════════════════════════════════════════════════════════════════════════════
test_io_scheduler() {
    echo -e "\n${BOLD}${BLUE}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  TEST E: I/O Scheduler Effect${NC}"
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════════════════════════${NC}"

    local blk_dev
    blk_dev=$(basename "$DEVICE")
    local sched_path="/sys/block/${blk_dev}/queue/scheduler"
    local original_sched
    original_sched=$(cat "$sched_path" 2>/dev/null | grep -oP '\[\K[^\]]+' || echo "none")

    local common="--ioengine=io_uring --bs=${BS} --size=${SIZE} --iodepth=32 --rw=randread"

    # E1: none scheduler
    echo "none" > "$sched_path" 2>/dev/null || true
    run_fio_test "E1_sched_none" \
        "${common}" \
        "Scheduler=none, io_uring QD=32 random read" \
        "$DEV_NUMA"

    # E2: mq-deadline scheduler
    echo "mq-deadline" > "$sched_path" 2>/dev/null || true
    run_fio_test "E2_sched_mqdeadline" \
        "${common}" \
        "Scheduler=mq-deadline, io_uring QD=32 random read" \
        "$DEV_NUMA"

    # E3: kyber scheduler (if available)
    if echo "kyber" > "$sched_path" 2>/dev/null; then
        run_fio_test "E3_sched_kyber" \
            "${common}" \
            "Scheduler=kyber, io_uring QD=32 random read" \
            "$DEV_NUMA"
    fi

    # E4: none + rq_affinity comparison
    echo "none" > "$sched_path" 2>/dev/null || true
    local rq_aff_path="/sys/block/${blk_dev}/queue/rq_affinity"
    local orig_rq_aff
    orig_rq_aff=$(cat "$rq_aff_path" 2>/dev/null || echo "1")

    echo 0 > "$rq_aff_path" 2>/dev/null || true
    run_fio_test "E4_rqaff_0" \
        "${common}" \
        "rq_affinity=0 (complete on any CPU)" \
        "$DEV_NUMA"

    echo 1 > "$rq_aff_path" 2>/dev/null || true
    run_fio_test "E5_rqaff_1" \
        "${common}" \
        "rq_affinity=1 (complete on submitting CPU's group)" \
        "$DEV_NUMA"

    echo 2 > "$rq_aff_path" 2>/dev/null || true
    run_fio_test "E6_rqaff_2" \
        "${common}" \
        "rq_affinity=2 (strict: complete on submitting CPU)" \
        "$DEV_NUMA"

    # Restore
    echo "$original_sched" > "$sched_path" 2>/dev/null || true
    echo "$orig_rq_aff" > "$rq_aff_path" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST F: Polling Mode (hipri / io_poll)
# ═══════════════════════════════════════════════════════════════════════════════
test_polling_mode() {
    echo -e "\n${BOLD}${BLUE}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  TEST F: Polling Mode (Interrupt vs io_poll)${NC}"
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════════════════════════${NC}"

    local poll_queues
    poll_queues=$(cat /sys/module/nvme/parameters/poll_queues 2>/dev/null || echo "0")

    if [[ "$poll_queues" == "0" ]]; then
        echo -e "  ${YELLOW}NOTE: poll_queues=0. Polling tests may fall back to interrupt mode.${NC}"
        echo -e "  ${YELLOW}To enable: add 'options nvme poll_queues=4' to /etc/modprobe.d/nvme.conf${NC}"
    fi

    local common="--ioengine=io_uring --bs=${BS} --size=${SIZE} --rw=randread"

    # F1: Interrupt mode (default)
    run_fio_test "F1_interrupt_qd1" \
        "${common} --iodepth=1 --hipri=0" \
        "Interrupt mode, QD=1 (baseline latency)" \
        "$DEV_NUMA"

    # F2: Polling mode QD=1
    run_fio_test "F2_polling_qd1" \
        "${common} --iodepth=1 --hipri=1" \
        "Polling mode (hipri=1), QD=1 (lowest latency)" \
        "$DEV_NUMA"

    # F3: Interrupt mode QD=32
    run_fio_test "F3_interrupt_qd32" \
        "${common} --iodepth=32 --hipri=0" \
        "Interrupt mode, QD=32" \
        "$DEV_NUMA"

    # F4: Polling mode QD=32
    run_fio_test "F4_polling_qd32" \
        "${common} --iodepth=32 --hipri=1" \
        "Polling mode (hipri=1), QD=32" \
        "$DEV_NUMA"

    # F5: SQPOLL + Polling
    run_fio_test "F5_sqpoll_polling_qd32" \
        "${common} --iodepth=32 --hipri=1 --sqthread_poll=1" \
        "SQPOLL + Polling (hipri=1), QD=32 (maximum optimization)" \
        "$DEV_NUMA"

    # F6: psync baseline for comparison
    run_fio_test "F6_psync_baseline" \
        "--ioengine=psync --bs=${BS} --size=${SIZE} --rw=randread --iodepth=1" \
        "psync baseline (synchronous, QD=1)" \
        "$DEV_NUMA"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Results Summary & Comparison
# ═══════════════════════════════════════════════════════════════════════════════
generate_summary() {
    echo -e "\n${BOLD}${BLUE}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  RESULTS SUMMARY${NC}"
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════════════════════════${NC}\n"

    local summary_csv="$OUTPUT_DIR/results_summary.csv"
    echo "test_name,description,read_iops,read_bw_kb,read_lat_mean_us,read_lat_p99_us,write_iops,write_bw_kb,write_lat_mean_us,write_lat_p99_us" > "$summary_csv"

    printf "%-35s %10s %10s %12s %12s %10s %12s\n" \
        "Test" "R_IOPS" "W_IOPS" "R_Lat(avg)" "R_Lat(P99)" "R_BW(KB)" "W_BW(KB)"
    echo "──────────────────────────────────────────────────────────────────────────────────────────────────────────"

    for summary_file in "$OUTPUT_DIR"/summary/*.txt; do
        [[ -f "$summary_file" ]] || continue

        local tn desc ri rb rlm rlp wi wb wlm wlp
        tn=$(grep "^test_name=" "$summary_file" | cut -d= -f2)
        desc=$(grep "^description=" "$summary_file" | cut -d= -f2)
        ri=$(grep "^read_iops=" "$summary_file" | cut -d= -f2)
        rb=$(grep "^read_bw_kb=" "$summary_file" | cut -d= -f2)
        rlm=$(grep "^read_lat_mean_us=" "$summary_file" | cut -d= -f2)
        rlp=$(grep "^read_lat_p99_us=" "$summary_file" | cut -d= -f2)
        wi=$(grep "^write_iops=" "$summary_file" | cut -d= -f2)
        wb=$(grep "^write_bw_kb=" "$summary_file" | cut -d= -f2)
        wlm=$(grep "^write_lat_mean_us=" "$summary_file" | cut -d= -f2)
        wlp=$(grep "^write_lat_p99_us=" "$summary_file" | cut -d= -f2)

        printf "%-35s %10s %10s %12s %12s %10s %12s\n" \
            "$tn" "$ri" "$wi" "${rlm}us" "${rlp}us" "$rb" "$wb"

        echo "$tn,$desc,$ri,$rb,$rlm,$rlp,$wi,$wb,$wlm,$wlp" >> "$summary_csv"
    done

    echo ""
    echo -e "CSV saved: ${BOLD}${summary_csv}${NC}"

    # Generate comparison highlights
    echo -e "\n${BOLD}── Key Comparisons ──${NC}\n"

    python3 << 'PYEOF' "$summary_csv"
import csv, sys

data = {}
with open(sys.argv[1]) as f:
    reader = csv.DictReader(f)
    for row in reader:
        data[row['test_name']] = row

def compare(name, t1, t2, metric, unit=""):
    v1 = float(data.get(t1, {}).get(metric, 0))
    v2 = float(data.get(t2, {}).get(metric, 0))
    if v1 == 0 or v2 == 0:
        return
    diff_pct = ((v2 - v1) / v1) * 100
    better = "↑" if ("iops" in metric and diff_pct > 0) or ("lat" in metric and diff_pct < 0) else "↓"
    if "lat" in metric:
        better = "↑ better" if diff_pct < 0 else "↓ worse"
        diff_pct = -diff_pct  # Invert for latency (lower is better)
    else:
        better = "↑ better" if diff_pct > 0 else "↓ worse"
    print(f"  {name}:")
    print(f"    {t1}: {v1:.0f}{unit}")
    print(f"    {t2}: {v2:.0f}{unit}")
    print(f"    Delta: {diff_pct:+.1f}% ({better})")
    print()

# Engine comparison
compare("libaio vs io_uring (IOPS)",
        "A1_libaio_randread", "A2_iouring_randread", "read_iops")
compare("io_uring vs io_uring+SQPOLL (IOPS)",
        "A2_iouring_randread", "A3_iouring_sqpoll_randread", "read_iops")
compare("io_uring vs Full Optimization (IOPS)",
        "A2_iouring_randread", "A5_iouring_fullopt_randread", "read_iops")

# NUMA comparison
compare("NUMA Local vs Remote Read (IOPS)",
        "B1_numa_local_randread", "B2_numa_remote_randread", "read_iops")
compare("NUMA Local vs Remote Read (Latency)",
        "B1_numa_local_randread", "B2_numa_remote_randread", "read_lat_mean_us", "us")

# IRQ comparison
compare("Default IRQ vs NUMA-local IRQ (IOPS)",
        "D1_irq_default", "D2_irq_numa_local", "read_iops")
compare("NUMA-local IRQ vs Cross-NUMA IRQ (IOPS)",
        "D2_irq_numa_local", "D4_irq_cross_numa", "read_iops")

# Scheduler comparison
compare("none vs mq-deadline Scheduler (IOPS)",
        "E1_sched_none", "E2_sched_mqdeadline", "read_iops")
compare("rq_affinity=0 vs 2 (IOPS)",
        "E4_rqaff_0", "E6_rqaff_2", "read_iops")

# Polling comparison
compare("Interrupt vs Polling QD=1 (Latency)",
        "F1_interrupt_qd1", "F2_polling_qd1", "read_lat_mean_us", "us")
compare("Interrupt vs Polling QD=32 (IOPS)",
        "F3_interrupt_qd32", "F4_polling_qd32", "read_iops")

PYEOF

    echo -e "\n${GREEN}All results saved to: ${OUTPUT_DIR}/${NC}"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    echo -e "${BOLD}${BLUE}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║   NVMe I/O Stack Benchmark Suite                                ║"
    echo "║   Quantitative Comparison of I/O Path Optimizations             ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    echo "Device:  $DEVICE"
    echo "Output:  $OUTPUT_DIR"
    echo "Runtime: ${RUNTIME}s per test"
    echo "Tests:   $TESTS"
    echo ""

    collect_system_info

    local run_all=false
    [[ "$TESTS" == "all" ]] && run_all=true

    if [[ "$run_all" == "true" ]] || echo "$TESTS" | grep -q "engine"; then
        test_io_engines
    fi

    if [[ "$run_all" == "true" ]] || echo "$TESTS" | grep -q "numa"; then
        test_numa_affinity
    fi

    if [[ "$run_all" == "true" ]] || echo "$TESTS" | grep -q "qd"; then
        test_queue_depth
    fi

    if [[ "$run_all" == "true" ]] || echo "$TESTS" | grep -q "irq"; then
        test_irq_affinity
    fi

    if [[ "$run_all" == "true" ]] || echo "$TESTS" | grep -q "sched"; then
        test_io_scheduler
    fi

    if [[ "$run_all" == "true" ]] || echo "$TESTS" | grep -q "poll"; then
        test_polling_mode
    fi

    generate_summary

    echo -e "\n${BOLD}${GREEN}Benchmark suite complete!${NC}"
    echo -e "Run eBPF analysis (05_ebpf_analysis.sh) alongside for detailed tracing.\n"
}

main "$@"

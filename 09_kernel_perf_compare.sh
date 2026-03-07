#!/bin/bash
###############################################################################
# NVMe Kernel Version Performance Comparator
#
# Ubuntu LTS 기본 커널과 업데이트된 커널 간 NVMe SSD 성능을 비교합니다.
# 동일 시스템에서 커널만 변경했을 때의 성능 차이를 정량적으로 측정합니다.
#
# 사용법:
#   # 1단계: 현재 커널에서 벤치마크 실행
#   sudo bash 09_kernel_perf_compare.sh --run --dev /dev/nvme0n1 [--tag "6.8.0-ga"]
#
#   # 2단계: 커널 변경 후 같은 명령으로 다시 실행
#   sudo bash 09_kernel_perf_compare.sh --run --dev /dev/nvme0n1 [--tag "6.11.0-hwe"]
#
#   # 3단계: 결과 비교
#   sudo bash 09_kernel_perf_compare.sh --compare --baseline results/6.8.0-ga \
#                                        --target results/6.11.0-hwe
#
# 옵션:
#   --run                  벤치마크 실행
#   --compare              두 결과 비교
#   --dev <device>         NVMe 블록 디바이스 (e.g., /dev/nvme0n1)
#   --tag <label>          결과 식별 태그 (default: kernel version)
#   --baseline <dir>       비교 기준 결과 디렉토리
#   --target <dir>         비교 대상 결과 디렉토리
#   --quick                빠른 테스트 (런타임 감소, 정확도 ↓)
#   --outdir <dir>         결과 출력 디렉토리 (default: ./results)
#
# 요구사항: root 권한, fio, NVMe SSD
###############################################################################

set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'
SEPARATOR="════════════════════════════════════════════════════════════════════════"

# ─── Defaults ─────────────────────────────────────────────────────────────────
MODE=""
DEVICE=""
TAG=""
BASELINE_DIR=""
TARGET_DIR=""
QUICK=false
OUTDIR="./results"

# fio parameters
RUNTIME=30          # seconds per test
RAMP=5              # ramp-up seconds
LOOPS=3             # repeat count for averaging
BS_LIST="4k 8k 128k 1m"
QD_LIST="1 4 16 64 128"

# ─── Parse Options ────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        --run)       MODE="run"; shift ;;
        --compare)   MODE="compare"; shift ;;
        --dev)       DEVICE="$2"; shift 2 ;;
        --tag)       TAG="$2"; shift 2 ;;
        --baseline)  BASELINE_DIR="$2"; shift 2 ;;
        --target)    TARGET_DIR="$2"; shift 2 ;;
        --quick)     QUICK=true; shift ;;
        --outdir)    OUTDIR="$2"; shift 2 ;;
        -h|--help)
            head -30 "$0" | grep "^#" | sed 's/^#//'
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ─── Helpers ──────────────────────────────────────────────────────────────────
print_header() {
    echo -e "\n${BOLD}${BLUE}${SEPARATOR}${NC}"
    echo -e "${BOLD}${BLUE}  $1${NC}"
    echo -e "${BOLD}${BLUE}${SEPARATOR}${NC}\n"
}

print_info() {
    echo -e "  ${BOLD}$1${NC}: $2"
}

die() {
    echo -e "${RED}ERROR: $1${NC}" >&2
    exit 1
}

check_deps() {
    [[ $EUID -eq 0 ]] || die "Root required. Run with sudo."
    command -v fio &>/dev/null || die "fio not found. Install: apt install fio"
    command -v jq &>/dev/null || die "jq not found. Install: apt install jq"
}

# ─── System Fingerprint ──────────────────────────────────────────────────────
collect_system_info() {
    local outdir="$1"
    local info_file="${outdir}/system_info.txt"

    {
        echo "=== System Fingerprint ==="
        echo "Date:            $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "Hostname:        $(hostname)"
        echo ""

        echo "=== OS ==="
        echo "OS:              $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)"
        echo "OS Version:      $(grep VERSION_ID /etc/os-release 2>/dev/null | cut -d'"' -f2)"
        echo "Codename:        $(grep VERSION_CODENAME /etc/os-release 2>/dev/null | cut -d'=' -f2)"
        echo ""

        echo "=== Kernel ==="
        echo "Kernel Version:  $(uname -r)"
        echo "Kernel Build:    $(uname -v)"
        if uname -r | grep -q "\-hwe"; then
            echo "Kernel Type:     HWE (Hardware Enablement)"
        else
            echo "Kernel Type:     GA (General Availability)"
        fi
        echo ""

        echo "=== Ubuntu Kernel Package ==="
        dpkg -l 2>/dev/null | grep -E "linux-image-$(uname -r)" | head -5 || echo "N/A"
        echo ""
        echo "Available kernels:"
        dpkg -l 2>/dev/null | grep "linux-image-[0-9]" | awk '{print $2, $3}' || echo "N/A"
        echo ""

        echo "=== CPU ==="
        echo "Model:           $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
        echo "Sockets:         $(grep 'physical id' /proc/cpuinfo | sort -u | wc -l)"
        echo "Cores/Socket:    $(grep 'cpu cores' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
        echo "Total CPUs:      $(nproc)"
        echo "Governor:        $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo 'N/A')"
        echo ""

        echo "=== Memory ==="
        free -h | head -2
        echo ""

        echo "=== NVMe Device: ${DEVICE} ==="
        local ctrl
        ctrl=$(echo "$DEVICE" | sed 's|/dev/||; s|n[0-9]*$||')
        echo "Model:           $(cat /sys/class/nvme/${ctrl}/model 2>/dev/null | xargs)"
        echo "Serial:          $(cat /sys/class/nvme/${ctrl}/serial 2>/dev/null | xargs)"
        echo "Firmware:        $(cat /sys/class/nvme/${ctrl}/firmware_rev 2>/dev/null | xargs)"
        echo "Queue Count:     $(cat /sys/class/nvme/${ctrl}/queue_count 2>/dev/null)"
        echo "NUMA Node:       $(cat /sys/class/nvme/${ctrl}/device/numa_node 2>/dev/null)"
        if command -v nvme &>/dev/null; then
            echo ""
            echo "nvme id-ctrl (key fields):"
            nvme id-ctrl "/dev/${ctrl}" 2>/dev/null | grep -E "^vid |^ssvid |^mn |^sn |^fr |^nn |^tnvmcap " || true
        fi
        echo ""

        # PCIe link info
        local bdf
        bdf=$(readlink -f "/sys/class/nvme/${ctrl}/device" 2>/dev/null | xargs basename 2>/dev/null)
        if [[ -n "$bdf" ]]; then
            echo "PCIe BDF:        $bdf"
            lspci -vvv -s "$bdf" 2>/dev/null | grep -E "LnkSta:|LnkCap:|DevCtl:" | while read -r line; do
                echo "  $line"
            done
        fi
        echo ""

        echo "=== Block Device Settings ==="
        local blkdev
        blkdev=$(basename "$DEVICE")
        echo "Scheduler:       $(cat /sys/class/block/${blkdev}/queue/scheduler 2>/dev/null)"
        echo "nr_requests:     $(cat /sys/class/block/${blkdev}/queue/nr_requests 2>/dev/null)"
        echo "read_ahead_kb:   $(cat /sys/class/block/${blkdev}/queue/read_ahead_kb 2>/dev/null)"
        echo "rq_affinity:     $(cat /sys/class/block/${blkdev}/queue/rq_affinity 2>/dev/null)"
        echo "io_poll:         $(cat /sys/class/block/${blkdev}/queue/io_poll 2>/dev/null)"
        echo "max_sectors_kb:  $(cat /sys/class/block/${blkdev}/queue/max_sectors_kb 2>/dev/null)"
        echo "nomerges:        $(cat /sys/class/block/${blkdev}/queue/nomerges 2>/dev/null)"
        echo "write_cache:     $(cat /sys/class/block/${blkdev}/queue/write_cache 2>/dev/null)"
        echo ""

        echo "=== NVMe Module Parameters ==="
        if [[ -d /sys/module/nvme/parameters ]]; then
            for p in /sys/module/nvme/parameters/*; do
                printf "%-25s = %s\n" "$(basename $p)" "$(cat $p 2>/dev/null)"
            done
        fi
        echo ""

        echo "=== Kernel Key Parameters ==="
        for p in kernel.numa_balancing vm.nr_hugepages vm.swappiness vm.dirty_ratio vm.dirty_background_ratio; do
            printf "%-35s = %s\n" "$p" "$(sysctl -n $p 2>/dev/null || echo N/A)"
        done
        echo ""

        echo "=== Kernel Boot Parameters ==="
        cat /proc/cmdline 2>/dev/null
        echo ""

        echo "=== I/O Stack ==="
        echo "fio version:     $(fio --version 2>/dev/null)"
        echo "io_uring:        $(fio --enghelp 2>/dev/null | grep -c io_uring || echo 0) engines"
        echo "libaio:          $(fio --enghelp 2>/dev/null | grep -c libaio || echo 0) engines"

    } > "$info_file" 2>&1

    echo "  System info saved: ${info_file}"
}

# ─── FIO Runner ───────────────────────────────────────────────────────────────
run_fio_test() {
    local name="$1" engine="$2" rw="$3" bs="$4" qd="$5" outfile="$6"
    local extra_opts="${7:-}"

    local runtime_val=$RUNTIME
    local ramp_val=$RAMP
    if $QUICK; then
        runtime_val=10
        ramp_val=2
    fi

    local fio_cmd=(
        fio
        --name="$name"
        --filename="$DEVICE"
        --ioengine="$engine"
        --direct=1
        --rw="$rw"
        --bs="$bs"
        --iodepth="$qd"
        --numjobs=1
        --time_based
        --runtime="${runtime_val}"
        --ramp_time="${ramp_val}"
        --group_reporting
        --output-format=json
        --output="$outfile"
    )

    # Engine-specific options
    case "$engine" in
        io_uring)
            fio_cmd+=(--fixedbufs=1 --registerfiles=1)
            ;;
        io_uring_sqpoll)
            # Use io_uring with sqthread_poll
            fio_cmd=("${fio_cmd[@]/--ioengine=io_uring_sqpoll/--ioengine=io_uring}")
            fio_cmd+=(--fixedbufs=1 --registerfiles=1 --sqthread_poll=1)
            ;;
    esac

    # Add any extra options
    if [[ -n "$extra_opts" ]]; then
        for opt in $extra_opts; do
            fio_cmd+=("$opt")
        done
    fi

    "${fio_cmd[@]}" 2>/dev/null
}

# Extract metrics from fio JSON output
extract_metrics() {
    local json_file="$1" rw_type="$2"

    if [[ ! -f "$json_file" ]]; then
        echo "0 0 0 0 0"
        return
    fi

    local read_or_write
    case "$rw_type" in
        *read*|*rand*r*) read_or_write="read" ;;
        *write*|*rand*w*) read_or_write="write" ;;
        *) read_or_write="read" ;;
    esac

    # Extract: iops, bw_bytes, lat_ns_mean, lat_ns_p99, lat_ns_p999
    local iops bw_bytes lat_mean lat_p99 lat_p999
    iops=$(jq -r ".jobs[0].${read_or_write}.iops // 0" "$json_file" 2>/dev/null || echo "0")
    bw_bytes=$(jq -r ".jobs[0].${read_or_write}.bw_bytes // 0" "$json_file" 2>/dev/null || echo "0")
    lat_mean=$(jq -r ".jobs[0].${read_or_write}.clat_ns.mean // 0" "$json_file" 2>/dev/null || echo "0")
    lat_p99=$(jq -r '.jobs[0].'"${read_or_write}"'.clat_ns.percentile["99.000000"] // 0' "$json_file" 2>/dev/null || echo "0")
    lat_p999=$(jq -r '.jobs[0].'"${read_or_write}"'.clat_ns.percentile["99.900000"] // 0' "$json_file" 2>/dev/null || echo "0")

    echo "$iops $bw_bytes $lat_mean $lat_p99 $lat_p999"
}

# ─── Benchmark Suite ──────────────────────────────────────────────────────────
run_benchmarks() {
    local result_dir="$1"

    local total_tests=0
    local current_test=0

    # Count total tests
    for engine in libaio io_uring; do
        for bs in $BS_LIST; do
            for rw in randread randwrite read write; do
                for qd in $QD_LIST; do
                    total_tests=$((total_tests + 1))
                done
            done
        done
    done

    echo "  Total tests to run: $total_tests"
    echo ""

    # ── Test A: Engine Comparison (libaio vs io_uring) ──
    print_header "Test A: I/O Engine Comparison"

    for engine in libaio io_uring; do
        local eng_dir="${result_dir}/engine_${engine}"
        mkdir -p "$eng_dir"

        for rw in randread randwrite read write; do
            for bs in $BS_LIST; do
                for qd in $QD_LIST; do
                    current_test=$((current_test + 1))
                    local test_name="${engine}_${rw}_${bs}_qd${qd}"
                    local outfile="${eng_dir}/${test_name}.json"

                    printf "  [%3d/%d] %-50s " "$current_test" "$total_tests" "$test_name"

                    run_fio_test "$test_name" "$engine" "$rw" "$bs" "$qd" "$outfile"

                    # Quick result
                    local metrics
                    metrics=$(extract_metrics "$outfile" "$rw")
                    local iops bw lat_mean
                    iops=$(echo "$metrics" | awk '{printf "%.0f", $1}')
                    bw=$(echo "$metrics" | awk '{printf "%.1f", $2/1048576}')
                    lat_mean=$(echo "$metrics" | awk '{printf "%.1f", $3/1000}')
                    echo -e "${GREEN}IOPS=${iops} BW=${bw}MB/s Lat=${lat_mean}us${NC}"
                done
            done
        done
    done

    # ── Test B: io_uring Advanced Features ──
    print_header "Test B: io_uring Advanced Features"

    local adv_dir="${result_dir}/engine_io_uring_advanced"
    mkdir -p "$adv_dir"

    for rw in randread randwrite; do
        for qd in 1 16 64; do
            # io_uring with SQPOLL
            local test_name="uring_sqpoll_${rw}_4k_qd${qd}"
            local outfile="${adv_dir}/${test_name}.json"
            printf "  %-50s " "$test_name"
            run_fio_test "$test_name" "io_uring" "$rw" "4k" "$qd" "$outfile" "--sqthread_poll=1 --fixedbufs=1 --registerfiles=1"
            local metrics
            metrics=$(extract_metrics "$outfile" "$rw")
            local iops lat_mean
            iops=$(echo "$metrics" | awk '{printf "%.0f", $1}')
            lat_mean=$(echo "$metrics" | awk '{printf "%.1f", $3/1000}')
            echo -e "${GREEN}IOPS=${iops} Lat=${lat_mean}us${NC}"

            # io_uring with hipri (polling)
            test_name="uring_hipri_${rw}_4k_qd${qd}"
            outfile="${adv_dir}/${test_name}.json"
            printf "  %-50s " "$test_name"
            run_fio_test "$test_name" "io_uring" "$rw" "4k" "$qd" "$outfile" "--hipri=1 --fixedbufs=1 --registerfiles=1"
            metrics=$(extract_metrics "$outfile" "$rw")
            iops=$(echo "$metrics" | awk '{printf "%.0f", $1}')
            lat_mean=$(echo "$metrics" | awk '{printf "%.1f", $3/1000}')
            echo -e "${GREEN}IOPS=${iops} Lat=${lat_mean}us${NC}"
        done
    done

    # ── Generate CSV Summary ──
    generate_csv "$result_dir"
}

# ─── CSV Summary Generator ───────────────────────────────────────────────────
generate_csv() {
    local result_dir="$1"
    local csv_file="${result_dir}/summary.csv"

    echo "kernel,engine,rw,bs,qd,iops,bw_MBs,lat_avg_us,lat_p99_us,lat_p999_us" > "$csv_file"

    local kernel_ver
    kernel_ver=$(uname -r)

    for json_file in $(find "$result_dir" -name "*.json" -type f | sort); do
        local fname
        fname=$(basename "$json_file" .json)
        local dir_name
        dir_name=$(basename "$(dirname "$json_file")")

        # Parse engine from directory name
        local engine
        engine=$(echo "$dir_name" | sed 's/engine_//')

        # Parse rw, bs, qd from filename
        local rw bs qd
        # Patterns: libaio_randread_4k_qd1, uring_sqpoll_randread_4k_qd1
        rw=$(echo "$fname" | grep -oP '(randread|randwrite|read|write)' | head -1)
        bs=$(echo "$fname" | grep -oP '\d+[km]' | head -1)
        qd=$(echo "$fname" | grep -oP 'qd\K\d+')

        if [[ -z "$rw" || -z "$bs" || -z "$qd" ]]; then
            continue
        fi

        local metrics
        metrics=$(extract_metrics "$json_file" "$rw")
        local iops bw_mb lat_avg lat_p99 lat_p999
        iops=$(echo "$metrics" | awk '{printf "%.0f", $1}')
        bw_mb=$(echo "$metrics" | awk '{printf "%.2f", $2/1048576}')
        lat_avg=$(echo "$metrics" | awk '{printf "%.2f", $3/1000}')
        lat_p99=$(echo "$metrics" | awk '{printf "%.2f", $4/1000}')
        lat_p999=$(echo "$metrics" | awk '{printf "%.2f", $5/1000}')

        echo "${kernel_ver},${engine},${rw},${bs},${qd},${iops},${bw_mb},${lat_avg},${lat_p99},${lat_p999}" >> "$csv_file"
    done

    echo "  CSV summary: ${csv_file}"
}

# ─── Compare Results ──────────────────────────────────────────────────────────
compare_results() {
    [[ -d "$BASELINE_DIR" ]] || die "Baseline directory not found: $BASELINE_DIR"
    [[ -d "$TARGET_DIR" ]] || die "Target directory not found: $TARGET_DIR"

    local base_csv="${BASELINE_DIR}/summary.csv"
    local target_csv="${TARGET_DIR}/summary.csv"
    [[ -f "$base_csv" ]] || die "Baseline CSV not found: $base_csv"
    [[ -f "$target_csv" ]] || die "Target CSV not found: $target_csv"

    local base_info="${BASELINE_DIR}/system_info.txt"
    local target_info="${TARGET_DIR}/system_info.txt"

    print_header "KERNEL PERFORMANCE COMPARISON"

    # Show kernel versions
    local base_kernel target_kernel
    base_kernel=$(head -1 "$base_csv" > /dev/null; sed -n '2p' "$base_csv" | cut -d',' -f1)
    target_kernel=$(head -1 "$target_csv" > /dev/null; sed -n '2p' "$target_csv" | cut -d',' -f1)

    echo -e "  ${BOLD}Baseline Kernel:${NC} ${CYAN}${base_kernel}${NC}"
    echo -e "  ${BOLD}Target Kernel:${NC}   ${CYAN}${target_kernel}${NC}"
    echo ""

    # Show key system info differences
    if [[ -f "$base_info" && -f "$target_info" ]]; then
        echo -e "  ${BOLD}System Info Differences:${NC}"
        diff --suppress-common-lines <(grep -E "^(Kernel|OS |Governor|Scheduler|fio)" "$base_info" 2>/dev/null) \
             <(grep -E "^(Kernel|OS |Governor|Scheduler|fio)" "$target_info" 2>/dev/null) 2>/dev/null | head -20 | while read -r line; do
            echo "    $line"
        done
        echo ""
    fi

    # ── Comparison Table ──
    print_header "IOPS Comparison (key tests)"

    printf "  ${BOLD}%-12s %-10s %-6s %-5s │ %12s %12s │ %8s │ %s${NC}\n" \
        "Engine" "I/O Type" "BS" "QD" "Baseline" "Target" "Δ%" "Verdict"
    echo "  ──────────────────────────────────────────────────────────────────────────────────────"

    # Read baseline into associative-like structure (using temp file for portability)
    local tmp_base="/tmp/kperf_base_$$"
    local tmp_target="/tmp/kperf_target_$$"
    tail -n +2 "$base_csv" | sort > "$tmp_base"
    tail -n +2 "$target_csv" | sort > "$tmp_target"

    # Key test cases to compare
    local key_tests=(
        "libaio,randread,4k,1"
        "libaio,randread,4k,16"
        "libaio,randread,4k,64"
        "libaio,randread,4k,128"
        "libaio,randwrite,4k,1"
        "libaio,randwrite,4k,64"
        "io_uring,randread,4k,1"
        "io_uring,randread,4k,16"
        "io_uring,randread,4k,64"
        "io_uring,randread,4k,128"
        "io_uring,randwrite,4k,1"
        "io_uring,randwrite,4k,64"
        "libaio,read,128k,64"
        "libaio,write,128k,64"
        "io_uring,read,128k,64"
        "io_uring,write,128k,64"
        "libaio,read,1m,64"
        "libaio,write,1m,64"
        "io_uring,read,1m,64"
        "io_uring,write,1m,64"
    )

    local improvements=0
    local regressions=0
    local neutral=0

    for key in "${key_tests[@]}"; do
        local engine rw bs qd
        IFS=',' read -r engine rw bs qd <<< "$key"

        # Find matching rows
        local base_row target_row
        base_row=$(grep "^[^,]*,${engine},${rw},${bs},${qd}," "$tmp_base" 2>/dev/null | head -1)
        target_row=$(grep "^[^,]*,${engine},${rw},${bs},${qd}," "$tmp_target" 2>/dev/null | head -1)

        if [[ -z "$base_row" || -z "$target_row" ]]; then
            continue
        fi

        local base_iops target_iops
        base_iops=$(echo "$base_row" | cut -d',' -f6)
        target_iops=$(echo "$target_row" | cut -d',' -f6)

        if [[ "$base_iops" -eq 0 ]]; then
            continue
        fi

        local delta_pct
        delta_pct=$(awk "BEGIN {printf \"%.1f\", (($target_iops - $base_iops) / $base_iops) * 100}")

        local verdict color
        if (( $(awk "BEGIN {print ($delta_pct > 3) ? 1 : 0}") )); then
            verdict="IMPROVED"
            color="$GREEN"
            improvements=$((improvements + 1))
        elif (( $(awk "BEGIN {print ($delta_pct < -3) ? 1 : 0}") )); then
            verdict="REGRESSED"
            color="$RED"
            regressions=$((regressions + 1))
        else
            verdict="NEUTRAL"
            color="$NC"
            neutral=$((neutral + 1))
        fi

        printf "  %-12s %-10s %-6s %-5s │ %12s %12s │ " "$engine" "$rw" "$bs" "$qd" "$base_iops" "$target_iops"
        echo -e "${color}%6s%%${NC} │ ${color}${verdict}${NC}" | awk -v d="$delta_pct" '{gsub(/%6s/, d); print}'
        printf "${color}  %-12s %-10s %-6s %-5s │ %12s %12s │ %+7.1f%% │ %s${NC}\n" \
            "$engine" "$rw" "$bs" "$qd" "$base_iops" "$target_iops" "$delta_pct" "$verdict"
    done

    # ── Latency Comparison ──
    echo ""
    print_header "Latency Comparison (4K Random Read, avg μs)"

    printf "  ${BOLD}%-12s %-5s │ %10s %10s │ %8s │ %s${NC}\n" \
        "Engine" "QD" "Base Lat" "Target Lat" "Δ%" "Verdict"
    echo "  ────────────────────────────────────────────────────────────────────"

    for engine in libaio io_uring; do
        for qd in 1 16 64 128; do
            local base_row target_row
            base_row=$(grep "^[^,]*,${engine},randread,4k,${qd}," "$tmp_base" 2>/dev/null | head -1)
            target_row=$(grep "^[^,]*,${engine},randread,4k,${qd}," "$tmp_target" 2>/dev/null | head -1)

            if [[ -z "$base_row" || -z "$target_row" ]]; then continue; fi

            local base_lat target_lat
            base_lat=$(echo "$base_row" | cut -d',' -f8)
            target_lat=$(echo "$target_row" | cut -d',' -f8)

            local delta_pct
            delta_pct=$(awk "BEGIN {
                if ($base_lat == 0) { print \"N/A\"; exit }
                printf \"%.1f\", (($target_lat - $base_lat) / $base_lat) * 100
            }")

            # For latency, negative delta = improvement (lower is better)
            local verdict color
            if (( $(awk "BEGIN {print ($delta_pct < -3) ? 1 : 0}") )); then
                verdict="IMPROVED"
                color="$GREEN"
            elif (( $(awk "BEGIN {print ($delta_pct > 3) ? 1 : 0}") )); then
                verdict="REGRESSED"
                color="$RED"
            else
                verdict="NEUTRAL"
                color="$NC"
            fi

            printf "${color}  %-12s %-5s │ %10s %10s │ %+7.1f%% │ %s${NC}\n" \
                "$engine" "$qd" "${base_lat}μs" "${target_lat}μs" "$delta_pct" "$verdict"
        done
    done

    # ── P99 Latency Comparison ──
    echo ""
    print_header "P99 Tail Latency Comparison (4K Random Read, μs)"

    printf "  ${BOLD}%-12s %-5s │ %10s %10s │ %8s │ %s${NC}\n" \
        "Engine" "QD" "Base P99" "Target P99" "Δ%" "Verdict"
    echo "  ────────────────────────────────────────────────────────────────────"

    for engine in libaio io_uring; do
        for qd in 1 16 64 128; do
            local base_row target_row
            base_row=$(grep "^[^,]*,${engine},randread,4k,${qd}," "$tmp_base" 2>/dev/null | head -1)
            target_row=$(grep "^[^,]*,${engine},randread,4k,${qd}," "$tmp_target" 2>/dev/null | head -1)

            if [[ -z "$base_row" || -z "$target_row" ]]; then continue; fi

            local base_p99 target_p99
            base_p99=$(echo "$base_row" | cut -d',' -f9)
            target_p99=$(echo "$target_row" | cut -d',' -f9)

            local delta_pct
            delta_pct=$(awk "BEGIN {
                if ($base_p99 == 0) { print \"0.0\"; exit }
                printf \"%.1f\", (($target_p99 - $base_p99) / $base_p99) * 100
            }")

            local verdict color
            if (( $(awk "BEGIN {print ($delta_pct < -3) ? 1 : 0}") )); then
                verdict="IMPROVED"; color="$GREEN"
            elif (( $(awk "BEGIN {print ($delta_pct > 3) ? 1 : 0}") )); then
                verdict="REGRESSED"; color="$RED"
            else
                verdict="NEUTRAL"; color="$NC"
            fi

            printf "${color}  %-12s %-5s │ %10s %10s │ %+7.1f%% │ %s${NC}\n" \
                "$engine" "$qd" "${base_p99}μs" "${target_p99}μs" "$delta_pct" "$verdict"
        done
    done

    # ── Summary ──
    echo ""
    print_header "COMPARISON SUMMARY"
    echo -e "  Baseline: ${CYAN}${base_kernel}${NC}"
    echo -e "  Target:   ${CYAN}${target_kernel}${NC}"
    echo ""
    echo -e "  Results:  ${GREEN}${improvements} improved${NC}, ${RED}${regressions} regressed${NC}, ${neutral} neutral"
    echo ""

    if [[ $regressions -gt 0 ]]; then
        echo -e "  ${RED}${BOLD}⚠ WARNING: ${regressions} performance regressions detected!${NC}"
        echo -e "  ${RED}  Consider staying on ${base_kernel} for NVMe-intensive workloads,${NC}"
        echo -e "  ${RED}  or investigate kernel changes that may have caused regressions.${NC}"
    elif [[ $improvements -gt 0 ]]; then
        echo -e "  ${GREEN}${BOLD}✓ Kernel ${target_kernel} shows ${improvements} improvements.${NC}"
        echo -e "  ${GREEN}  Upgrade recommended for NVMe workloads.${NC}"
    else
        echo -e "  ${BOLD}No significant performance difference between kernels.${NC}"
    fi
    echo ""

    # Cleanup
    rm -f "$tmp_base" "$tmp_target"

    # Generate comparison CSV
    local comp_csv="${OUTDIR}/comparison_${base_kernel}_vs_${target_kernel}.csv"
    echo "engine,rw,bs,qd,base_iops,target_iops,delta_pct,base_lat_us,target_lat_us,lat_delta_pct" > "$comp_csv"
    echo "  Comparison CSV: ${comp_csv}"
}

# ─── Ubuntu LTS Kernel Info ──────────────────────────────────────────────────
show_ubuntu_kernel_info() {
    print_header "UBUNTU LTS KERNEL VERSION REFERENCE"

    cat << 'KERNEL_TABLE'
  ┌────────────────────────────────────────────────────────────────────────────┐
  │ Ubuntu LTS    │ GA Kernel  │ HWE Kernels        │ Key I/O Changes        │
  ├───────────────┼────────────┼────────────────────┼────────────────────────┤
  │ 20.04 (Focal) │ 5.4        │ 5.8, 5.11, 5.13   │ io_uring early stage   │
  │               │            │ 5.15               │ basic async I/O        │
  │               │            │                    │                        │
  │ 22.04 (Jammy) │ 5.15       │ 5.19, 6.2, 6.5    │ io_uring mature        │
  │               │            │ 6.8                │ blk-mq improvements   │
  │               │            │                    │ NVMe multipath fixes   │
  │               │            │                    │                        │
  │ 24.04 (Noble) │ 6.8        │ 6.11, 6.12+        │ io_uring passthrough   │
  │               │            │                    │ NVMe enhancements      │
  │               │            │                    │ blk-mq scheduler opt   │
  │               │            │                    │ PCIe/CXL improvements  │
  └────────────────────────────────────────────────────────────────────────────┘

  Key Kernel Changes Affecting NVMe Performance:
  ──────────────────────────────────────────────
  5.4  → 5.15:  io_uring SQPOLL stabilization, NVMe poll queue support
  5.15 → 6.2:   blk-mq tag set scaling, io_uring zerocopy networking
  6.2  → 6.5:   NVMe multipath optimization, block layer lock reduction
  6.5  → 6.8:   io_uring passthrough (NVMe char dev), blk-mq improvement
  6.8  → 6.11:  NVMe rotational quirk fix, io_uring registered buffers opt
  6.11 → 6.12+: PCIe 6.0 prep, CXL region improvements, NVMe 2.1 features

  ┌──────────────────────────────────────────────────────────────────────┐
  │ 커널 변경 시 주의사항:                                              │
  │                                                                     │
  │ 1. NVMe module parameters가 커널 버전에 따라 다를 수 있음          │
  │    (poll_queues, write_queues 등의 기본값 변경)                    │
  │                                                                     │
  │ 2. I/O scheduler 기본값이 변경될 수 있음                          │
  │    (none vs mq-deadline, 커널/배포판에 따라 다름)                  │
  │                                                                     │
  │ 3. blk-mq 내부 구현 변경으로 특정 QD에서 성능 변동 가능           │
  │                                                                     │
  │ 4. io_uring 버전이 커널에 포함되어 있어 커널 업그레이드 =         │
  │    io_uring 업그레이드 (별도 설치 불가)                            │
  │                                                                     │
  │ 5. IOMMU/DMAR 기본 동작이 변경될 수 있음 (P2P DMA 영향)          │
  └──────────────────────────────────────────────────────────────────────┘
KERNEL_TABLE
}

# ─── Kernel Switch Guide ─────────────────────────────────────────────────────
show_kernel_switch_guide() {
    print_header "UBUNTU KERNEL SWITCH GUIDE"

    cat << 'GUIDE'

  ── Step 1: 현재 커널 확인 ──

    uname -r                           # 현재 실행 중인 커널
    dpkg -l | grep linux-image         # 설치된 커널 목록
    ls /boot/vmlinuz-*                 # 부트 가능한 커널

  ── Step 2: 다른 커널 설치 ──

    # GA 커널 (기본)
    sudo apt install linux-image-generic

    # HWE 커널 (Hardware Enablement - 더 새로운 버전)
    sudo apt install linux-image-generic-hwe-24.04    # Ubuntu 24.04 LTS

    # 특정 버전 설치
    apt search linux-image-6.8 | grep generic         # 사용 가능한 6.8.x 목록
    sudo apt install linux-image-6.8.0-45-generic     # 특정 버전

    # Mainline 커널 (kernel.ubuntu.com)
    # 주의: Ubuntu 공식 지원 아님, 테스트 목적으로만
    wget https://kernel.ubuntu.com/mainline/v6.12/amd64/linux-image-unsigned-6.12.0-*.deb
    sudo dpkg -i linux-image-unsigned-6.12.0-*.deb

  ── Step 3: 부트 커널 선택 ──

    # GRUB 메뉴에서 선택 (재부팅 시)
    # /etc/default/grub 에서:
    GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux 6.8.0-45-generic"
    sudo update-grub
    sudo reboot

    # 또는 grub-reboot으로 1회성 변경
    sudo grub-reboot "Advanced options for Ubuntu>Ubuntu, with Linux 5.15.0-91-generic"
    sudo reboot

  ── Step 4: 벤치마크 실행 후 비교 ──

    # 커널 A에서:
    sudo bash 09_kernel_perf_compare.sh --run --dev /dev/nvme0n1 --tag "6.8.0-ga"

    # 재부팅 후 커널 B에서:
    sudo bash 09_kernel_perf_compare.sh --run --dev /dev/nvme0n1 --tag "6.11.0-hwe"

    # 결과 비교:
    sudo bash 09_kernel_perf_compare.sh --compare \
        --baseline results/6.8.0-ga \
        --target results/6.11.0-hwe

  ── Step 5: 환경 일관성 체크리스트 ──

    비교 시 아래 항목이 동일해야 유효한 비교:
    ✓ 동일 하드웨어 (CPU, Memory, SSD)
    ✓ 동일 SSD 상태 (TRIM 수행, 동일 사용률)
    ✓ 동일 CPU governor (performance)
    ✓ 동일 NUMA 설정 (numa_balancing)
    ✓ 동일 I/O scheduler (none 또는 mq-deadline)
    ✓ 동일 NVMe module parameters
    ✓ 동일 fio 버전
    ✓ 시스템 idle 상태 (백그라운드 작업 최소화)
    ✓ SSD thermal throttling 없음 (온도 확인)
    ✓ 충분한 Ramp-up time (안정 상태 도달)

    # 사전 조건 설정 스크립트
    sudo bash -c '
        echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
        echo 0 > /proc/sys/kernel/numa_balancing
        echo none > /sys/class/block/nvme0n1/queue/scheduler
        echo 2 > /sys/class/block/nvme0n1/queue/rq_affinity
        echo 0 > /sys/class/block/nvme0n1/queue/nomerges
        fstrim -av  # TRIM all mounted NVMe
        sync
        echo 3 > /proc/sys/vm/drop_caches
        sleep 5
    '

GUIDE
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    echo -e "${BOLD}${BLUE}"
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║   NVMe Kernel Version Performance Comparator                     ║"
    echo "║   Compare NVMe SSD performance across different kernel versions  ║"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    if [[ -z "$MODE" ]]; then
        echo "Usage:"
        echo "  sudo $0 --run --dev /dev/nvme0n1 [--tag label] [--quick]"
        echo "  sudo $0 --compare --baseline results/dir1 --target results/dir2"
        echo ""
        show_ubuntu_kernel_info
        show_kernel_switch_guide
        exit 0
    fi

    case "$MODE" in
        run)
            check_deps
            [[ -b "$DEVICE" ]] || die "Block device not found: $DEVICE"

            # Determine tag
            if [[ -z "$TAG" ]]; then
                TAG=$(uname -r)
            fi
            local result_dir="${OUTDIR}/${TAG}"
            mkdir -p "$result_dir"

            print_header "BENCHMARK RUN: Kernel $(uname -r) [Tag: ${TAG}]"
            echo "  Device:     $DEVICE"
            echo "  Output:     $result_dir"
            echo "  Quick mode: $QUICK"
            echo ""

            # Collect system info
            collect_system_info "$result_dir"

            # Show Ubuntu kernel info
            show_ubuntu_kernel_info

            # Pre-benchmark preparation
            echo ""
            print_header "PRE-BENCHMARK PREPARATION"
            echo "  Setting optimal benchmark conditions..."

            # CPU governor
            if [[ -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
                local gov
                gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
                if [[ "$gov" != "performance" ]]; then
                    echo "  Setting CPU governor to 'performance'..."
                    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
                        echo performance > "$cpu" 2>/dev/null || true
                    done
                fi
            fi

            # Drop caches
            echo "  Dropping page cache..."
            sync
            echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

            # Wait for steady state
            echo "  Waiting 5s for steady state..."
            sleep 5

            # Run benchmarks
            run_benchmarks "$result_dir"

            echo ""
            print_header "BENCHMARK COMPLETE"
            echo "  Results saved to: $result_dir"
            echo "  System info: ${result_dir}/system_info.txt"
            echo "  CSV summary: ${result_dir}/summary.csv"
            echo ""
            echo "  Next steps:"
            echo "    1. Switch to another kernel (see guide below)"
            echo "    2. Re-run: sudo $0 --run --dev $DEVICE --tag <new-tag>"
            echo "    3. Compare: sudo $0 --compare --baseline ${result_dir} --target results/<new-tag>"
            echo ""
            ;;

        compare)
            compare_results
            ;;

        *)
            die "Unknown mode: $MODE"
            ;;
    esac
}

main "$@"

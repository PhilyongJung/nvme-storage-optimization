#!/bin/bash
###############################################################################
# NVMe Storage Resource Optimization Advisor
#
# 현재 시스템의 자원 할당 상태를 분석하고, 비효율적인 부분을 감지하여
# Balanced & Optimized 자원 할당 가이드를 제공합니다.
#
# 사용법: sudo bash 03_optimization_guide.sh [--apply] [--save <filename>]
# 옵션:
#   --apply         권장 설정을 즉시 적용 (주의: 시스템 변경됨)
#   --save <file>   결과를 파일로 저장
#   --script-only   적용 스크립트만 생성 (직접 적용하지 않음)
#
# 출력: 분석 결과 + 최적화 권장사항 + 적용 스크립트
###############################################################################

set -euo pipefail

# ─── Colors & Formatting ─────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

SEPARATOR="═══════════════════════════════════════════════════════════════════════"

# ─── Options ──────────────────────────────────────────────────────────────────
APPLY_NOW=false
SAVE_FILE=""
SCRIPT_ONLY=false
APPLY_SCRIPT="./apply_optimizations.sh"

while [[ $# -gt 0 ]]; do
    case $1 in
        --apply) APPLY_NOW=true; shift ;;
        --save) SAVE_FILE="$2"; shift 2 ;;
        --script-only) SCRIPT_ONLY=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -n "$SAVE_FILE" ]]; then
    exec > >(tee "$SAVE_FILE") 2>&1
fi

# ─── Counters ─────────────────────────────────────────────────────────────────
TOTAL_CHECKS=0
ISSUES_FOUND=0
OPTIMIZATIONS=()      # Array of optimization commands
OPT_DESCRIPTIONS=()   # Array of optimization descriptions

# ─── Helpers ──────────────────────────────────────────────────────────────────
print_header() {
    echo -e "\n${BOLD}${BLUE}${SEPARATOR}${NC}"
    echo -e "${BOLD}${BLUE}  $1${NC}"
    echo -e "${BOLD}${BLUE}${SEPARATOR}${NC}\n"
}

print_subheader() {
    echo -e "\n${CYAN}  ── $1 ──${NC}"
}

check_pass() {
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    echo -e "  ${GREEN}[PASS]${NC} $1"
}

check_fail() {
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
    echo -e "  ${RED}[FAIL]${NC} $1"
}

check_warn() {
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    echo -e "  ${YELLOW}[WARN]${NC} $1"
}

recommend() {
    echo -e "  ${MAGENTA}[FIX]${NC}  $1"
    echo -e "         ${BOLD}Command:${NC} $2"
}

add_optimization() {
    local desc="$1"
    local cmd="$2"
    OPTIMIZATIONS+=("$cmd")
    OPT_DESCRIPTIONS+=("$desc")
    recommend "$desc" "$cmd"
}

# Expand CPU list like "0-3,8-11" to individual numbers
expand_cpulist() {
    local list="$1"
    python3 -c "
cpus = set()
for part in '${list}'.split(','):
    part = part.strip()
    if '-' in part:
        a, b = part.split('-')
        cpus.update(range(int(a), int(b)+1))
    elif part:
        cpus.add(int(part))
for c in sorted(cpus):
    print(c)
" 2>/dev/null
}

cpu_in_numa() {
    local cpu="$1"
    local numa_cpulist="$2"
    python3 -c "
cpus = set()
for part in '${numa_cpulist}'.split(','):
    part = part.strip()
    if '-' in part:
        a, b = part.split('-')
        cpus.update(range(int(a), int(b)+1))
    elif part:
        cpus.add(int(part))
exit(0 if ${cpu} in cpus else 1)
" 2>/dev/null
}

get_physical_cores_for_numa() {
    local numa_node="$1"
    local numa_cpus
    numa_cpus=$(cat "/sys/devices/system/node/node${numa_node}/cpulist" 2>/dev/null || echo "")
    local physical_cores=()

    for cpu_id in $(expand_cpulist "$numa_cpus"); do
        local siblings
        siblings=$(cat "/sys/devices/system/cpu/cpu${cpu_id}/topology/thread_siblings_list" 2>/dev/null || echo "$cpu_id")
        local first_sibling
        first_sibling=$(echo "$siblings" | cut -d',' -f1 | cut -d'-' -f1)
        if [[ "$cpu_id" == "$first_sibling" ]]; then
            physical_cores+=("$cpu_id")
        fi
    done
    echo "${physical_cores[@]}"
}

# ─── Check 1: NUMA Balancing ─────────────────────────────────────────────────
check_numa_balancing() {
    print_header "CHECK 1: NUMA CONFIGURATION"

    print_subheader "NUMA Balancing"
    local val
    val=$(cat /proc/sys/kernel/numa_balancing 2>/dev/null || echo "N/A")

    if [[ "$val" == "1" ]]; then
        check_fail "NUMA balancing is ENABLED (current: $val)"
        add_optimization \
            "Disable NUMA balancing for consistent storage performance" \
            "echo 0 > /proc/sys/kernel/numa_balancing"
    elif [[ "$val" == "0" ]]; then
        check_pass "NUMA balancing is disabled"
    fi

    # Zone reclaim
    print_subheader "Zone Reclaim Mode"
    local zrm
    zrm=$(cat /proc/sys/vm/zone_reclaim_mode 2>/dev/null || echo "N/A")
    if [[ "$zrm" == "0" ]]; then
        check_pass "zone_reclaim_mode=0 (allows cross-NUMA allocation to avoid OOM)"
    elif [[ "$zrm" != "N/A" ]]; then
        check_warn "zone_reclaim_mode=$zrm (consider 0 for storage workloads)"
        add_optimization \
            "Set zone_reclaim_mode=0 to allow cross-NUMA allocation" \
            "echo 0 > /proc/sys/vm/zone_reclaim_mode"
    fi
}

# ─── Check 2: CPU Governor & C-States ────────────────────────────────────────
check_cpu_power() {
    print_header "CHECK 2: CPU POWER MANAGEMENT"

    print_subheader "CPU Frequency Governor"
    if [[ -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
        local governor
        governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A")

        if [[ "$governor" == "performance" ]]; then
            check_pass "CPU governor is 'performance'"
        else
            check_fail "CPU governor is '$governor' (expected: performance)"
            add_optimization \
                "Set CPU governor to 'performance' for all cores" \
                "for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > \$g; done"
        fi
    else
        check_warn "CPU frequency scaling not available (VM or firmware controlled)"
    fi

    # C-States check
    print_subheader "C-State Configuration"
    if [[ -d /sys/devices/system/cpu/cpu0/cpuidle ]]; then
        local deep_cstate=false
        for state in /sys/devices/system/cpu/cpu0/cpuidle/state*/; do
            local name
            name=$(cat "${state}name" 2>/dev/null || echo "")
            local disabled
            disabled=$(cat "${state}disable" 2>/dev/null || echo "0")
            local latency
            latency=$(cat "${state}latency" 2>/dev/null || echo "0")

            if [[ "$latency" -gt 10 && "$disabled" == "0" ]]; then
                deep_cstate=true
            fi
        done

        if [[ "$deep_cstate" == "true" ]]; then
            check_warn "Deep C-States are enabled (may increase tail latency)"
            echo -e "  ${MAGENTA}[TIP]${NC}  For ultra-low latency: add 'processor.max_cstate=1 intel_idle.max_cstate=0' to kernel boot params"
        else
            check_pass "Deep C-States are disabled or not impactful"
        fi
    fi
}

# ─── Check 3: NVMe I/O Scheduler ─────────────────────────────────────────────
check_io_scheduler() {
    print_header "CHECK 3: NVMe I/O SCHEDULER & BLOCK SETTINGS"

    for blk in /sys/class/block/nvme*; do
        [[ -d "$blk" ]] || continue
        local dev
        dev=$(basename "$blk")

        # Skip partitions
        [[ "$dev" =~ p[0-9]+$ ]] && continue

        print_subheader "/dev/${dev}"

        # Scheduler
        local sched
        sched=$(cat "${blk}/queue/scheduler" 2>/dev/null || echo "N/A")
        if [[ "$sched" == *"[none]"* ]]; then
            check_pass "Scheduler: none (optimal for NVMe)"
        elif [[ "$sched" == *"[mq-deadline]"* ]]; then
            check_warn "Scheduler: mq-deadline (acceptable, but 'none' is better for NVMe)"
            add_optimization \
                "Set I/O scheduler to 'none' for /dev/${dev}" \
                "echo none > /sys/block/${dev}/queue/scheduler"
        else
            check_fail "Scheduler: ${sched} (should be 'none' for NVMe)"
            add_optimization \
                "Set I/O scheduler to 'none' for /dev/${dev}" \
                "echo none > /sys/block/${dev}/queue/scheduler"
        fi

        # rq_affinity
        local rq_aff
        rq_aff=$(cat "${blk}/queue/rq_affinity" 2>/dev/null || echo "N/A")
        if [[ "$rq_aff" == "2" ]]; then
            check_pass "rq_affinity=2 (strict, completion on submitting CPU)"
        elif [[ "$rq_aff" == "1" ]]; then
            check_warn "rq_affinity=1 (default). Consider rq_affinity=2 for NUMA-local completion"
            add_optimization \
                "Set rq_affinity=2 for strict CPU completion on /dev/${dev}" \
                "echo 2 > /sys/block/${dev}/queue/rq_affinity"
        else
            check_fail "rq_affinity=$rq_aff (should be 2 for NUMA-optimal completion)"
            add_optimization \
                "Set rq_affinity=2 for /dev/${dev}" \
                "echo 2 > /sys/block/${dev}/queue/rq_affinity"
        fi

        # nr_requests
        local nr_req
        nr_req=$(cat "${blk}/queue/nr_requests" 2>/dev/null || echo "0")
        if [[ "$nr_req" -lt 64 ]]; then
            check_warn "nr_requests=$nr_req (low for high-IOPS workloads)"
            add_optimization \
                "Increase nr_requests to 256 for /dev/${dev}" \
                "echo 256 > /sys/block/${dev}/queue/nr_requests"
        elif [[ "$nr_req" -ge 64 && "$nr_req" -le 1024 ]]; then
            check_pass "nr_requests=$nr_req (reasonable)"
        fi

        # read_ahead_kb for random workloads
        local ra
        ra=$(cat "${blk}/queue/read_ahead_kb" 2>/dev/null || echo "0")
        if [[ "$ra" -gt 128 ]]; then
            check_warn "read_ahead_kb=$ra (high for random I/O, consider reducing to 8-128)"
        else
            check_pass "read_ahead_kb=$ra"
        fi

        # nomerges
        local nomerges
        nomerges=$(cat "${blk}/queue/nomerges" 2>/dev/null || echo "N/A")
        if [[ "$nomerges" == "0" ]]; then
            check_warn "nomerges=0 (merge enabled). For 4K random I/O, nomerges=2 can reduce overhead"
        fi
    done
}

# ─── Check 4: IRQ Affinity ───────────────────────────────────────────────────
check_irq_affinity() {
    print_header "CHECK 4: NVMe IRQ AFFINITY"

    # irqbalance
    print_subheader "irqbalance Service"
    if systemctl is-active irqbalance &>/dev/null 2>&1; then
        check_fail "irqbalance is RUNNING (interferes with manual IRQ affinity)"
        add_optimization \
            "Stop irqbalance service" \
            "systemctl stop irqbalance && systemctl disable irqbalance"
    else
        check_pass "irqbalance is not running"
    fi

    # Per-NVMe controller IRQ check
    for nvme_ctrl in $(ls /sys/class/nvme/ 2>/dev/null); do
        print_subheader "IRQ Affinity: ${nvme_ctrl}"

        local dev_numa
        dev_numa=$(cat "/sys/class/nvme/${nvme_ctrl}/device/numa_node" 2>/dev/null || echo "-1")

        if [[ "$dev_numa" == "-1" ]]; then
            check_warn "${nvme_ctrl}: NUMA node is -1 (cannot verify affinity)"
            continue
        fi

        local numa_cpulist
        numa_cpulist=$(cat "/sys/devices/system/node/node${dev_numa}/cpulist" 2>/dev/null || echo "")

        local cross_numa_count=0
        local total_irqs=0

        grep "${nvme_ctrl}" /proc/interrupts 2>/dev/null | while read -r line; do
            local irq_num
            irq_num=$(echo "$line" | awk '{print $1}' | tr -d ':')
            local irq_name
            irq_name=$(echo "$line" | awk '{print $NF}')
            local eff_affinity
            eff_affinity=$(cat "/proc/irq/${irq_num}/effective_affinity_list" 2>/dev/null || echo "")
            local smp_affinity
            smp_affinity=$(cat "/proc/irq/${irq_num}/smp_affinity_list" 2>/dev/null || echo "")

            total_irqs=$((total_irqs + 1))

            if [[ -n "$eff_affinity" ]]; then
                local first_cpu
                first_cpu=$(echo "$eff_affinity" | cut -d',' -f1 | cut -d'-' -f1)
                if cpu_in_numa "$first_cpu" "$numa_cpulist"; then
                    check_pass "IRQ $irq_num ($irq_name) → CPU $eff_affinity (NUMA $dev_numa local)"
                else
                    check_fail "IRQ $irq_num ($irq_name) → CPU $eff_affinity (CROSS-NUMA! Device on NUMA $dev_numa)"
                    cross_numa_count=$((cross_numa_count + 1))
                fi
            fi
        done

        if [[ $cross_numa_count -gt 0 ]]; then
            echo ""
            echo -e "  ${MAGENTA}[RECOMMENDATION]${NC} Reassign ${nvme_ctrl} IRQs to NUMA ${dev_numa} CPUs (${numa_cpulist})"
        fi
    done
}

# ─── Check 5: NIC-NVMe NUMA Alignment ────────────────────────────────────────
check_nic_nvme_alignment() {
    print_header "CHECK 5: NIC ↔ NVMe NUMA ALIGNMENT"

    # Collect NVMe NUMA info
    declare -A nvme_numa_map
    for nvme_ctrl in $(ls /sys/class/nvme/ 2>/dev/null); do
        local n
        n=$(cat "/sys/class/nvme/${nvme_ctrl}/device/numa_node" 2>/dev/null || echo "-1")
        nvme_numa_map[$nvme_ctrl]=$n
    done

    # Collect NIC NUMA info
    declare -A nic_numa_map
    for net_dev in $(ls /sys/class/net/ 2>/dev/null | grep -v lo); do
        if [[ -L "/sys/class/net/${net_dev}/device" ]]; then
            local n
            n=$(cat "/sys/class/net/${net_dev}/device/numa_node" 2>/dev/null || echo "-1")
            nic_numa_map[$net_dev]=$n
        fi
    done

    # Report alignment
    echo "  Device NUMA Placement:"
    echo ""
    for ctrl in "${!nvme_numa_map[@]}"; do
        echo -e "    NVMe ${BOLD}$ctrl${NC} → NUMA ${nvme_numa_map[$ctrl]}"
    done
    for nic in "${!nic_numa_map[@]}"; do
        echo -e "    NIC  ${BOLD}$nic${NC}  → NUMA ${nic_numa_map[$nic]}"
    done

    echo ""

    # Check alignment
    local all_nvme_numas=()
    for n in "${nvme_numa_map[@]}"; do
        all_nvme_numas+=("$n")
    done
    local unique_nvme_numas
    unique_nvme_numas=$(echo "${all_nvme_numas[@]}" | tr ' ' '\n' | sort -u)

    for nic in "${!nic_numa_map[@]}"; do
        local nic_numa="${nic_numa_map[$nic]}"
        local found_match=false
        for nvme_numa in $unique_nvme_numas; do
            if [[ "$nic_numa" == "$nvme_numa" ]]; then
                found_match=true
                check_pass "NIC $nic (NUMA $nic_numa) has NVMe device(s) on same NUMA node"
            fi
        done
        if [[ "$found_match" == "false" ]]; then
            check_warn "NIC $nic (NUMA $nic_numa) has NO NVMe on same NUMA node → potential cross-NUMA data path"
            echo -e "  ${MAGENTA}[TIP]${NC}  For storage service using NIC $nic, ensure I/O threads and NVMe are on NUMA $nic_numa"
        fi
    done
}

# ─── Check 6: HugePages ──────────────────────────────────────────────────────
check_hugepages() {
    print_header "CHECK 6: HUGEPAGES CONFIGURATION"

    local hp_total
    hp_total=$(grep HugePages_Total /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
    local hp_free
    hp_free=$(grep HugePages_Free /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
    local hp_size
    hp_size=$(grep Hugepagesize /proc/meminfo 2>/dev/null | awk '{print $2, $3}' || echo "N/A")

    echo "  Current HugePages: total=$hp_total, free=$hp_free, size=$hp_size"
    echo ""

    if [[ "$hp_total" -eq 0 ]]; then
        check_fail "No HugePages configured"
        add_optimization \
            "Allocate HugePages (example: 4GB worth of 2MB pages)" \
            "echo 2048 > /proc/sys/vm/nr_hugepages"
        echo -e "  ${MAGENTA}[TIP]${NC}  For SPDK: allocate HugePages before starting the application"
        echo -e "  ${MAGENTA}[TIP]${NC}  For 1GB HugePages: add 'hugepagesz=1G hugepages=16' to kernel boot params"
    elif [[ "$hp_total" -lt 512 ]]; then
        check_warn "HugePages configured ($hp_total) but may be insufficient for high-perf storage"
    else
        check_pass "HugePages configured: $hp_total pages ($hp_size each)"
    fi

    # Check per-NUMA HugePages balance
    print_subheader "Per-NUMA HugePages Distribution"
    local numa_nodes
    numa_nodes=$(ls -d /sys/devices/system/node/node* 2>/dev/null | sort -V)
    local imbalanced=false

    for node_path in $numa_nodes; do
        local node
        node=$(basename "$node_path")
        local hp
        hp=$(cat "${node_path}/hugepages/hugepages-2048kB/nr_hugepages" 2>/dev/null || echo "0")
        echo "    $node: $hp pages (2MB)"

        # Check 1GB pages too
        if [[ -d "${node_path}/hugepages/hugepages-1048576kB" ]]; then
            local hp1g
            hp1g=$(cat "${node_path}/hugepages/hugepages-1048576kB/nr_hugepages" 2>/dev/null || echo "0")
            echo "    $node: $hp1g pages (1GB)"
        fi
    done
}

# ─── Check 7: Kernel Parameters ──────────────────────────────────────────────
check_kernel_params() {
    print_header "CHECK 7: KERNEL PARAMETERS"

    # Swappiness
    print_subheader "Memory Management"
    local swap
    swap=$(sysctl -n vm.swappiness 2>/dev/null || echo "N/A")
    if [[ "$swap" != "N/A" && "$swap" -gt 10 ]]; then
        check_warn "vm.swappiness=$swap (should be ≤10 for storage workloads)"
        add_optimization \
            "Reduce swappiness to 1" \
            "sysctl -w vm.swappiness=1"
    else
        check_pass "vm.swappiness=$swap"
    fi

    # Dirty ratio
    local dirty
    dirty=$(sysctl -n vm.dirty_ratio 2>/dev/null || echo "N/A")
    local dirty_bg
    dirty_bg=$(sysctl -n vm.dirty_background_ratio 2>/dev/null || echo "N/A")
    echo "  vm.dirty_ratio=$dirty, vm.dirty_background_ratio=$dirty_bg"

    # Network parameters (relevant for NVMe-oF)
    print_subheader "Network Stack (for NVMe-oF / iSCSI)"

    local rmem
    rmem=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "0")
    if [[ "$rmem" -lt 16777216 ]]; then
        check_warn "net.core.rmem_max=$rmem (recommend ≥16MB for NVMe-oF)"
        add_optimization \
            "Increase receive buffer max to 16MB" \
            "sysctl -w net.core.rmem_max=16777216"
    else
        check_pass "net.core.rmem_max=$rmem"
    fi

    local wmem
    wmem=$(sysctl -n net.core.wmem_max 2>/dev/null || echo "0")
    if [[ "$wmem" -lt 16777216 ]]; then
        check_warn "net.core.wmem_max=$wmem (recommend ≥16MB for NVMe-oF)"
        add_optimization \
            "Increase send buffer max to 16MB" \
            "sysctl -w net.core.wmem_max=16777216"
    else
        check_pass "net.core.wmem_max=$wmem"
    fi

    local backlog
    backlog=$(sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo "0")
    if [[ "$backlog" -lt 10000 ]]; then
        check_warn "net.core.netdev_max_backlog=$backlog (recommend ≥65536)"
        add_optimization \
            "Increase netdev backlog" \
            "sysctl -w net.core.netdev_max_backlog=65536"
    else
        check_pass "net.core.netdev_max_backlog=$backlog"
    fi

    # Busy poll
    local bpoll
    bpoll=$(sysctl -n net.core.busy_poll 2>/dev/null || echo "0")
    local bread
    bread=$(sysctl -n net.core.busy_read 2>/dev/null || echo "0")
    if [[ "$bpoll" == "0" ]]; then
        check_warn "net.core.busy_poll=0 (enable for low-latency networking)"
        add_optimization \
            "Enable busy polling for low-latency network I/O" \
            "sysctl -w net.core.busy_poll=50 && sysctl -w net.core.busy_read=50"
    else
        check_pass "net.core.busy_poll=$bpoll, busy_read=$bread"
    fi
}

# ─── Check 8: NVMe Module Parameters ─────────────────────────────────────────
check_nvme_module() {
    print_header "CHECK 8: NVMe MODULE PARAMETERS"

    if [[ ! -d /sys/module/nvme/parameters ]]; then
        check_warn "NVMe module parameters not accessible"
        return
    fi

    # poll_queues
    local poll_q
    poll_q=$(cat /sys/module/nvme/parameters/poll_queues 2>/dev/null || echo "0")
    if [[ "$poll_q" == "0" ]]; then
        check_warn "poll_queues=0 (no polling queues for io_uring IOPOLL)"
        echo -e "  ${MAGENTA}[TIP]${NC}  For io_uring IOPOLL: set poll_queues=N (N = number of polling threads)"
        echo -e "  ${MAGENTA}[TIP]${NC}  Add to /etc/modprobe.d/nvme.conf: options nvme poll_queues=4"
    else
        check_pass "poll_queues=$poll_q (polling queues available for io_uring)"
    fi

    # write_queues
    local write_q
    write_q=$(cat /sys/module/nvme/parameters/write_queues 2>/dev/null || echo "0")
    echo "  write_queues=$write_q (0=shared, N=dedicated write queues)"

    # io_queue_depth
    local q_depth
    q_depth=$(cat /sys/module/nvme/parameters/io_queue_depth 2>/dev/null || echo "N/A")
    echo "  io_queue_depth=$q_depth"
}

# ─── Optimal Resource Allocation Plan ─────────────────────────────────────────
generate_allocation_plan() {
    print_header "OPTIMAL RESOURCE ALLOCATION PLAN"

    echo -e "  ${BOLD}Based on the analysis above, here is the recommended resource allocation:${NC}"
    echo ""

    # Collect system info
    local num_numas
    num_numas=$(ls -d /sys/devices/system/node/node* 2>/dev/null | wc -l)

    for numa_id in $(seq 0 $((num_numas - 1))); do
        local numa_cpus
        numa_cpus=$(cat "/sys/devices/system/node/node${numa_id}/cpulist" 2>/dev/null || echo "N/A")
        local physical_cores
        physical_cores=$(get_physical_cores_for_numa "$numa_id" 2>/dev/null || echo "")
        local pc_count
        pc_count=$(echo "$physical_cores" | wc -w)

        echo -e "  ${BOLD}━━━ NUMA Node $numa_id ━━━${NC}"
        echo "  CPUs (all):      $numa_cpus"
        echo "  Physical cores:  $physical_cores ($pc_count cores)"
        echo ""

        # NVMe on this NUMA
        echo "  NVMe Devices on NUMA $numa_id:"
        local nvme_count=0
        for nvme_ctrl in $(ls /sys/class/nvme/ 2>/dev/null); do
            local n
            n=$(cat "/sys/class/nvme/${nvme_ctrl}/device/numa_node" 2>/dev/null || echo "-1")
            if [[ "$n" == "$numa_id" ]]; then
                local bdf
                bdf=$(readlink -f "/sys/class/nvme/${nvme_ctrl}/device" 2>/dev/null | xargs basename 2>/dev/null || echo "?")
                echo "    - ${nvme_ctrl} (PCIe: $bdf)"
                nvme_count=$((nvme_count + 1))
            fi
        done
        if [[ $nvme_count -eq 0 ]]; then
            echo "    (none)"
        fi

        # NIC on this NUMA
        echo "  NICs on NUMA $numa_id:"
        local nic_count=0
        for net_dev in $(ls /sys/class/net/ 2>/dev/null | grep -v lo); do
            if [[ -L "/sys/class/net/${net_dev}/device" ]]; then
                local n
                n=$(cat "/sys/class/net/${net_dev}/device/numa_node" 2>/dev/null || echo "-1")
                if [[ "$n" == "$numa_id" ]]; then
                    echo "    - ${net_dev}"
                    nic_count=$((nic_count + 1))
                fi
            fi
        done
        if [[ $nic_count -eq 0 ]]; then
            echo "    (none)"
        fi

        # GPU on this NUMA
        echo "  GPUs on NUMA $numa_id:"
        local gpu_count=0
        for pci_dev in $(lspci -D 2>/dev/null | grep -iE "VGA|3D|NVIDIA|AMD/ATI" | awk '{print $1}'); do
            local n
            n=$(cat "/sys/bus/pci/devices/${pci_dev}/numa_node" 2>/dev/null || echo "-1")
            if [[ "$n" == "$numa_id" ]]; then
                local desc
                desc=$(lspci -s "${pci_dev#*:}" 2>/dev/null | cut -d: -f3- || echo "GPU")
                echo "    - $pci_dev ($desc)"
                gpu_count=$((gpu_count + 1))
            fi
        done
        if [[ $gpu_count -eq 0 ]]; then
            echo "    (none)"
        fi

        # Recommended allocation
        echo ""
        echo -e "  ${CYAN}Recommended Core Allocation for NUMA $numa_id:${NC}"

        if [[ $pc_count -gt 0 ]]; then
            local cores_arr=($physical_cores)
            local idx=0

            # Reserve core 0 (or first core) for OS
            echo "    Core ${cores_arr[$idx]}: OS/Management (reserved)"
            idx=$((idx + 1))

            # Allocate cores for NVMe
            if [[ $nvme_count -gt 0 && $idx -lt $pc_count ]]; then
                local cores_per_nvme=$(( (pc_count - 2) / (nvme_count + nic_count + 1) ))
                [[ $cores_per_nvme -lt 1 ]] && cores_per_nvme=1
                [[ $cores_per_nvme -gt 8 ]] && cores_per_nvme=8

                for nvme_ctrl in $(ls /sys/class/nvme/ 2>/dev/null); do
                    local n
                    n=$(cat "/sys/class/nvme/${nvme_ctrl}/device/numa_node" 2>/dev/null || echo "-1")
                    if [[ "$n" == "$numa_id" && $idx -lt $pc_count ]]; then
                        local end_idx=$((idx + cores_per_nvme - 1))
                        [[ $end_idx -ge $pc_count ]] && end_idx=$((pc_count - 1))
                        local core_range="${cores_arr[$idx]}"
                        if [[ $idx -ne $end_idx ]]; then
                            core_range="${cores_arr[$idx]}-${cores_arr[$end_idx]}"
                        fi
                        echo "    Core $core_range: ${nvme_ctrl} I/O (QP + IRQ affinity)"
                        idx=$((end_idx + 1))
                    fi
                done
            fi

            # Allocate cores for NIC
            if [[ $nic_count -gt 0 && $idx -lt $pc_count ]]; then
                local nic_cores=2
                [[ $((pc_count - idx)) -lt 4 ]] && nic_cores=1
                local end_idx=$((idx + nic_cores - 1))
                [[ $end_idx -ge $pc_count ]] && end_idx=$((pc_count - 1))
                echo "    Core ${cores_arr[$idx]}-${cores_arr[$end_idx]}: NIC RX/TX processing"
                idx=$((end_idx + 1))
            fi

            # Remaining cores for application
            if [[ $idx -lt $pc_count ]]; then
                echo "    Core ${cores_arr[$idx]}-${cores_arr[$((pc_count-1))]}: Application threads"
            fi
        fi

        echo ""
    done

    # IRQ affinity commands
    echo ""
    echo -e "  ${BOLD}━━━ Recommended IRQ Affinity Commands ━━━${NC}"
    echo ""

    for nvme_ctrl in $(ls /sys/class/nvme/ 2>/dev/null); do
        local dev_numa
        dev_numa=$(cat "/sys/class/nvme/${nvme_ctrl}/device/numa_node" 2>/dev/null || echo "-1")
        if [[ "$dev_numa" == "-1" ]]; then continue; fi

        local numa_cpus
        numa_cpus=$(cat "/sys/devices/system/node/node${dev_numa}/cpulist" 2>/dev/null || echo "")
        local phys_cores
        phys_cores=$(get_physical_cores_for_numa "$dev_numa" 2>/dev/null || echo "")
        local core_arr=($phys_cores)
        local core_idx=1  # Skip first core (OS)

        echo "  # ${nvme_ctrl} (NUMA $dev_numa)"
        grep "${nvme_ctrl}" /proc/interrupts 2>/dev/null | while read -r line; do
            local irq_num
            irq_num=$(echo "$line" | awk '{print $1}' | tr -d ':')
            local irq_name
            irq_name=$(echo "$line" | awk '{print $NF}')

            if [[ $core_idx -lt ${#core_arr[@]} ]]; then
                echo "  echo ${core_arr[$core_idx]} > /proc/irq/${irq_num}/smp_affinity_list  # ${irq_name} → Core ${core_arr[$core_idx]}"
                core_idx=$((core_idx + 1))
            fi
        done
        echo ""
    done
}

# ─── Generate Apply Script ───────────────────────────────────────────────────
generate_apply_script() {
    print_header "OPTIMIZATION APPLY SCRIPT"

    if [[ ${#OPTIMIZATIONS[@]} -eq 0 ]]; then
        echo -e "  ${GREEN}No optimizations needed! System appears well-configured.${NC}"
        return
    fi

    echo -e "  ${BOLD}Found ${#OPTIMIZATIONS[@]} optimizations to apply.${NC}"
    echo ""

    # Write script
    cat > "$APPLY_SCRIPT" << 'SCRIPT_HEADER'
#!/bin/bash
###############################################################################
# Auto-generated NVMe Storage Optimization Script
# Generated by: 03_optimization_guide.sh
#
# WARNING: This script modifies system settings. Review before running!
# Usage: sudo bash apply_optimizations.sh
###############################################################################

set -euo pipefail

echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║  Applying NVMe Storage Optimizations                        ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must run as root"
    exit 1
fi

SCRIPT_HEADER

    for i in "${!OPTIMIZATIONS[@]}"; do
        cat >> "$APPLY_SCRIPT" << EOF

# Optimization $((i+1)): ${OPT_DESCRIPTIONS[$i]}
echo "[$((i+1))/${#OPTIMIZATIONS[@]}] ${OPT_DESCRIPTIONS[$i]}..."
${OPTIMIZATIONS[$i]} && echo "  Done." || echo "  WARNING: Failed!"

EOF
    done

    # Add IRQ affinity commands for NVMe
    cat >> "$APPLY_SCRIPT" << 'IRQ_SECTION'

# ─── IRQ Affinity Optimization ───────────────────────────────────────────────
echo ""
echo "Applying NVMe IRQ affinity..."

for nvme_ctrl in $(ls /sys/class/nvme/ 2>/dev/null); do
    dev_numa=$(cat "/sys/class/nvme/${nvme_ctrl}/device/numa_node" 2>/dev/null || echo "-1")
    if [[ "$dev_numa" == "-1" ]]; then continue; fi

    numa_cpus=$(cat "/sys/devices/system/node/node${dev_numa}/cpulist" 2>/dev/null || echo "")

    # Get physical cores for this NUMA
    phys_cores=()
    for cpu_id in $(python3 -c "
for part in '${numa_cpus}'.split(','):
    part = part.strip()
    if '-' in part:
        a, b = part.split('-')
        for c in range(int(a), int(b)+1):
            print(c)
    elif part:
        print(int(part))
" 2>/dev/null); do
        siblings=$(cat "/sys/devices/system/cpu/cpu${cpu_id}/topology/thread_siblings_list" 2>/dev/null || echo "$cpu_id")
        first=$(echo "$siblings" | cut -d',' -f1 | cut -d'-' -f1)
        if [[ "$cpu_id" == "$first" ]]; then
            phys_cores+=("$cpu_id")
        fi
    done

    core_idx=1  # Skip first core
    grep "${nvme_ctrl}" /proc/interrupts 2>/dev/null | while read -r line; do
        irq_num=$(echo "$line" | awk '{print $1}' | tr -d ':')
        if [[ $core_idx -lt ${#phys_cores[@]} ]]; then
            echo "  IRQ $irq_num → CPU ${phys_cores[$core_idx]}"
            echo "${phys_cores[$core_idx]}" > "/proc/irq/${irq_num}/smp_affinity_list" 2>/dev/null || true
            core_idx=$((core_idx + 1))
        fi
    done
done

IRQ_SECTION

    cat >> "$APPLY_SCRIPT" << 'SCRIPT_FOOTER'

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Optimizations applied successfully!"
echo "  To make persistent across reboots, add these to:"
echo "    - /etc/sysctl.d/99-nvme-perf.conf (sysctl parameters)"
echo "    - /etc/modprobe.d/nvme.conf (NVMe module parameters)"
echo "    - /etc/default/grub (kernel boot parameters)"
echo "    - /etc/rc.local or systemd unit (IRQ affinity settings)"
echo "═══════════════════════════════════════════════════════════════"
SCRIPT_FOOTER

    chmod +x "$APPLY_SCRIPT"

    echo -e "  Apply script generated: ${BOLD}${APPLY_SCRIPT}${NC}"
    echo ""
    echo "  To review:  cat $APPLY_SCRIPT"
    echo "  To apply:   sudo bash $APPLY_SCRIPT"
    echo ""

    # Also generate persistent config files
    echo -e "  ${BOLD}━━━ Persistent Configuration Files ━━━${NC}"
    echo ""
    echo "  Create these files to persist settings across reboots:"
    echo ""

    # sysctl.conf
    echo "  ┌─── /etc/sysctl.d/99-nvme-perf.conf ───┐"
    echo "  │ kernel.numa_balancing = 0               │"
    echo "  │ vm.swappiness = 1                       │"
    echo "  │ vm.zone_reclaim_mode = 0                │"
    echo "  │ vm.dirty_ratio = 40                     │"
    echo "  │ vm.dirty_background_ratio = 10          │"
    echo "  │ net.core.rmem_max = 16777216            │"
    echo "  │ net.core.wmem_max = 16777216            │"
    echo "  │ net.core.netdev_max_backlog = 65536     │"
    echo "  │ net.core.busy_poll = 50                 │"
    echo "  │ net.core.busy_read = 50                 │"
    echo "  └─────────────────────────────────────────┘"
    echo ""

    # modprobe
    echo "  ┌─── /etc/modprobe.d/nvme.conf ──────────┐"
    echo "  │ options nvme poll_queues=4               │"
    echo "  │ options nvme write_queues=2              │"
    echo "  │ options nvme io_queue_depth=128          │"
    echo "  └─────────────────────────────────────────┘"
    echo ""

    # GRUB
    echo "  ┌─── /etc/default/grub (GRUB_CMDLINE) ───┐"
    echo "  │ default_hugepagesz=1G hugepagesz=1G     │"
    echo "  │ hugepages=16                             │"
    echo "  │ intel_iommu=on iommu=pt                  │"
    echo "  │ processor.max_cstate=1                    │"
    echo "  │ intel_idle.max_cstate=0                   │"
    echo "  └─────────────────────────────────────────┘"

    if [[ "$APPLY_NOW" == "true" ]]; then
        echo ""
        echo -e "  ${YELLOW}Applying optimizations now...${NC}"
        bash "$APPLY_SCRIPT"
    fi
}

# ─── Score Summary ────────────────────────────────────────────────────────────
print_score() {
    print_header "OPTIMIZATION SCORE"

    local passed=$((TOTAL_CHECKS - ISSUES_FOUND))
    local pct=0
    if [[ $TOTAL_CHECKS -gt 0 ]]; then
        pct=$((passed * 100 / TOTAL_CHECKS))
    fi

    echo -e "  Total Checks:  $TOTAL_CHECKS"
    echo -e "  Passed:        ${GREEN}${passed}${NC}"
    echo -e "  Issues Found:  ${RED}${ISSUES_FOUND}${NC}"
    echo ""

    # Score bar
    local bar_len=50
    local filled=$((pct * bar_len / 100))
    local empty=$((bar_len - filled))
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done

    local color=$RED
    if [[ $pct -ge 80 ]]; then color=$GREEN
    elif [[ $pct -ge 60 ]]; then color=$YELLOW
    fi

    echo -e "  Score: ${color}${BOLD}${pct}%${NC}"
    echo -e "  ${color}[${bar}]${NC}"
    echo ""

    if [[ $pct -ge 90 ]]; then
        echo -e "  ${GREEN}${BOLD}Excellent!${NC} System is well-optimized for NVMe storage."
    elif [[ $pct -ge 70 ]]; then
        echo -e "  ${YELLOW}${BOLD}Good.${NC} Minor optimizations recommended."
    elif [[ $pct -ge 50 ]]; then
        echo -e "  ${YELLOW}${BOLD}Fair.${NC} Several optimizations needed for optimal performance."
    else
        echo -e "  ${RED}${BOLD}Needs Work.${NC} Significant optimizations required."
    fi
    echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    echo -e "${BOLD}${BLUE}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║     NVMe Storage Resource Optimization Advisor                  ║"
    echo "║     Balanced & Optimized Allocation Guide                       ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    if [[ $EUID -ne 0 ]]; then
        echo -e "${YELLOW}WARNING: Running without root. Some checks may be incomplete.${NC}"
        echo -e "${YELLOW}Re-run with: sudo $0${NC}\n"
    fi

    check_numa_balancing
    check_cpu_power
    check_io_scheduler
    check_irq_affinity
    check_nic_nvme_alignment
    check_hugepages
    check_kernel_params
    check_nvme_module

    print_score

    generate_allocation_plan
    generate_apply_script

    echo -e "\n${GREEN}Analysis complete.${NC}"
    if [[ -n "$SAVE_FILE" ]]; then
        echo -e "${GREEN}Results saved to: ${SAVE_FILE}${NC}"
    fi
}

main "$@"

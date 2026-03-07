#!/bin/bash
###############################################################################
# NVMe Storage System Topology Analyzer
#
# 현재 시스템의 CPU NUMA, PCIe 토폴로지, NVMe Queue Pair, IRQ 매핑,
# NIC/GPU 배치 등을 종합적으로 분석하여 출력합니다.
#
# 사용법: sudo bash 02_system_topology_analyzer.sh [--json] [--save <filename>]
# 옵션:
#   --json          JSON 형식으로도 출력
#   --save <file>   결과를 파일로 저장
#
# 요구사항: root 권한, lspci, numactl, ethtool, nvme-cli
###############################################################################

set -euo pipefail

# ─── Colors & Formatting ─────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

SEPARATOR="═══════════════════════════════════════════════════════════════════════"
SUB_SEP="───────────────────────────────────────────────────────────────────────"

# ─── Options ──────────────────────────────────────────────────────────────────
OUTPUT_JSON=false
SAVE_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --json) OUTPUT_JSON=true; shift ;;
        --save) SAVE_FILE="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ─── Redirect output if saving ───────────────────────────────────────────────
if [[ -n "$SAVE_FILE" ]]; then
    exec > >(tee "$SAVE_FILE") 2>&1
fi

# ─── Helper Functions ─────────────────────────────────────────────────────────
print_header() {
    echo -e "\n${BOLD}${BLUE}${SEPARATOR}${NC}"
    echo -e "${BOLD}${BLUE}  $1${NC}"
    echo -e "${BOLD}${BLUE}${SEPARATOR}${NC}\n"
}

print_subheader() {
    echo -e "\n${CYAN}${SUB_SEP}${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${CYAN}${SUB_SEP}${NC}"
}

print_ok() {
    echo -e "  ${GREEN}[OK]${NC} $1"
}

print_warn() {
    echo -e "  ${YELLOW}[WARN]${NC} $1"
}

print_err() {
    echo -e "  ${RED}[ERR]${NC} $1"
}

print_info() {
    echo -e "  ${BOLD}$1${NC}: $2"
}

check_command() {
    if ! command -v "$1" &>/dev/null; then
        print_warn "$1 not found, some information may be unavailable"
        return 1
    fi
    return 0
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${YELLOW}WARNING: Running without root. Some information may be incomplete.${NC}"
        echo -e "${YELLOW}Re-run with: sudo $0${NC}\n"
    fi
}

# ─── System Overview ─────────────────────────────────────────────────────────
system_overview() {
    print_header "SYSTEM OVERVIEW"

    print_info "Hostname" "$(hostname)"
    print_info "Architecture" "$(uname -m)"
    print_info "Date" "$(date '+%Y-%m-%d %H:%M:%S %Z')"

    # ── Detailed OS Info ──
    echo ""
    print_subheader "OS Information"
    local os_name os_id os_version os_codename
    os_name=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo 'Unknown')
    os_id=$(grep "^ID=" /etc/os-release 2>/dev/null | cut -d'=' -f2 || echo 'Unknown')
    os_version=$(grep "^VERSION_ID=" /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo 'Unknown')
    os_codename=$(grep "^VERSION_CODENAME=" /etc/os-release 2>/dev/null | cut -d'=' -f2 || echo 'Unknown')
    print_info "Distribution" "$os_name"
    print_info "OS ID / Version" "${os_id} / ${os_version}"
    print_info "Codename" "$os_codename"
    if [[ "$os_id" == "ubuntu" ]]; then
        local minor_ver
        minor_ver=$(echo "$os_version" | cut -d'.' -f2)
        if [[ "$minor_ver" == "04" ]]; then
            print_info "LTS Status" "Ubuntu ${os_version} LTS (Long Term Support)"
        else
            print_info "LTS Status" "Ubuntu ${os_version} (Interim Release)"
        fi
        if uname -r | grep -q "\-hwe"; then
            print_info "Kernel Type" "HWE (Hardware Enablement) kernel"
        else
            print_info "Kernel Type" "GA (General Availability) kernel"
        fi
    fi

    # ── Detailed Kernel Info ──
    echo ""
    print_subheader "Kernel Information"
    print_info "Kernel Version" "$(uname -r)"
    print_info "Kernel Build" "$(uname -v)"
    print_info "Kernel Arch" "$(uname -m)"

    local kconfig=""
    if [[ -f "/boot/config-$(uname -r)" ]]; then
        kconfig="/boot/config-$(uname -r)"
    elif [[ -f /proc/config.gz ]]; then
        kconfig="/proc/config.gz"
    fi
    if [[ -n "$kconfig" ]]; then
        print_info "Kernel Config" "$kconfig"
        echo ""
        echo "  Key I/O Kernel Configs:"
        local io_configs=(
            "CONFIG_BLK_DEV_NVME"
            "CONFIG_NVME_MULTIPATH"
            "CONFIG_IO_URING"
            "CONFIG_NVME_TARGET"
            "CONFIG_BLK_MQ_PCI"
            "CONFIG_BLK_WBT"
            "CONFIG_VFIO_PCI"
            "CONFIG_BLK_CGROUP"
        )
        for cfg in "${io_configs[@]}"; do
            local val
            if [[ "$kconfig" == *.gz ]]; then
                val=$(zgrep "^${cfg}=" "$kconfig" 2>/dev/null | cut -d'=' -f2 || echo "not set")
            else
                val=$(grep "^${cfg}=" "$kconfig" 2>/dev/null | cut -d'=' -f2 || echo "not set")
            fi
            printf "    %-35s = %s\n" "$cfg" "$val"
        done
    fi

    # ── Loaded I/O Modules ──
    echo ""
    echo "  Loaded I/O Modules:"
    local io_modules=("nvme" "nvme_core" "nvme_fabrics" "nvme_tcp" "nvme_rdma" "vfio_pci" "uio" "uio_pci_generic" "nbd")
    for mod in "${io_modules[@]}"; do
        if lsmod 2>/dev/null | grep -qw "$mod"; then
            echo -e "    ${mod}: ${GREEN}loaded${NC}"
        else
            echo "    ${mod}: not loaded"
        fi
    done

    # ── I/O Stack Info ──
    echo ""
    print_subheader "I/O Stack Information"

    # io_uring support
    if [[ -f /proc/config.gz ]] && zgrep -q "CONFIG_IO_URING=y" /proc/config.gz 2>/dev/null; then
        print_ok "io_uring: Compiled in kernel"
    elif [[ -n "$kconfig" && "$kconfig" != *.gz ]] && grep -q "CONFIG_IO_URING=y" "$kconfig" 2>/dev/null; then
        print_ok "io_uring: Compiled in kernel"
    else
        print_info "io_uring" "Not detected or check /boot/config-$(uname -r)"
    fi

    # SPDK check
    if command -v spdk_nvme_perf &>/dev/null || [[ -d /opt/spdk ]] || [[ -d /usr/local/lib/spdk ]]; then
        print_ok "SPDK: Installed ($(spdk_nvme_perf --version 2>/dev/null || echo 'path found'))"
    else
        print_info "SPDK" "Not installed"
    fi

    # fio check
    if command -v fio &>/dev/null; then
        local fio_ver fio_engines
        fio_ver=$(fio --version 2>/dev/null || echo "unknown")
        fio_engines=$(fio --enghelp 2>/dev/null | grep -cE "io_uring|libaio|psync|spdk" || echo "?")
        print_ok "fio: ${fio_ver} (${fio_engines} relevant engines)"
        echo "    Engines:"
        fio --enghelp 2>/dev/null | grep -E "io_uring|libaio|psync|pvsync|spdk|sg" | while read -r eng; do
            echo "      $eng"
        done
    else
        print_info "fio" "Not installed"
    fi

    # bpftrace / perf check
    if command -v bpftrace &>/dev/null; then
        print_ok "bpftrace: $(bpftrace --version 2>/dev/null | head -1)"
    else
        print_info "bpftrace" "Not installed"
    fi
    if command -v perf &>/dev/null; then
        print_ok "perf: $(perf version 2>/dev/null | head -1)"
    else
        print_info "perf" "Not installed"
    fi

    # nvme-cli version
    if command -v nvme &>/dev/null; then
        print_ok "nvme-cli: $(nvme version 2>/dev/null || echo 'installed')"
    else
        print_info "nvme-cli" "Not installed"
    fi

    # CPU info
    local cpu_model
    cpu_model=$(grep "model name" /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs)
    local cpu_sockets
    cpu_sockets=$(grep "physical id" /proc/cpuinfo 2>/dev/null | sort -u | wc -l)
    local cpu_cores_total
    cpu_cores_total=$(nproc 2>/dev/null || echo "N/A")
    local cpu_cores_per_socket
    cpu_cores_per_socket=$(grep "cpu cores" /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs)

    echo ""
    print_info "CPU Model" "${cpu_model:-Unknown}"
    print_info "Sockets" "${cpu_sockets:-Unknown}"
    print_info "Cores/Socket" "${cpu_cores_per_socket:-Unknown}"
    print_info "Total Logical CPUs" "${cpu_cores_total}"

    # HyperThreading
    local threads_per_core
    threads_per_core=$(lscpu 2>/dev/null | grep "Thread(s) per core" | awk '{print $NF}')
    if [[ "$threads_per_core" == "2" ]]; then
        print_info "Hyper-Threading" "Enabled (2 threads/core)"
    else
        print_info "Hyper-Threading" "Disabled"
    fi

    # Total Memory
    local total_mem
    total_mem=$(free -h 2>/dev/null | grep Mem | awk '{print $2}')
    print_info "Total Memory" "${total_mem:-Unknown}"

    # HugePages
    echo ""
    print_subheader "HugePages Configuration"
    if [[ -f /proc/meminfo ]]; then
        grep -i huge /proc/meminfo 2>/dev/null | while read -r line; do
            echo "  $line"
        done
    fi

    # CPU Governor
    echo ""
    print_subheader "CPU Frequency Governor"
    if [[ -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
        local governor
        governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A")
        print_info "Current Governor" "$governor"
        if [[ "$governor" != "performance" ]]; then
            print_warn "Governor is '$governor'. 'performance' recommended for NVMe workloads."
        else
            print_ok "Governor is set to 'performance'"
        fi
    else
        print_info "CPU Freq Scaling" "Not available (possibly running in VM or cpufreq disabled)"
    fi
}

# ─── Memory Configuration ────────────────────────────────────────────────────
memory_configuration() {
    print_header "MEMORY (DIMM) CONFIGURATION"

    # Total memory
    local total_mem
    total_mem=$(free -h 2>/dev/null | grep Mem | awk '{print $2}')
    print_info "Total System Memory" "${total_mem:-Unknown}"

    # dmidecode for DIMM details (requires root)
    if [[ $EUID -eq 0 ]] && check_command dmidecode; then

        # Physical Memory Array info
        echo ""
        print_subheader "Physical Memory Arrays"
        dmidecode -t 16 2>/dev/null | grep -E "Maximum Capacity|Number Of Devices|Error Correction" | while read -r line; do
            echo "  $line"
        done

        # DIMM Slot Summary
        echo ""
        print_subheader "DIMM Slot Summary"
        local total_slots=0
        local populated_slots=0
        local total_capacity_mb=0

        echo ""
        printf "  %-8s %-14s %-8s %-10s %-16s %-20s %-22s\n" \
            "Slot" "Locator" "Size" "Speed" "Type" "Vendor" "Part Number"
        echo "  ─────────────────────────────────────────────────────────────────────────────────────────────────"

        # Parse each Memory Device (type 17)
        local slot_idx=0
        dmidecode -t 17 2>/dev/null | awk '
        /^Memory Device$/ { slot++ }
        /Size:/ { size[slot] = $0; sub(/.*Size: */, "", size[slot]) }
        /Speed:.*MHz/ && !/Configured/ { speed[slot] = $0; sub(/.*Speed: */, "", speed[slot]) }
        /Configured Memory Speed:/ { cfg_speed[slot] = $0; sub(/.*Configured Memory Speed: */, "", cfg_speed[slot]) }
        /Type:/ && !/Detail/ && !/Error/ { type[slot] = $0; sub(/.*Type: */, "", type[slot]) }
        /Manufacturer:/ { vendor[slot] = $0; sub(/.*Manufacturer: */, "", vendor[slot]) }
        /Part Number:/ { part[slot] = $0; sub(/.*Part Number: */, "", part[slot]) }
        /Locator:/ && !/Bank/ { locator[slot] = $0; sub(/.*Locator: */, "", locator[slot]) }
        /Bank Locator:/ { bank[slot] = $0; sub(/.*Bank Locator: */, "", bank[slot]) }
        /Serial Number:/ { serial[slot] = $0; sub(/.*Serial Number: */, "", serial[slot]) }
        /Rank:/ { rank[slot] = $0; sub(/.*Rank: */, "", rank[slot]) }
        END {
            for (i=1; i<=slot; i++) {
                sz = (size[i] ~ /No Module/) ? "Empty" : size[i]
                sp = (speed[i] != "") ? speed[i] : "N/A"
                tp = (type[i] != "") ? type[i] : "N/A"
                vn = (vendor[i] != "") ? vendor[i] : "N/A"
                pn = (part[i] != "") ? part[i] : "N/A"
                lo = (locator[i] != "") ? locator[i] : "N/A"
                printf "  %-8d %-14s %-8s %-10s %-16s %-20s %-22s\n", i, lo, sz, sp, tp, vn, pn
            }
        }'

        # Summary counts
        echo ""
        local total_s populated_s
        total_s=$(dmidecode -t 17 2>/dev/null | grep -c "^Memory Device$" || echo "0")
        populated_s=$(dmidecode -t 17 2>/dev/null | grep "Size:" | grep -cv "No Module Installed" || echo "0")
        local empty_s=$((total_s - populated_s))

        print_info "Total DIMM Slots" "$total_s"
        print_info "Populated Slots" "$populated_s"
        print_info "Empty Slots" "$empty_s"

        # Channels estimation
        echo ""
        print_subheader "Memory Channel Estimation"
        # Get DIMMs per channel from locator patterns
        if dmidecode -t 17 2>/dev/null | grep "Locator:" | grep -v "Bank" | head -1 | grep -qiE "CPU|NODE|SOCKET"; then
            echo "  (Estimating from DIMM locator labels)"
            dmidecode -t 17 2>/dev/null | grep "Locator:" | grep -v "Bank" | grep -v "^$" | sort | while read -r line; do
                local loc
                loc=$(echo "$line" | sed 's/.*Locator: *//')
                echo "    $loc"
            done | head -32
        fi

        # Per-socket memory summary
        echo ""
        echo "  Per-Socket Memory Summary:"
        local prev_bank=""
        local socket_count=0
        dmidecode -t 17 2>/dev/null | awk '
        /Bank Locator:/ {
            bank=$0; sub(/.*Bank Locator: */, "", bank)
            if (bank != prev_bank) {
                if (prev_bank != "") printf "    %-20s : %d DIMMs, %d MB\n", prev_bank, cnt, total_mb
                prev_bank = bank; cnt = 0; total_mb = 0
            }
        }
        /Size:/ && !/No Module/ {
            cnt++
            sz = $0; sub(/.*Size: */, "", sz)
            if (sz ~ /GB/) { gsub(/ GB/, "", sz); total_mb += sz * 1024 }
            else if (sz ~ /MB/) { gsub(/ MB/, "", sz); total_mb += sz }
        }
        END {
            if (prev_bank != "") printf "    %-20s : %d DIMMs, %d MB\n", prev_bank, cnt, total_mb
        }'

        # Configured speed
        echo ""
        print_subheader "Memory Speed Details"
        local max_speed cfg_speed_val
        max_speed=$(dmidecode -t 17 2>/dev/null | grep "Speed:" | grep -v "Configured" | grep "MHz" | head -1 | sed 's/.*Speed: *//')
        cfg_speed_val=$(dmidecode -t 17 2>/dev/null | grep "Configured Memory Speed:" | grep "MHz" | head -1 | sed 's/.*Configured Memory Speed: *//')
        print_info "Max DIMM Speed" "${max_speed:-N/A}"
        print_info "Configured Speed" "${cfg_speed_val:-N/A}"
        if [[ -n "$max_speed" && -n "$cfg_speed_val" && "$max_speed" != "$cfg_speed_val" ]]; then
            print_warn "DIMM running below rated speed: ${cfg_speed_val} < ${max_speed}"
        fi

    else
        echo ""
        if [[ $EUID -ne 0 ]]; then
            print_warn "Root required for DIMM details. Re-run with sudo."
        else
            print_warn "dmidecode not found. Install: apt install dmidecode"
        fi

        # Fallback: /proc/meminfo basic info
        echo ""
        print_subheader "Memory Info (from /proc/meminfo)"
        grep -E "MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree" /proc/meminfo 2>/dev/null | while read -r line; do
            echo "  $line"
        done
    fi
}

# ─── NUMA Topology ───────────────────────────────────────────────────────────
numa_topology() {
    print_header "CPU NUMA TOPOLOGY"

    # NUMA Nodes
    if check_command numactl; then
        print_subheader "NUMA Hardware Info"
        numactl --hardware 2>/dev/null || echo "  numactl --hardware failed"
        echo ""
    fi

    # lscpu NUMA mapping
    print_subheader "CPU-to-NUMA Mapping (lscpu)"
    lscpu 2>/dev/null | grep -E "NUMA|Socket|Core|Thread|CPU\(s\)" | head -20

    # Per-NUMA node details
    echo ""
    print_subheader "Per-NUMA Node Details"
    local numa_nodes
    numa_nodes=$(ls -d /sys/devices/system/node/node* 2>/dev/null | sort -V)

    for node_path in $numa_nodes; do
        local node
        node=$(basename "$node_path")
        local node_id
        node_id=${node#node}
        local cpulist
        cpulist=$(cat "${node_path}/cpulist" 2>/dev/null || echo "N/A")
        local meminfo_total
        meminfo_total=$(grep MemTotal "${node_path}/meminfo" 2>/dev/null | awk '{print $4, $5}')
        local meminfo_free
        meminfo_free=$(grep MemFree "${node_path}/meminfo" 2>/dev/null | awk '{print $4, $5}')

        echo ""
        echo -e "  ${BOLD}NUMA Node ${node_id}:${NC}"
        echo "    CPUs:        $cpulist"
        echo "    Total Mem:   $meminfo_total"
        echo "    Free Mem:    $meminfo_free"

        # HugePages per NUMA
        local hp_total
        hp_total=$(cat "${node_path}/hugepages/hugepages-2048kB/nr_hugepages" 2>/dev/null || echo "0")
        local hp_free
        hp_free=$(cat "${node_path}/hugepages/hugepages-2048kB/free_hugepages" 2>/dev/null || echo "0")
        echo "    HugePages:   total=$hp_total, free=$hp_free (2MB pages)"

        # 1GB HugePages
        if [[ -d "${node_path}/hugepages/hugepages-1048576kB" ]]; then
            local hp1g_total
            hp1g_total=$(cat "${node_path}/hugepages/hugepages-1048576kB/nr_hugepages" 2>/dev/null || echo "0")
            local hp1g_free
            hp1g_free=$(cat "${node_path}/hugepages/hugepages-1048576kB/free_hugepages" 2>/dev/null || echo "0")
            echo "    HugePages:   total=$hp1g_total, free=$hp1g_free (1GB pages)"
        fi
    done

    # NUMA distances
    echo ""
    print_subheader "NUMA Distance Matrix"
    if check_command numactl; then
        numactl --hardware 2>/dev/null | grep -A 100 "node distances" || echo "  Not available"
    fi

    # NUMA balancing
    echo ""
    print_subheader "NUMA Balancing Status"
    local numa_bal
    numa_bal=$(cat /proc/sys/kernel/numa_balancing 2>/dev/null || echo "N/A")
    print_info "kernel.numa_balancing" "$numa_bal"
    if [[ "$numa_bal" == "1" ]]; then
        print_warn "NUMA balancing is ENABLED. Consider disabling for dedicated storage workloads."
    elif [[ "$numa_bal" == "0" ]]; then
        print_ok "NUMA balancing is disabled"
    fi

    # HT siblings mapping
    echo ""
    print_subheader "Hyper-Threading Sibling Map"
    echo "  (Physical Core sharing - first CPU is recommended for I/O pinning)"
    echo ""
    local shown_pairs=""
    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*/; do
        local cpu_id
        cpu_id=$(basename "$cpu_dir" | sed 's/cpu//')
        local siblings
        siblings=$(cat "${cpu_dir}topology/thread_siblings_list" 2>/dev/null || continue)
        # Only show unique pairs
        if ! echo "$shown_pairs" | grep -q "|${siblings}|"; then
            shown_pairs="${shown_pairs}|${siblings}|"
            echo "    CPU Siblings: $siblings"
        fi
    done | head -40
    echo "    (showing up to 40 pairs)"
}

# ─── PCIe Topology ───────────────────────────────────────────────────────────
pcie_topology() {
    print_header "PCIe TOPOLOGY"

    if ! check_command lspci; then
        print_err "lspci not found. Install pciutils: apt install pciutils"
        return
    fi

    # Full PCIe tree
    print_subheader "PCIe Device Tree"
    lspci -tv 2>/dev/null || lspci -t 2>/dev/null || echo "  Failed to get PCIe tree"

    # ── System-wide PCIe MPS/MRRS ──
    echo ""
    print_subheader "PCIe Max Payload Size (MPS) & Max Read Request Size (MRRS)"
    echo ""
    echo -e "  ${BOLD}Note: MPS/MRRS mismatch across devices can cause PCIe errors or limit throughput.${NC}"
    echo -e "  ${BOLD}All devices on the same hierarchy should have compatible MPS settings.${NC}"
    echo ""
    printf "  %-14s %-45s %-12s %-12s\n" "BDF" "Device" "MPS" "MRRS"
    echo "  ────────────────────────────────────────────────────────────────────────────────────"
    lspci -nn 2>/dev/null | grep -iE "Non-Volatile|NVM Express|Ethernet|Network|VGA|3D|NVIDIA|AMD/ATI" | while read -r line; do
        local bdf desc devctl mps mrrs
        bdf=$(echo "$line" | awk '{print $1}')
        desc=$(echo "$line" | cut -d' ' -f2- | cut -c1-43)
        devctl=$(lspci -vvv -s "$bdf" 2>/dev/null | grep "DevCtl:" | head -1)
        mps=$(echo "$devctl" | grep -oP 'MaxPayload \K[0-9]+ bytes' || echo "N/A")
        mrrs=$(echo "$devctl" | grep -oP 'MaxReadReq \K[0-9]+ bytes' || echo "N/A")
        printf "  %-14s %-45s %-12s %-12s\n" "$bdf" "$desc" "$mps" "$mrrs"
    done

    # MPS/MRRS capability (max supported)
    echo ""
    echo "  Capability (Max Supported):"
    printf "  %-14s %-45s %-12s %-12s\n" "BDF" "Device" "MPS Cap" "MRRS Cap"
    echo "  ────────────────────────────────────────────────────────────────────────────────────"
    lspci -nn 2>/dev/null | grep -iE "Non-Volatile|NVM Express|Ethernet|Network|VGA|3D|NVIDIA|AMD/ATI" | while read -r line; do
        local bdf desc devcap mps_cap
        bdf=$(echo "$line" | awk '{print $1}')
        desc=$(echo "$line" | cut -d' ' -f2- | cut -c1-43)
        devcap=$(lspci -vvv -s "$bdf" 2>/dev/null | grep "DevCap:" | head -1)
        mps_cap=$(echo "$devcap" | grep -oP 'MaxPayload \K[0-9]+ bytes' || echo "N/A")
        printf "  %-14s %-45s %-12s\n" "$bdf" "$desc" "$mps_cap"
    done

    # NVMe devices on PCIe
    echo ""
    print_subheader "NVMe Controllers on PCIe"
    echo ""
    lspci -nn 2>/dev/null | grep -i "Non-Volatile memory\|NVM Express" | while read -r line; do
        local bdf
        bdf=$(echo "$line" | awk '{print $1}')
        local numa_node
        numa_node=$(cat "/sys/bus/pci/devices/0000:${bdf}/numa_node" 2>/dev/null || echo "N/A")
        local link_speed
        link_speed=$(lspci -vvv -s "$bdf" 2>/dev/null | grep "LnkSta:" | head -1 | sed 's/.*Speed \([^,]*\), Width \([^,]*\).*/\1, \2/' || echo "N/A")
        local link_cap
        link_cap=$(lspci -vvv -s "$bdf" 2>/dev/null | grep "LnkCap:" | head -1 | sed 's/.*Speed \([^,]*\), Width \([^,]*\).*/\1, \2/' || echo "N/A")
        local driver
        driver=$(lspci -k -s "$bdf" 2>/dev/null | grep "Kernel driver" | awk '{print $NF}' || echo "N/A")
        local blk_dev
        blk_dev=$(ls "/sys/bus/pci/devices/0000:${bdf}/nvme/" 2>/dev/null | head -1 || echo "N/A")
        # MPS/MRRS per device
        local devctl mps mrrs
        devctl=$(lspci -vvv -s "$bdf" 2>/dev/null | grep "DevCtl:" | head -1)
        mps=$(echo "$devctl" | grep -oP 'MaxPayload \K[0-9]+ bytes' || echo "N/A")
        mrrs=$(echo "$devctl" | grep -oP 'MaxReadReq \K[0-9]+ bytes' || echo "N/A")

        echo -e "  ${BOLD}PCIe BDF: ${bdf}${NC}"
        echo "    Description: $(echo "$line" | cut -d' ' -f2-)"
        echo "    NUMA Node:   $numa_node"
        echo "    Link Speed:  $link_speed (Current)"
        echo "    Link Cap:    $link_cap (Capable)"
        echo "    MPS:         $mps"
        echo "    MRRS:        $mrrs"
        echo "    Driver:      $driver"
        echo "    Block Dev:   $blk_dev"
        echo ""
    done

    # Network devices on PCIe
    echo ""
    print_subheader "Network Adapters on PCIe"
    echo ""
    lspci -nn 2>/dev/null | grep -i "Ethernet\|Network" | while read -r line; do
        local bdf
        bdf=$(echo "$line" | awk '{print $1}')
        local numa_node
        numa_node=$(cat "/sys/bus/pci/devices/0000:${bdf}/numa_node" 2>/dev/null || echo "N/A")
        local link_speed
        link_speed=$(lspci -vvv -s "$bdf" 2>/dev/null | grep "LnkSta:" | head -1 | sed 's/.*Speed \([^,]*\), Width \([^,]*\).*/\1, \2/' || echo "N/A")
        local driver
        driver=$(lspci -k -s "$bdf" 2>/dev/null | grep "Kernel driver" | awk '{print $NF}' || echo "N/A")
        local net_dev
        net_dev=$(ls "/sys/bus/pci/devices/0000:${bdf}/net/" 2>/dev/null | head -1 || echo "N/A")

        echo -e "  ${BOLD}PCIe BDF: ${bdf}${NC}"
        echo "    Description: $(echo "$line" | cut -d' ' -f2-)"
        echo "    NUMA Node:   $numa_node"
        echo "    Link Speed:  $link_speed"
        echo "    Driver:      $driver"
        echo "    Net Dev:     $net_dev"
        echo ""
    done

    # GPU devices on PCIe
    echo ""
    print_subheader "GPU Devices on PCIe"
    echo ""
    local gpu_found=false
    lspci -nn 2>/dev/null | grep -iE "VGA|3D|Display|NVIDIA|AMD/ATI" | while read -r line; do
        gpu_found=true
        local bdf
        bdf=$(echo "$line" | awk '{print $1}')
        local numa_node
        numa_node=$(cat "/sys/bus/pci/devices/0000:${bdf}/numa_node" 2>/dev/null || echo "N/A")
        local link_speed
        link_speed=$(lspci -vvv -s "$bdf" 2>/dev/null | grep "LnkSta:" | head -1 | sed 's/.*Speed \([^,]*\), Width \([^,]*\).*/\1, \2/' || echo "N/A")
        local driver
        driver=$(lspci -k -s "$bdf" 2>/dev/null | grep "Kernel driver" | awk '{print $NF}' || echo "N/A")

        echo -e "  ${BOLD}PCIe BDF: ${bdf}${NC}"
        echo "    Description: $(echo "$line" | cut -d' ' -f2-)"
        echo "    NUMA Node:   $numa_node"
        echo "    Link Speed:  $link_speed"
        echo "    Driver:      $driver"
        echo ""
    done
    if [[ "$gpu_found" == "false" ]]; then
        echo "  No discrete GPU detected."
    fi
}

# ─── NVMe Device Details ─────────────────────────────────────────────────────
nvme_details() {
    print_header "NVMe DEVICE DETAILS"

    local nvme_devs
    nvme_devs=$(ls /sys/class/nvme/ 2>/dev/null)

    if [[ -z "$nvme_devs" ]]; then
        print_warn "No NVMe devices found in /sys/class/nvme/"
        return
    fi

    for nvme_ctrl in $nvme_devs; do
        local ctrl_path="/sys/class/nvme/${nvme_ctrl}"

        print_subheader "Controller: ${nvme_ctrl}"

        # Basic info
        local model
        model=$(cat "${ctrl_path}/model" 2>/dev/null | xargs || echo "N/A")
        local serial
        serial=$(cat "${ctrl_path}/serial" 2>/dev/null | xargs || echo "N/A")
        local firmware
        firmware=$(cat "${ctrl_path}/firmware_rev" 2>/dev/null | xargs || echo "N/A")
        local transport
        transport=$(cat "${ctrl_path}/transport" 2>/dev/null || echo "N/A")
        local numa_node
        numa_node=$(cat "${ctrl_path}/device/numa_node" 2>/dev/null || echo "N/A")
        local queue_count
        queue_count=$(cat "${ctrl_path}/queue_count" 2>/dev/null || echo "N/A")

        echo ""
        print_info "Model" "$model"
        print_info "Serial" "$serial"
        print_info "Firmware" "$firmware"
        print_info "Transport" "$transport"
        print_info "NUMA Node" "$numa_node"
        print_info "Total Queues" "$queue_count (including Admin Queue)"

        # PCIe BDF
        local pci_addr
        pci_addr=$(readlink -f "${ctrl_path}/device" 2>/dev/null | xargs basename 2>/dev/null || echo "N/A")
        print_info "PCIe BDF" "$pci_addr"

        # ── Vendor/Part-ID from nvme id-ctrl ──
        local ns_dev="/dev/${nvme_ctrl}n1"
        if check_command nvme && [[ -b "$ns_dev" || -c "/dev/${nvme_ctrl}" ]]; then
            local id_ctrl_out
            id_ctrl_out=$(nvme id-ctrl "/dev/${nvme_ctrl}" 2>/dev/null || echo "")
            if [[ -n "$id_ctrl_out" ]]; then
                local vid svid ssvid mn sn fr
                vid=$(echo "$id_ctrl_out" | grep "^vid " | awk -F: '{print $2}' | xargs)
                svid=$(echo "$id_ctrl_out" | grep "^ssvid " | awk -F: '{print $2}' | xargs)
                mn=$(echo "$id_ctrl_out" | grep "^mn " | awk -F: '{print $2}' | xargs)
                sn=$(echo "$id_ctrl_out" | grep "^sn " | awk -F: '{print $2}' | xargs)
                fr=$(echo "$id_ctrl_out" | grep "^fr " | awk -F: '{print $2}' | xargs)
                local subnqn
                subnqn=$(echo "$id_ctrl_out" | grep "^subnqn " | awk -F: '{print $2}' | xargs)
                local tnvmcap
                tnvmcap=$(echo "$id_ctrl_out" | grep "^tnvmcap " | awk -F: '{print $2}' | xargs)
                local nn
                nn=$(echo "$id_ctrl_out" | grep "^nn " | awk -F: '{print $2}' | xargs)

                # Decode VID to vendor name
                local vendor_name="Unknown"
                case "$vid" in
                    0x*144d|*144d) vendor_name="Samsung" ;;
                    0x*1c5c|*1c5c) vendor_name="SK hynix" ;;
                    0x*1e0f|*1e0f) vendor_name="Kioxia" ;;
                    0x*8086|*8086) vendor_name="Intel/Solidigm" ;;
                    0x*1344|*1344) vendor_name="Micron" ;;
                    0x*15b7|*15b7) vendor_name="Western Digital/SanDisk" ;;
                    0x*1179|*1179) vendor_name="Toshiba" ;;
                    0x*1987|*1987) vendor_name="Phison" ;;
                    0x*126f|*126f) vendor_name="Silicon Motion" ;;
                    0x*1e49|*1e49) vendor_name="Yangtze Memory (YMTC)" ;;
                    0x*025e|*025e) vendor_name="Solidigm" ;;
                esac

                print_info "Vendor ID (VID)" "$vid ($vendor_name)"
                print_info "Sub-Vendor (SSVID)" "$svid"
                print_info "Model Number (MN)" "$mn"
                print_info "Serial Number (SN)" "$sn"
                print_info "Firmware Rev (FR)" "$fr"
                if [[ -n "$tnvmcap" && "$tnvmcap" != "0" ]]; then
                    local cap_tb
                    cap_tb=$(echo "scale=2; $tnvmcap / 1000000000000" | bc 2>/dev/null || echo "N/A")
                    print_info "Total NVM Capacity" "${tnvmcap} bytes (~${cap_tb} TB)"
                fi
                print_info "Num Namespaces (NN)" "$nn"
                if [[ -n "$subnqn" ]]; then
                    print_info "SubNQN" "$subnqn"
                fi

                # NVMe Features: CMB, PMR, etc.
                local oacs cmbsz pmrcap
                oacs=$(echo "$id_ctrl_out" | grep "^oacs " | awk -F: '{print $2}' | xargs)
                cmbsz=$(echo "$id_ctrl_out" | grep "^cmbsz " | awk -F: '{print $2}' | xargs)
                pmrcap=$(echo "$id_ctrl_out" | grep "^pmrcap " | awk -F: '{print $2}' | xargs)
                if [[ -n "$cmbsz" && "$cmbsz" != "0" ]]; then
                    print_info "CMB (Controller Mem Buf)" "Supported (cmbsz=$cmbsz)"
                fi
                if [[ -n "$pmrcap" && "$pmrcap" != "0" ]]; then
                    print_info "PMR (Persistent Mem Region)" "Supported (pmrcap=$pmrcap)"
                fi
            fi
        fi

        # Block devices under this controller
        echo ""
        echo "  Block Devices:"
        ls "${ctrl_path}/" 2>/dev/null | grep "nvme[0-9]n[0-9]" | while read -r ns; do
            local size_bytes
            size_bytes=$(cat "/sys/class/block/${ns}/size" 2>/dev/null || echo "0")
            local size_gb
            size_gb=$(echo "scale=1; $size_bytes * 512 / 1073741824" | bc 2>/dev/null || echo "N/A")
            local scheduler
            scheduler=$(cat "/sys/class/block/${ns}/queue/scheduler" 2>/dev/null || echo "N/A")
            local nr_requests
            nr_requests=$(cat "/sys/class/block/${ns}/queue/nr_requests" 2>/dev/null || echo "N/A")
            local rotational
            rotational=$(cat "/sys/class/block/${ns}/queue/rotational" 2>/dev/null || echo "N/A")
            local max_sectors_kb
            max_sectors_kb=$(cat "/sys/class/block/${ns}/queue/max_sectors_kb" 2>/dev/null || echo "N/A")

            echo "    /dev/${ns}:"
            echo "      Size:          ${size_gb} GB"
            echo "      Scheduler:     ${scheduler}"
            echo "      nr_requests:   ${nr_requests}"
            echo "      max_sectors:   ${max_sectors_kb} KB"
            echo "      Rotational:    ${rotational} (0=SSD)"
        done

        # nvme-cli info (if available)
        if check_command nvme; then
            echo ""
            echo "  NVMe Smart Log (key metrics):"
            local ns_dev="/dev/${nvme_ctrl}n1"
            if [[ -b "$ns_dev" ]]; then
                nvme smart-log "$ns_dev" 2>/dev/null | grep -E "temperature|percentage_used|available_spare|data_units" | while read -r line; do
                    echo "    $line"
                done
            fi
        fi
        echo ""
    done
}

# ─── Queue Pair & IRQ Mapping ─────────────────────────────────────────────────
qp_irq_mapping() {
    print_header "NVMe QUEUE PAIR & IRQ MAPPING"

    local nvme_devs
    nvme_devs=$(ls /sys/class/nvme/ 2>/dev/null)

    if [[ -z "$nvme_devs" ]]; then
        print_warn "No NVMe devices found"
        return
    fi

    for nvme_ctrl in $nvme_devs; do
        print_subheader "Queue/IRQ Mapping: ${nvme_ctrl}"

        local numa_node
        numa_node=$(cat "/sys/class/nvme/${nvme_ctrl}/device/numa_node" 2>/dev/null || echo "N/A")
        local numa_cpus=""
        if [[ "$numa_node" != "N/A" && "$numa_node" != "-1" ]]; then
            numa_cpus=$(cat "/sys/devices/system/node/node${numa_node}/cpulist" 2>/dev/null || echo "")
        fi

        echo ""
        print_info "NUMA Node" "$numa_node"
        print_info "NUMA-local CPUs" "${numa_cpus:-All (no NUMA)}"
        echo ""

        # IRQ mapping from /proc/interrupts
        echo -e "  ${BOLD}IRQ → CPU Affinity Mapping:${NC}"
        echo "  ────────────────────────────────────────────────────────────────"
        printf "  %-8s %-25s %-20s %-10s\n" "IRQ#" "Name" "CPU Affinity" "NUMA OK?"
        echo "  ────────────────────────────────────────────────────────────────"

        grep "${nvme_ctrl}" /proc/interrupts 2>/dev/null | while read -r line; do
            local irq_num
            irq_num=$(echo "$line" | awk '{print $1}' | tr -d ':')
            local irq_name
            irq_name=$(echo "$line" | awk '{print $NF}')

            # Get affinity
            local affinity_list
            affinity_list=$(cat "/proc/irq/${irq_num}/smp_affinity_list" 2>/dev/null || echo "N/A")
            local effective_affinity
            effective_affinity=$(cat "/proc/irq/${irq_num}/effective_affinity_list" 2>/dev/null || echo "$affinity_list")

            # Check if affinity matches NUMA
            local numa_ok="N/A"
            if [[ -n "$numa_cpus" && "$affinity_list" != "N/A" ]]; then
                # Simple check: first CPU in affinity should be in NUMA-local CPUs
                local first_cpu
                first_cpu=$(echo "$affinity_list" | cut -d',' -f1 | cut -d'-' -f1)
                if echo "$numa_cpus" | grep -qw "$first_cpu" 2>/dev/null; then
                    numa_ok="${GREEN}YES${NC}"
                else
                    numa_ok="${RED}NO${NC}"
                fi
            fi

            printf "  %-8s %-25s %-20s " "$irq_num" "$irq_name" "$effective_affinity"
            echo -e "$numa_ok"
        done

        # Queue count details
        echo ""
        echo -e "  ${BOLD}Queue Configuration:${NC}"
        local q_count
        q_count=$(cat "/sys/class/nvme/${nvme_ctrl}/queue_count" 2>/dev/null || echo "N/A")
        echo "    Total Queues (incl Admin): $q_count"

        # Check write/poll queues from module params
        local write_q
        write_q=$(cat /sys/module/nvme/parameters/write_queues 2>/dev/null || echo "N/A")
        local poll_q
        poll_q=$(cat /sys/module/nvme/parameters/poll_queues 2>/dev/null || echo "N/A")
        echo "    Write Queues (module):     $write_q"
        echo "    Poll Queues (module):      $poll_q"

        echo ""
    done

    # Summary of all NVMe IRQs
    print_subheader "All NVMe IRQ Summary (/proc/interrupts)"
    echo ""
    if [[ -f /proc/interrupts ]]; then
        local header
        header=$(head -1 /proc/interrupts)
        echo "  $header"
        grep -i nvme /proc/interrupts 2>/dev/null | while read -r line; do
            echo "  $line"
        done
    fi
}

# ─── NIC Details ──────────────────────────────────────────────────────────────
nic_details() {
    print_header "NETWORK INTERFACE DETAILS"

    local net_devs
    net_devs=$(ls /sys/class/net/ 2>/dev/null | grep -v lo)

    for net_dev in $net_devs; do
        local dev_path="/sys/class/net/${net_dev}"

        # Skip virtual devices
        if [[ ! -L "${dev_path}/device" ]]; then
            continue
        fi

        print_subheader "NIC: ${net_dev}"

        local pci_addr
        pci_addr=$(readlink -f "${dev_path}/device" 2>/dev/null | xargs basename 2>/dev/null || echo "N/A")
        local numa_node
        numa_node=$(cat "${dev_path}/device/numa_node" 2>/dev/null || echo "N/A")
        local driver
        driver=$(readlink "${dev_path}/device/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "N/A")
        local operstate
        operstate=$(cat "${dev_path}/operstate" 2>/dev/null || echo "N/A")
        local speed
        speed=$(cat "${dev_path}/speed" 2>/dev/null || echo "N/A")
        local mtu
        mtu=$(cat "${dev_path}/mtu" 2>/dev/null || echo "N/A")

        echo ""
        print_info "PCIe BDF" "$pci_addr"
        print_info "NUMA Node" "$numa_node"
        print_info "Driver" "$driver"
        print_info "State" "$operstate"
        print_info "Speed" "${speed} Mbps"
        print_info "MTU" "$mtu"

        # Ring buffer info
        if check_command ethtool; then
            echo ""
            echo "  Ring Buffer:"
            ethtool -g "$net_dev" 2>/dev/null | head -10 | while read -r line; do
                echo "    $line"
            done

            # Queue info
            echo ""
            echo "  Channel/Queue Count:"
            ethtool -l "$net_dev" 2>/dev/null | while read -r line; do
                echo "    $line"
            done

            # Coalesce settings
            echo ""
            echo "  Interrupt Coalescing:"
            ethtool -c "$net_dev" 2>/dev/null | head -10 | while read -r line; do
                echo "    $line"
            done
        fi

        # NIC IRQ affinity
        echo ""
        echo -e "  ${BOLD}NIC IRQ → CPU Mapping:${NC}"
        grep "$net_dev" /proc/interrupts 2>/dev/null | while read -r line; do
            local irq_num
            irq_num=$(echo "$line" | awk '{print $1}' | tr -d ':')
            local irq_name
            irq_name=$(echo "$line" | awk '{print $NF}')
            local affinity
            affinity=$(cat "/proc/irq/${irq_num}/smp_affinity_list" 2>/dev/null || echo "N/A")
            printf "    IRQ %-6s  %-30s  → CPU %s\n" "$irq_num" "$irq_name" "$affinity"
        done

        # XPS/RPS settings
        echo ""
        echo "  XPS/RPS Configuration:"
        for txq in "${dev_path}/queues/tx-"*; do
            if [[ -d "$txq" ]]; then
                local qname
                qname=$(basename "$txq")
                local xps_cpus
                xps_cpus=$(cat "${txq}/xps_cpus" 2>/dev/null || echo "N/A")
                echo "    ${qname}: xps_cpus=$xps_cpus"
            fi
        done | head -8
        echo "    (showing up to 8 queues)"

        echo ""
    done
}

# ─── IRQ Balance Status ──────────────────────────────────────────────────────
irq_balance_status() {
    print_header "IRQ BALANCE STATUS"

    # irqbalance service
    print_subheader "irqbalance Service"
    if systemctl is-active irqbalance &>/dev/null; then
        print_warn "irqbalance is ACTIVE (running)"
        echo "    For dedicated NVMe workloads, consider: systemctl stop irqbalance"
    elif systemctl is-enabled irqbalance &>/dev/null 2>&1; then
        print_info "irqbalance" "Installed but not running"
    else
        print_ok "irqbalance is not active"
    fi

    # irqbalance config
    if [[ -f /etc/default/irqbalance ]]; then
        echo ""
        echo "  /etc/default/irqbalance:"
        cat /etc/default/irqbalance 2>/dev/null | grep -v "^#" | grep -v "^$" | while read -r line; do
            echo "    $line"
        done
    fi

    # Show top IRQ consumers
    echo ""
    print_subheader "Top 20 Active IRQs (by count)"
    echo ""
    if [[ -f /proc/interrupts ]]; then
        head -1 /proc/interrupts | awk '{printf "  %-8s", "IRQ"; for(i=1;i<=NF;i++) printf "%-12s", $i; print ""}'
        echo "  ────────────────────────────────────────────────────────"
        # Sum all CPU columns, sort by total
        tail -n +2 /proc/interrupts | awk '{
            irq=$1; name=$NF;
            total=0;
            for(i=2;i<NF;i++) total+=$i;
            if(total > 0) printf "  %-8s %12d  %s\n", irq, total, name
        }' | sort -t' ' -k2 -rn | head -20
    fi
}

# ─── I/O Scheduler & Block Settings ──────────────────────────────────────────
block_settings() {
    print_header "BLOCK DEVICE I/O SETTINGS"

    for blk in /sys/class/block/nvme*; do
        if [[ ! -d "$blk" ]]; then continue; fi
        local dev
        dev=$(basename "$blk")

        # Skip partitions
        if [[ "$dev" =~ p[0-9]+$ ]]; then continue; fi

        print_subheader "Block Device: /dev/${dev}"

        echo ""
        print_info "Scheduler" "$(cat "${blk}/queue/scheduler" 2>/dev/null || echo 'N/A')"
        print_info "nr_requests" "$(cat "${blk}/queue/nr_requests" 2>/dev/null || echo 'N/A')"
        print_info "read_ahead_kb" "$(cat "${blk}/queue/read_ahead_kb" 2>/dev/null || echo 'N/A')"
        print_info "max_sectors_kb" "$(cat "${blk}/queue/max_sectors_kb" 2>/dev/null || echo 'N/A')"
        print_info "max_hw_sectors_kb" "$(cat "${blk}/queue/max_hw_sectors_kb" 2>/dev/null || echo 'N/A')"
        print_info "rotational" "$(cat "${blk}/queue/rotational" 2>/dev/null || echo 'N/A')"
        print_info "rq_affinity" "$(cat "${blk}/queue/rq_affinity" 2>/dev/null || echo 'N/A')"
        print_info "nomerges" "$(cat "${blk}/queue/nomerges" 2>/dev/null || echo 'N/A')"
        print_info "io_poll" "$(cat "${blk}/queue/io_poll" 2>/dev/null || echo 'N/A')"
        print_info "write_cache" "$(cat "${blk}/queue/write_cache" 2>/dev/null || echo 'N/A')"

        # Check for suboptimal settings
        local sched
        sched=$(cat "${blk}/queue/scheduler" 2>/dev/null || echo "")
        if [[ "$sched" != *"[none]"* && "$sched" != *"[mq-deadline]"* ]]; then
            print_warn "Scheduler for $dev is not 'none'. For NVMe, 'none' is recommended."
        fi
        echo ""
    done
}

# ─── Kernel Module Parameters ────────────────────────────────────────────────
kernel_params() {
    print_header "KERNEL & MODULE PARAMETERS"

    print_subheader "NVMe Module Parameters"
    if [[ -d /sys/module/nvme/parameters ]]; then
        for param in /sys/module/nvme/parameters/*; do
            local pname
            pname=$(basename "$param")
            local pval
            pval=$(cat "$param" 2>/dev/null || echo "N/A")
            printf "  %-25s = %s\n" "$pname" "$pval"
        done
    else
        echo "  NVMe module parameters not found"
    fi

    # nvme_core parameters
    echo ""
    print_subheader "NVMe-Core Module Parameters"
    if [[ -d /sys/module/nvme_core/parameters ]]; then
        for param in /sys/module/nvme_core/parameters/*; do
            local pname
            pname=$(basename "$param")
            local pval
            pval=$(cat "$param" 2>/dev/null || echo "N/A")
            printf "  %-25s = %s\n" "$pname" "$pval"
        done
    else
        echo "  NVMe-core module parameters not found"
    fi

    # Key sysctl parameters
    echo ""
    print_subheader "Key Kernel Parameters (sysctl)"
    local params=(
        "kernel.numa_balancing"
        "vm.nr_hugepages"
        "vm.swappiness"
        "vm.dirty_ratio"
        "vm.dirty_background_ratio"
        "vm.zone_reclaim_mode"
        "net.core.rmem_max"
        "net.core.wmem_max"
        "net.core.busy_poll"
        "net.core.busy_read"
        "net.core.netdev_max_backlog"
    )
    for p in "${params[@]}"; do
        local val
        val=$(sysctl -n "$p" 2>/dev/null || echo "N/A")
        printf "  %-35s = %s\n" "$p" "$val"
    done

    # Boot parameters
    echo ""
    print_subheader "Kernel Boot Parameters"
    echo "  $(cat /proc/cmdline 2>/dev/null || echo 'N/A')"
}

# ─── Cross-NUMA Affinity Check ───────────────────────────────────────────────
cross_numa_check() {
    print_header "CROSS-NUMA AFFINITY ANALYSIS"

    echo -e "  ${BOLD}Checking if NVMe IRQs are assigned to NUMA-local CPUs...${NC}"
    echo ""

    local issues_found=0

    # For each NVMe controller
    for nvme_ctrl in $(ls /sys/class/nvme/ 2>/dev/null); do
        local numa_node
        numa_node=$(cat "/sys/class/nvme/${nvme_ctrl}/device/numa_node" 2>/dev/null || echo "-1")

        if [[ "$numa_node" == "-1" ]]; then
            continue
        fi

        local numa_cpus
        numa_cpus=$(cat "/sys/devices/system/node/node${numa_node}/cpulist" 2>/dev/null || echo "")

        grep "${nvme_ctrl}" /proc/interrupts 2>/dev/null | while read -r line; do
            local irq_num
            irq_num=$(echo "$line" | awk '{print $1}' | tr -d ':')
            local irq_name
            irq_name=$(echo "$line" | awk '{print $NF}')
            local eff_affinity
            eff_affinity=$(cat "/proc/irq/${irq_num}/effective_affinity_list" 2>/dev/null || echo "")

            if [[ -n "$eff_affinity" && -n "$numa_cpus" ]]; then
                local first_cpu
                first_cpu=$(echo "$eff_affinity" | cut -d',' -f1 | cut -d'-' -f1)
                # Check membership in NUMA CPUs
                if ! python3 -c "
cpus = set()
for part in '${numa_cpus}'.split(','):
    if '-' in part:
        a, b = part.split('-')
        cpus.update(range(int(a), int(b)+1))
    else:
        cpus.add(int(part))
exit(0 if ${first_cpu} in cpus else 1)
" 2>/dev/null; then
                    print_err "CROSS-NUMA: ${irq_name} (IRQ ${irq_num}) → CPU ${eff_affinity}, but ${nvme_ctrl} is on NUMA ${numa_node} (CPUs: ${numa_cpus})"
                    issues_found=$((issues_found + 1))
                fi
            fi
        done
    done

    # Check NIC-NVMe NUMA alignment
    echo ""
    echo -e "  ${BOLD}Checking NVMe-NIC NUMA alignment...${NC}"
    echo ""

    local nvme_numas=""
    for nvme_ctrl in $(ls /sys/class/nvme/ 2>/dev/null); do
        local n
        n=$(cat "/sys/class/nvme/${nvme_ctrl}/device/numa_node" 2>/dev/null || echo "-1")
        nvme_numas="${nvme_numas} ${nvme_ctrl}:NUMA${n}"
    done

    local nic_numas=""
    for net_dev in $(ls /sys/class/net/ 2>/dev/null | grep -v lo); do
        if [[ -L "/sys/class/net/${net_dev}/device" ]]; then
            local n
            n=$(cat "/sys/class/net/${net_dev}/device/numa_node" 2>/dev/null || echo "-1")
            nic_numas="${nic_numas} ${net_dev}:NUMA${n}"
        fi
    done

    echo "  NVMe NUMA placement: $nvme_numas"
    echo "  NIC NUMA placement:  $nic_numas"
    echo ""

    if [[ $issues_found -eq 0 ]]; then
        print_ok "No obvious cross-NUMA affinity issues detected"
    else
        print_warn "Found $issues_found cross-NUMA affinity issues (see above)"
    fi
}

# ─── Summary ──────────────────────────────────────────────────────────────────
summary_table() {
    print_header "TOPOLOGY SUMMARY TABLE"

    echo -e "  ${BOLD}Device → NUMA → PCIe BDF → IRQ Range → CPU Affinity${NC}"
    echo "  ════════════════════════════════════════════════════════════════"

    # NVMe summary
    for nvme_ctrl in $(ls /sys/class/nvme/ 2>/dev/null); do
        local numa
        numa=$(cat "/sys/class/nvme/${nvme_ctrl}/device/numa_node" 2>/dev/null || echo "?")
        local bdf
        bdf=$(readlink -f "/sys/class/nvme/${nvme_ctrl}/device" 2>/dev/null | xargs basename 2>/dev/null || echo "?")
        local irq_range
        irq_range=$(grep "${nvme_ctrl}" /proc/interrupts 2>/dev/null | awk '{print $1}' | tr -d ':' | head -1)
        local irq_last
        irq_last=$(grep "${nvme_ctrl}" /proc/interrupts 2>/dev/null | awk '{print $1}' | tr -d ':' | tail -1)
        if [[ -n "$irq_range" && -n "$irq_last" ]]; then
            irq_range="${irq_range}-${irq_last}"
        fi
        local affinity
        affinity=""
        local first_irq
        first_irq=$(grep "${nvme_ctrl}" /proc/interrupts 2>/dev/null | head -1 | awk '{print $1}' | tr -d ':')
        if [[ -n "$first_irq" ]]; then
            affinity=$(cat "/proc/irq/${first_irq}/smp_affinity_list" 2>/dev/null || echo "?")
        fi

        printf "  %-12s  NUMA %-3s  %-14s  IRQ %-10s  CPU %s\n" \
            "$nvme_ctrl" "$numa" "$bdf" "${irq_range:-N/A}" "${affinity:-N/A}"
    done

    # NIC summary
    for net_dev in $(ls /sys/class/net/ 2>/dev/null | grep -v lo); do
        if [[ ! -L "/sys/class/net/${net_dev}/device" ]]; then continue; fi
        local numa
        numa=$(cat "/sys/class/net/${net_dev}/device/numa_node" 2>/dev/null || echo "?")
        local bdf
        bdf=$(readlink -f "/sys/class/net/${net_dev}/device" 2>/dev/null | xargs basename 2>/dev/null || echo "?")
        local irq_range
        irq_range=$(grep "${net_dev}" /proc/interrupts 2>/dev/null | awk '{print $1}' | tr -d ':' | head -1)
        local irq_last
        irq_last=$(grep "${net_dev}" /proc/interrupts 2>/dev/null | awk '{print $1}' | tr -d ':' | tail -1)
        if [[ -n "$irq_range" && -n "$irq_last" ]]; then
            irq_range="${irq_range}-${irq_last}"
        fi

        printf "  %-12s  NUMA %-3s  %-14s  IRQ %-10s\n" \
            "$net_dev" "$numa" "$bdf" "${irq_range:-N/A}"
    done

    echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    echo -e "${BOLD}${BLUE}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║     NVMe Storage System Topology Analyzer                       ║"
    echo "║     High-Performance Storage Resource Mapping Tool              ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    check_root

    system_overview
    memory_configuration
    numa_topology
    pcie_topology
    nvme_details
    qp_irq_mapping
    nic_details
    irq_balance_status
    block_settings
    kernel_params
    cross_numa_check
    summary_table

    echo -e "\n${GREEN}Analysis complete.${NC}"
    if [[ -n "$SAVE_FILE" ]]; then
        echo -e "${GREEN}Results saved to: ${SAVE_FILE}${NC}"
    fi
    echo -e "Run the optimization script (03_optimization_guide.sh) for recommendations.\n"
}

main "$@"

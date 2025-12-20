#!/usr/bin/env bash
#######################################
# Debian 12 System Health Analyzer
# Production-grade health monitoring script
#
# Version: 1.0.0
# Author: CalouNX (DevOps/SRE)
# License: MIT
#######################################

set -euo pipefail
IFS=$'\n\t'

# Script metadata
readonly SCRIPT_VERSION="1.0.0"
# SC2155: Declare and assign separately
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

# Thresholds - CPU
readonly CPU_LOAD_WARNING=70
readonly CPU_LOAD_CRITICAL=90
readonly CPU_IOWAIT_WARNING=10
readonly CPU_IOWAIT_CRITICAL=25
readonly CPU_STEAL_WARNING=5

# Thresholds - Memory
readonly MEM_USAGE_WARNING=80
readonly MEM_USAGE_CRITICAL=95
readonly SWAP_USAGE_WARNING=1
readonly SWAP_USAGE_CRITICAL=50
readonly OOM_EVENTS_CRITICAL=1

# Thresholds - Disk
readonly DISK_USAGE_WARNING=80
readonly DISK_USAGE_CRITICAL=90
readonly INODE_USAGE_WARNING=80
readonly INODE_USAGE_CRITICAL=90
# Note: DISK_IOWAIT thresholds unused (use CPU_IOWAIT instead)

# Thresholds - Network
readonly NET_ERRORS_WARNING=100
readonly NET_ERRORS_CRITICAL=1000
readonly NET_DROPPED_WARNING=100
readonly NET_RETRANSMIT_WARNING=1000

# Thresholds - Services
readonly FAILED_SERVICES_CRITICAL=1
readonly ZOMBIE_PROCESSES_WARNING=5
# Note: DEFUNCT_PROCESSES are counted as ZOMBIE_PROCESSES (they're the same)
readonly D_STATE_PROCESSES_WARNING=2

# Scoring weights (must sum to 100)
readonly CPU_WEIGHT=20
readonly MEMORY_WEIGHT=30
readonly DISK_WEIGHT=20
readonly NETWORK_WEIGHT=10
readonly SERVICES_WEIGHT=20

# Required commands
readonly REQUIRED_COMMANDS=(
    "jq"
    "bc"
    "awk"
    "date"
    "df"
    "free"
    "uptime"
    "nproc"
)

# Optional commands
readonly OPTIONAL_COMMANDS=(
    "iostat"
    "lsof"
    "netstat"
)

# Global variables
declare -A METRICS=()
declare -a ALERTS=()
declare -a RECOMMENDATIONS=()
declare -a COLLECTION_ERRORS=()

# Output format (default: markdown)
OUTPUT_FORMAT="markdown"
OUTPUT_FILE=""
QUIET_MODE=false
SCORE_ONLY=false
NO_COLOR=false
DEBUG_MODE=false

#######################################
# C1: Cleanup and signal handling
#######################################

cleanup() {
    local exit_code=$?

    # Kill any remaining child processes (if any were spawned)
    jobs -p 2>/dev/null | xargs -r kill 2>/dev/null || true

    return $exit_code
}

# Set up traps
trap cleanup EXIT SIGTERM SIGINT

#######################################
# Logging functions
#######################################

log_error() {
    # S1: Errors always output (critical for debugging)
    # Use --quiet with 2>/dev/null in cron if suppression needed
    echo "[$(date -Iseconds)] ERROR: $*" >&2
}

log_warn() {
    # S1: Warnings respect QUIET_MODE (prevent cron email spam)
    if [[ "$QUIET_MODE" == "false" ]]; then
        echo "[$(date -Iseconds)] WARN: $*" >&2
    fi
}

log_info() {
    if [[ "$QUIET_MODE" == "false" && "$DEBUG_MODE" == "true" ]]; then
        echo "[$(date -Iseconds)] INFO: $*" >&2
    fi
}

log_debug() {
    if [[ "$DEBUG_MODE" == "true" ]]; then
        echo "[$(date -Iseconds)] DEBUG: $*" >&2
    fi
}

#######################################
# Dependency validation
#######################################

check_dependencies() {
    local missing=()

    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        log_error "Install with: apt install -y jq bc"
        exit 2
    fi

    # Check optional dependencies
    for cmd in "${OPTIONAL_COMMANDS[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_warn "Optional command missing: $cmd (some metrics will be unavailable)"
        fi
    done
}

#######################################
# Sudo validation
#######################################

validate_sudo() {
    # Check if we can run specific commands with sudo
    local sudo_commands=("dmesg" "journalctl")

    for cmd in "${sudo_commands[@]}"; do
        if ! sudo -n "$cmd" --help &>/dev/null 2>&1; then
            log_warn "Cannot run 'sudo $cmd' without password (some metrics will be unavailable)"
        fi
    done
}

#######################################
# Calculate component score (0-100)
# Arguments:
#   $1 - current value
#   $2 - warning threshold
#   $3 - critical threshold
# Returns:
#   Score between 0-100
#######################################

calculate_component_score() {
    local value=$1
    local warning=$2
    local critical=$3

    # C4: Guard against division by zero
    if (( $(echo "$critical == 0" | bc -l) )); then
        log_warn "calculate_component_score: critical threshold is 0, returning default score"
        echo 50
        return 0
    fi

    if (( $(echo "$value < $warning" | bc -l) )); then
        echo 100
    elif (( $(echo "$value < $critical" | bc -l) )); then
        # Linear interpolation between warning and critical
        local range
        range=$(echo "scale=2; $critical - $warning" | bc)
        if (( $(echo "$range == 0" | bc -l) )); then
            echo 75  # warning == critical edge case
        else
            echo "scale=0; 100 - ((($value - $warning) / $range) * 50)" | bc
        fi
    else
        # Beyond critical: 0-50 based on how far over
        local penalty
        penalty=$(echo "scale=0; 50 - ((($value - $critical) / $critical) * 50)" | bc)
        if (( $(echo "$penalty < 0" | bc -l) )); then
            echo 0
        else
            echo "$penalty"
        fi
    fi
}

#######################################
# Add alert to alerts array
#######################################

add_alert() {
    local severity="$1"
    local component="$2"
    local message="$3"
    local value="$4"
    local threshold="$5"

    ALERTS+=("$(jq -nc \
        --arg sev "$severity" \
        --arg comp "$component" \
        --arg msg "$message" \
        --arg val "$value" \
        --arg thresh "$threshold" \
        '{severity: $sev, component: $comp, message: $msg, value: ($val | tonumber), threshold: ($thresh | tonumber)}')")
}

#######################################
# Collect CPU metrics
# Outputs: JSON object with CPU metrics
# Returns: 0 on success, 1 on failure
#######################################

collect_cpu_metrics() {
    local load_1min load_5min load_15min
    local cpu_count cpu_usage iowait steal

    # Read load average from /proc
    local loadavg_line
    if ! loadavg_line=$(cat /proc/loadavg); then
        log_error "Failed to read /proc/loadavg"
        return 1
    fi

    load_1min=$(echo "$loadavg_line" | awk '{print $1}')
    load_5min=$(echo "$loadavg_line" | awk '{print $2}')
    load_15min=$(echo "$loadavg_line" | awk '{print $3}')

    # Get CPU count
    cpu_count=$(nproc) || return 1

    # Calculate CPU usage from /proc/stat
    # Get first two lines to calculate delta
    local stat1 stat2
    stat1=$(grep '^cpu ' /proc/stat) || return 1
    sleep 1
    stat2=$(grep '^cpu ' /proc/stat) || return 1

    local -a vals1 vals2
    read -ra vals1 <<< "$stat1"
    read -ra vals2 <<< "$stat2"

    # S2: Calculate total dynamically based on available fields
    # Fields: user nice system idle iowait irq softirq steal guest guest_nice
    local total1=0 total2=0
    local max_fields=${#vals1[@]}
    # Limit to actual fields present (skip field 0 which is 'cpu' label)
    if [[ $max_fields -gt 10 ]]; then
        max_fields=10
    fi

    for ((i=1; i<max_fields; i++)); do
        total1=$((total1 + ${vals1[i]:-0}))
        total2=$((total2 + ${vals2[i]:-0}))
    done

    # P4 & C8: Calculate deltas for idle, iowait, and steal
    local idle1 idle2 iowait1 iowait2 steal1 steal2
    idle1=${vals1[4]:-0}
    idle2=${vals2[4]:-0}
    iowait1=${vals1[5]:-0}
    iowait2=${vals2[5]:-0}
    steal1=${vals1[8]:-0}
    steal2=${vals2[8]:-0}

    local total_delta=$((total2 - total1))
    local idle_delta=$((idle2 - idle1))
    local iowait_delta=$((iowait2 - iowait1))
    local steal_delta=$((steal2 - steal1))

    if [[ $total_delta -gt 0 ]]; then
        cpu_usage=$(echo "scale=1; 100 * ($total_delta - $idle_delta) / $total_delta" | bc)
        iowait=$(echo "scale=1; 100 * $iowait_delta / $total_delta" | bc)
        steal=$(echo "scale=1; 100 * $steal_delta / $total_delta" | bc)
    else
        cpu_usage="0.0"
        iowait="0.0"
        steal="0.0"
    fi

    jq -nc \
        --arg l1 "$load_1min" \
        --arg l5 "$load_5min" \
        --arg l15 "$load_15min" \
        --arg cores "$cpu_count" \
        --arg usage "$cpu_usage" \
        --arg iow "$iowait" \
        --arg st "$steal" \
        '{
            load_1min: ($l1 | tonumber),
            load_5min: ($l5 | tonumber),
            load_15min: ($l15 | tonumber),
            cores: ($cores | tonumber),
            usage_percent: ($usage | tonumber),
            iowait_percent: ($iow | tonumber),
            steal_percent: ($st | tonumber)
        }'
}

#######################################
# Analyze CPU metrics and generate score
#######################################

analyze_cpu_metrics() {
    local cpu_json="$1"

    local load_1min cores usage_percent iowait_percent steal_percent
    load_1min=$(echo "$cpu_json" | jq -r '.load_1min // 0')
    cores=$(echo "$cpu_json" | jq -r '.cores // 1')
    usage_percent=$(echo "$cpu_json" | jq -r '.usage_percent // 0')
    iowait_percent=$(echo "$cpu_json" | jq -r '.iowait_percent // 0')
    steal_percent=$(echo "$cpu_json" | jq -r '.steal_percent // 0')

    # Calculate load as percentage of cores
    local load_percent
    load_percent=$(echo "scale=1; 100 * $load_1min / $cores" | bc)

    # Check thresholds
    if (( $(echo "$load_percent >= $CPU_LOAD_CRITICAL" | bc -l) )); then
        add_alert "critical" "cpu" "CPU load critical" "$load_percent" "$CPU_LOAD_CRITICAL"
    elif (( $(echo "$load_percent >= $CPU_LOAD_WARNING" | bc -l) )); then
        add_alert "warning" "cpu" "CPU load high" "$load_percent" "$CPU_LOAD_WARNING"
    fi

    if (( $(echo "$iowait_percent >= $CPU_IOWAIT_CRITICAL" | bc -l) )); then
        add_alert "critical" "cpu" "I/O wait time critical" "$iowait_percent" "$CPU_IOWAIT_CRITICAL"
        RECOMMENDATIONS+=("Check disk I/O performance with iostat")
    elif (( $(echo "$iowait_percent >= $CPU_IOWAIT_WARNING" | bc -l) )); then
        add_alert "warning" "cpu" "I/O wait time high" "$iowait_percent" "$CPU_IOWAIT_WARNING"
    fi

    if (( $(echo "$steal_percent >= $CPU_STEAL_WARNING" | bc -l) )); then
        add_alert "warning" "cpu" "CPU steal time detected" "$steal_percent" "$CPU_STEAL_WARNING"
        RECOMMENDATIONS+=("Contact hosting provider about CPU contention")
    fi

    # Calculate CPU score
    local load_score iowait_score
    load_score=$(calculate_component_score "$load_percent" "$CPU_LOAD_WARNING" "$CPU_LOAD_CRITICAL")
    iowait_score=$(calculate_component_score "$iowait_percent" "$CPU_IOWAIT_WARNING" "$CPU_IOWAIT_CRITICAL")

    # Average the subscores
    echo "scale=0; ($load_score + $iowait_score) / 2" | bc
}

#######################################
# Collect Memory metrics
#######################################

collect_memory_metrics() {
    local total_kb available_kb
    local swap_total_kb swap_used_kb

    # Parse /proc/meminfo
    local meminfo
    meminfo=$(cat /proc/meminfo) || return 1

    total_kb=$(echo "$meminfo" | awk '/^MemTotal:/ {print $2}')
    available_kb=$(echo "$meminfo" | awk '/^MemAvailable:/ {print $2}')

    # S4: Fallback for old kernels without MemAvailable (< Linux 3.14)
    if [[ -z "$available_kb" || "$available_kb" == "0" ]]; then
        local free_kb buffers_kb cached_kb
        free_kb=$(echo "$meminfo" | awk '/^MemFree:/ {print $2}')
        buffers_kb=$(echo "$meminfo" | awk '/^Buffers:/ {print $2}')
        cached_kb=$(echo "$meminfo" | awk '/^Cached:/ {print $2}')
        available_kb=$((free_kb + buffers_kb + cached_kb))
        log_debug "MemAvailable not found, using MemFree+Buffers+Cached"
    fi

    swap_total_kb=$(echo "$meminfo" | awk '/^SwapTotal:/ {print $2}')
    swap_used_kb=$(echo "$meminfo" | awk '/^SwapFree:/ {print $2}')
    swap_used_kb=$((swap_total_kb - swap_used_kb))

    # Convert to MB
    local total_mb available_mb swap_total_mb swap_used_mb
    total_mb=$((total_kb / 1024))
    available_mb=$((available_kb / 1024))
    swap_total_mb=$((swap_total_kb / 1024))
    swap_used_mb=$((swap_used_kb / 1024))

    # Calculate used memory
    local used_mb=$((total_mb - available_mb))

    # Calculate percentages
    local usage_percent swap_percent
    usage_percent=$(echo "scale=1; 100 * $used_mb / $total_mb" | bc)
    if [[ $swap_total_mb -gt 0 ]]; then
        swap_percent=$(echo "scale=1; 100 * $swap_used_mb / $swap_total_mb" | bc)
    else
        swap_percent="0.0"
    fi

    # P5: Check for OOM events in last 24 hours (requires sudo)
    local oom_events=0
    if sudo -n dmesg &>/dev/null 2>&1; then
        # Try to use timestamp-based filtering if available
        if sudo dmesg --time-format=iso &>/dev/null 2>&1; then
            local since_time
            since_time=$(date -d '24 hours ago' '+%Y-%m-%d' 2>/dev/null || date -d '1 day ago' '+%Y-%m-%d')
            oom_events=$(sudo dmesg --time-format=iso 2>/dev/null | \
                awk -v since="$since_time" '$1 >= since' | \
                grep -c "Out of memory" || true)
        else
            # Fallback: use journalctl if available
            if command -v journalctl &>/dev/null && sudo -n journalctl --version &>/dev/null 2>&1; then
                oom_events=$(sudo journalctl --since "24 hours ago" --dmesg 2>/dev/null | \
                    grep -c "Out of memory" || true)
            else
                # Last resort: just count recent dmesg (limited buffer)
                oom_events=$(sudo dmesg | grep -c "Out of memory" || true)
            fi
        fi
    fi

    jq -nc \
        --arg total "$total_mb" \
        --arg used "$used_mb" \
        --arg avail "$available_mb" \
        --arg usage "$usage_percent" \
        --arg swaptotal "$swap_total_mb" \
        --arg swapused "$swap_used_mb" \
        --arg swappct "$swap_percent" \
        --arg oom "$oom_events" \
        '{
            total_mb: ($total | tonumber),
            used_mb: ($used | tonumber),
            available_mb: ($avail | tonumber),
            usage_percent: ($usage | tonumber),
            swap_total_mb: ($swaptotal | tonumber),
            swap_used_mb: ($swapused | tonumber),
            swap_percent: ($swappct | tonumber),
            oom_events: ($oom | tonumber)
        }'
}

#######################################
# Analyze Memory metrics
#######################################

analyze_memory_metrics() {
    local mem_json="$1"

    local usage_percent swap_used_mb swap_percent oom_events
    usage_percent=$(echo "$mem_json" | jq -r '.usage_percent // 0')
    swap_used_mb=$(echo "$mem_json" | jq -r '.swap_used_mb // 0')
    swap_percent=$(echo "$mem_json" | jq -r '.swap_percent // 0')
    oom_events=$(echo "$mem_json" | jq -r '.oom_events // 0')

    # Check thresholds
    if (( $(echo "$usage_percent >= $MEM_USAGE_CRITICAL" | bc -l) )); then
        add_alert "critical" "memory" "Memory usage critical" "$usage_percent" "$MEM_USAGE_CRITICAL"
        RECOMMENDATIONS+=("Consider adding more RAM or reducing memory usage")
    elif (( $(echo "$usage_percent >= $MEM_USAGE_WARNING" | bc -l) )); then
        add_alert "warning" "memory" "Memory usage high" "$usage_percent" "$MEM_USAGE_WARNING"
    fi

    if (( $(echo "$swap_percent >= $SWAP_USAGE_CRITICAL" | bc -l) )); then
        add_alert "critical" "memory" "Swap usage critical" "$swap_percent" "$SWAP_USAGE_CRITICAL"
        RECOMMENDATIONS+=("System is heavily swapping - add RAM immediately")
    elif [[ $swap_used_mb -gt 0 ]]; then
        add_alert "warning" "memory" "Swap in use" "$swap_used_mb" "0"
        RECOMMENDATIONS+=("Consider disabling swap or adding RAM")
    fi

    if [[ $oom_events -gt 0 ]]; then
        add_alert "critical" "memory" "OOM killer events detected" "$oom_events" "$OOM_EVENTS_CRITICAL"
        RECOMMENDATIONS+=("Review OOM events in dmesg - processes were killed")
    fi

    # Calculate memory score
    local mem_score swap_score
    mem_score=$(calculate_component_score "$usage_percent" "$MEM_USAGE_WARNING" "$MEM_USAGE_CRITICAL")
    swap_score=$(calculate_component_score "$swap_percent" "$SWAP_USAGE_WARNING" "$SWAP_USAGE_CRITICAL")

    # OOM events severely impact score
    if [[ $oom_events -gt 0 ]]; then
        echo "scale=0; ($mem_score + $swap_score) / 2 - ($oom_events * 20)" | bc | awk '{print ($1 < 0) ? 0 : $1}'
    else
        echo "scale=0; ($mem_score + $swap_score) / 2" | bc
    fi
}

#######################################
# Collect Disk metrics
#######################################

collect_disk_metrics() {
    local filesystems=()

    # C2: Use reliable df parsing with --output option
    # S7: Add timeout for NFS filesystem checks
    while IFS='|' read -r device mount usage inodes; do
        # Skip empty lines
        [[ -z "$device" ]] && continue

        # Remove % signs
        usage=${usage%\%}
        inodes=${inodes%\%}

        filesystems+=("$(jq -nc \
            --arg dev "$device" \
            --arg mnt "$mount" \
            --arg use "$usage" \
            --arg ino "$inodes" \
            '{device: $dev, mount: $mnt, usage_percent: ($use | tonumber), inodes_percent: ($ino | tonumber)}')")
    done < <(
        # Timeout wrapper for df (prevents NFS hangs)
        timeout 5s df --output=source,target,pcent,ipcent 2>/dev/null | \
        grep '^/dev/' | grep -v '/boot' | \
        awk 'NR>1 {printf "%s|%s|%s|%s\n", $1, $2, $3, $4}'
    )

    # Get I/O wait from earlier CPU collection (reuse)
    local iowait_percent="0.0"

    # P8: Get IOPS if iostat available (with timeout)
    local iops="0"
    if command -v iostat &>/dev/null; then
        iops=$(timeout 3s iostat -d -x 1 2 2>/dev/null | tail -n +4 | awk 'NR>1 {sum+=$4} END {print int(sum)}' || echo 0)
    fi

    # Build JSON array
    local fs_json
    if [[ ${#filesystems[@]} -eq 0 ]]; then
        fs_json="[]"
    else
        fs_json=$(printf '%s\n' "${filesystems[@]}" | jq -s '.')
    fi

    jq -nc \
        --argjson fs "$fs_json" \
        --arg iow "$iowait_percent" \
        --arg io "$iops" \
        '{
            filesystems: $fs,
            iowait_percent: ($iow | tonumber),
            iops: ($io | tonumber)
        }'
}

#######################################
# Analyze Disk metrics
#######################################

analyze_disk_metrics() {
    local disk_json="$1"

    local filesystems
    filesystems=$(echo "$disk_json" | jq -r '.filesystems')

    local critical_count=0
    local warning_count=0
    local worst_score=100

    # Check each filesystem
    while IFS= read -r fs; do
        local mount usage_percent inodes_percent
        mount=$(echo "$fs" | jq -r '.mount')
        usage_percent=$(echo "$fs" | jq -r '.usage_percent')
        inodes_percent=$(echo "$fs" | jq -r '.inodes_percent')

        # Disk usage checks
        if (( $(echo "$usage_percent >= $DISK_USAGE_CRITICAL" | bc -l) )); then
            add_alert "critical" "disk" "Disk usage critical on $mount" "$usage_percent" "$DISK_USAGE_CRITICAL"
            ((critical_count++))
        elif (( $(echo "$usage_percent >= $DISK_USAGE_WARNING" | bc -l) )); then
            add_alert "warning" "disk" "Disk usage high on $mount" "$usage_percent" "$DISK_USAGE_WARNING"
            ((warning_count++))
        fi

        # Inode checks
        if (( $(echo "$inodes_percent >= $INODE_USAGE_CRITICAL" | bc -l) )); then
            add_alert "critical" "disk" "Inode usage critical on $mount" "$inodes_percent" "$INODE_USAGE_CRITICAL"
        elif (( $(echo "$inodes_percent >= $INODE_USAGE_WARNING" | bc -l) )); then
            add_alert "warning" "disk" "Inode usage high on $mount" "$inodes_percent" "$INODE_USAGE_WARNING"
        fi

        # Calculate score for this filesystem
        local fs_score
        fs_score=$(calculate_component_score "$usage_percent" "$DISK_USAGE_WARNING" "$DISK_USAGE_CRITICAL")

        if (( $(echo "$fs_score < $worst_score" | bc -l) )); then
            worst_score=$fs_score
        fi
    done < <(echo "$filesystems" | jq -c '.[]')

    # Add recommendations
    if [[ $critical_count -gt 0 ]] || [[ $warning_count -gt 0 ]]; then
        RECOMMENDATIONS+=("Investigate disk usage growth - use 'du -sh /*' to find large directories")
    fi

    echo "$worst_score"
}

#######################################
# Collect Network metrics
# NOTE (P6): Network counters are cumulative since boot.
# For rate-based monitoring, implement baseline storage
# or calculate per-second rates. Current implementation
# is suitable for short-uptime systems or trending.
#######################################

collect_network_metrics() {
    local interfaces=()

    # Get network interface statistics from /sys (cumulative counters)
    for iface_dir in /sys/class/net/*; do
        local iface
        iface=$(basename "$iface_dir")

        # Skip loopback
        [[ "$iface" == "lo" ]] && continue

        # Check if interface is real (not virtual)
        [[ -d "$iface_dir/device" ]] || continue

        local rx_errors tx_errors rx_dropped tx_dropped rx_bytes tx_bytes
        rx_errors=$(cat "$iface_dir/statistics/rx_errors" 2>/dev/null || echo 0)
        tx_errors=$(cat "$iface_dir/statistics/tx_errors" 2>/dev/null || echo 0)
        rx_dropped=$(cat "$iface_dir/statistics/rx_dropped" 2>/dev/null || echo 0)
        tx_dropped=$(cat "$iface_dir/statistics/tx_dropped" 2>/dev/null || echo 0)
        rx_bytes=$(cat "$iface_dir/statistics/rx_bytes" 2>/dev/null || echo 0)
        tx_bytes=$(cat "$iface_dir/statistics/tx_bytes" 2>/dev/null || echo 0)

        interfaces+=("$(jq -nc \
            --arg name "$iface" \
            --arg rxerr "$rx_errors" \
            --arg txerr "$tx_errors" \
            --arg rxdrop "$rx_dropped" \
            --arg txdrop "$tx_dropped" \
            --arg rxbytes "$rx_bytes" \
            --arg txbytes "$tx_bytes" \
            '{
                name: $name,
                rx_errors: ($rxerr | tonumber),
                tx_errors: ($txerr | tonumber),
                rx_dropped: ($rxdrop | tonumber),
                tx_dropped: ($txdrop | tonumber),
                rx_bytes_sec: ($rxbytes | tonumber),
                tx_bytes_sec: ($txbytes | tonumber)
            }')")
    done

    # P6: Get TCP retransmits (cumulative) and normalize by uptime
    local retransmits=0
    local uptime_days=1
    if command -v netstat &>/dev/null; then
        retransmits=$(netstat -s 2>/dev/null | awk '/segments retransmitted/ {print $1}' || echo 0)
        # Get uptime in days for normalization
        uptime_days=$(awk '{print int($1/86400)+1}' /proc/uptime)
        # Calculate daily average retransmits
        retransmits=$((retransmits / uptime_days))
    fi

    # Get established connections
    local connections=0
    if command -v ss &>/dev/null; then
        connections=$(ss -tan state established 2>/dev/null | wc -l)
        ((connections--)) || true  # Remove header line
    fi

    local iface_json
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        iface_json="[]"
    else
        iface_json=$(printf '%s\n' "${interfaces[@]}" | jq -s '.')
    fi

    jq -nc \
        --argjson ifaces "$iface_json" \
        --arg retr "$retransmits" \
        --arg conn "$connections" \
        '{
            interfaces: $ifaces,
            retransmits: ($retr | tonumber),
            connections_established: ($conn | tonumber)
        }'
}

#######################################
# Analyze Network metrics
#######################################

analyze_network_metrics() {
    local net_json="$1"

    local interfaces retransmits
    interfaces=$(echo "$net_json" | jq -r '.interfaces // []')
    retransmits=$(echo "$net_json" | jq -r '.retransmits // 0')

    local total_errors=0
    local total_dropped=0
    local worst_score=100

    # Check each interface
    while IFS= read -r iface; do
        local name rx_errors tx_errors rx_dropped tx_dropped
        name=$(echo "$iface" | jq -r '.name')
        rx_errors=$(echo "$iface" | jq -r '.rx_errors')
        tx_errors=$(echo "$iface" | jq -r '.tx_errors')
        rx_dropped=$(echo "$iface" | jq -r '.rx_dropped')
        tx_dropped=$(echo "$iface" | jq -r '.tx_dropped')

        local iface_errors=$((rx_errors + tx_errors))
        local iface_dropped=$((rx_dropped + tx_dropped))

        total_errors=$((total_errors + iface_errors))
        total_dropped=$((total_dropped + iface_dropped))

        # Check thresholds per interface
        if [[ $iface_errors -ge $NET_ERRORS_CRITICAL ]]; then
            add_alert "critical" "network" "High error rate on $name" "$iface_errors" "$NET_ERRORS_CRITICAL"
        elif [[ $iface_errors -ge $NET_ERRORS_WARNING ]]; then
            add_alert "warning" "network" "Elevated errors on $name" "$iface_errors" "$NET_ERRORS_WARNING"
        fi

        if [[ $iface_dropped -ge $NET_DROPPED_WARNING ]]; then
            add_alert "warning" "network" "Dropped packets on $name" "$iface_dropped" "$NET_DROPPED_WARNING"
        fi
    done < <(echo "$interfaces" | jq -c '.[]')

    # Check retransmits
    if [[ $retransmits -ge $NET_RETRANSMIT_WARNING ]]; then
        add_alert "warning" "network" "High TCP retransmit rate" "$retransmits" "$NET_RETRANSMIT_WARNING"
        RECOMMENDATIONS+=("Check network latency and packet loss")
    fi

    # Calculate network score
    local error_score drop_score
    error_score=$(calculate_component_score "$total_errors" "$NET_ERRORS_WARNING" "$NET_ERRORS_CRITICAL")
    drop_score=$(calculate_component_score "$total_dropped" "$NET_DROPPED_WARNING" "$((NET_DROPPED_WARNING * 2))")

    echo "scale=0; ($error_score + $drop_score) / 2" | bc
}

#######################################
# Collect Services metrics
#######################################

collect_services_metrics() {
    local failed_units=()

    # P8: Get failed systemd units (with timeout)
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        failed_units+=("\"$line\"")
    done < <(timeout 3s systemctl --state=failed --no-pager --no-legend 2>/dev/null | awk '{print $1}')

    # P9 & C3: Count zombie and defunct processes efficiently (single ps call)
    # Note: Defunct processes ARE zombies, so we only count zombies once
    local zombie_count d_state_count
    # Temporarily restore default IFS for read to split on spaces
    IFS=' ' read -r zombie_count d_state_count < <(
        ps aux | awk '
            $8 ~ /Z/ {zombie++}
            $8 ~ /D/ {dstate++}
            END {print zombie+0, dstate+0}
        '
    )
    IFS=$'\n\t'  # Restore script IFS

    # Get top memory processes
    local top_procs=()
    while IFS= read -r line; do
        local pid mem_kb comm
        pid=$(echo "$line" | awk '{print $2}')
        mem_kb=$(echo "$line" | awk '{print $6}')
        comm=$(echo "$line" | awk '{print $11}')

        local mem_mb=$((mem_kb / 1024))

        top_procs+=("$(jq -nc \
            --arg name "$comm" \
            --arg p "$pid" \
            --arg mem "$mem_mb" \
            '{name: $name, pid: ($p | tonumber), mem_mb: ($mem | tonumber)}')")
    done < <(ps aux --sort=-%mem | head -11 | tail -10)

    local failed_json top_json
    if [[ ${#failed_units[@]} -eq 0 ]]; then
        failed_json="[]"
    else
        failed_json=$(printf '%s\n' "${failed_units[@]}" | jq -s '.')
    fi

    if [[ ${#top_procs[@]} -eq 0 ]]; then
        top_json="[]"
    else
        top_json=$(printf '%s\n' "${top_procs[@]}" | jq -s '.')
    fi

    jq -nc \
        --argjson failed "$failed_json" \
        --arg zomb "$zombie_count" \
        --arg dstate "$d_state_count" \
        --argjson top "$top_json" \
        '{
            failed_units: $failed,
            zombie_processes: ($zomb | tonumber),
            d_state_processes: ($dstate | tonumber),
            top_memory_processes: $top
        }'
}

#######################################
# Analyze Services metrics
#######################################

analyze_services_metrics() {
    local svc_json="$1"

    local failed_count zombie_count d_state_count
    failed_count=$(echo "$svc_json" | jq -r '.failed_units | length // 0')
    zombie_count=$(echo "$svc_json" | jq -r '.zombie_processes // 0')
    d_state_count=$(echo "$svc_json" | jq -r '.d_state_processes // 0')

    local score=100

    # Failed services are critical
    if [[ $failed_count -gt 0 ]]; then
        add_alert "critical" "services" "Failed systemd units detected" "$failed_count" "$FAILED_SERVICES_CRITICAL"
        RECOMMENDATIONS+=("Check failed services with: systemctl --state=failed")
        score=$((score - (failed_count * 20)))
    fi

    # Zombie processes (C3: defunct processes are zombies, counted together)
    if [[ $zombie_count -ge $ZOMBIE_PROCESSES_WARNING ]]; then
        add_alert "warning" "services" "Zombie processes detected" "$zombie_count" "$ZOMBIE_PROCESSES_WARNING"
        RECOMMENDATIONS+=("Investigate parent processes not reaping children")
        score=$((score - (zombie_count * 2)))
    fi

    # D-state processes (uninterruptible sleep)
    if [[ $d_state_count -ge $D_STATE_PROCESSES_WARNING ]]; then
        add_alert "warning" "services" "Processes in uninterruptible sleep" "$d_state_count" "$D_STATE_PROCESSES_WARNING"
        RECOMMENDATIONS+=("Check for I/O or kernel issues causing D-state processes")
        score=$((score - (d_state_count * 3)))
    fi

    # Ensure score doesn't go negative
    if [[ $score -lt 0 ]]; then
        score=0
    fi

    echo "$score"
}

#######################################
# Calculate overall health score
#######################################

calculate_health_score() {
    local cpu_score=$1
    local mem_score=$2
    local disk_score=$3
    local net_score=$4
    local svc_score=$5

    local weighted_score
    weighted_score=$(echo "scale=0; ($cpu_score * $CPU_WEIGHT + $mem_score * $MEMORY_WEIGHT + $disk_score * $DISK_WEIGHT + $net_score * $NETWORK_WEIGHT + $svc_score * $SERVICES_WEIGHT) / 100" | bc)

    echo "$weighted_score"
}

#######################################
# Determine health status from score
#######################################

get_health_status() {
    local score=$1

    if [[ $score -ge 80 ]]; then
        echo "healthy"
    elif [[ $score -ge 50 ]]; then
        echo "warning"
    else
        echo "critical"
    fi
}

#######################################
# S8: Deduplicate recommendations array
#######################################

deduplicate_recommendations() {
    if [[ ${#RECOMMENDATIONS[@]} -eq 0 ]]; then
        return
    fi

    # Use associative array to track unique recommendations
    declare -A seen
    local -a unique_recs=()

    for rec in "${RECOMMENDATIONS[@]}"; do
        if [[ -z "${seen[$rec]}" ]]; then
            seen[$rec]=1
            unique_recs+=("$rec")
        fi
    done

    # Replace global array with deduplicated version
    RECOMMENDATIONS=("${unique_recs[@]}")
}

#######################################
# Generate JSON output
#######################################

generate_json_output() {
    local timestamp hostname status score
    local cpu_json mem_json disk_json net_json svc_json

    timestamp="$1"
    hostname="$2"
    status="$3"
    score="$4"
    cpu_json="$5"
    mem_json="$6"
    disk_json="$7"
    net_json="$8"
    svc_json="$9"

    # S8: Deduplicate recommendations before output
    deduplicate_recommendations

    local alerts_json recs_json
    if [[ ${#ALERTS[@]} -eq 0 ]]; then
        alerts_json="[]"
    else
        alerts_json=$(printf '%s\n' "${ALERTS[@]}" | jq -s '.')
    fi

    if [[ ${#RECOMMENDATIONS[@]} -eq 0 ]]; then
        recs_json="[]"
    else
        recs_json=$(printf '%s\n' "${RECOMMENDATIONS[@]}" | jq -Rn '[inputs]')
    fi

    jq -nc \
        --arg ts "$timestamp" \
        --arg host "$hostname" \
        --arg st "$status" \
        --arg sc "$score" \
        --arg ver "$SCRIPT_VERSION" \
        --argjson cpu "$cpu_json" \
        --argjson mem "$mem_json" \
        --argjson disk "$disk_json" \
        --argjson net "$net_json" \
        --argjson svc "$svc_json" \
        --argjson alerts "$alerts_json" \
        --argjson recs "$recs_json" \
        '{
            schema_version: "1.0.0",
            script_version: $ver,
            timestamp: $ts,
            hostname: $host,
            status: $st,
            score: ($sc | tonumber),
            metrics: {
                cpu: $cpu,
                memory: $mem,
                disk: $disk,
                network: $net,
                services: $svc
            },
            alerts: $alerts,
            recommendations: $recs
        }'
}

#######################################
# Generate Markdown output
#######################################

generate_markdown_output() {
    local json_output="$1"

    local hostname status score timestamp
    hostname=$(echo "$json_output" | jq -r '.hostname')
    status=$(echo "$json_output" | jq -r '.status')
    score=$(echo "$json_output" | jq -r '.score')
    timestamp=$(echo "$json_output" | jq -r '.timestamp')

    local status_icon
    case "$status" in
        healthy) status_icon="✓" ;;
        warning) status_icon="⚠" ;;
        critical) status_icon="✗" ;;
    esac

    echo "# System Health Report - $hostname"
    echo "**Status**: $status_icon ${status^^} (Score: $score/100)"
    echo "**Generated**: $timestamp"
    echo ""

    # Critical alerts
    local critical_alerts
    critical_alerts=$(echo "$json_output" | jq -r '.alerts[] | select(.severity=="critical")')
    if [[ -n "$critical_alerts" ]]; then
        echo "## 🚨 Critical Alerts"
        echo "$critical_alerts" | jq -r '"- **" + .component + "**: " + .message + " (" + (.value|tostring) + "%)"'
        echo ""
    else
        echo "## 🚨 Critical Alerts"
        echo "None"
        echo ""
    fi

    # Warnings
    local warning_alerts
    warning_alerts=$(echo "$json_output" | jq -r '.alerts[] | select(.severity=="warning")')
    if [[ -n "$warning_alerts" ]]; then
        echo "## ⚠️ Warnings"
        echo "$warning_alerts" | jq -r '"- **" + .component + "**: " + .message + " (" + (.value|tostring) + "%)"'
        echo ""
    fi

    # Metrics summary
    echo "## 📊 Metrics Summary"
    echo ""
    echo "### CPU"
    echo "$json_output" | jq -r '"- Load Average: " + (.metrics.cpu.load_1min|tostring) + " / " + (.metrics.cpu.load_5min|tostring) + " / " + (.metrics.cpu.load_15min|tostring) + " (" + (.metrics.cpu.cores|tostring) + " cores)"'
    echo "$json_output" | jq -r '"- Usage: " + (.metrics.cpu.usage_percent|tostring) + "%"'
    echo "$json_output" | jq -r '"- I/O Wait: " + (.metrics.cpu.iowait_percent|tostring) + "%"'
    echo ""

    echo "### Memory"
    echo "$json_output" | jq -r '"- Used: " + ((.metrics.memory.used_mb/1024)|floor|tostring) + "GB / " + ((.metrics.memory.total_mb/1024)|floor|tostring) + "GB (" + (.metrics.memory.usage_percent|tostring) + "%)"'
    echo "$json_output" | jq -r '"- Swap: " + (.metrics.memory.swap_used_mb|tostring) + "MB / " + (.metrics.memory.swap_total_mb|tostring) + "MB (" + (.metrics.memory.swap_percent|tostring) + "%)"'
    echo ""

    echo "### Disk"
    echo "$json_output" | jq -r '.metrics.disk.filesystems[] | "- " + .mount + ": " + (.usage_percent|tostring) + "%" + (if .usage_percent >= 80 then " ⚠️" else "" end)'
    echo ""

    echo "### Services"
    echo "$json_output" | jq -r '"- Failed Units: " + (.metrics.services.failed_units|length|tostring)'
    echo "$json_output" | jq -r '"- Zombie Processes: " + (.metrics.services.zombie_processes|tostring)'
    echo ""

    # Recommendations
    local recs
    recs=$(echo "$json_output" | jq -r '.recommendations | length')
    if [[ $recs -gt 0 ]]; then
        echo "## 💡 Recommendations"
        echo "$json_output" | jq -r '.recommendations[] | "1. " + .'
        echo ""
    fi
}

#######################################
# Show help
#######################################

show_help() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Production-grade system health analyzer for Debian 12

OPTIONS:
    -h, --help              Show this help message
    -v, --version           Show version information
    -q, --quiet             Suppress output (exit code only)
    -j, --json              Output JSON only (no markdown)
    -f, --format FORMAT     Output format: json|markdown
    -o, --output FILE       Write output to file instead of stdout
    -s, --score-only        Output health score only
    --no-color              Disable colored output
    --debug                 Enable debug logging

EXIT CODES:
    0   System healthy (score >= 80)
    1   Warnings detected (score 50-79)
    2   Critical issues (score < 50) or script error

EXAMPLES:
    # Interactive mode with markdown report
    ./$SCRIPT_NAME

    # JSON output for monitoring system
    ./$SCRIPT_NAME --json | jq '.score'

    # Quiet mode for cron (exit code only)
    ./$SCRIPT_NAME --quiet || alert-team "Health check failed"

EOF
}

#######################################
# Main execution
#######################################

main() {
    # P1: Prevent execution as root
    if [[ $EUID -eq 0 ]]; then
        log_error "This script must NOT be run as root"
        log_error "Run as a non-root user with sudo privileges"
        exit 2
    fi

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                echo "$SCRIPT_NAME version $SCRIPT_VERSION"
                exit 0
                ;;
            -q|--quiet)
                QUIET_MODE=true
                shift
                ;;
            -j|--json)
                OUTPUT_FORMAT="json"
                shift
                ;;
            -f|--format)
                OUTPUT_FORMAT="$2"
                shift 2
                ;;
            -o|--output)
                OUTPUT_FILE="$2"
                shift 2
                ;;
            -s|--score-only)
                SCORE_ONLY=true
                shift
                ;;
            --no-color)
                NO_COLOR=true
                shift
                ;;
            --debug)
                DEBUG_MODE=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 2
                ;;
        esac
    done

    # Validation
    check_dependencies
    validate_sudo

    # Collect all metrics sequentially
    # NOTE: Parallel collection (P7) reverted due to subshell execution issues
    # TODO: Re-implement parallel collection with proper error handling in future version
    log_info "Collecting system metrics..."

    local cpu_json mem_json disk_json net_json svc_json

    # Sequential collection with error handling
    if ! cpu_json=$(collect_cpu_metrics 2>&1); then
        COLLECTION_ERRORS+=("CPU metrics collection failed")
        cpu_json='{}'
    fi

    if ! mem_json=$(collect_memory_metrics 2>&1); then
        COLLECTION_ERRORS+=("Memory metrics collection failed")
        mem_json='{}'
    fi

    if ! disk_json=$(collect_disk_metrics 2>&1); then
        COLLECTION_ERRORS+=("Disk metrics collection failed")
        disk_json='{}'
    fi

    if ! net_json=$(collect_network_metrics 2>&1); then
        COLLECTION_ERRORS+=("Network metrics collection failed")
        net_json='{}'
    fi

    if ! svc_json=$(collect_services_metrics 2>&1); then
        COLLECTION_ERRORS+=("Services metrics collection failed")
        svc_json='{}'
    fi

    # Analyze metrics and calculate scores
    log_info "Analyzing metrics..."

    local cpu_score mem_score disk_score net_score svc_score
    cpu_score=$(analyze_cpu_metrics "$cpu_json" || echo "50")
    mem_score=$(analyze_memory_metrics "$mem_json" || echo "50")
    disk_score=$(analyze_disk_metrics "$disk_json" || echo "50")
    net_score=$(analyze_network_metrics "$net_json" || echo "50")
    svc_score=$(analyze_services_metrics "$svc_json" || echo "50")

    log_debug "Component scores - CPU: $cpu_score, Memory: $mem_score, Disk: $disk_score, Network: $net_score, Services: $svc_score"

    # Calculate overall health score
    local health_score
    health_score=$(calculate_health_score "$cpu_score" "$mem_score" "$disk_score" "$net_score" "$svc_score")

    local health_status
    health_status=$(get_health_status "$health_score")

    # Generate output
    local timestamp hostname
    timestamp=$(date -Iseconds)
    hostname=$(hostname)

    # Score-only mode
    if [[ "$SCORE_ONLY" == "true" ]]; then
        echo "$health_score"
        exit 0
    fi

    # Generate JSON
    local json_output
    json_output=$(generate_json_output "$timestamp" "$hostname" "$health_status" "$health_score" \
        "$cpu_json" "$mem_json" "$disk_json" "$net_json" "$svc_json")

    # Output based on format
    local output
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        output="$json_output"
    else
        output=$(generate_markdown_output "$json_output")
    fi

    # Write to file or stdout
    if [[ -n "$OUTPUT_FILE" ]]; then
        echo "$output" > "$OUTPUT_FILE"
        log_info "Output written to $OUTPUT_FILE"
    elif [[ "$QUIET_MODE" == "false" ]]; then
        echo "$output"
    fi

    # Exit with appropriate code
    if [[ "$health_status" == "healthy" ]]; then
        exit 0
    elif [[ "$health_status" == "warning" ]]; then
        exit 1
    else
        exit 2
    fi
}

# Run main if not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

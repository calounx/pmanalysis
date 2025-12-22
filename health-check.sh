#!/usr/bin/env bash
#######################################
# Debian 12 System Health Analyzer
# Production-grade health monitoring script
#
# Version: 2.0.0
# Author: CalouNX (DevOps/SRE)
# License: MIT
#######################################

set -euo pipefail
IFS=$'\n\t'

# Script metadata
readonly SCRIPT_VERSION="2.1.0"
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

# Thresholds - Nginx
readonly NGINX_CONNECTIONS_WARNING=800
readonly NGINX_CONNECTIONS_CRITICAL=1000
readonly NGINX_REQUESTS_PER_SEC_WARNING=1000
readonly NGINX_REQUESTS_PER_SEC_CRITICAL=5000
readonly NGINX_ERROR_RATE_WARNING=5       # Percentage of 4xx/5xx responses
readonly NGINX_ERROR_RATE_CRITICAL=15

# Thresholds - Apache
readonly APACHE_BUSY_WORKERS_WARNING=80   # Percentage of MaxRequestWorkers
readonly APACHE_BUSY_WORKERS_CRITICAL=95
readonly APACHE_REQUESTS_PER_SEC_WARNING=500
readonly APACHE_REQUESTS_PER_SEC_CRITICAL=2000
readonly APACHE_ERROR_RATE_WARNING=5
readonly APACHE_ERROR_RATE_CRITICAL=15

# Thresholds - MySQL/MariaDB
readonly MYSQL_CONNECTIONS_WARNING=80     # Percentage of max_connections
readonly MYSQL_CONNECTIONS_CRITICAL=95
readonly MYSQL_SLOW_QUERIES_WARNING=10    # Per minute
readonly MYSQL_SLOW_QUERIES_CRITICAL=50
readonly MYSQL_REPLICATION_LAG_WARNING=30 # Seconds
readonly MYSQL_REPLICATION_LAG_CRITICAL=120
readonly MYSQL_THREADS_RUNNING_WARNING=50
readonly MYSQL_THREADS_RUNNING_CRITICAL=100
readonly MYSQL_QUERY_CACHE_HIT_WARNING=80 # Percentage (below is warning)

# Thresholds - Redis
readonly REDIS_MEMORY_WARNING=80          # Percentage of maxmemory
readonly REDIS_MEMORY_CRITICAL=95
readonly REDIS_CONNECTIONS_WARNING=800
readonly REDIS_CONNECTIONS_CRITICAL=950
readonly REDIS_HIT_RATE_WARNING=90        # Below this is warning
readonly REDIS_EVICTIONS_WARNING=100      # Per minute
readonly REDIS_EVICTIONS_CRITICAL=1000
readonly REDIS_REJECTED_CONNECTIONS_WARNING=1

# Thresholds - WordOps/PHP-FPM
readonly PHPFPM_ACTIVE_WARNING=80         # Percentage of max_children
readonly PHPFPM_ACTIVE_CRITICAL=95
readonly PHPFPM_QUEUE_WARNING=5           # Listen queue length
readonly PHPFPM_QUEUE_CRITICAL=20
readonly WORDOPS_CACHE_HIT_WARNING=70     # Cache hit percentage
readonly SSL_EXPIRY_WARNING=30            # Days until expiry
readonly SSL_EXPIRY_CRITICAL=7

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
declare -a ALERTS=()
declare -a RECOMMENDATIONS=()
declare -a COLLECTION_ERRORS=()

# Root Cause Analysis
readonly RCA_HISTORY_DIR="/var/lib/health-check"
readonly RCA_HISTORY_FILE="$RCA_HISTORY_DIR/history.json"
readonly RCA_LOOKBACK_HOURS=24

# Output format (default: markdown)
OUTPUT_FORMAT="markdown"
OUTPUT_FILE=""
QUIET_MODE=false
SCORE_ONLY=false
NO_COLOR=false
DEBUG_MODE=false

# Auto-healing configuration (disabled by default for safety)
HEALING_ENABLED="${HEALING_ENABLED:-false}"
HEALING_LOG_DIR="${HEALING_LOG_DIR:-/var/log/health-check}"
HEALING_LOG_FILE="$HEALING_LOG_DIR/healing.log"
HEALING_HISTORY_FILE="$HEALING_LOG_DIR/healing-history.json"
HEALING_MAX_ATTEMPTS=3          # Max healing attempts per component per hour
HEALING_COOLDOWN=300            # Seconds between healing attempts for same component
declare -A HEALING_ATTEMPTS=()  # Track healing attempts per component

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
# Auto-healing functions
#######################################

# Initialize healing log directory
init_healing_log() {
    if [[ "$HEALING_ENABLED" == "true" ]]; then
        if [[ ! -d "$HEALING_LOG_DIR" ]]; then
            mkdir -p "$HEALING_LOG_DIR" 2>/dev/null || log_warn "Cannot create healing log directory"
        fi
    fi
}

# Log healing action
log_healing() {
    local action="$1"
    local component="$2"
    local result="$3"
    local details="${4:-}"

    if [[ -w "$HEALING_LOG_DIR" ]]; then
        echo "[$(date -Iseconds)] $result: $action on $component - $details" >> "$HEALING_LOG_FILE"
    fi
    log_info "Healing: $result - $action on $component"
}

# Check if healing is allowed for component (rate limiting)
can_heal() {
    local component="$1"
    local current_time
    current_time=$(date +%s)

    # Check if we've exceeded max attempts
    local attempt_key="${component}_attempts"
    local last_time_key="${component}_last"

    local attempts=${HEALING_ATTEMPTS[$attempt_key]:-0}
    local last_time=${HEALING_ATTEMPTS[$last_time_key]:-0}

    # Reset counter if more than an hour has passed
    if (( current_time - last_time > 3600 )); then
        HEALING_ATTEMPTS[$attempt_key]=0
        attempts=0
    fi

    # Check cooldown
    if (( current_time - last_time < HEALING_COOLDOWN )); then
        log_debug "Healing cooldown active for $component"
        return 1
    fi

    # Check max attempts
    if (( attempts >= HEALING_MAX_ATTEMPTS )); then
        log_warn "Max healing attempts ($HEALING_MAX_ATTEMPTS) exceeded for $component"
        return 1
    fi

    return 0
}

# Record healing attempt
record_healing_attempt() {
    local component="$1"
    local current_time
    current_time=$(date +%s)

    local attempt_key="${component}_attempts"
    local last_time_key="${component}_last"

    local attempts=${HEALING_ATTEMPTS[$attempt_key]:-0}
    HEALING_ATTEMPTS[$attempt_key]=$((attempts + 1))
    HEALING_ATTEMPTS[$last_time_key]=$current_time
}

# Perform healing action with risk level check
# Risk levels: low (safe), medium (restart service), high (requires confirmation)
perform_healing() {
    local component="$1"
    local action="$2"
    local risk_level="${3:-medium}"

    if [[ "$HEALING_ENABLED" != "true" ]]; then
        log_debug "Auto-healing disabled, would have performed: $action on $component"
        return 0
    fi

    # Only allow low-risk actions without explicit confirmation
    if [[ "$risk_level" != "low" ]]; then
        log_info "Skipping $risk_level-risk healing action: $action (requires manual intervention)"
        return 0
    fi

    if ! can_heal "$component"; then
        return 1
    fi

    record_healing_attempt "$component"
    log_healing "$action" "$component" "ATTEMPTING"

    local result=0
    case "$action" in
        "reload_nginx")
            nginx -s reload 2>/dev/null && result=0 || result=1
            ;;
        "reload_php-fpm")
            systemctl reload php*-fpm 2>/dev/null && result=0 || result=1
            ;;
        "clear_nginx_cache")
            rm -rf /var/cache/nginx/* 2>/dev/null && result=0 || result=1
            ;;
        "renew_ssl")
            certbot renew --quiet 2>/dev/null && result=0 || result=1
            ;;
        "clear_systemd_failed")
            systemctl reset-failed 2>/dev/null && result=0 || result=1
            ;;
        *)
            log_warn "Unknown healing action: $action"
            result=1
            ;;
    esac

    if [[ $result -eq 0 ]]; then
        log_healing "$action" "$component" "SUCCESS"
    else
        log_healing "$action" "$component" "FAILED"
    fi

    return $result
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
# Check if service is available
#######################################

is_nginx_available() {
    # Check systemd service
    command -v nginx &>/dev/null && systemctl is-active --quiet nginx 2>/dev/null && return 0
    # Check for Docker container
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qi nginx && return 0
    return 1
}

is_apache_available() {
    # Check systemd services
    (command -v apache2 &>/dev/null || command -v httpd &>/dev/null) && \
    (systemctl is-active --quiet apache2 2>/dev/null || systemctl is-active --quiet httpd 2>/dev/null) && return 0
    # Check for Docker container
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qiE 'apache|httpd' && return 0
    return 1
}

is_mysql_available() {
    # Check systemd services
    if (command -v mysql &>/dev/null || command -v mariadb &>/dev/null) && \
       (systemctl is-active --quiet mysql 2>/dev/null || systemctl is-active --quiet mariadb 2>/dev/null || systemctl is-active --quiet mysqld 2>/dev/null); then
        return 0
    fi
    # Check for Unix socket
    if [[ -S /var/run/mysqld/mysqld.sock ]] || [[ -S /tmp/mysql.sock ]]; then
        return 0
    fi
    # Check for Docker container
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qiE 'mysql|mariadb' && return 0
    return 1
}

is_redis_available() {
    # Check systemd service
    command -v redis-cli &>/dev/null && systemctl is-active --quiet redis-server 2>/dev/null && return 0
    # Check for Unix socket
    if [[ -S /var/run/redis/redis-server.sock ]] || [[ -S /var/run/redis/redis.sock ]]; then
        return 0
    fi
    # Check for Docker container
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qi redis && return 0
    return 1
}

is_docker_available() {
    command -v docker &>/dev/null && docker info &>/dev/null
}

is_podman_available() {
    command -v podman &>/dev/null && podman info &>/dev/null
}

is_wordops_available() {
    command -v wo &>/dev/null
}

is_phpfpm_available() {
    # Check for PHP-FPM master process (various naming patterns)
    pgrep -f "php-fpm:.*master" &>/dev/null || \
    pgrep -x "php-fpm" &>/dev/null || \
    systemctl is-active --quiet php-fpm 2>/dev/null || \
    systemctl is-active --quiet php7.4-fpm 2>/dev/null || \
    systemctl is-active --quiet php8.0-fpm 2>/dev/null || \
    systemctl is-active --quiet php8.1-fpm 2>/dev/null || \
    systemctl is-active --quiet php8.2-fpm 2>/dev/null || \
    systemctl is-active --quiet php8.3-fpm 2>/dev/null
}

#######################################
# Collect Nginx metrics
# Requires: nginx with stub_status module enabled
#######################################

collect_nginx_metrics() {
    if ! is_nginx_available; then
        echo '{"available": false}'
        return 0
    fi

    local active_connections waiting reading writing requests_per_sec
    local worker_processes worker_connections max_connections
    local error_count total_requests error_rate

    # Try to get stub_status from common locations
    local stub_status=""
    for url in "http://127.0.0.1/nginx_status" "http://localhost/nginx_status" "http://127.0.0.1:80/stub_status" "http://localhost/stub_status"; do
        if stub_status=$(curl -s --connect-timeout 2 "$url" 2>/dev/null); then
            if [[ "$stub_status" =~ Active\ connections ]]; then
                break
            fi
        fi
        stub_status=""
    done

    if [[ -n "$stub_status" ]]; then
        # Parse stub_status output
        active_connections=$(echo "$stub_status" | awk '/Active connections:/ {print $3}')
        reading=$(echo "$stub_status" | awk '/Reading:/ {print $2}')
        writing=$(echo "$stub_status" | awk '/Writing:/ {print $4}')
        waiting=$(echo "$stub_status" | awk '/Waiting:/ {print $6}')

        # Get requests from stub_status (3rd line: accepts handled requests)
        local requests_line
        requests_line=$(echo "$stub_status" | sed -n '3p' | awk '{print $3}')
        requests_per_sec=${requests_line:-0}
    else
        # Fallback: get basic info from process stats
        # Use tail -n +2 to skip header instead of decrementing (avoids negative values)
        active_connections=$(ss -tan state established '( dport = :80 or dport = :443 )' 2>/dev/null | tail -n +2 | wc -l)
        reading=0
        writing=0
        waiting=0
        requests_per_sec=0
    fi

    # Get nginx configuration with validation
    worker_processes=$(nginx -T 2>/dev/null | grep -m1 "worker_processes" | awk '{print $2}' | tr -d ';' || echo "auto")
    if [[ "$worker_processes" == "auto" ]] || ! [[ "$worker_processes" =~ ^[0-9]+$ ]]; then
        worker_processes=$(nproc)
    fi
    worker_connections=$(nginx -T 2>/dev/null | grep -m1 "worker_connections" | awk '{print $2}' | tr -d ';' || echo "1024")
    # Validate worker_connections is numeric
    if ! [[ "$worker_connections" =~ ^[0-9]+$ ]]; then
        worker_connections=1024
    fi
    max_connections=$((worker_processes * worker_connections))

    # Check error logs for recent errors (last 5 minutes)
    local error_log="/var/log/nginx/error.log"
    if [[ -r "$error_log" ]]; then
        local five_min_ago
        five_min_ago=$(date -d '5 minutes ago' '+%Y/%m/%d %H:%M' 2>/dev/null || echo "")
        if [[ -n "$five_min_ago" ]]; then
            error_count=$(awk -v since="$five_min_ago" '$0 >= since {count++} END {print count+0}' "$error_log" 2>/dev/null || echo "0")
        else
            error_count=$(tail -n 100 "$error_log" 2>/dev/null | grep -c "error" || echo "0")
        fi
    else
        error_count=0
    fi

    # Check access logs for 4xx/5xx errors
    local access_log="/var/log/nginx/access.log"
    if [[ -r "$access_log" ]]; then
        local recent_requests recent_errors
        recent_requests=$(tail -n 1000 "$access_log" 2>/dev/null | wc -l || echo "1")
        recent_errors=$(tail -n 1000 "$access_log" 2>/dev/null | awk '$9 ~ /^[45][0-9][0-9]$/ {count++} END {print count+0}' || echo "0")
        if [[ $recent_requests -gt 0 ]]; then
            error_rate=$(echo "scale=1; 100 * $recent_errors / $recent_requests" | bc)
        else
            error_rate="0.0"
        fi
    else
        error_rate="0.0"
    fi

    # Get memory usage
    local mem_usage_kb
    mem_usage_kb=$(ps aux | grep '[n]ginx' | awk '{sum+=$6} END {print sum+0}')
    local mem_usage_mb=$((mem_usage_kb / 1024))

    # Check for SSL handshake errors in error log
    local ssl_errors=0
    if [[ -r "$error_log" ]]; then
        ssl_errors=$(tail -n 500 "$error_log" 2>/dev/null | grep -c "SSL_do_handshake\|SSL handshake\|ssl_handshake" || echo "0")
    fi

    # Check upstream health (if proxy configured)
    local upstream_errors=0
    local upstream_timeout=0
    if [[ -r "$error_log" ]]; then
        upstream_errors=$(tail -n 500 "$error_log" 2>/dev/null | grep -c "upstream\|connect() failed\|no live upstreams" || echo "0")
        upstream_timeout=$(tail -n 500 "$error_log" 2>/dev/null | grep -c "upstream timed out" || echo "0")
    fi

    # Check for rate limiting hits in error log
    local rate_limit_hits=0
    if [[ -r "$error_log" ]]; then
        rate_limit_hits=$(tail -n 500 "$error_log" 2>/dev/null | grep -c "limiting requests" || echo "0")
    fi

    # Count 4xx and 5xx separately from access log
    local count_4xx=0 count_5xx=0
    if [[ -r "$access_log" ]]; then
        count_4xx=$(tail -n 1000 "$access_log" 2>/dev/null | awk '$9 ~ /^4[0-9][0-9]$/ {count++} END {print count+0}' || echo "0")
        count_5xx=$(tail -n 1000 "$access_log" 2>/dev/null | awk '$9 ~ /^5[0-9][0-9]$/ {count++} END {print count+0}' || echo "0")
    fi

    jq -nc \
        --arg avail "true" \
        --arg active "$active_connections" \
        --arg reading "$reading" \
        --arg writing "$writing" \
        --arg waiting "$waiting" \
        --arg rps "$requests_per_sec" \
        --arg max "$max_connections" \
        --arg errors "$error_count" \
        --arg errrate "$error_rate" \
        --arg mem "$mem_usage_mb" \
        --arg ssl_errs "$ssl_errors" \
        --arg upstream_errs "$upstream_errors" \
        --arg upstream_to "$upstream_timeout" \
        --arg ratelimit "$rate_limit_hits" \
        --arg http4xx "$count_4xx" \
        --arg http5xx "$count_5xx" \
        '{
            available: ($avail | test("true")),
            active_connections: ($active | tonumber),
            reading: ($reading | tonumber),
            writing: ($writing | tonumber),
            waiting: ($waiting | tonumber),
            requests_per_sec: ($rps | tonumber),
            max_connections: ($max | tonumber),
            error_count: ($errors | tonumber),
            error_rate: ($errrate | tonumber),
            memory_mb: ($mem | tonumber),
            ssl_errors: ($ssl_errs | tonumber),
            upstream_errors: ($upstream_errs | tonumber),
            upstream_timeouts: ($upstream_to | tonumber),
            rate_limit_hits: ($ratelimit | tonumber),
            http_4xx_count: ($http4xx | tonumber),
            http_5xx_count: ($http5xx | tonumber)
        }'
}

#######################################
# Analyze Nginx metrics
#######################################

analyze_nginx_metrics() {
    local nginx_json="$1"

    local available
    available=$(echo "$nginx_json" | jq -r '.available // false')

    if [[ "$available" != "true" ]]; then
        echo "100"  # Not available, don't penalize
        return 0
    fi

    local active_connections max_connections error_rate
    active_connections=$(echo "$nginx_json" | jq -r '.active_connections // 0')
    max_connections=$(echo "$nginx_json" | jq -r '.max_connections // 1024')
    error_rate=$(echo "$nginx_json" | jq -r '.error_rate // 0')

    local score=100
    local connection_percent
    connection_percent=$(echo "scale=1; 100 * $active_connections / $max_connections" | bc)

    # Check connection thresholds
    if (( $(echo "$active_connections >= $NGINX_CONNECTIONS_CRITICAL" | bc -l) )); then
        add_alert "critical" "nginx" "Nginx connections critical" "$active_connections" "$NGINX_CONNECTIONS_CRITICAL"
        RECOMMENDATIONS+=("Scale Nginx worker_connections or add load balancing")
        score=$((score - 30))
    elif (( $(echo "$active_connections >= $NGINX_CONNECTIONS_WARNING" | bc -l) )); then
        add_alert "warning" "nginx" "Nginx connections high" "$active_connections" "$NGINX_CONNECTIONS_WARNING"
        score=$((score - 15))
    fi

    # Check error rate
    if (( $(echo "$error_rate >= $NGINX_ERROR_RATE_CRITICAL" | bc -l) )); then
        add_alert "critical" "nginx" "Nginx error rate critical" "$error_rate" "$NGINX_ERROR_RATE_CRITICAL"
        RECOMMENDATIONS+=("Check Nginx error logs: tail -f /var/log/nginx/error.log")
        score=$((score - 25))
    elif (( $(echo "$error_rate >= $NGINX_ERROR_RATE_WARNING" | bc -l) )); then
        add_alert "warning" "nginx" "Nginx error rate elevated" "$error_rate" "$NGINX_ERROR_RATE_WARNING"
        score=$((score - 10))
    fi

    # Ensure score doesn't go negative
    if [[ $score -lt 0 ]]; then
        score=0
    fi

    echo "$score"
}

#######################################
# Collect Apache metrics
# Requires: mod_status enabled
#######################################

collect_apache_metrics() {
    if ! is_apache_available; then
        echo '{"available": false}'
        return 0
    fi

    local server_status=""
    local busy_workers idle_workers total_slots requests_per_sec
    local cpu_load uptime_seconds bytes_per_sec

    # Try to get server-status from common locations
    for url in "http://127.0.0.1/server-status?auto" "http://localhost/server-status?auto" "http://127.0.0.1:80/server-status?auto"; do
        if server_status=$(curl -s --connect-timeout 2 "$url" 2>/dev/null); then
            if [[ "$server_status" =~ BusyWorkers ]]; then
                break
            fi
        fi
        server_status=""
    done

    if [[ -n "$server_status" ]]; then
        # Parse server-status output
        busy_workers=$(echo "$server_status" | awk -F': ' '/^BusyWorkers:/ {print $2}')
        idle_workers=$(echo "$server_status" | awk -F': ' '/^IdleWorkers:/ {print $2}')
        requests_per_sec=$(echo "$server_status" | awk -F': ' '/^ReqPerSec:/ {print $2}')
        cpu_load=$(echo "$server_status" | awk -F': ' '/^CPULoad:/ {print $2}')
        uptime_seconds=$(echo "$server_status" | awk -F': ' '/^Uptime:/ {print $2}')
        bytes_per_sec=$(echo "$server_status" | awk -F': ' '/^BytesPerSec:/ {print $2}')
        total_slots=$(echo "$server_status" | awk -F': ' '/^ServerLimit:/ {print $2}')
    else
        # Fallback: get basic info from process stats
        busy_workers=$(pgrep -c 'apache2\|httpd' 2>/dev/null || echo "0")
        idle_workers=0
        requests_per_sec=0
        cpu_load=0
        uptime_seconds=0
        bytes_per_sec=0
        total_slots=256  # Default MaxRequestWorkers
    fi

    # Ensure we have valid values
    busy_workers=${busy_workers:-0}
    idle_workers=${idle_workers:-0}
    total_slots=${total_slots:-256}
    requests_per_sec=${requests_per_sec:-0}

    # Calculate busy percentage
    local busy_percent
    if [[ $total_slots -gt 0 ]]; then
        busy_percent=$(echo "scale=1; 100 * $busy_workers / $total_slots" | bc)
    else
        busy_percent="0.0"
    fi

    # Check error logs for recent errors
    local error_log=""
    for log in "/var/log/apache2/error.log" "/var/log/httpd/error_log"; do
        if [[ -r "$log" ]]; then
            error_log="$log"
            break
        fi
    done

    local error_count=0
    local error_rate="0.0"
    if [[ -n "$error_log" && -r "$error_log" ]]; then
        error_count=$(tail -n 100 "$error_log" 2>/dev/null | grep -ci "error" || echo "0")
    fi

    # Check access logs for 4xx/5xx errors
    local access_log=""
    for log in "/var/log/apache2/access.log" "/var/log/httpd/access_log"; do
        if [[ -r "$log" ]]; then
            access_log="$log"
            break
        fi
    done

    if [[ -n "$access_log" && -r "$access_log" ]]; then
        local recent_requests recent_errors
        recent_requests=$(tail -n 1000 "$access_log" 2>/dev/null | wc -l || echo "1")
        recent_errors=$(tail -n 1000 "$access_log" 2>/dev/null | awk '$9 ~ /^[45][0-9][0-9]$/ {count++} END {print count+0}' || echo "0")
        if [[ $recent_requests -gt 0 ]]; then
            error_rate=$(echo "scale=1; 100 * $recent_errors / $recent_requests" | bc)
        fi
    fi

    # Get memory usage
    local mem_usage_kb
    mem_usage_kb=$(ps aux | grep -E '[a]pache2|[h]ttpd' | awk '{sum+=$6} END {print sum+0}')
    local mem_usage_mb=$((mem_usage_kb / 1024))

    jq -nc \
        --arg avail "true" \
        --arg busy "$busy_workers" \
        --arg idle "$idle_workers" \
        --arg total "$total_slots" \
        --arg busypct "$busy_percent" \
        --arg rps "$requests_per_sec" \
        --arg cpu "${cpu_load:-0}" \
        --arg errors "$error_count" \
        --arg errrate "$error_rate" \
        --arg mem "$mem_usage_mb" \
        '{
            available: ($avail | test("true")),
            busy_workers: ($busy | tonumber),
            idle_workers: ($idle | tonumber),
            max_workers: ($total | tonumber),
            busy_percent: ($busypct | tonumber),
            requests_per_sec: ($rps | tonumber),
            cpu_load: ($cpu | tonumber),
            error_count: ($errors | tonumber),
            error_rate: ($errrate | tonumber),
            memory_mb: ($mem | tonumber)
        }'
}

#######################################
# Analyze Apache metrics
#######################################

analyze_apache_metrics() {
    local apache_json="$1"

    local available
    available=$(echo "$apache_json" | jq -r '.available // false')

    if [[ "$available" != "true" ]]; then
        echo "100"  # Not available, don't penalize
        return 0
    fi

    local busy_percent error_rate requests_per_sec
    busy_percent=$(echo "$apache_json" | jq -r '.busy_percent // 0')
    error_rate=$(echo "$apache_json" | jq -r '.error_rate // 0')
    requests_per_sec=$(echo "$apache_json" | jq -r '.requests_per_sec // 0')

    local score=100

    # Check worker utilization
    if (( $(echo "$busy_percent >= $APACHE_BUSY_WORKERS_CRITICAL" | bc -l) )); then
        add_alert "critical" "apache" "Apache workers saturated" "$busy_percent" "$APACHE_BUSY_WORKERS_CRITICAL"
        RECOMMENDATIONS+=("Increase Apache MaxRequestWorkers or scale horizontally")
        score=$((score - 30))
    elif (( $(echo "$busy_percent >= $APACHE_BUSY_WORKERS_WARNING" | bc -l) )); then
        add_alert "warning" "apache" "Apache worker utilization high" "$busy_percent" "$APACHE_BUSY_WORKERS_WARNING"
        score=$((score - 15))
    fi

    # Check error rate
    if (( $(echo "$error_rate >= $APACHE_ERROR_RATE_CRITICAL" | bc -l) )); then
        add_alert "critical" "apache" "Apache error rate critical" "$error_rate" "$APACHE_ERROR_RATE_CRITICAL"
        RECOMMENDATIONS+=("Check Apache error logs for issues")
        score=$((score - 25))
    elif (( $(echo "$error_rate >= $APACHE_ERROR_RATE_WARNING" | bc -l) )); then
        add_alert "warning" "apache" "Apache error rate elevated" "$error_rate" "$APACHE_ERROR_RATE_WARNING"
        score=$((score - 10))
    fi

    # Ensure score doesn't go negative
    if [[ $score -lt 0 ]]; then
        score=0
    fi

    echo "$score"
}

#######################################
# Collect MySQL/MariaDB metrics
#######################################

collect_mysql_metrics() {
    if ! is_mysql_available; then
        echo '{"available": false}'
        return 0
    fi

    local mysql_cmd="mysql"
    if command -v mariadb &>/dev/null; then
        mysql_cmd="mariadb"
    fi

    # Build mysql options array for safe command execution
    local -a mysql_opts=()
    if [[ -f /etc/mysql/debian.cnf ]] && [[ -r /etc/mysql/debian.cnf ]]; then
        mysql_opts=("--defaults-file=/etc/mysql/debian.cnf")
    fi

    # Helper function for safe MySQL execution
    run_mysql() {
        "$mysql_cmd" "${mysql_opts[@]}" "$@"
    }

    # Test connection with retry logic for transient failures
    local retry_count=0
    local max_retries=2
    local connected=false

    while [[ $retry_count -lt $max_retries ]]; do
        if run_mysql -e "SELECT 1" &>/dev/null 2>&1; then
            connected=true
            break
        fi
        # Try without options on first failure
        if [[ $retry_count -eq 0 ]] && [[ ${#mysql_opts[@]} -gt 0 ]]; then
            mysql_opts=()
            if run_mysql -e "SELECT 1" &>/dev/null 2>&1; then
                connected=true
                break
            fi
        fi
        ((retry_count++))
        sleep 0.5
    done

    if [[ "$connected" != "true" ]]; then
        echo '{"available": false, "reason": "connection_failed"}'
        return 0
    fi

    # Get status variables
    local status_output
    status_output=$(run_mysql -N -e "SHOW GLOBAL STATUS" 2>/dev/null || echo "")

    if [[ -z "$status_output" ]]; then
        echo '{"available": false, "reason": "no_status"}'
        return 0
    fi

    # Parse status variables
    local threads_connected max_connections threads_running
    local slow_queries questions uptime
    local qcache_hits qcache_inserts
    local bytes_received bytes_sent
    local aborted_connects aborted_clients
    local innodb_row_lock_waits innodb_row_lock_time innodb_deadlocks
    local created_tmp_disk_tables created_tmp_tables
    local table_locks_waited table_locks_immediate

    threads_connected=$(echo "$status_output" | awk '/^Threads_connected\t/ {print $2}')
    threads_running=$(echo "$status_output" | awk '/^Threads_running\t/ {print $2}')
    slow_queries=$(echo "$status_output" | awk '/^Slow_queries\t/ {print $2}')
    questions=$(echo "$status_output" | awk '/^Questions\t/ {print $2}')
    uptime=$(echo "$status_output" | awk '/^Uptime\t/ {print $2}')
    qcache_hits=$(echo "$status_output" | awk '/^Qcache_hits\t/ {print $2}')
    qcache_inserts=$(echo "$status_output" | awk '/^Qcache_inserts\t/ {print $2}')
    bytes_received=$(echo "$status_output" | awk '/^Bytes_received\t/ {print $2}')
    bytes_sent=$(echo "$status_output" | awk '/^Bytes_sent\t/ {print $2}')
    aborted_connects=$(echo "$status_output" | awk '/^Aborted_connects\t/ {print $2}')
    aborted_clients=$(echo "$status_output" | awk '/^Aborted_clients\t/ {print $2}')

    # InnoDB lock metrics
    innodb_row_lock_waits=$(echo "$status_output" | awk '/^Innodb_row_lock_waits\t/ {print $2}')
    innodb_row_lock_time=$(echo "$status_output" | awk '/^Innodb_row_lock_time\t/ {print $2}')
    innodb_deadlocks=$(echo "$status_output" | awk '/^Innodb_deadlocks\t/ {print $2}')

    # Temporary table metrics
    created_tmp_disk_tables=$(echo "$status_output" | awk '/^Created_tmp_disk_tables\t/ {print $2}')
    created_tmp_tables=$(echo "$status_output" | awk '/^Created_tmp_tables\t/ {print $2}')

    # Table lock contention
    table_locks_waited=$(echo "$status_output" | awk '/^Table_locks_waited\t/ {print $2}')
    table_locks_immediate=$(echo "$status_output" | awk '/^Table_locks_immediate\t/ {print $2}')

    # Get variables
    local variables_output
    variables_output=$(run_mysql -N -e "SHOW GLOBAL VARIABLES LIKE 'max_connections'" 2>/dev/null || echo "")
    max_connections=$(echo "$variables_output" | awk '{print $2}')
    max_connections=${max_connections:-151}

    # Calculate derived metrics
    local connection_percent queries_per_sec slow_per_minute
    threads_connected=${threads_connected:-0}
    connection_percent=$(echo "scale=1; 100 * $threads_connected / $max_connections" | bc)

    uptime=${uptime:-1}
    questions=${questions:-0}
    queries_per_sec=$(echo "scale=1; $questions / $uptime" | bc)

    # Slow queries per minute (normalized by uptime)
    slow_queries=${slow_queries:-0}
    slow_per_minute=$(echo "scale=2; 60 * $slow_queries / $uptime" | bc)

    # Query cache hit rate
    qcache_hits=${qcache_hits:-0}
    qcache_inserts=${qcache_inserts:-0}
    local cache_hit_rate="0.0"
    local total_cache=$((qcache_hits + qcache_inserts))
    if [[ $total_cache -gt 0 ]]; then
        cache_hit_rate=$(echo "scale=1; 100 * $qcache_hits / $total_cache" | bc)
    fi

    # Check replication status (if replica)
    # MySQL 8.0.22+ uses SHOW REPLICA STATUS, older versions use SHOW SLAVE STATUS
    local replication_lag=0
    local is_replica="false"
    local replica_status
    replica_status=$(run_mysql -N -e "SHOW REPLICA STATUS\G" 2>/dev/null || \
                     run_mysql -N -e "SHOW SLAVE STATUS\G" 2>/dev/null || echo "")
    if [[ -n "$replica_status" ]]; then
        is_replica="true"
        # Handle both old (Seconds_Behind_Master) and new (Seconds_Behind_Source) field names
        replication_lag=$(echo "$replica_status" | awk '/Seconds_Behind_Source:/ {print $2}')
        if [[ -z "$replication_lag" ]]; then
            replication_lag=$(echo "$replica_status" | awk '/Seconds_Behind_Master:/ {print $2}')
        fi
        replication_lag=${replication_lag:-0}
        if [[ "$replication_lag" == "NULL" ]]; then
            replication_lag=0
        fi
    fi

    # Get InnoDB metrics
    local innodb_buffer_pool_size innodb_buffer_pool_used buffer_pool_percent
    innodb_buffer_pool_size=$(run_mysql -N -e "SHOW GLOBAL VARIABLES LIKE 'innodb_buffer_pool_size'" 2>/dev/null | awk '{print $2}')
    innodb_buffer_pool_used=$(echo "$status_output" | awk '/^Innodb_buffer_pool_bytes_data\t/ {print $2}')
    innodb_buffer_pool_size=${innodb_buffer_pool_size:-0}
    innodb_buffer_pool_used=${innodb_buffer_pool_used:-0}

    if [[ $innodb_buffer_pool_size -gt 0 ]]; then
        buffer_pool_percent=$(echo "scale=1; 100 * $innodb_buffer_pool_used / $innodb_buffer_pool_size" | bc)
    else
        buffer_pool_percent="0.0"
    fi

    # Set defaults for new metrics
    innodb_row_lock_waits=${innodb_row_lock_waits:-0}
    innodb_row_lock_time=${innodb_row_lock_time:-0}
    innodb_deadlocks=${innodb_deadlocks:-0}
    created_tmp_disk_tables=${created_tmp_disk_tables:-0}
    created_tmp_tables=${created_tmp_tables:-1}  # Avoid division by zero
    table_locks_waited=${table_locks_waited:-0}
    table_locks_immediate=${table_locks_immediate:-1}

    # Calculate lock waits per minute
    local lock_waits_per_min
    lock_waits_per_min=$(echo "scale=2; 60 * $innodb_row_lock_waits / $uptime" | bc)

    # Calculate temp disk table ratio
    local tmp_disk_ratio
    tmp_disk_ratio=$(echo "scale=1; 100 * $created_tmp_disk_tables / $created_tmp_tables" | bc)

    # Calculate table lock contention
    local total_locks=$((table_locks_waited + table_locks_immediate))
    local table_lock_contention="0.0"
    if [[ $total_locks -gt 0 ]]; then
        table_lock_contention=$(echo "scale=2; 100 * $table_locks_waited / $total_locks" | bc)
    fi

    jq -nc \
        --arg avail "true" \
        --arg conn "$threads_connected" \
        --arg maxconn "$max_connections" \
        --arg connpct "$connection_percent" \
        --arg running "${threads_running:-0}" \
        --arg qps "$queries_per_sec" \
        --arg slow "$slow_per_minute" \
        --arg cachehit "$cache_hit_rate" \
        --arg replica "$is_replica" \
        --arg replag "$replication_lag" \
        --arg bufferpct "$buffer_pool_percent" \
        --arg abortconn "${aborted_connects:-0}" \
        --arg abortcli "${aborted_clients:-0}" \
        --arg lockwaits "$lock_waits_per_min" \
        --arg deadlocks "${innodb_deadlocks:-0}" \
        --arg tmpdiskratio "$tmp_disk_ratio" \
        --arg lockcontention "$table_lock_contention" \
        '{
            available: ($avail | test("true")),
            connections: ($conn | tonumber),
            max_connections: ($maxconn | tonumber),
            connection_percent: ($connpct | tonumber),
            threads_running: ($running | tonumber),
            queries_per_sec: ($qps | tonumber),
            slow_queries_per_min: ($slow | tonumber),
            query_cache_hit_rate: ($cachehit | tonumber),
            is_replica: ($replica | test("true")),
            replication_lag_sec: ($replag | tonumber),
            buffer_pool_percent: ($bufferpct | tonumber),
            aborted_connections: ($abortconn | tonumber),
            aborted_clients: ($abortcli | tonumber),
            lock_waits_per_min: ($lockwaits | tonumber),
            deadlocks: ($deadlocks | tonumber),
            tmp_disk_table_ratio: ($tmpdiskratio | tonumber),
            table_lock_contention: ($lockcontention | tonumber)
        }'
}

#######################################
# Analyze MySQL/MariaDB metrics
#######################################

analyze_mysql_metrics() {
    local mysql_json="$1"

    local available
    available=$(echo "$mysql_json" | jq -r '.available // false')

    if [[ "$available" != "true" ]]; then
        echo "100"  # Not available, don't penalize
        return 0
    fi

    local connection_percent threads_running slow_queries_per_min
    local is_replica replication_lag_sec
    connection_percent=$(echo "$mysql_json" | jq -r '.connection_percent // 0')
    threads_running=$(echo "$mysql_json" | jq -r '.threads_running // 0')
    slow_queries_per_min=$(echo "$mysql_json" | jq -r '.slow_queries_per_min // 0')
    is_replica=$(echo "$mysql_json" | jq -r '.is_replica // false')
    replication_lag_sec=$(echo "$mysql_json" | jq -r '.replication_lag_sec // 0')

    local score=100

    # Check connection utilization
    if (( $(echo "$connection_percent >= $MYSQL_CONNECTIONS_CRITICAL" | bc -l) )); then
        add_alert "critical" "mysql" "MySQL connections critical" "$connection_percent" "$MYSQL_CONNECTIONS_CRITICAL"
        RECOMMENDATIONS+=("Increase MySQL max_connections or optimize connection pooling")
        score=$((score - 30))
    elif (( $(echo "$connection_percent >= $MYSQL_CONNECTIONS_WARNING" | bc -l) )); then
        add_alert "warning" "mysql" "MySQL connections high" "$connection_percent" "$MYSQL_CONNECTIONS_WARNING"
        score=$((score - 15))
    fi

    # Check threads running
    if (( $(echo "$threads_running >= $MYSQL_THREADS_RUNNING_CRITICAL" | bc -l) )); then
        add_alert "critical" "mysql" "MySQL threads running critical" "$threads_running" "$MYSQL_THREADS_RUNNING_CRITICAL"
        RECOMMENDATIONS+=("Check for long-running queries: SHOW PROCESSLIST")
        score=$((score - 25))
    elif (( $(echo "$threads_running >= $MYSQL_THREADS_RUNNING_WARNING" | bc -l) )); then
        add_alert "warning" "mysql" "MySQL threads running high" "$threads_running" "$MYSQL_THREADS_RUNNING_WARNING"
        score=$((score - 10))
    fi

    # Check slow queries
    if (( $(echo "$slow_queries_per_min >= $MYSQL_SLOW_QUERIES_CRITICAL" | bc -l) )); then
        add_alert "critical" "mysql" "MySQL slow queries critical" "$slow_queries_per_min" "$MYSQL_SLOW_QUERIES_CRITICAL"
        RECOMMENDATIONS+=("Enable slow query log and optimize problematic queries")
        score=$((score - 20))
    elif (( $(echo "$slow_queries_per_min >= $MYSQL_SLOW_QUERIES_WARNING" | bc -l) )); then
        add_alert "warning" "mysql" "MySQL slow queries elevated" "$slow_queries_per_min" "$MYSQL_SLOW_QUERIES_WARNING"
        score=$((score - 10))
    fi

    # Check replication lag (if replica)
    if [[ "$is_replica" == "true" ]]; then
        if (( $(echo "$replication_lag_sec >= $MYSQL_REPLICATION_LAG_CRITICAL" | bc -l) )); then
            add_alert "critical" "mysql" "MySQL replication lag critical" "$replication_lag_sec" "$MYSQL_REPLICATION_LAG_CRITICAL"
            RECOMMENDATIONS+=("Check MySQL replication status and network connectivity to master")
            score=$((score - 25))
        elif (( $(echo "$replication_lag_sec >= $MYSQL_REPLICATION_LAG_WARNING" | bc -l) )); then
            add_alert "warning" "mysql" "MySQL replication lag high" "$replication_lag_sec" "$MYSQL_REPLICATION_LAG_WARNING"
            score=$((score - 10))
        fi
    fi

    # Ensure score doesn't go negative
    if [[ $score -lt 0 ]]; then
        score=0
    fi

    echo "$score"
}

#######################################
# Collect Redis metrics
#######################################

collect_redis_metrics() {
    if ! is_redis_available; then
        echo '{"available": false}'
        return 0
    fi

    # Get Redis INFO
    local redis_info
    redis_info=$(redis-cli INFO 2>/dev/null || echo "")

    if [[ -z "$redis_info" ]]; then
        echo '{"available": false, "reason": "connection_failed"}'
        return 0
    fi

    # Parse Redis INFO
    local used_memory maxmemory memory_percent
    local connected_clients blocked_clients
    local keyspace_hits keyspace_misses hit_rate
    local evicted_keys expired_keys
    local rejected_connections total_connections
    local instantaneous_ops_per_sec
    local uptime_in_seconds
    local mem_fragmentation_ratio used_memory_rss
    local rdb_last_save_time aof_enabled aof_last_rewrite_time
    local instantaneous_input_kbps instantaneous_output_kbps

    used_memory=$(echo "$redis_info" | awk -F: '/^used_memory:/ {print $2}' | tr -d '\r')
    maxmemory=$(echo "$redis_info" | awk -F: '/^maxmemory:/ {print $2}' | tr -d '\r')
    connected_clients=$(echo "$redis_info" | awk -F: '/^connected_clients:/ {print $2}' | tr -d '\r')
    blocked_clients=$(echo "$redis_info" | awk -F: '/^blocked_clients:/ {print $2}' | tr -d '\r')
    keyspace_hits=$(echo "$redis_info" | awk -F: '/^keyspace_hits:/ {print $2}' | tr -d '\r')
    keyspace_misses=$(echo "$redis_info" | awk -F: '/^keyspace_misses:/ {print $2}' | tr -d '\r')
    evicted_keys=$(echo "$redis_info" | awk -F: '/^evicted_keys:/ {print $2}' | tr -d '\r')
    expired_keys=$(echo "$redis_info" | awk -F: '/^expired_keys:/ {print $2}' | tr -d '\r')
    rejected_connections=$(echo "$redis_info" | awk -F: '/^rejected_connections:/ {print $2}' | tr -d '\r')
    total_connections=$(echo "$redis_info" | awk -F: '/^total_connections_received:/ {print $2}' | tr -d '\r')
    instantaneous_ops_per_sec=$(echo "$redis_info" | awk -F: '/^instantaneous_ops_per_sec:/ {print $2}' | tr -d '\r')
    uptime_in_seconds=$(echo "$redis_info" | awk -F: '/^uptime_in_seconds:/ {print $2}' | tr -d '\r')

    # Fragmentation metrics
    mem_fragmentation_ratio=$(echo "$redis_info" | awk -F: '/^mem_fragmentation_ratio:/ {print $2}' | tr -d '\r')
    used_memory_rss=$(echo "$redis_info" | awk -F: '/^used_memory_rss:/ {print $2}' | tr -d '\r')

    # Persistence metrics
    rdb_last_save_time=$(echo "$redis_info" | awk -F: '/^rdb_last_save_time:/ {print $2}' | tr -d '\r')
    aof_enabled=$(echo "$redis_info" | awk -F: '/^aof_enabled:/ {print $2}' | tr -d '\r')
    aof_last_rewrite_time=$(echo "$redis_info" | awk -F: '/^aof_last_rewrite_time_sec:/ {print $2}' | tr -d '\r')

    # Network throughput
    instantaneous_input_kbps=$(echo "$redis_info" | awk -F: '/^instantaneous_input_kbps:/ {print $2}' | tr -d '\r')
    instantaneous_output_kbps=$(echo "$redis_info" | awk -F: '/^instantaneous_output_kbps:/ {print $2}' | tr -d '\r')

    # Set defaults
    used_memory=${used_memory:-0}
    maxmemory=${maxmemory:-0}
    connected_clients=${connected_clients:-0}
    blocked_clients=${blocked_clients:-0}
    keyspace_hits=${keyspace_hits:-0}
    keyspace_misses=${keyspace_misses:-0}
    evicted_keys=${evicted_keys:-0}
    uptime_in_seconds=${uptime_in_seconds:-1}
    rejected_connections=${rejected_connections:-0}
    instantaneous_ops_per_sec=${instantaneous_ops_per_sec:-0}
    mem_fragmentation_ratio=${mem_fragmentation_ratio:-1.0}
    used_memory_rss=${used_memory_rss:-0}
    rdb_last_save_time=${rdb_last_save_time:-0}
    aof_enabled=${aof_enabled:-0}
    instantaneous_input_kbps=${instantaneous_input_kbps:-0}
    instantaneous_output_kbps=${instantaneous_output_kbps:-0}

    # Calculate memory percentage
    # When maxmemory is 0 (unlimited), calculate based on system memory
    local maxmemory_effective=$maxmemory
    if [[ $maxmemory -eq 0 ]]; then
        # Use system total memory as reference
        maxmemory_effective=$(awk '/MemTotal/ {print $2 * 1024}' /proc/meminfo 2>/dev/null || echo "0")
    fi
    if [[ $maxmemory_effective -gt 0 ]]; then
        memory_percent=$(echo "scale=1; 100 * $used_memory / $maxmemory_effective" | bc)
    else
        memory_percent="0.0"
    fi

    # Calculate hit rate
    local total_ops=$((keyspace_hits + keyspace_misses))
    if [[ $total_ops -gt 0 ]]; then
        hit_rate=$(echo "scale=1; 100 * $keyspace_hits / $total_ops" | bc)
    else
        hit_rate="100.0"  # No operations = 100% hit rate (no misses)
    fi

    # Calculate evictions per minute
    local evictions_per_min
    evictions_per_min=$(echo "scale=2; 60 * $evicted_keys / $uptime_in_seconds" | bc)

    # Get memory in MB
    local used_memory_mb
    used_memory_mb=$(echo "scale=0; $used_memory / 1048576" | bc)

    # Get database info (key counts)
    local total_keys=0
    while IFS=: read -r db info; do
        if [[ "$db" =~ ^db[0-9]+ ]]; then
            local keys
            keys=$(echo "$info" | awk -F'[,=]' '{print $2}')
            total_keys=$((total_keys + keys))
        fi
    done <<< "$(echo "$redis_info" | grep '^db[0-9]')"

    # Calculate persistence age (seconds since last save)
    local current_time rdb_age
    current_time=$(date +%s)
    if [[ $rdb_last_save_time -gt 0 ]]; then
        rdb_age=$((current_time - rdb_last_save_time))
    else
        rdb_age=0
    fi

    # Get Redis latency (if available)
    local latency_ms="0"
    local latency_output
    latency_output=$(redis-cli --latency-history -i 1 2>/dev/null | head -1 || echo "")
    if [[ "$latency_output" =~ avg=([0-9.]+) ]]; then
        latency_ms="${BASH_REMATCH[1]}"
    fi

    jq -nc \
        --arg avail "true" \
        --arg mempct "$memory_percent" \
        --arg memmb "$used_memory_mb" \
        --arg clients "$connected_clients" \
        --arg blocked "$blocked_clients" \
        --arg hitrate "$hit_rate" \
        --arg evictmin "$evictions_per_min" \
        --arg rejected "$rejected_connections" \
        --arg ops "$instantaneous_ops_per_sec" \
        --arg keys "$total_keys" \
        --arg fragmentation "$mem_fragmentation_ratio" \
        --arg rdb_age "$rdb_age" \
        --arg aof "$aof_enabled" \
        --arg latency "$latency_ms" \
        --arg input_kbps "$instantaneous_input_kbps" \
        --arg output_kbps "$instantaneous_output_kbps" \
        '{
            available: ($avail | test("true")),
            memory_percent: ($mempct | tonumber),
            memory_mb: ($memmb | tonumber),
            connected_clients: ($clients | tonumber),
            blocked_clients: ($blocked | tonumber),
            hit_rate: ($hitrate | tonumber),
            evictions_per_min: ($evictmin | tonumber),
            rejected_connections: ($rejected | tonumber),
            ops_per_sec: ($ops | tonumber),
            total_keys: ($keys | tonumber),
            fragmentation_ratio: ($fragmentation | tonumber),
            rdb_save_age_sec: ($rdb_age | tonumber),
            aof_enabled: ($aof | test("1")),
            latency_ms: ($latency | tonumber),
            input_kbps: ($input_kbps | tonumber),
            output_kbps: ($output_kbps | tonumber)
        }'
}

#######################################
# Analyze Redis metrics
#######################################

analyze_redis_metrics() {
    local redis_json="$1"

    local available
    available=$(echo "$redis_json" | jq -r '.available // false')

    if [[ "$available" != "true" ]]; then
        echo "100"  # Not available, don't penalize
        return 0
    fi

    local memory_percent connected_clients hit_rate evictions_per_min rejected_connections
    memory_percent=$(echo "$redis_json" | jq -r '.memory_percent // 0')
    connected_clients=$(echo "$redis_json" | jq -r '.connected_clients // 0')
    hit_rate=$(echo "$redis_json" | jq -r '.hit_rate // 100')
    evictions_per_min=$(echo "$redis_json" | jq -r '.evictions_per_min // 0')
    rejected_connections=$(echo "$redis_json" | jq -r '.rejected_connections // 0')

    local score=100

    # Check memory usage
    if (( $(echo "$memory_percent >= $REDIS_MEMORY_CRITICAL" | bc -l) )); then
        add_alert "critical" "redis" "Redis memory critical" "$memory_percent" "$REDIS_MEMORY_CRITICAL"
        RECOMMENDATIONS+=("Increase Redis maxmemory or implement key eviction policies")
        score=$((score - 30))
    elif (( $(echo "$memory_percent >= $REDIS_MEMORY_WARNING" | bc -l) )); then
        add_alert "warning" "redis" "Redis memory high" "$memory_percent" "$REDIS_MEMORY_WARNING"
        score=$((score - 15))
    fi

    # Check connections
    if (( $(echo "$connected_clients >= $REDIS_CONNECTIONS_CRITICAL" | bc -l) )); then
        add_alert "critical" "redis" "Redis connections critical" "$connected_clients" "$REDIS_CONNECTIONS_CRITICAL"
        score=$((score - 25))
    elif (( $(echo "$connected_clients >= $REDIS_CONNECTIONS_WARNING" | bc -l) )); then
        add_alert "warning" "redis" "Redis connections high" "$connected_clients" "$REDIS_CONNECTIONS_WARNING"
        score=$((score - 10))
    fi

    # Check hit rate (low hit rate is bad)
    if (( $(echo "$hit_rate < $REDIS_HIT_RATE_WARNING" | bc -l) )); then
        add_alert "warning" "redis" "Redis hit rate low" "$hit_rate" "$REDIS_HIT_RATE_WARNING"
        RECOMMENDATIONS+=("Review Redis cache strategy - low hit rate indicates ineffective caching")
        score=$((score - 10))
    fi

    # Check evictions
    if (( $(echo "$evictions_per_min >= $REDIS_EVICTIONS_CRITICAL" | bc -l) )); then
        add_alert "critical" "redis" "Redis evictions critical" "$evictions_per_min" "$REDIS_EVICTIONS_CRITICAL"
        RECOMMENDATIONS+=("Increase Redis memory or review cache TTL policies")
        score=$((score - 20))
    elif (( $(echo "$evictions_per_min >= $REDIS_EVICTIONS_WARNING" | bc -l) )); then
        add_alert "warning" "redis" "Redis evictions elevated" "$evictions_per_min" "$REDIS_EVICTIONS_WARNING"
        score=$((score - 10))
    fi

    # Check rejected connections
    if (( $(echo "$rejected_connections >= $REDIS_REJECTED_CONNECTIONS_WARNING" | bc -l) )); then
        add_alert "warning" "redis" "Redis rejected connections detected" "$rejected_connections" "$REDIS_REJECTED_CONNECTIONS_WARNING"
        RECOMMENDATIONS+=("Increase Redis maxclients configuration")
        score=$((score - 15))
    fi

    # Ensure score doesn't go negative
    if [[ $score -lt 0 ]]; then
        score=0
    fi

    echo "$score"
}

#######################################
# Collect WordOps/PHP-FPM metrics
#######################################

collect_wordops_metrics() {
    local wordops_installed=false
    local phpfpm_available=false

    if is_wordops_available; then
        wordops_installed=true
    fi

    if is_phpfpm_available; then
        phpfpm_available=true
    fi

    if [[ "$wordops_installed" == "false" && "$phpfpm_available" == "false" ]]; then
        echo '{"available": false}'
        return 0
    fi

    # Get PHP-FPM pools status
    local pools=()
    local total_active=0
    local total_idle=0
    local total_max=0
    local total_queue=0

    # Find PHP-FPM status pages
    for version in 8.3 8.2 8.1 8.0 7.4 7.3 7.2; do
        local status_url="http://127.0.0.1/status-php${version//./}"
        local pool_status

        if pool_status=$(curl -s --connect-timeout 2 "$status_url" 2>/dev/null); then
            if [[ "$pool_status" =~ pool ]]; then
                local pool_name active idle max_children listen_queue
                pool_name=$(echo "$pool_status" | awk '/^pool:/ {print $2}')
                active=$(echo "$pool_status" | awk '/^active processes:/ {print $3}')
                idle=$(echo "$pool_status" | awk '/^idle processes:/ {print $3}')
                max_children=$(echo "$pool_status" | awk '/^max children reached:/ {print $4}')
                listen_queue=$(echo "$pool_status" | awk '/^listen queue:/ {print $3}')

                total_active=$((total_active + ${active:-0}))
                total_idle=$((total_idle + ${idle:-0}))
                total_queue=$((total_queue + ${listen_queue:-0}))

                pools+=("$pool_name:$version")
            fi
        fi
    done

    # Fallback: parse from process list
    if [[ ${#pools[@]} -eq 0 ]]; then
        local fpm_processes
        fpm_processes=$(pgrep -c 'php-fpm' 2>/dev/null || echo "0")
        total_active=$fpm_processes
        total_idle=0
    fi

    # Get max_children from config (estimate)
    local config_max=0
    for conf in /etc/php/*/fpm/pool.d/*.conf /etc/php-fpm.d/*.conf; do
        if [[ -r "$conf" ]]; then
            local max
            max=$(grep -h "pm.max_children" "$conf" 2>/dev/null | awk -F= '{print $2}' | tr -d ' ')
            config_max=$((config_max + ${max:-0}))
        fi
    done

    if [[ $config_max -eq 0 ]]; then
        config_max=50  # Default assumption
    fi
    total_max=$config_max

    # Calculate utilization
    local fpm_percent
    if [[ $total_max -gt 0 ]]; then
        fpm_percent=$(echo "scale=1; 100 * $total_active / $total_max" | bc)
    else
        fpm_percent="0.0"
    fi

    # WordOps specific checks
    local sites_count=0
    local cache_status="unknown"
    local ssl_issues=0

    if [[ "$wordops_installed" == "true" ]]; then
        # Count sites
        sites_count=$(wo site list 2>/dev/null | wc -l || echo "0")

        # Check cache status (Redis/Memcached)
        if systemctl is-active --quiet redis-server 2>/dev/null; then
            cache_status="redis"
        elif systemctl is-active --quiet memcached 2>/dev/null; then
            cache_status="memcached"
        else
            cache_status="none"
        fi

        # Check SSL certificate expiry for all sites
        if command -v openssl &>/dev/null; then
            for site_dir in /var/www/*/; do
                local site_name
                site_name=$(basename "$site_dir")
                local cert_file="/etc/letsencrypt/live/$site_name/cert.pem"

                if [[ -f "$cert_file" ]]; then
                    local expiry_date expiry_epoch now_epoch days_until
                    expiry_date=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
                    if [[ -n "$expiry_date" ]]; then
                        expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || echo "0")
                        now_epoch=$(date +%s)
                        days_until=$(( (expiry_epoch - now_epoch) / 86400 ))

                        if [[ $days_until -lt $SSL_EXPIRY_CRITICAL ]]; then
                            ((ssl_issues++))
                        fi
                    fi
                fi
            done
        fi
    fi

    # Get PHP-FPM memory usage
    local mem_usage_kb
    mem_usage_kb=$(ps aux | grep '[p]hp-fpm' | awk '{sum+=$6} END {print sum+0}')
    local mem_usage_mb=$((mem_usage_kb / 1024))

    jq -nc \
        --arg avail "true" \
        --arg wo "$wordops_installed" \
        --arg fpm "$phpfpm_available" \
        --arg active "$total_active" \
        --arg idle "$total_idle" \
        --arg max "$total_max" \
        --arg fpmpct "$fpm_percent" \
        --arg queue "$total_queue" \
        --arg sites "$sites_count" \
        --arg cache "$cache_status" \
        --arg sslissues "$ssl_issues" \
        --arg mem "$mem_usage_mb" \
        --arg pools "${#pools[@]}" \
        '{
            available: ($avail | test("true")),
            wordops_installed: ($wo | test("true")),
            phpfpm_running: ($fpm | test("true")),
            fpm_active_processes: ($active | tonumber),
            fpm_idle_processes: ($idle | tonumber),
            fpm_max_processes: ($max | tonumber),
            fpm_utilization_percent: ($fpmpct | tonumber),
            fpm_listen_queue: ($queue | tonumber),
            sites_count: ($sites | tonumber),
            cache_backend: $cache,
            ssl_expiry_issues: ($sslissues | tonumber),
            memory_mb: ($mem | tonumber),
            pools_count: ($pools | tonumber)
        }'
}

#######################################
# Analyze WordOps/PHP-FPM metrics
#######################################

analyze_wordops_metrics() {
    local wordops_json="$1"

    local available
    available=$(echo "$wordops_json" | jq -r '.available // false')

    if [[ "$available" != "true" ]]; then
        echo "100"  # Not available, don't penalize
        return 0
    fi

    local fpm_utilization_percent fpm_listen_queue ssl_expiry_issues cache_backend
    fpm_utilization_percent=$(echo "$wordops_json" | jq -r '.fpm_utilization_percent // 0')
    fpm_listen_queue=$(echo "$wordops_json" | jq -r '.fpm_listen_queue // 0')
    ssl_expiry_issues=$(echo "$wordops_json" | jq -r '.ssl_expiry_issues // 0')
    cache_backend=$(echo "$wordops_json" | jq -r '.cache_backend // "unknown"')

    local score=100

    # Check PHP-FPM utilization
    if (( $(echo "$fpm_utilization_percent >= $PHPFPM_ACTIVE_CRITICAL" | bc -l) )); then
        add_alert "critical" "php-fpm" "PHP-FPM workers saturated" "$fpm_utilization_percent" "$PHPFPM_ACTIVE_CRITICAL"
        RECOMMENDATIONS+=("Increase PHP-FPM pm.max_children or optimize PHP scripts")
        score=$((score - 30))
    elif (( $(echo "$fpm_utilization_percent >= $PHPFPM_ACTIVE_WARNING" | bc -l) )); then
        add_alert "warning" "php-fpm" "PHP-FPM utilization high" "$fpm_utilization_percent" "$PHPFPM_ACTIVE_WARNING"
        score=$((score - 15))
    fi

    # Check listen queue
    if (( $(echo "$fpm_listen_queue >= $PHPFPM_QUEUE_CRITICAL" | bc -l) )); then
        add_alert "critical" "php-fpm" "PHP-FPM listen queue critical" "$fpm_listen_queue" "$PHPFPM_QUEUE_CRITICAL"
        RECOMMENDATIONS+=("PHP-FPM is queuing requests - increase workers or optimize code")
        score=$((score - 25))
    elif (( $(echo "$fpm_listen_queue >= $PHPFPM_QUEUE_WARNING" | bc -l) )); then
        add_alert "warning" "php-fpm" "PHP-FPM listen queue building" "$fpm_listen_queue" "$PHPFPM_QUEUE_WARNING"
        score=$((score - 10))
    fi

    # Check SSL expiry issues
    if [[ $ssl_expiry_issues -gt 0 ]]; then
        add_alert "critical" "ssl" "SSL certificates expiring soon" "$ssl_expiry_issues" "$SSL_EXPIRY_CRITICAL"
        RECOMMENDATIONS+=("Renew SSL certificates: wo site update --letsencrypt=renew")
        score=$((score - (ssl_expiry_issues * 10)))
    fi

    # Check cache backend
    if [[ "$cache_backend" == "none" ]]; then
        add_alert "warning" "wordops" "No cache backend detected" "0" "1"
        RECOMMENDATIONS+=("Consider enabling Redis or Memcached for better performance")
        score=$((score - 5))
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
    local cpu_json mem_json disk_json net_json svc_json rca_json
    local nginx_json apache_json mysql_json redis_json wordops_json

    timestamp="$1"
    hostname="$2"
    status="$3"
    score="$4"
    cpu_json="$5"
    mem_json="$6"
    disk_json="$7"
    net_json="$8"
    svc_json="$9"
    rca_json="${10}"
    nginx_json="${11:-{\}}"
    apache_json="${12:-{\}}"
    mysql_json="${13:-{\}}"
    redis_json="${14:-{\}}"
    wordops_json="${15:-{\}}"

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
        --argjson nginx "$nginx_json" \
        --argjson apache "$apache_json" \
        --argjson mysql "$mysql_json" \
        --argjson redis "$redis_json" \
        --argjson wordops "$wordops_json" \
        --argjson alerts "$alerts_json" \
        --argjson recs "$recs_json" \
        --argjson rca "$rca_json" \
        '{
            schema_version: "2.0.0",
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
                services: $svc,
                nginx: $nginx,
                apache: $apache,
                mysql: $mysql,
                redis: $redis,
                wordops: $wordops
            },
            alerts: $alerts,
            recommendations: $recs,
            root_cause_analysis: $rca
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

    # Nginx section (if available)
    local nginx_available
    nginx_available=$(echo "$json_output" | jq -r '.metrics.nginx.available // false')
    if [[ "$nginx_available" == "true" ]]; then
        echo "### Nginx"
        echo "$json_output" | jq -r '"- Active Connections: " + (.metrics.nginx.active_connections|tostring)'
        echo "$json_output" | jq -r '"- Max Connections: " + (.metrics.nginx.max_connections|tostring)'
        echo "$json_output" | jq -r '"- Error Rate: " + (.metrics.nginx.error_rate|tostring) + "%"'
        echo "$json_output" | jq -r '"- Memory: " + (.metrics.nginx.memory_mb|tostring) + "MB"'
        echo ""
    fi

    # Apache section (if available)
    local apache_available
    apache_available=$(echo "$json_output" | jq -r '.metrics.apache.available // false')
    if [[ "$apache_available" == "true" ]]; then
        echo "### Apache"
        echo "$json_output" | jq -r '"- Busy Workers: " + (.metrics.apache.busy_workers|tostring) + "/" + (.metrics.apache.max_workers|tostring) + " (" + (.metrics.apache.busy_percent|tostring) + "%)"'
        echo "$json_output" | jq -r '"- Requests/sec: " + (.metrics.apache.requests_per_sec|tostring)'
        echo "$json_output" | jq -r '"- Error Rate: " + (.metrics.apache.error_rate|tostring) + "%"'
        echo "$json_output" | jq -r '"- Memory: " + (.metrics.apache.memory_mb|tostring) + "MB"'
        echo ""
    fi

    # MySQL/MariaDB section (if available)
    local mysql_available
    mysql_available=$(echo "$json_output" | jq -r '.metrics.mysql.available // false')
    if [[ "$mysql_available" == "true" ]]; then
        echo "### MySQL/MariaDB"
        echo "$json_output" | jq -r '"- Connections: " + (.metrics.mysql.connections|tostring) + "/" + (.metrics.mysql.max_connections|tostring) + " (" + (.metrics.mysql.connection_percent|tostring) + "%)"'
        echo "$json_output" | jq -r '"- Threads Running: " + (.metrics.mysql.threads_running|tostring)'
        echo "$json_output" | jq -r '"- Queries/sec: " + (.metrics.mysql.queries_per_sec|tostring)'
        echo "$json_output" | jq -r '"- Slow Queries/min: " + (.metrics.mysql.slow_queries_per_min|tostring)'
        local is_replica
        is_replica=$(echo "$json_output" | jq -r '.metrics.mysql.is_replica // false')
        if [[ "$is_replica" == "true" ]]; then
            echo "$json_output" | jq -r '"- Replication Lag: " + (.metrics.mysql.replication_lag_sec|tostring) + "s"'
        fi
        echo ""
    fi

    # Redis section (if available)
    local redis_available
    redis_available=$(echo "$json_output" | jq -r '.metrics.redis.available // false')
    if [[ "$redis_available" == "true" ]]; then
        echo "### Redis"
        echo "$json_output" | jq -r '"- Memory: " + (.metrics.redis.memory_mb|tostring) + "MB (" + (.metrics.redis.memory_percent|tostring) + "%)"'
        echo "$json_output" | jq -r '"- Connected Clients: " + (.metrics.redis.connected_clients|tostring)'
        echo "$json_output" | jq -r '"- Hit Rate: " + (.metrics.redis.hit_rate|tostring) + "%"'
        echo "$json_output" | jq -r '"- Ops/sec: " + (.metrics.redis.ops_per_sec|tostring)'
        echo "$json_output" | jq -r '"- Total Keys: " + (.metrics.redis.total_keys|tostring)'
        echo ""
    fi

    # WordOps/PHP-FPM section (if available)
    local wordops_available
    wordops_available=$(echo "$json_output" | jq -r '.metrics.wordops.available // false')
    if [[ "$wordops_available" == "true" ]]; then
        local wordops_installed
        wordops_installed=$(echo "$json_output" | jq -r '.metrics.wordops.wordops_installed // false')
        if [[ "$wordops_installed" == "true" ]]; then
            echo "### WordOps"
            echo "$json_output" | jq -r '"- Sites: " + (.metrics.wordops.sites_count|tostring)'
            echo "$json_output" | jq -r '"- Cache Backend: " + .metrics.wordops.cache_backend'
            local ssl_issues
            ssl_issues=$(echo "$json_output" | jq -r '.metrics.wordops.ssl_expiry_issues // 0')
            if [[ $ssl_issues -gt 0 ]]; then
                echo "$json_output" | jq -r '"- SSL Expiry Issues: " + (.metrics.wordops.ssl_expiry_issues|tostring) + " ⚠️"'
            fi
        fi
        echo "### PHP-FPM"
        echo "$json_output" | jq -r '"- Active Processes: " + (.metrics.wordops.fpm_active_processes|tostring) + "/" + (.metrics.wordops.fpm_max_processes|tostring) + " (" + (.metrics.wordops.fpm_utilization_percent|tostring) + "%)"'
        echo "$json_output" | jq -r '"- Idle Processes: " + (.metrics.wordops.fpm_idle_processes|tostring)'
        echo "$json_output" | jq -r '"- Listen Queue: " + (.metrics.wordops.fpm_listen_queue|tostring)'
        echo "$json_output" | jq -r '"- Memory: " + (.metrics.wordops.memory_mb|tostring) + "MB"'
        echo ""
    fi

    # Root Cause Analysis
    local rca_enabled
    rca_enabled=$(echo "$json_output" | jq -r '.root_cause_analysis.enabled // false')
    if [[ "$rca_enabled" == "true" ]]; then
        echo "## 🔍 Root Cause Analysis"
        echo ""

        # Score change
        echo "### Performance Degradation Detected"
        echo "$json_output" | jq -r '"- Previous Score: " + (.root_cause_analysis.score_change.previous|tostring) + "/100"'
        echo "$json_output" | jq -r '"- Current Score: " + (.root_cause_analysis.score_change.current|tostring) + "/100"'
        echo "$json_output" | jq -r '"- Drop: " + (.root_cause_analysis.score_change.drop|tostring) + " points (-" + (.root_cause_analysis.score_change.drop_percent|tostring) + "%)"'
        echo ""

        # Diagnosis
        echo "### Diagnosis"
        echo "$json_output" | jq -r '"**" + .root_cause_analysis.diagnosis + "**"'
        echo ""
        echo "$json_output" | jq -r '"Suspicion: " + .root_cause_analysis.suspicion'
        echo ""

        # Recent changes
        local total_changes
        total_changes=$(echo "$json_output" | jq -r '.root_cause_analysis.recent_changes.total')
        if [[ $total_changes -gt 0 ]]; then
            echo "### Recent System Changes (Last $RCA_LOOKBACK_HOURS hours)"

            # Package changes
            local pkg_count
            pkg_count=$(echo "$json_output" | jq -r '.root_cause_analysis.recent_changes.packages | length')
            if [[ $pkg_count -gt 0 ]]; then
                echo ""
                echo "**Package Updates:**"
                echo "$json_output" | jq -r '.root_cause_analysis.recent_changes.packages[] | "- " + .timestamp + ": " + .type + " - " + .package'
            fi

            # Config changes
            local cfg_count
            cfg_count=$(echo "$json_output" | jq -r '.root_cause_analysis.recent_changes.configs | length')
            if [[ $cfg_count -gt 0 ]]; then
                echo ""
                echo "**Configuration Changes:**"
                echo "$json_output" | jq -r '.root_cause_analysis.recent_changes.configs[] | "- " + .timestamp + ": " + .file' | head -n 10
                if [[ $cfg_count -gt 10 ]]; then
                    echo "- ... and $((cfg_count - 10)) more files"
                fi
            fi

            # Service changes
            local svc_count
            svc_count=$(echo "$json_output" | jq -r '.root_cause_analysis.recent_changes.services | length')
            if [[ $svc_count -gt 0 ]]; then
                echo ""
                echo "**Service Restarts:**"
                echo "$json_output" | jq -r '.root_cause_analysis.recent_changes.services[] | "- " + .timestamp + ": " + .service + " (" + .type + ")"'
            fi
            echo ""
        fi

        # RCA Recommendations
        local rca_recs
        rca_recs=$(echo "$json_output" | jq -r '.root_cause_analysis.recommendations | length')
        if [[ $rca_recs -gt 0 ]]; then
            echo "### Recommended Actions"
            echo "$json_output" | jq -r '.root_cause_analysis.recommendations[] | "1. " + .'
            echo ""
        fi
    fi

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
# Check Prerequisites
# Verifies all required dependencies and configurations
#######################################

check_prerequisites() {
    # Temporarily disable errexit for checks
    set +e

    local -i pass_count=0 fail_count=0

    echo "════════════════════════════════════════════════════════════"
    echo "  Health Check - Prerequisites Verification"
    echo "════════════════════════════════════════════════════════════"
    echo ""

    # Check required commands
    echo "Checking Required Dependencies:"
    echo "────────────────────────────────────────────────────────────"

    local -a missing_apt=()

    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        if command -v "$cmd" &>/dev/null; then
            echo "  ✅ $cmd"
            ((pass_count++)) || true
        else
            echo "  ❌ $cmd - MISSING"
            ((fail_count++)) || true

            case "$cmd" in
                jq) missing_apt+=("jq") ;;
                bc) missing_apt+=("bc") ;;
                awk|date|df|nproc) missing_apt+=("coreutils") ;;
                free|uptime) missing_apt+=("procps") ;;
            esac
        fi
    done

    echo ""

    # Check optional commands
    echo "Checking Optional Dependencies:"
    echo "────────────────────────────────────────────────────────────"

    for cmd in "${OPTIONAL_COMMANDS[@]}"; do
        if command -v "$cmd" &>/dev/null; then
            echo "  ✅ $cmd"
        else
            echo "  ⚠️  $cmd - missing (optional)"
        fi
    done

    echo ""

    # Check sudo configuration
    echo "Checking Sudo Configuration:"
    echo "────────────────────────────────────────────────────────────"

    if timeout 2 sudo -n true &>/dev/null 2>&1; then
        if timeout 2 sudo -n dmesg --help &>/dev/null 2>&1; then
            echo "  ✅ sudo dmesg"
        else
            echo "  ⚠️  sudo dmesg - not configured (OOM detection unavailable)"
        fi

        if timeout 2 sudo -n journalctl --version &>/dev/null 2>&1; then
            echo "  ✅ sudo journalctl"
        else
            echo "  ⚠️  sudo journalctl - not configured"
        fi
    else
        echo "  ⚠️  sudo - not configured (passwordless sudo required)"
    fi

    echo ""

    # Check RCA directory
    echo "Checking RCA Configuration:"
    echo "────────────────────────────────────────────────────────────"

    if [[ -d "$RCA_HISTORY_DIR" ]]; then
        if [[ -w "$RCA_HISTORY_DIR" ]]; then
            echo "  ✅ $RCA_HISTORY_DIR (writable)"
        else
            echo "  ⚠️  $RCA_HISTORY_DIR (not writable - RCA degraded)"
        fi
    else
        echo "  ⚠️  $RCA_HISTORY_DIR (missing - RCA degraded)"
    fi

    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "  Summary: $pass_count passed, $fail_count failed"
    echo "════════════════════════════════════════════════════════════"
    echo ""

    if [[ $fail_count -gt 0 ]]; then
        echo "⚠️  Missing Dependencies Detected"
        echo ""

        if [[ ${#missing_apt[@]} -gt 0 ]]; then
            # Deduplicate packages
            local -a unique_packages
            mapfile -t unique_packages < <(printf '%s\n' "${missing_apt[@]}" | sort -u)

            echo "Install missing packages with:"
            echo "  sudo apt update"
            echo "  sudo apt install -y ${unique_packages[*]}"
            echo ""
        fi

        echo "Configure sudo with:"
        echo "  echo '$USER ALL=(root) NOPASSWD: /usr/bin/dmesg, /usr/bin/journalctl' | \\"
        echo "    sudo tee /etc/sudoers.d/health-check"
        echo "  sudo chmod 0440 /etc/sudoers.d/health-check"
        echo ""

        echo "Create RCA directory with:"
        echo "  sudo mkdir -p $RCA_HISTORY_DIR"
        echo "  sudo chown \$USER:\$USER $RCA_HISTORY_DIR"
        echo ""

        return 1
    else
        echo "✅ All required prerequisites met!"
        echo ""
        echo "Ready to run: ./$SCRIPT_NAME"
        echo ""
        set -e  # Re-enable errexit
        return 0
    fi

    set -e  # Re-enable errexit
}

#######################################
# Show help
#######################################

show_help() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Production-grade system health analyzer for Debian 12

OPTIONS:
    -h, --help                  Show this help message
    -v, --version               Show version information
    -q, --quiet                 Suppress output (exit code only)
    -j, --json                  Output JSON only (no markdown)
    -f, --format FORMAT         Output format: json|markdown
    -o, --output FILE           Write output to file instead of stdout
    -s, --score-only            Output health score only
    --no-color                  Disable colored output
    --debug                     Enable debug logging
    --check-prerequisites       Verify all dependencies and configuration

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
# Root Cause Analysis - Change Detection
#######################################

#######################################
# Collect recent package changes from dpkg log
# Returns: JSON array of package changes
#######################################
collect_package_changes() {
    local cutoff_time lookback_seconds
    lookback_seconds=$((RCA_LOOKBACK_HOURS * 3600))
    cutoff_time=$(date -d "@$(($(date +%s) - lookback_seconds))" '+%Y-%m-%d %H:%M:%S')

    local changes=()

    # Parse dpkg.log for installs, upgrades, removes
    if [[ -f /var/log/dpkg.log ]]; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2})\ (install|upgrade|remove)\ ([^:]+):?([^\ ]*)?\ (.+)$ ]]; then
                local timestamp="${BASH_REMATCH[1]}"
                local action="${BASH_REMATCH[2]}"
                local package="${BASH_REMATCH[3]}"
                # arch="${BASH_REMATCH[4]}" - not used
                local versions="${BASH_REMATCH[5]}"

                # Only include changes within lookback window
                if [[ "$timestamp" > "$cutoff_time" ]]; then
                    changes+=("$(jq -nc \
                        --arg ts "$timestamp" \
                        --arg act "$action" \
                        --arg pkg "$package" \
                        --arg ver "$versions" \
                        '{timestamp: $ts, type: "package_\($act)", package: $pkg, details: $ver}')")
                fi
            fi
        done < /var/log/dpkg.log
    fi

    # Combine into JSON array
    if [[ ${#changes[@]} -eq 0 ]]; then
        echo "[]"
    else
        printf '%s\n' "${changes[@]}" | jq -s '.'
    fi
}

#######################################
# Collect recent configuration file changes in /etc
# Returns: JSON array of file modifications
#######################################
collect_config_changes() {
    local lookback_minutes
    lookback_minutes=$((RCA_LOOKBACK_HOURS * 60))

    local changes=()

    # Find recently modified files in /etc
    while IFS= read -r file; do
        if [[ -f "$file" ]]; then
            local mtime
            mtime=$(stat -c '%Y' "$file" 2>/dev/null || echo "0")
            local mtime_human
            mtime_human=$(date -d "@$mtime" -Iseconds 2>/dev/null || echo "unknown")

            changes+=("$(jq -nc \
                --arg ts "$mtime_human" \
                --arg f "$file" \
                '{timestamp: $ts, type: "config_change", file: $f}')")
        fi
    done < <(find /etc -type f -mmin "-$lookback_minutes" 2>/dev/null | head -n 50)

    # Combine into JSON array
    if [[ ${#changes[@]} -eq 0 ]]; then
        echo "[]"
    else
        printf '%s\n' "${changes[@]}" | jq -s '.'
    fi
}

#######################################
# Collect recent service restarts from systemd journal
# Returns: JSON array of service changes
#######################################
collect_service_changes() {
    local lookback_seconds
    lookback_seconds=$((RCA_LOOKBACK_HOURS * 3600))

    local changes=()

    # Query systemd journal for service restarts
    if command -v journalctl &>/dev/null; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^([^\ ]+)\ ([0-9]{2}:[0-9]{2}:[0-9]{2}).*Started\ (.+)\.$ ]] || \
               [[ "$line" =~ ^([^\ ]+)\ ([0-9]{2}:[0-9]{2}:[0-9]{2}).*Stopped\ (.+)\.$ ]]; then
                local date="${BASH_REMATCH[1]}"
                local time="${BASH_REMATCH[2]}"
                local service="${BASH_REMATCH[3]}"
                local action="restart"

                [[ "$line" =~ Stopped ]] && action="stop"
                [[ "$line" =~ Started ]] && action="start"

                # Convert to ISO timestamp
                local timestamp
                timestamp=$(date -d "$date $time" -Iseconds 2>/dev/null || echo "unknown")

                changes+=("$(jq -nc \
                    --arg ts "$timestamp" \
                    --arg svc "$service" \
                    --arg act "$action" \
                    '{timestamp: $ts, type: "service_\($act)", service: $svc}')")
            fi
        done < <(journalctl --since "${lookback_seconds} seconds ago" --no-pager 2>/dev/null | grep -E "Started |Stopped " | tail -n 20)
    fi

    # Combine into JSON array
    if [[ ${#changes[@]} -eq 0 ]]; then
        echo "[]"
    else
        printf '%s\n' "${changes[@]}" | jq -s '.'
    fi
}

#######################################
# Load previous health score from history
# Returns: Previous score or empty string if no history
#######################################
load_previous_score() {
    if [[ -f "$RCA_HISTORY_FILE" ]]; then
        jq -r '.[-1].score // empty' "$RCA_HISTORY_FILE" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

#######################################
# Save current health score to history
# Args: $1 = timestamp, $2 = score
#######################################
save_health_score() {
    local timestamp="$1"
    local score="$2"

    # Create directory if it doesn't exist
    if [[ ! -d "$RCA_HISTORY_DIR" ]]; then
        mkdir -p "$RCA_HISTORY_DIR" 2>/dev/null || return 0
    fi

    # Check if directory is writable
    if [[ ! -w "$RCA_HISTORY_DIR" ]]; then
        return 0
    fi

    # Initialize history file if it doesn't exist
    if [[ ! -f "$RCA_HISTORY_FILE" ]]; then
        echo "[]" > "$RCA_HISTORY_FILE" 2>/dev/null || return 0
    fi

    # Check if file is writable
    if [[ ! -w "$RCA_HISTORY_FILE" ]]; then
        return 0
    fi

    # Append new entry
    local new_entry
    new_entry=$(jq -nc \
        --arg ts "$timestamp" \
        --arg sc "$score" \
        '{timestamp: $ts, score: ($sc | tonumber)}')

    # Keep only last 100 entries
    jq --argjson entry "$new_entry" '. += [$entry] | .[-100:]' "$RCA_HISTORY_FILE" > "${RCA_HISTORY_FILE}.tmp" 2>/dev/null && \
        mv "${RCA_HISTORY_FILE}.tmp" "$RCA_HISTORY_FILE" 2>/dev/null || true
}

#######################################
# Perform root cause analysis
# Args: $1 = current_score, $2 = previous_score
# Returns: JSON object with RCA results
#######################################
perform_root_cause_analysis() {
    local current_score="$1"
    local previous_score="$2"

    # If no previous score or no significant change, return minimal RCA
    if [[ -z "$previous_score" ]] || (( $(echo "$current_score >= $previous_score - 5" | bc -l) )); then
        jq -nc '{
            enabled: false,
            reason: "No significant score degradation detected"
        }'
        return 0
    fi

    # Calculate score drop
    local score_drop
    score_drop=$(echo "$previous_score - $current_score" | bc)
    local drop_percent
    drop_percent=$(echo "scale=1; ($score_drop / $previous_score) * 100" | bc)

    log_info "Performance degradation detected: $previous_score → $current_score (-${drop_percent}%)"
    log_info "Collecting change history for root cause analysis..."

    # Collect all changes
    local package_changes config_changes service_changes
    package_changes=$(collect_package_changes)
    config_changes=$(collect_config_changes)
    service_changes=$(collect_service_changes)

    # Count changes
    local pkg_count cfg_count svc_count
    pkg_count=$(echo "$package_changes" | jq 'length')
    cfg_count=$(echo "$config_changes" | jq 'length')
    svc_count=$(echo "$service_changes" | jq 'length')

    # Determine most likely cause
    local diagnosis=""
    local suspicion=""

    if [[ $pkg_count -gt 0 ]] && [[ $cfg_count -gt 0 ]]; then
        diagnosis="Performance degraded after package update(s) and configuration change(s)"
        suspicion="Package: $(echo "$package_changes" | jq -r '.[0].package // "unknown"'), Config: $(echo "$config_changes" | jq -r '.[0].file // "unknown"')"
    elif [[ $pkg_count -gt 0 ]]; then
        diagnosis="Performance degraded after package update(s)"
        suspicion="Package: $(echo "$package_changes" | jq -r '.[0].package // "unknown"')"
    elif [[ $cfg_count -gt 0 ]]; then
        diagnosis="Performance degraded after configuration change(s)"
        suspicion="Config: $(echo "$config_changes" | jq -r '.[0].file // "unknown"')"
    elif [[ $svc_count -gt 0 ]]; then
        diagnosis="Performance degraded around service restart(s)"
        suspicion="Service: $(echo "$service_changes" | jq -r '.[0].service // "unknown"')"
    else
        diagnosis="Performance degraded but no recent system changes detected"
        suspicion="May be external factors (load increase, resource contention)"
    fi

    # Generate recommendations
    local recommendations=()

    if [[ $pkg_count -gt 0 ]]; then
        recommendations+=("Review recently updated packages for known issues")
        recommendations+=("Consider rolling back suspect package updates")
    fi

    if [[ $cfg_count -gt 0 ]]; then
        recommendations+=("Review recent configuration changes")
        recommendations+=("Compare current config with previous versions")
    fi

    if [[ $svc_count -gt 0 ]]; then
        recommendations+=("Check service logs for errors after restart")
        recommendations+=("Verify service configuration is correct")
    fi

    if [[ ${#recommendations[@]} -eq 0 ]]; then
        recommendations+=("Investigate resource usage trends")
        recommendations+=("Check for external load increases")
    fi

    # Build RCA JSON
    jq -nc \
        --arg prev "$previous_score" \
        --arg curr "$current_score" \
        --arg drop "$score_drop" \
        --arg drop_pct "$drop_percent" \
        --arg diag "$diagnosis" \
        --arg susp "$suspicion" \
        --argjson pkgs "$package_changes" \
        --argjson cfgs "$config_changes" \
        --argjson svcs "$service_changes" \
        --argjson recs "$(printf '%s\n' "${recommendations[@]}" | jq -R . | jq -s .)" \
        '{
            enabled: true,
            score_change: {
                previous: ($prev | tonumber),
                current: ($curr | tonumber),
                drop: ($drop | tonumber),
                drop_percent: ($drop_pct | tonumber)
            },
            recent_changes: {
                packages: $pkgs,
                configs: $cfgs,
                services: $svcs,
                total: (($pkgs | length) + ($cfgs | length) + ($svcs | length))
            },
            diagnosis: $diag,
            suspicion: $susp,
            recommendations: $recs
        }'
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
                # shellcheck disable=SC2034  # NO_COLOR reserved for future use
                NO_COLOR=true
                shift
                ;;
            --debug)
                DEBUG_MODE=true
                shift
                ;;
            --check-prerequisites)
                trap - EXIT SIGTERM SIGINT  # Disable cleanup trap for check-prerequisites
                check_prerequisites
                exit $?
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
    local nginx_json apache_json mysql_json redis_json wordops_json

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

    # Collect optional service metrics (v2.0.0)
    # Use parallel collection for better performance (v2.1.0)
    log_info "Collecting optional service metrics..."

    # Create temp directory for parallel collection
    local temp_dir
    temp_dir=$(mktemp -d) || { log_error "Failed to create temp dir"; temp_dir=""; }

    if [[ -n "$temp_dir" ]]; then
        # Launch parallel collection jobs
        # Redirect stderr to /dev/null to avoid corrupting JSON output
        (collect_nginx_metrics 2>/dev/null > "$temp_dir/nginx.json" || echo '{"available": false}' > "$temp_dir/nginx.json") &
        local pid_nginx=$!

        (collect_apache_metrics 2>/dev/null > "$temp_dir/apache.json" || echo '{"available": false}' > "$temp_dir/apache.json") &
        local pid_apache=$!

        (collect_mysql_metrics 2>/dev/null > "$temp_dir/mysql.json" || echo '{"available": false}' > "$temp_dir/mysql.json") &
        local pid_mysql=$!

        (collect_redis_metrics 2>/dev/null > "$temp_dir/redis.json" || echo '{"available": false}' > "$temp_dir/redis.json") &
        local pid_redis=$!

        (collect_wordops_metrics 2>/dev/null > "$temp_dir/wordops.json" || echo '{"available": false}' > "$temp_dir/wordops.json") &
        local pid_wordops=$!

        # Wait for all jobs with timeout
        local timeout=10
        local waited=0
        while (( waited < timeout )); do
            local all_done=true
            for pid in $pid_nginx $pid_apache $pid_mysql $pid_redis $pid_wordops; do
                if kill -0 "$pid" 2>/dev/null; then
                    all_done=false
                    break
                fi
            done
            if $all_done; then
                break
            fi
            sleep 0.5
            ((waited++)) || true
        done

        # Kill any remaining jobs and wait to suppress "Killed" messages
        for pid in $pid_nginx $pid_apache $pid_mysql $pid_redis $pid_wordops; do
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null || true
                wait "$pid" 2>/dev/null || true
            fi
        done

        # Read results
        nginx_json=$(cat "$temp_dir/nginx.json" 2>/dev/null || echo '{"available": false}')
        apache_json=$(cat "$temp_dir/apache.json" 2>/dev/null || echo '{"available": false}')
        mysql_json=$(cat "$temp_dir/mysql.json" 2>/dev/null || echo '{"available": false}')
        redis_json=$(cat "$temp_dir/redis.json" 2>/dev/null || echo '{"available": false}')
        wordops_json=$(cat "$temp_dir/wordops.json" 2>/dev/null || echo '{"available": false}')

        # Cleanup temp directory
        rm -rf "$temp_dir"
    else
        # Fallback to sequential collection
        log_debug "Falling back to sequential collection"

        if ! nginx_json=$(collect_nginx_metrics 2>&1); then
            nginx_json='{"available": false}'
        fi

        if ! apache_json=$(collect_apache_metrics 2>&1); then
            apache_json='{"available": false}'
        fi

        if ! mysql_json=$(collect_mysql_metrics 2>&1); then
            mysql_json='{"available": false}'
        fi

        if ! redis_json=$(collect_redis_metrics 2>&1); then
            redis_json='{"available": false}'
        fi

        if ! wordops_json=$(collect_wordops_metrics 2>&1); then
            wordops_json='{"available": false}'
        fi
    fi

    # Analyze metrics and calculate scores
    log_info "Analyzing metrics..."

    local cpu_score mem_score disk_score net_score svc_score
    cpu_score=$(analyze_cpu_metrics "$cpu_json" || echo "50")
    mem_score=$(analyze_memory_metrics "$mem_json" || echo "50")
    disk_score=$(analyze_disk_metrics "$disk_json" || echo "50")
    net_score=$(analyze_network_metrics "$net_json" || echo "50")
    svc_score=$(analyze_services_metrics "$svc_json" || echo "50")

    # Analyze optional services (v2.0.0)
    local nginx_score apache_score mysql_score redis_score wordops_score
    nginx_score=$(analyze_nginx_metrics "$nginx_json" || echo "100")
    apache_score=$(analyze_apache_metrics "$apache_json" || echo "100")
    mysql_score=$(analyze_mysql_metrics "$mysql_json" || echo "100")
    redis_score=$(analyze_redis_metrics "$redis_json" || echo "100")
    wordops_score=$(analyze_wordops_metrics "$wordops_json" || echo "100")

    log_debug "Component scores - CPU: $cpu_score, Memory: $mem_score, Disk: $disk_score, Network: $net_score, Services: $svc_score"

    # Check which optional services are available and factor them into the score
    local optional_services_count=0
    local optional_services_total=0

    if [[ $(echo "$nginx_json" | jq -r '.available // false') == "true" ]]; then
        ((optional_services_count++)) || true
        optional_services_total=$((optional_services_total + nginx_score))
        log_debug "Nginx score: $nginx_score"
    fi

    if [[ $(echo "$apache_json" | jq -r '.available // false') == "true" ]]; then
        ((optional_services_count++)) || true
        optional_services_total=$((optional_services_total + apache_score))
        log_debug "Apache score: $apache_score"
    fi

    if [[ $(echo "$mysql_json" | jq -r '.available // false') == "true" ]]; then
        ((optional_services_count++)) || true
        optional_services_total=$((optional_services_total + mysql_score))
        log_debug "MySQL score: $mysql_score"
    fi

    if [[ $(echo "$redis_json" | jq -r '.available // false') == "true" ]]; then
        ((optional_services_count++)) || true
        optional_services_total=$((optional_services_total + redis_score))
        log_debug "Redis score: $redis_score"
    fi

    if [[ $(echo "$wordops_json" | jq -r '.available // false') == "true" ]]; then
        ((optional_services_count++)) || true
        optional_services_total=$((optional_services_total + wordops_score))
        log_debug "WordOps/PHP-FPM score: $wordops_score"
    fi

    # Calculate overall health score
    local health_score
    health_score=$(calculate_health_score "$cpu_score" "$mem_score" "$disk_score" "$net_score" "$svc_score")

    # Factor in optional services if any are present (10% weight for optional services combined)
    if [[ $optional_services_count -gt 0 ]]; then
        local optional_avg
        optional_avg=$((optional_services_total / optional_services_count))
        # Adjust: 90% base score + 10% optional services average
        health_score=$(echo "scale=0; ($health_score * 90 + $optional_avg * 10) / 100" | bc)
        log_debug "Optional services average: $optional_avg, Adjusted health score: $health_score"
    fi

    local health_status
    health_status=$(get_health_status "$health_score")

    # Generate output
    local timestamp hostname
    timestamp=$(date -Iseconds)
    hostname=$(hostname)

    # Root Cause Analysis
    log_info "Performing root cause analysis..."
    local previous_score rca_json
    previous_score=$(load_previous_score)
    rca_json=$(perform_root_cause_analysis "$health_score" "$previous_score")

    # Save current score for future RCA
    save_health_score "$timestamp" "$health_score"

    # Score-only mode
    if [[ "$SCORE_ONLY" == "true" ]]; then
        echo "$health_score"
        exit 0
    fi

    # Generate JSON
    local json_output
    json_output=$(generate_json_output "$timestamp" "$hostname" "$health_status" "$health_score" \
        "$cpu_json" "$mem_json" "$disk_json" "$net_json" "$svc_json" "$rca_json" \
        "$nginx_json" "$apache_json" "$mysql_json" "$redis_json" "$wordops_json")

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

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
readonly SCRIPT_VERSION="2.2.0"
# SC2155: Declare and assign separately
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

# Auto-discovery module
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/lib/auto-discovery.sh" ]]; then
    # shellcheck source=lib/auto-discovery.sh
    source "$SCRIPT_DIR/lib/auto-discovery.sh"
    AUTO_DISCOVERY_AVAILABLE=true
else
    AUTO_DISCOVERY_AVAILABLE=false
fi

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
ENABLE_AUTO_DISCOVERY=false
ENABLE_AUTO_HEALING=false

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
    # Check for running process (fallback for when command not in PATH)
    pgrep -x nginx &>/dev/null && return 0
    # Check for Docker container
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qi nginx && return 0
    return 1
}

is_apache_available() {
    # Check systemd services
    (command -v apache2 &>/dev/null || command -v httpd &>/dev/null) && \
    (systemctl is-active --quiet apache2 2>/dev/null || systemctl is-active --quiet httpd 2>/dev/null) && return 0
    # Check for running process
    pgrep -x apache2 &>/dev/null && return 0
    pgrep -x httpd &>/dev/null && return 0
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
    # Check systemd service (various service names)
    if command -v redis-cli &>/dev/null; then
        systemctl is-active --quiet redis-server 2>/dev/null && return 0
        systemctl is-active --quiet redis 2>/dev/null && return 0
    fi
    # Check for running process (fallback when redis-cli not installed)
    pgrep -x redis-server &>/dev/null && return 0
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

is_postgresql_available() {
    # Check systemd service
    if command -v psql &>/dev/null; then
        systemctl is-active --quiet postgresql 2>/dev/null && return 0
        systemctl is-active --quiet postgresql@* 2>/dev/null && return 0
    fi
    # Check for running process
    pgrep -x postgres &>/dev/null && return 0
    pgrep -x postmaster &>/dev/null && return 0
    # Check for Unix socket
    [[ -S /var/run/postgresql/.s.PGSQL.5432 ]] && return 0
    [[ -S /tmp/.s.PGSQL.5432 ]] && return 0
    return 1
}

is_memcached_available() {
    # Check systemd service
    systemctl is-active --quiet memcached 2>/dev/null && return 0
    # Check for running process
    pgrep -x memcached &>/dev/null && return 0
    # Check for Docker container
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qi memcached && return 0
    return 1
}

is_mongodb_available() {
    # Check systemd service
    systemctl is-active --quiet mongod 2>/dev/null && return 0
    systemctl is-active --quiet mongodb 2>/dev/null && return 0
    # Check for running process
    pgrep -x mongod &>/dev/null && return 0
    # Check for Docker container
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qi mongo && return 0
    return 1
}

is_elasticsearch_available() {
    # Check systemd service
    systemctl is-active --quiet elasticsearch 2>/dev/null && return 0
    # Check for running process
    pgrep -f "elasticsearch" &>/dev/null && return 0
    # Check for Docker container
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qi elasticsearch && return 0
    # Check if responding on default port
    curl -s --connect-timeout 2 "http://127.0.0.1:9200" &>/dev/null && return 0
    return 1
}

is_rabbitmq_available() {
    # Check systemd service
    systemctl is-active --quiet rabbitmq-server 2>/dev/null && return 0
    # Check for running process
    pgrep -f "beam.*rabbit" &>/dev/null && return 0
    # Check for Docker container
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qi rabbit && return 0
    return 1
}

is_fail2ban_available() {
    # Check systemd service
    systemctl is-active --quiet fail2ban 2>/dev/null && return 0
    # Check for running process
    pgrep -f "fail2ban-server" &>/dev/null && return 0
    return 1
}

is_postfix_available() {
    # Check systemd service
    systemctl is-active --quiet postfix 2>/dev/null && return 0
    # Check for running process (master is the main postfix process)
    pgrep -x master &>/dev/null && [[ -d /var/spool/postfix ]] && return 0
    return 1
}

is_dovecot_available() {
    # Check systemd service
    systemctl is-active --quiet dovecot 2>/dev/null && return 0
    # Check for running process
    pgrep -x dovecot &>/dev/null && return 0
    return 1
}

is_prometheus_available() {
    # Check systemd service
    systemctl is-active --quiet prometheus 2>/dev/null && return 0
    # Check for running process
    pgrep -x prometheus &>/dev/null && return 0
    # Check for Docker container
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qi prometheus && return 0
    # Check if responding on default port
    curl -s --connect-timeout 2 "http://127.0.0.1:9090/-/healthy" &>/dev/null && return 0
    return 1
}

is_grafana_available() {
    # Check systemd service
    systemctl is-active --quiet grafana-server 2>/dev/null && return 0
    # Check for running process
    pgrep -f "grafana-server" &>/dev/null && return 0
    # Check for Docker container
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qi grafana && return 0
    # Check if responding on default port
    curl -s --connect-timeout 2 "http://127.0.0.1:3000/api/health" &>/dev/null && return 0
    return 1
}

is_loki_available() {
    # Check systemd service
    systemctl is-active --quiet loki 2>/dev/null && return 0
    # Check for running process
    pgrep -x loki &>/dev/null && return 0
    # Check for Docker container
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qi loki && return 0
    # Check if responding on default port
    curl -s --connect-timeout 2 "http://127.0.0.1:3100/ready" &>/dev/null && return 0
    return 1
}

is_promtail_available() {
    # Check systemd service
    systemctl is-active --quiet promtail 2>/dev/null && return 0
    # Check for running process
    pgrep -x promtail &>/dev/null && return 0
    # Check for Docker container
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qi promtail && return 0
    return 1
}

is_node_exporter_available() {
    # Check systemd service
    systemctl is-active --quiet node_exporter 2>/dev/null && return 0
    systemctl is-active --quiet prometheus-node-exporter 2>/dev/null && return 0
    # Check for running process
    pgrep -f "node_exporter" &>/dev/null && return 0
    # Check if responding on default port
    curl -s --connect-timeout 2 "http://127.0.0.1:9100/metrics" &>/dev/null && return 0
    return 1
}

is_alertmanager_available() {
    # Check systemd service
    systemctl is-active --quiet alertmanager 2>/dev/null && return 0
    # Check for running process
    pgrep -x alertmanager &>/dev/null && return 0
    # Check for Docker container
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qi alertmanager && return 0
    # Check if responding on default port
    curl -s --connect-timeout 2 "http://127.0.0.1:9093/-/healthy" &>/dev/null && return 0
    return 1
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
    local use_sudo=false
    if [[ -f /etc/mysql/debian.cnf ]]; then
        if [[ -r /etc/mysql/debian.cnf ]]; then
            mysql_opts=("--defaults-file=/etc/mysql/debian.cnf")
        elif sudo -n test -r /etc/mysql/debian.cnf 2>/dev/null; then
            # Can use sudo without password prompt
            mysql_opts=("--defaults-file=/etc/mysql/debian.cnf")
            use_sudo=true
        fi
    fi

    # Helper function for safe MySQL execution
    run_mysql() {
        if [[ "$use_sudo" == "true" ]]; then
            sudo -n "$mysql_cmd" "${mysql_opts[@]}" "$@"
        else
            "$mysql_cmd" "${mysql_opts[@]}" "$@"
        fi
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
            use_sudo=false
            if run_mysql -e "SELECT 1" &>/dev/null 2>&1; then
                connected=true
                break
            fi
        fi
        ((retry_count++))
        sleep 0.5
    done

    # Try with sudo as last resort (for socket auth as root)
    if [[ "$connected" != "true" ]] && sudo -n true 2>/dev/null; then
        use_sudo=true
        mysql_opts=()
        if run_mysql -e "SELECT 1" &>/dev/null 2>&1; then
            connected=true
        fi
    fi

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

    # Check if redis-cli is available for metrics collection
    if ! command -v redis-cli &>/dev/null; then
        echo '{"available": true, "metrics_available": false, "reason": "redis-cli not installed"}'
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
# Collect PostgreSQL metrics
#######################################

collect_postgresql_metrics() {
    if ! is_postgresql_available; then
        echo '{"available": false}'
        return 0
    fi

    # Check if psql is available
    if ! command -v psql &>/dev/null; then
        echo '{"available": true, "metrics_available": false, "reason": "psql not installed"}'
        return 0
    fi

    # Build connection options
    local psql_cmd="psql"
    local use_sudo=false
    local connected=false

    # Try connecting as postgres user via sudo
    if sudo -n -u postgres psql -c "SELECT 1" &>/dev/null 2>&1; then
        use_sudo=true
        connected=true
    # Try direct connection (might work if peer auth configured)
    elif psql -c "SELECT 1" &>/dev/null 2>&1; then
        connected=true
    fi

    if [[ "$connected" != "true" ]]; then
        echo '{"available": true, "metrics_available": false, "reason": "connection_failed"}'
        return 0
    fi

    # Helper function
    run_psql() {
        if [[ "$use_sudo" == "true" ]]; then
            sudo -n -u postgres psql -t -A -c "$1" 2>/dev/null
        else
            psql -t -A -c "$1" 2>/dev/null
        fi
    }

    # Get connection stats
    local max_connections active_connections idle_connections
    max_connections=$(run_psql "SHOW max_connections;" | tr -d ' ')
    active_connections=$(run_psql "SELECT count(*) FROM pg_stat_activity WHERE state = 'active';" | tr -d ' ')
    idle_connections=$(run_psql "SELECT count(*) FROM pg_stat_activity WHERE state = 'idle';" | tr -d ' ')
    local total_connections=$((${active_connections:-0} + ${idle_connections:-0}))

    # Connection utilization
    local conn_percent=0
    if [[ ${max_connections:-0} -gt 0 ]]; then
        conn_percent=$(echo "scale=1; 100 * $total_connections / $max_connections" | bc)
    fi

    # Get database sizes
    local total_size_bytes
    total_size_bytes=$(run_psql "SELECT sum(pg_database_size(datname)) FROM pg_database WHERE datistemplate = false;" | tr -d ' ')
    local total_size_mb=$((${total_size_bytes:-0} / 1024 / 1024))

    # Get transaction stats
    local commits rollbacks
    commits=$(run_psql "SELECT sum(xact_commit) FROM pg_stat_database;" | tr -d ' ')
    rollbacks=$(run_psql "SELECT sum(xact_rollback) FROM pg_stat_database;" | tr -d ' ')

    # Get cache hit ratio
    local cache_hit_ratio
    cache_hit_ratio=$(run_psql "SELECT ROUND(100.0 * sum(blks_hit) / NULLIF(sum(blks_hit) + sum(blks_read), 0), 2) FROM pg_stat_database;" | tr -d ' ')

    # Get replication status (if any)
    local replication_lag=0
    local is_replica="false"
    if [[ $(run_psql "SELECT pg_is_in_recovery();" | tr -d ' ') == "t" ]]; then
        is_replica="true"
        replication_lag=$(run_psql "SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))::int;" | tr -d ' ')
    fi

    # Get database count
    local db_count
    db_count=$(run_psql "SELECT count(*) FROM pg_database WHERE datistemplate = false;" | tr -d ' ')

    # Get uptime
    local uptime_seconds
    uptime_seconds=$(run_psql "SELECT EXTRACT(EPOCH FROM (now() - pg_postmaster_start_time()))::int;" | tr -d ' ')

    # Get locks waiting
    local waiting_locks
    waiting_locks=$(run_psql "SELECT count(*) FROM pg_locks WHERE NOT granted;" | tr -d ' ')

    jq -nc \
        --arg avail "true" \
        --arg maxconn "${max_connections:-0}" \
        --arg activeconn "${active_connections:-0}" \
        --arg idleconn "${idle_connections:-0}" \
        --arg connpct "${conn_percent:-0}" \
        --arg totalsize "${total_size_mb:-0}" \
        --arg commits "${commits:-0}" \
        --arg rollbacks "${rollbacks:-0}" \
        --arg cachehit "${cache_hit_ratio:-0}" \
        --arg replica "$is_replica" \
        --arg replag "${replication_lag:-0}" \
        --arg dbcount "${db_count:-0}" \
        --arg uptime "${uptime_seconds:-0}" \
        --arg locks "${waiting_locks:-0}" \
        '{
            available: true,
            max_connections: ($maxconn | tonumber),
            active_connections: ($activeconn | tonumber),
            idle_connections: ($idleconn | tonumber),
            connection_percent: ($connpct | tonumber),
            total_size_mb: ($totalsize | tonumber),
            transactions_committed: ($commits | tonumber),
            transactions_rolled_back: ($rollbacks | tonumber),
            cache_hit_ratio: ($cachehit | tonumber),
            is_replica: ($replica | test("true")),
            replication_lag_seconds: ($replag | tonumber),
            database_count: ($dbcount | tonumber),
            uptime_seconds: ($uptime | tonumber),
            waiting_locks: ($locks | tonumber)
        }'
}

#######################################
# Collect Memcached metrics
#######################################

collect_memcached_metrics() {
    if ! is_memcached_available; then
        echo '{"available": false}'
        return 0
    fi

    # Try to get stats via netcat or telnet
    local stats=""
    if command -v nc &>/dev/null; then
        stats=$(echo "stats" | nc -q 1 127.0.0.1 11211 2>/dev/null || echo "")
    elif command -v telnet &>/dev/null; then
        stats=$(echo -e "stats\nquit" | timeout 2 telnet 127.0.0.1 11211 2>/dev/null || echo "")
    fi

    if [[ -z "$stats" ]] || [[ ! "$stats" =~ STAT ]]; then
        echo '{"available": true, "metrics_available": false, "reason": "cannot connect to memcached"}'
        return 0
    fi

    # Parse stats
    local curr_connections max_connections bytes limit_maxbytes
    local get_hits get_misses evictions uptime
    local bytes_read bytes_written curr_items

    curr_connections=$(echo "$stats" | awk '/STAT curr_connections/ {print $3}' | tr -d '\r')
    max_connections=$(echo "$stats" | awk '/STAT max_connections/ {print $3}' | tr -d '\r')
    bytes=$(echo "$stats" | awk '/STAT bytes / {print $3}' | tr -d '\r')
    limit_maxbytes=$(echo "$stats" | awk '/STAT limit_maxbytes/ {print $3}' | tr -d '\r')
    get_hits=$(echo "$stats" | awk '/STAT get_hits/ {print $3}' | tr -d '\r')
    get_misses=$(echo "$stats" | awk '/STAT get_misses/ {print $3}' | tr -d '\r')
    evictions=$(echo "$stats" | awk '/STAT evictions/ {print $3}' | tr -d '\r')
    uptime=$(echo "$stats" | awk '/STAT uptime/ {print $3}' | tr -d '\r')
    curr_items=$(echo "$stats" | awk '/STAT curr_items/ {print $3}' | tr -d '\r')

    # Calculate hit ratio
    local hit_ratio=0
    local total_gets=$((${get_hits:-0} + ${get_misses:-0}))
    if [[ $total_gets -gt 0 ]]; then
        hit_ratio=$(echo "scale=2; 100 * ${get_hits:-0} / $total_gets" | bc)
    fi

    # Calculate memory usage percent
    local mem_percent=0
    if [[ ${limit_maxbytes:-0} -gt 0 ]]; then
        mem_percent=$(echo "scale=1; 100 * ${bytes:-0} / ${limit_maxbytes:-0}" | bc)
    fi

    local mem_used_mb=$(( ${bytes:-0} / 1024 / 1024 ))
    local mem_max_mb=$(( ${limit_maxbytes:-0} / 1024 / 1024 ))

    jq -nc \
        --arg avail "true" \
        --arg currconn "${curr_connections:-0}" \
        --arg maxconn "${max_connections:-0}" \
        --arg memused "$mem_used_mb" \
        --arg memmax "$mem_max_mb" \
        --arg mempct "${mem_percent:-0}" \
        --arg hitratio "${hit_ratio:-0}" \
        --arg evict "${evictions:-0}" \
        --arg items "${curr_items:-0}" \
        --arg uptime "${uptime:-0}" \
        '{
            available: true,
            current_connections: ($currconn | tonumber),
            max_connections: ($maxconn | tonumber),
            memory_used_mb: ($memused | tonumber),
            memory_max_mb: ($memmax | tonumber),
            memory_percent: ($mempct | tonumber),
            hit_ratio: ($hitratio | tonumber),
            evictions: ($evict | tonumber),
            items: ($items | tonumber),
            uptime_seconds: ($uptime | tonumber)
        }'
}

#######################################
# Collect MongoDB metrics
#######################################

collect_mongodb_metrics() {
    if ! is_mongodb_available; then
        echo '{"available": false}'
        return 0
    fi

    # Determine which client to use
    local mongo_cmd=""
    if command -v mongosh &>/dev/null; then
        mongo_cmd="mongosh --quiet --eval"
    elif command -v mongo &>/dev/null; then
        mongo_cmd="mongo --quiet --eval"
    else
        echo '{"available": true, "metrics_available": false, "reason": "mongo client not installed"}'
        return 0
    fi

    # Test connection
    if ! $mongo_cmd "db.runCommand({ping: 1})" &>/dev/null 2>&1; then
        echo '{"available": true, "metrics_available": false, "reason": "connection_failed"}'
        return 0
    fi

    # Get server status
    local server_status
    server_status=$($mongo_cmd "JSON.stringify(db.serverStatus())" 2>/dev/null || echo "{}")

    if [[ "$server_status" == "{}" ]]; then
        echo '{"available": true, "metrics_available": false, "reason": "cannot get server status"}'
        return 0
    fi

    # Parse using jq
    local connections_current connections_available mem_resident mem_virtual
    local opcounters_query opcounters_insert opcounters_update opcounters_delete
    local uptime

    connections_current=$(echo "$server_status" | jq -r '.connections.current // 0')
    connections_available=$(echo "$server_status" | jq -r '.connections.available // 0')
    mem_resident=$(echo "$server_status" | jq -r '.mem.resident // 0')
    mem_virtual=$(echo "$server_status" | jq -r '.mem.virtual // 0')
    opcounters_query=$(echo "$server_status" | jq -r '.opcounters.query // 0')
    opcounters_insert=$(echo "$server_status" | jq -r '.opcounters.insert // 0')
    opcounters_update=$(echo "$server_status" | jq -r '.opcounters.update // 0')
    opcounters_delete=$(echo "$server_status" | jq -r '.opcounters.delete // 0')
    uptime=$(echo "$server_status" | jq -r '.uptime // 0')

    # Get database count and total size
    local db_stats
    db_stats=$($mongo_cmd "JSON.stringify(db.adminCommand({listDatabases: 1}))" 2>/dev/null || echo "{}")
    local db_count total_size_mb
    db_count=$(echo "$db_stats" | jq -r '.databases | length // 0')
    total_size_mb=$(echo "$db_stats" | jq -r '(.totalSize // 0) / 1024 / 1024 | floor')

    # Check replication status
    local is_replica="false"
    local repl_status
    repl_status=$($mongo_cmd "JSON.stringify(rs.status())" 2>/dev/null || echo "{}")
    if [[ $(echo "$repl_status" | jq -r '.ok // 0') == "1" ]]; then
        is_replica="true"
    fi

    jq -nc \
        --arg avail "true" \
        --arg connscurr "$connections_current" \
        --arg connsavail "$connections_available" \
        --arg memres "$mem_resident" \
        --arg memvirt "$mem_virtual" \
        --arg opquery "$opcounters_query" \
        --arg opinsert "$opcounters_insert" \
        --arg opupdate "$opcounters_update" \
        --arg opdelete "$opcounters_delete" \
        --arg uptime "$uptime" \
        --arg dbcount "$db_count" \
        --arg totalsize "$total_size_mb" \
        --arg replica "$is_replica" \
        '{
            available: true,
            connections_current: ($connscurr | tonumber),
            connections_available: ($connsavail | tonumber),
            memory_resident_mb: ($memres | tonumber),
            memory_virtual_mb: ($memvirt | tonumber),
            ops_query: ($opquery | tonumber),
            ops_insert: ($opinsert | tonumber),
            ops_update: ($opupdate | tonumber),
            ops_delete: ($opdelete | tonumber),
            uptime_seconds: ($uptime | tonumber),
            database_count: ($dbcount | tonumber),
            total_size_mb: ($totalsize | tonumber),
            is_replica_set: ($replica | test("true"))
        }'
}

#######################################
# Collect Elasticsearch metrics
#######################################

collect_elasticsearch_metrics() {
    if ! is_elasticsearch_available; then
        echo '{"available": false}'
        return 0
    fi

    local es_url="http://127.0.0.1:9200"

    # Test connection and get cluster health
    local cluster_health
    cluster_health=$(curl -s --connect-timeout 5 "$es_url/_cluster/health" 2>/dev/null || echo "")

    if [[ -z "$cluster_health" ]] || [[ ! "$cluster_health" =~ cluster_name ]]; then
        echo '{"available": true, "metrics_available": false, "reason": "cannot connect"}'
        return 0
    fi

    # Get node stats
    local node_stats
    node_stats=$(curl -s --connect-timeout 5 "$es_url/_nodes/stats" 2>/dev/null || echo "{}")

    # Parse cluster health
    local cluster_status num_nodes num_data_nodes active_shards relocating unassigned
    cluster_status=$(echo "$cluster_health" | jq -r '.status // "unknown"')
    num_nodes=$(echo "$cluster_health" | jq -r '.number_of_nodes // 0')
    num_data_nodes=$(echo "$cluster_health" | jq -r '.number_of_data_nodes // 0')
    active_shards=$(echo "$cluster_health" | jq -r '.active_shards // 0')
    relocating=$(echo "$cluster_health" | jq -r '.relocating_shards // 0')
    unassigned=$(echo "$cluster_health" | jq -r '.unassigned_shards // 0')

    # Get first node's stats for memory and disk
    local heap_used_mb heap_max_mb heap_percent disk_used_bytes disk_total_bytes
    heap_used_mb=$(echo "$node_stats" | jq -r '[.nodes[].jvm.mem.heap_used_in_bytes][0] // 0' | awk '{print int($1/1024/1024)}')
    heap_max_mb=$(echo "$node_stats" | jq -r '[.nodes[].jvm.mem.heap_max_in_bytes][0] // 0' | awk '{print int($1/1024/1024)}')
    heap_percent=$(echo "$node_stats" | jq -r '[.nodes[].jvm.mem.heap_used_percent][0] // 0')

    # Get indices stats
    local indices_stats
    indices_stats=$(curl -s --connect-timeout 5 "$es_url/_stats" 2>/dev/null || echo "{}")
    local docs_count store_size_mb
    docs_count=$(echo "$indices_stats" | jq -r '._all.primaries.docs.count // 0')
    store_size_mb=$(echo "$indices_stats" | jq -r '._all.primaries.store.size_in_bytes // 0' | awk '{print int($1/1024/1024)}')

    # Get index count
    local index_count
    index_count=$(curl -s --connect-timeout 5 "$es_url/_cat/indices?format=json" 2>/dev/null | jq -r 'length // 0')

    jq -nc \
        --arg avail "true" \
        --arg status "$cluster_status" \
        --arg nodes "$num_nodes" \
        --arg datanodes "$num_data_nodes" \
        --arg shards "$active_shards" \
        --arg reloc "$relocating" \
        --arg unassign "$unassigned" \
        --arg heapused "$heap_used_mb" \
        --arg heapmax "$heap_max_mb" \
        --arg heappct "$heap_percent" \
        --arg docs "$docs_count" \
        --arg storesize "$store_size_mb" \
        --arg indices "$index_count" \
        '{
            available: true,
            cluster_status: $status,
            nodes: ($nodes | tonumber),
            data_nodes: ($datanodes | tonumber),
            active_shards: ($shards | tonumber),
            relocating_shards: ($reloc | tonumber),
            unassigned_shards: ($unassign | tonumber),
            heap_used_mb: ($heapused | tonumber),
            heap_max_mb: ($heapmax | tonumber),
            heap_percent: ($heappct | tonumber),
            documents: ($docs | tonumber),
            store_size_mb: ($storesize | tonumber),
            index_count: ($indices | tonumber)
        }'
}

#######################################
# Collect RabbitMQ metrics
#######################################

collect_rabbitmq_metrics() {
    if ! is_rabbitmq_available; then
        echo '{"available": false}'
        return 0
    fi

    # Check if rabbitmqctl is available
    if ! command -v rabbitmqctl &>/dev/null; then
        echo '{"available": true, "metrics_available": false, "reason": "rabbitmqctl not installed"}'
        return 0
    fi

    # Try to get status (may need sudo)
    local status=""
    local use_sudo=false

    if rabbitmqctl status &>/dev/null 2>&1; then
        status=$(rabbitmqctl status 2>/dev/null)
    elif sudo -n rabbitmqctl status &>/dev/null 2>&1; then
        status=$(sudo -n rabbitmqctl status 2>/dev/null)
        use_sudo=true
    else
        echo '{"available": true, "metrics_available": false, "reason": "cannot get status"}'
        return 0
    fi

    # Helper function
    run_rabbitmqctl() {
        if [[ "$use_sudo" == "true" ]]; then
            sudo -n rabbitmqctl "$@" 2>/dev/null
        else
            rabbitmqctl "$@" 2>/dev/null
        fi
    }

    # Get overview via management API or rabbitmqctl
    local total_connections=0
    local total_channels=0
    local total_queues=0
    local messages_ready=0
    local messages_unacked=0
    local mem_used_mb=0

    # Try management API first (if available)
    local api_response
    api_response=$(curl -s --connect-timeout 2 -u guest:guest "http://127.0.0.1:15672/api/overview" 2>/dev/null || echo "")

    if [[ -n "$api_response" ]] && [[ "$api_response" =~ cluster_name ]]; then
        total_connections=$(echo "$api_response" | jq -r '.object_totals.connections // 0')
        total_channels=$(echo "$api_response" | jq -r '.object_totals.channels // 0')
        total_queues=$(echo "$api_response" | jq -r '.object_totals.queues // 0')
        messages_ready=$(echo "$api_response" | jq -r '.queue_totals.messages_ready // 0')
        messages_unacked=$(echo "$api_response" | jq -r '.queue_totals.messages_unacknowledged // 0')
        mem_used_mb=$(echo "$api_response" | jq -r '(.node_mem // 0) / 1024 / 1024 | floor')
    else
        # Fallback to rabbitmqctl
        total_connections=$(run_rabbitmqctl list_connections 2>/dev/null | wc -l || echo "0")
        total_queues=$(run_rabbitmqctl list_queues 2>/dev/null | wc -l || echo "0")

        # Get memory from status
        mem_used_mb=$(echo "$status" | grep -oP 'total,\K[0-9]+' | head -1 || echo "0")
        mem_used_mb=$((mem_used_mb / 1024 / 1024))
    fi

    # Get consumers count
    local consumers
    consumers=$(run_rabbitmqctl list_consumers 2>/dev/null | wc -l || echo "0")

    jq -nc \
        --arg avail "true" \
        --arg conns "$total_connections" \
        --arg chans "$total_channels" \
        --arg queues "$total_queues" \
        --arg ready "$messages_ready" \
        --arg unacked "$messages_unacked" \
        --arg consumers "$consumers" \
        --arg mem "$mem_used_mb" \
        '{
            available: true,
            connections: ($conns | tonumber),
            channels: ($chans | tonumber),
            queues: ($queues | tonumber),
            messages_ready: ($ready | tonumber),
            messages_unacknowledged: ($unacked | tonumber),
            consumers: ($consumers | tonumber),
            memory_mb: ($mem | tonumber)
        }'
}

#######################################
# Collect Fail2ban metrics
#######################################

collect_fail2ban_metrics() {
    if ! is_fail2ban_available; then
        echo '{"available": false}'
        return 0
    fi

    local use_sudo=false
    local status=""

    if fail2ban-client status &>/dev/null 2>&1; then
        status=$(fail2ban-client status 2>/dev/null)
    elif sudo -n fail2ban-client status &>/dev/null 2>&1; then
        status=$(sudo -n fail2ban-client status 2>/dev/null)
        use_sudo=true
    else
        echo '{"available": true, "metrics_available": false, "reason": "cannot get status"}'
        return 0
    fi

    # Helper
    run_f2b() {
        if [[ "$use_sudo" == "true" ]]; then
            sudo -n fail2ban-client "$@" 2>/dev/null
        else
            fail2ban-client "$@" 2>/dev/null
        fi
    }

    # Get jail list
    local jails
    jails=$(echo "$status" | grep "Jail list:" | sed 's/.*Jail list:\s*//' | tr -d '\t' | tr ',' '\n' | tr -d ' ')

    local total_banned=0
    local total_jails=0
    local jail_details=()

    for jail in $jails; do
        [[ -z "$jail" ]] && continue
        ((total_jails++))

        local jail_status
        jail_status=$(run_f2b status "$jail" 2>/dev/null)

        local currently_banned
        currently_banned=$(echo "$jail_status" | grep "Currently banned:" | awk '{print $NF}')
        total_banned=$((total_banned + ${currently_banned:-0}))
    done

    jq -nc \
        --arg avail "true" \
        --arg jails "$total_jails" \
        --arg banned "$total_banned" \
        '{
            available: true,
            jails_active: ($jails | tonumber),
            total_banned: ($banned | tonumber)
        }'
}

#######################################
# Collect Docker metrics
#######################################

collect_docker_metrics() {
    if ! is_docker_available; then
        echo '{"available": false}'
        return 0
    fi

    # Get container counts
    local running stopped total
    running=$(docker ps -q 2>/dev/null | wc -l)
    total=$(docker ps -a -q 2>/dev/null | wc -l)
    stopped=$((total - running))

    # Get containers with high restart counts
    local high_restarts=0
    while IFS= read -r restart_count; do
        if [[ ${restart_count:-0} -gt 5 ]]; then
            ((high_restarts++))
        fi
    done < <(docker ps --format '{{.Names}}' 2>/dev/null | while read name; do
        docker inspect --format '{{.RestartCount}}' "$name" 2>/dev/null
    done)

    # Get unhealthy containers
    local unhealthy
    unhealthy=$(docker ps --filter "health=unhealthy" -q 2>/dev/null | wc -l)

    # Get image count
    local images
    images=$(docker images -q 2>/dev/null | wc -l)

    # Get disk usage (might need parsing)
    local disk_usage_gb=0
    local disk_output
    disk_output=$(docker system df --format '{{.Size}}' 2>/dev/null | head -1 || echo "0")
    if [[ "$disk_output" =~ ([0-9.]+)GB ]]; then
        disk_usage_gb="${BASH_REMATCH[1]}"
    elif [[ "$disk_output" =~ ([0-9.]+)MB ]]; then
        disk_usage_gb=$(echo "scale=2; ${BASH_REMATCH[1]} / 1024" | bc)
    fi

    # Get volume count
    local volumes
    volumes=$(docker volume ls -q 2>/dev/null | wc -l)

    # Get network count
    local networks
    networks=$(docker network ls -q 2>/dev/null | wc -l)

    jq -nc \
        --arg avail "true" \
        --arg running "$running" \
        --arg stopped "$stopped" \
        --arg total "$total" \
        --arg unhealthy "$unhealthy" \
        --arg restarts "$high_restarts" \
        --arg images "$images" \
        --arg diskgb "$disk_usage_gb" \
        --arg volumes "$volumes" \
        --arg networks "$networks" \
        '{
            available: true,
            containers_running: ($running | tonumber),
            containers_stopped: ($stopped | tonumber),
            containers_total: ($total | tonumber),
            containers_unhealthy: ($unhealthy | tonumber),
            containers_high_restarts: ($restarts | tonumber),
            images: ($images | tonumber),
            disk_usage_gb: ($diskgb | tonumber),
            volumes: ($volumes | tonumber),
            networks: ($networks | tonumber)
        }'
}

#######################################
# Collect Postfix metrics
#######################################

collect_postfix_metrics() {
    if ! is_postfix_available; then
        echo '{"available": false}'
        return 0
    fi

    # Get queue counts
    local queue_active=0
    local queue_deferred=0
    local queue_hold=0
    local queue_incoming=0

    if command -v mailq &>/dev/null; then
        local mailq_output
        mailq_output=$(mailq 2>/dev/null || sudo -n mailq 2>/dev/null || echo "")

        if [[ "$mailq_output" =~ "Mail queue is empty" ]]; then
            queue_active=0
        else
            queue_active=$(echo "$mailq_output" | grep -c "^[A-F0-9]" || echo "0")
        fi
    fi

    # Try to get more detailed queue info
    if command -v postqueue &>/dev/null; then
        queue_deferred=$(find /var/spool/postfix/deferred -type f 2>/dev/null | wc -l || echo "0")
        queue_active=$(find /var/spool/postfix/active -type f 2>/dev/null | wc -l || echo "0")
        queue_hold=$(find /var/spool/postfix/hold -type f 2>/dev/null | wc -l || echo "0")
        queue_incoming=$(find /var/spool/postfix/incoming -type f 2>/dev/null | wc -l || echo "0")
    fi

    local total_queue=$((queue_active + queue_deferred + queue_hold + queue_incoming))

    jq -nc \
        --arg avail "true" \
        --arg active "$queue_active" \
        --arg deferred "$queue_deferred" \
        --arg hold "$queue_hold" \
        --arg incoming "$queue_incoming" \
        --arg total "$total_queue" \
        '{
            available: true,
            queue_active: ($active | tonumber),
            queue_deferred: ($deferred | tonumber),
            queue_hold: ($hold | tonumber),
            queue_incoming: ($incoming | tonumber),
            queue_total: ($total | tonumber)
        }'
}

#######################################
# Collect Dovecot metrics
#######################################

collect_dovecot_metrics() {
    if ! is_dovecot_available; then
        echo '{"available": false}'
        return 0
    fi

    local use_sudo=false

    # Check if we can run doveadm
    if ! command -v doveadm &>/dev/null; then
        echo '{"available": true, "metrics_available": false, "reason": "doveadm not installed"}'
        return 0
    fi

    # Try to get stats
    local stats=""
    if doveadm stats dump 2>/dev/null | head -1 &>/dev/null; then
        stats=$(doveadm stats dump 2>/dev/null)
    elif sudo -n doveadm stats dump 2>/dev/null | head -1 &>/dev/null; then
        stats=$(sudo -n doveadm stats dump 2>/dev/null)
        use_sudo=true
    fi

    # Get connection counts
    local imap_connections=0
    local pop3_connections=0

    if [[ "$use_sudo" == "true" ]]; then
        imap_connections=$(sudo -n doveadm who -1 2>/dev/null | grep -c "imap" || echo "0")
        pop3_connections=$(sudo -n doveadm who -1 2>/dev/null | grep -c "pop3" || echo "0")
    else
        imap_connections=$(doveadm who -1 2>/dev/null | grep -c "imap" || echo "0")
        pop3_connections=$(doveadm who -1 2>/dev/null | grep -c "pop3" || echo "0")
    fi

    local total_connections=$((${imap_connections:-0} + ${pop3_connections:-0}))

    jq -nc \
        --arg avail "true" \
        --arg imap "${imap_connections:-0}" \
        --arg pop3 "${pop3_connections:-0}" \
        --arg total "$total_connections" \
        '{
            available: true,
            imap_connections: ($imap | tonumber),
            pop3_connections: ($pop3 | tonumber),
            total_connections: ($total | tonumber)
        }'
}

#######################################
# Collect Prometheus metrics
#######################################

collect_prometheus_metrics() {
    if ! is_prometheus_available; then
        echo '{"available": false}'
        return 0
    fi

    local prom_url="http://127.0.0.1:9090"

    # Check health
    local health
    health=$(curl -s --connect-timeout 5 "$prom_url/-/healthy" 2>/dev/null || echo "")

    if [[ "$health" != "Prometheus Server is Healthy." ]] && [[ "$health" != "OK" ]]; then
        echo '{"available": true, "metrics_available": false, "reason": "health check failed"}'
        return 0
    fi

    # Get runtime info
    local runtime_info
    runtime_info=$(curl -s --connect-timeout 5 "$prom_url/api/v1/status/runtimeinfo" 2>/dev/null || echo "{}")

    # Get TSDB stats
    local tsdb_stats
    tsdb_stats=$(curl -s --connect-timeout 5 "$prom_url/api/v1/status/tsdb" 2>/dev/null || echo "{}")

    # Get targets
    local targets
    targets=$(curl -s --connect-timeout 5 "$prom_url/api/v1/targets" 2>/dev/null || echo "{}")

    # Parse values
    local storage_retention uptime_seconds
    storage_retention=$(echo "$runtime_info" | jq -r '.data.storageRetention // "unknown"')
    uptime_seconds=$(echo "$runtime_info" | jq -r '.data.startTime // ""' | xargs -I {} date -d {} +%s 2>/dev/null || echo "0")
    if [[ -n "$uptime_seconds" ]] && [[ "$uptime_seconds" != "0" ]]; then
        uptime_seconds=$(($(date +%s) - uptime_seconds))
    fi

    local head_series head_chunks
    head_series=$(echo "$tsdb_stats" | jq -r '.data.headStats.numSeries // 0')
    head_chunks=$(echo "$tsdb_stats" | jq -r '.data.headStats.numChunks // 0')

    # Count targets
    local active_targets down_targets
    active_targets=$(echo "$targets" | jq -r '[.data.activeTargets[]] | length // 0')
    down_targets=$(echo "$targets" | jq -r '[.data.activeTargets[] | select(.health != "up")] | length // 0')

    # Get alerting rules count
    local rules
    rules=$(curl -s --connect-timeout 5 "$prom_url/api/v1/rules" 2>/dev/null || echo "{}")
    local total_rules firing_alerts
    total_rules=$(echo "$rules" | jq -r '[.data.groups[].rules[]] | length // 0')
    firing_alerts=$(echo "$rules" | jq -r '[.data.groups[].rules[] | select(.state == "firing")] | length // 0')

    jq -nc \
        --arg avail "true" \
        --arg retention "$storage_retention" \
        --arg uptime "${uptime_seconds:-0}" \
        --arg series "$head_series" \
        --arg chunks "$head_chunks" \
        --arg targets "$active_targets" \
        --arg down "$down_targets" \
        --arg rules "$total_rules" \
        --arg firing "$firing_alerts" \
        '{
            available: true,
            storage_retention: $retention,
            uptime_seconds: ($uptime | tonumber),
            head_series: ($series | tonumber),
            head_chunks: ($chunks | tonumber),
            active_targets: ($targets | tonumber),
            down_targets: ($down | tonumber),
            total_rules: ($rules | tonumber),
            firing_alerts: ($firing | tonumber)
        }'
}

#######################################
# Collect Grafana metrics
#######################################

collect_grafana_metrics() {
    if ! is_grafana_available; then
        echo '{"available": false}'
        return 0
    fi

    local grafana_url="http://127.0.0.1:3000"
    local api_key=""

    # Try to find API key from common secret locations
    for secret_file in /etc/grafana/api_key /etc/grafana/secrets/api_key /var/lib/grafana/api_key ~/.grafana_api_key; do
        if [[ -r "$secret_file" ]]; then
            api_key=$(cat "$secret_file" 2>/dev/null | tr -d '\n')
            break
        fi
    done

    # Check health (doesn't require auth)
    local health
    health=$(curl -s --connect-timeout 5 "$grafana_url/api/health" 2>/dev/null || echo "{}")

    if [[ ! "$health" =~ database ]]; then
        echo '{"available": true, "metrics_available": false, "reason": "health check failed"}'
        return 0
    fi

    local db_status version
    db_status=$(echo "$health" | jq -r '.database // "unknown"')
    version=$(echo "$health" | jq -r '.version // "unknown"')

    # Try to get more stats with API key if available
    local dashboards=0
    local datasources=0
    local users=0
    local orgs=0

    if [[ -n "$api_key" ]]; then
        local auth_header="Authorization: Bearer $api_key"

        # Get dashboard count
        local search_result
        search_result=$(curl -s --connect-timeout 5 -H "$auth_header" "$grafana_url/api/search?type=dash-db" 2>/dev/null || echo "[]")
        dashboards=$(echo "$search_result" | jq -r 'length // 0')

        # Get datasources count
        local ds_result
        ds_result=$(curl -s --connect-timeout 5 -H "$auth_header" "$grafana_url/api/datasources" 2>/dev/null || echo "[]")
        datasources=$(echo "$ds_result" | jq -r 'length // 0')

        # Get users count (admin only)
        local users_result
        users_result=$(curl -s --connect-timeout 5 -H "$auth_header" "$grafana_url/api/org/users" 2>/dev/null || echo "[]")
        users=$(echo "$users_result" | jq -r 'length // 0')
    fi

    jq -nc \
        --arg avail "true" \
        --arg db "$db_status" \
        --arg ver "$version" \
        --arg dash "$dashboards" \
        --arg ds "$datasources" \
        --arg users "$users" \
        '{
            available: true,
            database_status: $db,
            version: $ver,
            dashboards: ($dash | tonumber),
            datasources: ($ds | tonumber),
            users: ($users | tonumber)
        }'
}

#######################################
# Collect Loki metrics
#######################################

collect_loki_metrics() {
    if ! is_loki_available; then
        echo '{"available": false}'
        return 0
    fi

    local loki_url="http://127.0.0.1:3100"

    # Check ready status
    local ready
    ready=$(curl -s --connect-timeout 5 "$loki_url/ready" 2>/dev/null || echo "")

    if [[ "$ready" != "ready" ]]; then
        echo '{"available": true, "metrics_available": false, "reason": "not ready"}'
        return 0
    fi

    # Get metrics
    local metrics
    metrics=$(curl -s --connect-timeout 5 "$loki_url/metrics" 2>/dev/null || echo "")

    # Parse key metrics
    local ingester_streams=0
    local ingester_chunks=0
    local distributor_bytes_received=0

    if [[ -n "$metrics" ]]; then
        ingester_streams=$(echo "$metrics" | grep "^loki_ingester_streams_created_total" | awk '{sum+=$2} END {print sum+0}')
        ingester_chunks=$(echo "$metrics" | grep "^loki_ingester_chunks_stored_total" | awk '{sum+=$2} END {print sum+0}')
        distributor_bytes_received=$(echo "$metrics" | grep "^loki_distributor_bytes_received_total" | awk '{sum+=$2} END {print sum+0}')
    fi

    # Get build info
    local build_info
    build_info=$(curl -s --connect-timeout 5 "$loki_url/loki/api/v1/status/buildinfo" 2>/dev/null || echo "{}")
    local version
    version=$(echo "$build_info" | jq -r '.version // "unknown"')

    local bytes_mb=$((${distributor_bytes_received:-0} / 1024 / 1024))

    jq -nc \
        --arg avail "true" \
        --arg ver "$version" \
        --arg streams "${ingester_streams:-0}" \
        --arg chunks "${ingester_chunks:-0}" \
        --arg bytesmb "$bytes_mb" \
        '{
            available: true,
            version: $ver,
            streams_created: ($streams | tonumber),
            chunks_stored: ($chunks | tonumber),
            bytes_received_mb: ($bytesmb | tonumber)
        }'
}

#######################################
# Collect Alertmanager metrics
#######################################

collect_alertmanager_metrics() {
    if ! is_alertmanager_available; then
        echo '{"available": false}'
        return 0
    fi

    local am_url="http://127.0.0.1:9093"

    # Check health
    local health
    health=$(curl -s --connect-timeout 5 "$am_url/-/healthy" 2>/dev/null || echo "")

    if [[ "$health" != "OK" ]]; then
        echo '{"available": true, "metrics_available": false, "reason": "health check failed"}'
        return 0
    fi

    # Get status
    local status
    status=$(curl -s --connect-timeout 5 "$am_url/api/v2/status" 2>/dev/null || echo "{}")

    # Get alerts
    local alerts
    alerts=$(curl -s --connect-timeout 5 "$am_url/api/v2/alerts" 2>/dev/null || echo "[]")

    # Get silences
    local silences
    silences=$(curl -s --connect-timeout 5 "$am_url/api/v2/silences" 2>/dev/null || echo "[]")

    # Parse values
    local cluster_status uptime version
    cluster_status=$(echo "$status" | jq -r '.cluster.status // "unknown"')
    uptime=$(echo "$status" | jq -r '.uptime // "0s"')
    version=$(echo "$status" | jq -r '.versionInfo.version // "unknown"')

    local active_alerts suppressed_alerts active_silences
    active_alerts=$(echo "$alerts" | jq -r '[.[] | select(.status.state == "active")] | length // 0')
    suppressed_alerts=$(echo "$alerts" | jq -r '[.[] | select(.status.state == "suppressed")] | length // 0')
    active_silences=$(echo "$silences" | jq -r '[.[] | select(.status.state == "active")] | length // 0')

    jq -nc \
        --arg avail "true" \
        --arg ver "$version" \
        --arg cluster "$cluster_status" \
        --arg uptime "$uptime" \
        --arg active "$active_alerts" \
        --arg suppressed "$suppressed_alerts" \
        --arg silences "$active_silences" \
        '{
            available: true,
            version: $ver,
            cluster_status: $cluster,
            uptime: $uptime,
            active_alerts: ($active | tonumber),
            suppressed_alerts: ($suppressed | tonumber),
            active_silences: ($silences | tonumber)
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
    local extended_services_json

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
    extended_services_json="${16:-{\}}"

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
        --argjson extended "$extended_services_json" \
        --argjson alerts "$alerts_json" \
        --argjson recs "$recs_json" \
        --argjson rca "$rca_json" \
        '{
            schema_version: "2.2.0",
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
                wordops: $wordops,
                extended: $extended
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
    --auto-discover             Enable auto-discovery of unknown components
    --auto-heal                 Enable auto-healing (with user prompts)

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
            --auto-discover)
                ENABLE_AUTO_DISCOVERY=true
                shift
                ;;
            --auto-heal)
                ENABLE_AUTO_HEALING=true
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

        # Read results with validation (empty files get default JSON)
        nginx_json=$(cat "$temp_dir/nginx.json" 2>/dev/null)
        [[ -z "$nginx_json" ]] && nginx_json='{"available": false}'
        apache_json=$(cat "$temp_dir/apache.json" 2>/dev/null)
        [[ -z "$apache_json" ]] && apache_json='{"available": false}'
        mysql_json=$(cat "$temp_dir/mysql.json" 2>/dev/null)
        [[ -z "$mysql_json" ]] && mysql_json='{"available": false}'
        redis_json=$(cat "$temp_dir/redis.json" 2>/dev/null)
        [[ -z "$redis_json" ]] && redis_json='{"available": false}'
        wordops_json=$(cat "$temp_dir/wordops.json" 2>/dev/null)
        [[ -z "$wordops_json" ]] && wordops_json='{"available": false}'

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

    # Collect extended services (v2.2.0)
    log_info "Collecting extended service metrics..."
    local postgresql_json='{"available": false}'
    local memcached_json='{"available": false}'
    local mongodb_json='{"available": false}'
    local elasticsearch_json='{"available": false}'
    local rabbitmq_json='{"available": false}'
    local fail2ban_json='{"available": false}'
    local docker_json='{"available": false}'
    local postfix_json='{"available": false}'
    local dovecot_json='{"available": false}'
    local prometheus_json='{"available": false}'
    local grafana_json='{"available": false}'
    local loki_json='{"available": false}'
    local alertmanager_json='{"available": false}'

    # Create temp directory for parallel collection
    local ext_temp_dir
    ext_temp_dir=$(mktemp -d 2>/dev/null) || ext_temp_dir=""

    if [[ -n "$ext_temp_dir" ]]; then
        # Launch parallel collection for extended services
        (collect_postgresql_metrics 2>/dev/null > "$ext_temp_dir/postgresql.json" || echo '{"available": false}' > "$ext_temp_dir/postgresql.json") &
        local pid_pg=$!
        (collect_memcached_metrics 2>/dev/null > "$ext_temp_dir/memcached.json" || echo '{"available": false}' > "$ext_temp_dir/memcached.json") &
        local pid_mc=$!
        (collect_mongodb_metrics 2>/dev/null > "$ext_temp_dir/mongodb.json" || echo '{"available": false}' > "$ext_temp_dir/mongodb.json") &
        local pid_mongo=$!
        (collect_elasticsearch_metrics 2>/dev/null > "$ext_temp_dir/elasticsearch.json" || echo '{"available": false}' > "$ext_temp_dir/elasticsearch.json") &
        local pid_es=$!
        (collect_rabbitmq_metrics 2>/dev/null > "$ext_temp_dir/rabbitmq.json" || echo '{"available": false}' > "$ext_temp_dir/rabbitmq.json") &
        local pid_rmq=$!
        (collect_fail2ban_metrics 2>/dev/null > "$ext_temp_dir/fail2ban.json" || echo '{"available": false}' > "$ext_temp_dir/fail2ban.json") &
        local pid_f2b=$!
        (collect_docker_metrics 2>/dev/null > "$ext_temp_dir/docker.json" || echo '{"available": false}' > "$ext_temp_dir/docker.json") &
        local pid_docker=$!
        (collect_postfix_metrics 2>/dev/null > "$ext_temp_dir/postfix.json" || echo '{"available": false}' > "$ext_temp_dir/postfix.json") &
        local pid_postfix=$!
        (collect_dovecot_metrics 2>/dev/null > "$ext_temp_dir/dovecot.json" || echo '{"available": false}' > "$ext_temp_dir/dovecot.json") &
        local pid_dovecot=$!
        (collect_prometheus_metrics 2>/dev/null > "$ext_temp_dir/prometheus.json" || echo '{"available": false}' > "$ext_temp_dir/prometheus.json") &
        local pid_prom=$!
        (collect_grafana_metrics 2>/dev/null > "$ext_temp_dir/grafana.json" || echo '{"available": false}' > "$ext_temp_dir/grafana.json") &
        local pid_grafana=$!
        (collect_loki_metrics 2>/dev/null > "$ext_temp_dir/loki.json" || echo '{"available": false}' > "$ext_temp_dir/loki.json") &
        local pid_loki=$!
        (collect_alertmanager_metrics 2>/dev/null > "$ext_temp_dir/alertmanager.json" || echo '{"available": false}' > "$ext_temp_dir/alertmanager.json") &
        local pid_am=$!

        # Wait for extended services with timeout
        local ext_timeout=15
        local ext_waited=0
        local ext_pids="$pid_pg $pid_mc $pid_mongo $pid_es $pid_rmq $pid_f2b $pid_docker $pid_postfix $pid_dovecot $pid_prom $pid_grafana $pid_loki $pid_am"

        while (( ext_waited < ext_timeout )); do
            local ext_all_done=true
            for pid in $ext_pids; do
                if kill -0 "$pid" 2>/dev/null; then
                    ext_all_done=false
                    break
                fi
            done
            if $ext_all_done; then
                break
            fi
            sleep 0.5
            ((ext_waited++)) || true
        done

        # Kill remaining and suppress messages
        for pid in $ext_pids; do
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null || true
                wait "$pid" 2>/dev/null || true
            fi
        done

        # Read results with validation (empty files get default JSON)
        postgresql_json=$(cat "$ext_temp_dir/postgresql.json" 2>/dev/null)
        [[ -z "$postgresql_json" ]] && postgresql_json='{"available": false}'
        memcached_json=$(cat "$ext_temp_dir/memcached.json" 2>/dev/null)
        [[ -z "$memcached_json" ]] && memcached_json='{"available": false}'
        mongodb_json=$(cat "$ext_temp_dir/mongodb.json" 2>/dev/null)
        [[ -z "$mongodb_json" ]] && mongodb_json='{"available": false}'
        elasticsearch_json=$(cat "$ext_temp_dir/elasticsearch.json" 2>/dev/null)
        [[ -z "$elasticsearch_json" ]] && elasticsearch_json='{"available": false}'
        rabbitmq_json=$(cat "$ext_temp_dir/rabbitmq.json" 2>/dev/null)
        [[ -z "$rabbitmq_json" ]] && rabbitmq_json='{"available": false}'
        fail2ban_json=$(cat "$ext_temp_dir/fail2ban.json" 2>/dev/null)
        [[ -z "$fail2ban_json" ]] && fail2ban_json='{"available": false}'
        docker_json=$(cat "$ext_temp_dir/docker.json" 2>/dev/null)
        [[ -z "$docker_json" ]] && docker_json='{"available": false}'
        postfix_json=$(cat "$ext_temp_dir/postfix.json" 2>/dev/null)
        [[ -z "$postfix_json" ]] && postfix_json='{"available": false}'
        dovecot_json=$(cat "$ext_temp_dir/dovecot.json" 2>/dev/null)
        [[ -z "$dovecot_json" ]] && dovecot_json='{"available": false}'
        prometheus_json=$(cat "$ext_temp_dir/prometheus.json" 2>/dev/null)
        [[ -z "$prometheus_json" ]] && prometheus_json='{"available": false}'
        grafana_json=$(cat "$ext_temp_dir/grafana.json" 2>/dev/null)
        [[ -z "$grafana_json" ]] && grafana_json='{"available": false}'
        loki_json=$(cat "$ext_temp_dir/loki.json" 2>/dev/null)
        [[ -z "$loki_json" ]] && loki_json='{"available": false}'
        alertmanager_json=$(cat "$ext_temp_dir/alertmanager.json" 2>/dev/null)
        [[ -z "$alertmanager_json" ]] && alertmanager_json='{"available": false}'

        rm -rf "$ext_temp_dir"
    fi

    # Collect auto-discovered components (if enabled)
    local discovered_components_json='{"available": false}'
    if [[ "$ENABLE_AUTO_DISCOVERY" == "true" ]] && [[ "$AUTO_DISCOVERY_AVAILABLE" == "true" ]]; then
        log_info "Running auto-discovery for unknown components..."

        # Export flags for auto-discovery module
        export AUTOHEALING_ENABLED="$ENABLE_AUTO_HEALING"
        export AUTOHEALING_ASK_USER=true

        # Run discovery and monitoring
        local discovered_raw
        if discovered_raw=$(discover_all_components 2>/dev/null); then
            local monitored_components
            if monitored_components=$(monitor_all_discovered_components 2>/dev/null); then
                local component_count
                component_count=$(echo "$monitored_components" | jq 'length')

                log_info "Discovered and monitoring $component_count components"

                # Check for unhealthy components and attempt healing if enabled
                if [[ "$ENABLE_AUTO_HEALING" == "true" ]]; then
                    local unhealthy_components
                    unhealthy_components=$(echo "$monitored_components" | jq -c '.[] | select(.monitoring.status == "unhealthy")')

                    if [[ -n "$unhealthy_components" ]]; then
                        log_info "Found unhealthy discovered components, attempting auto-healing..."
                        while IFS= read -r component; do
                            attempt_autohealing "$component" || true
                        done <<< "$unhealthy_components"
                    fi
                fi

                discovered_components_json=$(jq -nc \
                    --argjson components "$monitored_components" \
                    --argjson count "$component_count" \
                    '{
                        available: true,
                        component_count: $count,
                        components: $components
                    }')
            fi
        fi
    fi

    # Build extended services JSON object
    local extended_services_json
    extended_services_json=$(jq -nc \
        --argjson postgresql "$postgresql_json" \
        --argjson memcached "$memcached_json" \
        --argjson mongodb "$mongodb_json" \
        --argjson elasticsearch "$elasticsearch_json" \
        --argjson rabbitmq "$rabbitmq_json" \
        --argjson fail2ban "$fail2ban_json" \
        --argjson docker "$docker_json" \
        --argjson postfix "$postfix_json" \
        --argjson dovecot "$dovecot_json" \
        --argjson prometheus "$prometheus_json" \
        --argjson grafana "$grafana_json" \
        --argjson loki "$loki_json" \
        --argjson alertmanager "$alertmanager_json" \
        --argjson discovered "$discovered_components_json" \
        '{
            postgresql: $postgresql,
            memcached: $memcached,
            mongodb: $mongodb,
            elasticsearch: $elasticsearch,
            rabbitmq: $rabbitmq,
            fail2ban: $fail2ban,
            docker: $docker,
            postfix: $postfix,
            dovecot: $dovecot,
            prometheus: $prometheus,
            grafana: $grafana,
            loki: $loki,
            alertmanager: $alertmanager,
            auto_discovered: $discovered
        }')

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
        "$nginx_json" "$apache_json" "$mysql_json" "$redis_json" "$wordops_json" \
        "$extended_services_json")

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

#!/usr/bin/env bash
#
# Auto-Discovery Module for System Health Monitor
# Discovers unknown components, monitors them, and provides auto-healing
#
# Version: 1.0.0
# Author: System Health Monitor Team
#

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

# Discovery methods to use (can be toggled)
DISCOVERY_SYSTEMD=true
DISCOVERY_PROCESSES=true
DISCOVERY_PORTS=true
DISCOVERY_DOCKER=true
DISCOVERY_KUBERNETES=false  # Enable if K8s available
DISCOVERY_LOGFILES=true
DISCOVERY_CONFIGS=true

# Component database file (cache discovered components)
COMPONENT_DB="${COMPONENT_DB:-/var/lib/health-check/discovered-components.json}"
COMPONENT_DB_DIR="$(dirname "$COMPONENT_DB")"

# Auto-healing settings
AUTOHEALING_ENABLED="${AUTOHEALING_ENABLED:-false}"
AUTOHEALING_ASK_USER="${AUTOHEALING_ASK_USER:-true}"
AUTOHEALING_LOG="/var/log/health-check/autohealing.log"

# Logrotate configuration directory
LOGROTATE_DIR="/etc/logrotate.d"

# Discovery cache TTL (seconds)
DISCOVERY_CACHE_TTL=3600  # 1 hour

# ============================================================================
# COMPONENT FINGERPRINTING DATABASE
# ============================================================================

# Common port to service mapping
declare -A PORT_TO_SERVICE=(
    [80]="http-server"
    [443]="https-server"
    [3306]="mysql"
    [5432]="postgresql"
    [6379]="redis"
    [27017]="mongodb"
    [9200]="elasticsearch"
    [5672]="rabbitmq"
    [11211]="memcached"
    [8080]="app-server"
    [9000]="php-fpm"
    [9090]="prometheus"
    [3000]="grafana"
    [5601]="kibana"
    [8086]="influxdb"
    [2181]="zookeeper"
    [9092]="kafka"
    [4369]="erlang-epmd"
    [25]="smtp"
    [587]="smtp-submission"
    [143]="imap"
    [993]="imaps"
    [110]="pop3"
    [995]="pop3s"
    [53]="dns"
    [22]="ssh"
    [21]="ftp"
    [445]="smb"
    [139]="netbios"
    [3389]="rdp"
    [5900]="vnc"
)

# Process name patterns for identification
declare -A PROCESS_PATTERNS=(
    ["nginx"]="webserver"
    ["apache2|httpd"]="webserver"
    ["mysqld|mariadb"]="database"
    ["postgres"]="database"
    ["redis-server"]="cache"
    ["mongod"]="database"
    ["elasticsearch"]="search-engine"
    ["rabbitmq"]="message-queue"
    ["memcached"]="cache"
    ["php-fpm"]="application-runtime"
    ["java.*kafka"]="message-queue"
    ["node.*"]="application-runtime"
    ["python.*"]="application-runtime"
    ["ruby.*"]="application-runtime"
    ["prometheus"]="monitoring"
    ["grafana"]="monitoring"
    ["alertmanager"]="monitoring"
    ["loki"]="logging"
    ["docker"]="container-runtime"
    ["containerd"]="container-runtime"
    ["kubelet"]="orchestration"
    ["postfix"]="mail-server"
    ["dovecot"]="mail-server"
    ["fail2ban"]="security"
    ["haproxy"]="load-balancer"
    ["varnish"]="cache"
)

# Configuration file patterns
declare -A CONFIG_PATTERNS=(
    ["/etc/nginx"]="nginx"
    ["/etc/apache2"]="apache"
    ["/etc/mysql"]="mysql"
    ["/etc/postgresql"]="postgresql"
    ["/etc/redis"]="redis"
    ["/etc/mongodb"]="mongodb"
    ["/etc/rabbitmq"]="rabbitmq"
    ["/etc/prometheus"]="prometheus"
    ["/etc/grafana"]="grafana"
)

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

log_discovery() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >&2
}

ensure_component_db_dir() {
    if [[ ! -d "$COMPONENT_DB_DIR" ]]; then
        mkdir -p "$COMPONENT_DB_DIR" 2>/dev/null || sudo mkdir -p "$COMPONENT_DB_DIR"
    fi
}

# ============================================================================
# DISCOVERY METHODS
# ============================================================================

discover_systemd_services() {
    log_discovery "INFO" "Discovering systemd services..."

    local services=()

    # Get all loaded services
    while IFS= read -r line; do
        local service_name=$(echo "$line" | awk '{print $1}')
        local state=$(echo "$line" | awk '{print $3}')
        local sub_state=$(echo "$line" | awk '{print $4}')

        # Skip known system services
        if [[ "$service_name" =~ ^(systemd-|user@|getty@|dbus|udev) ]]; then
            continue
        fi

        services+=("$(jq -n \
            --arg name "$service_name" \
            --arg state "$state" \
            --arg substate "$sub_state" \
            --arg type "systemd-service" \
            --arg discovery_method "systemd" \
            '{
                name: $name,
                type: $type,
                state: $state,
                substate: $substate,
                discovery_method: $discovery_method,
                discovered_at: now
            }')")
    done < <(systemctl list-units --type=service --all --no-pager --no-legend 2>/dev/null || true)

    # Return as JSON array
    if [[ ${#services[@]} -gt 0 ]]; then
        echo "${services[@]}" | jq -s '.'
    else
        echo "[]"
    fi
}

discover_running_processes() {
    log_discovery "INFO" "Discovering running processes..."

    local processes=()

    # Get all running processes (exclude kernel threads and common system processes)
    while IFS= read -r line; do
        local pid=$(echo "$line" | awk '{print $1}')
        local cmd=$(echo "$line" | awk '{$1=$2=$3=$4=""; print $0}' | xargs)
        local user=$(echo "$line" | awk '{print $2}')

        # Skip system processes
        if [[ "$user" == "root" ]] && [[ "$cmd" =~ ^\[.*\]$ ]]; then
            continue
        fi

        # Extract process name
        local proc_name=$(basename "$(echo "$cmd" | awk '{print $1}')")

        # Try to identify component type
        local component_type="unknown"
        for pattern in "${!PROCESS_PATTERNS[@]}"; do
            if [[ "$proc_name" =~ $pattern ]] || [[ "$cmd" =~ $pattern ]]; then
                component_type="${PROCESS_PATTERNS[$pattern]}"
                break
            fi
        done

        processes+=("$(jq -n \
            --arg name "$proc_name" \
            --arg pid "$pid" \
            --arg user "$user" \
            --arg cmd "$cmd" \
            --arg type "$component_type" \
            --arg discovery_method "process" \
            '{
                name: $name,
                type: $type,
                pid: ($pid | tonumber),
                user: $user,
                command: $cmd,
                discovery_method: $discovery_method,
                discovered_at: now
            }')")
    done < <(ps aux --sort=-%mem | grep -v "PID" | head -50 || true)

    # Return as JSON array
    if [[ ${#processes[@]} -gt 0 ]]; then
        echo "${processes[@]}" | jq -s '.'
    else
        echo "[]"
    fi
}

discover_listening_ports() {
    log_discovery "INFO" "Discovering listening ports..."

    local ports=()

    # Try ss first (modern), then netstat (legacy)
    local port_cmd
    if command -v ss &>/dev/null; then
        port_cmd="ss -tlnp"
    elif command -v netstat &>/dev/null; then
        port_cmd="netstat -tlnp"
    else
        log_discovery "WARN" "Neither ss nor netstat available"
        echo "[]"
        return
    fi

    while IFS= read -r line; do
        # Parse port and process info
        local port=$(echo "$line" | awk '{print $4}' | grep -oP ':\K[0-9]+$' || echo "")
        local process=$(echo "$line" | grep -oP 'users:\(\(".*?"\)' | grep -oP '"\K[^"]+' | head -1 || echo "unknown")

        [[ -z "$port" ]] && continue

        # Identify service by port
        local service_name="${PORT_TO_SERVICE[$port]:-unknown-port-$port}"
        local component_type="network-service"

        ports+=("$(jq -n \
            --arg name "$service_name" \
            --arg port "$port" \
            --arg process "$process" \
            --arg type "$component_type" \
            --arg discovery_method "port-scan" \
            '{
                name: $name,
                type: $type,
                port: ($port | tonumber),
                process: $process,
                discovery_method: $discovery_method,
                discovered_at: now
            }')")
    done < <($port_cmd 2>/dev/null | grep LISTEN || true)

    if [[ ${#ports[@]} -gt 0 ]]; then
        echo "${ports[@]}" | jq -s '.'
    else
        echo "[]"
    fi
}

discover_docker_containers() {
    log_discovery "INFO" "Discovering Docker containers..."

    if ! command -v docker &>/dev/null; then
        echo "[]"
        return
    fi

    local containers=()

    # Get all containers (running and stopped)
    while IFS= read -r line; do
        local container_id=$(echo "$line" | awk '{print $1}')
        local image=$(echo "$line" | awk '{print $2}')
        local status=$(echo "$line" | awk '{print $3}')
        local name=$(echo "$line" | awk '{print $NF}')

        containers+=("$(jq -n \
            --arg name "$name" \
            --arg id "$container_id" \
            --arg image "$image" \
            --arg status "$status" \
            --arg type "docker-container" \
            --arg discovery_method "docker" \
            '{
                name: $name,
                type: $type,
                container_id: $id,
                image: $image,
                status: $status,
                discovery_method: $discovery_method,
                discovered_at: now
            }')")
    done < <(docker ps -a --format "{{.ID}}\t{{.Image}}\t{{.Status}}\t{{.Names}}" 2>/dev/null || true)

    if [[ ${#containers[@]} -gt 0 ]]; then
        echo "${containers[@]}" | jq -s '.'
    else
        echo "[]"
    fi
}

discover_log_files() {
    log_discovery "INFO" "Discovering log files..."

    local logfiles=()

    # Scan common log directories
    local log_dirs=("/var/log" "/var/log/nginx" "/var/log/apache2" "/var/log/mysql")

    for log_dir in "${log_dirs[@]}"; do
        [[ ! -d "$log_dir" ]] && continue

        while IFS= read -r logfile; do
            local basename=$(basename "$logfile")
            local component_name=$(echo "$basename" | sed 's/\.log.*//')

            # Check if logrotate config exists
            local has_logrotate=false
            if [[ -f "$LOGROTATE_DIR/$component_name" ]] || \
               grep -q "$logfile" "$LOGROTATE_DIR"/* 2>/dev/null; then
                has_logrotate=true
            fi

            logfiles+=("$(jq -n \
                --arg name "$component_name" \
                --arg path "$logfile" \
                --arg has_logrotate "$has_logrotate" \
                --arg type "log-file" \
                --arg discovery_method "logfile-scan" \
                '{
                    name: $name,
                    type: $type,
                    log_path: $path,
                    has_logrotate: ($has_logrotate | test("true")),
                    discovery_method: $discovery_method,
                    discovered_at: now
                }')")
        done < <(find "$log_dir" -maxdepth 2 -type f -name "*.log" 2>/dev/null || true)
    done

    if [[ ${#logfiles[@]} -gt 0 ]]; then
        echo "${logfiles[@]}" | jq -s '.'
    else
        echo "[]"
    fi
}

# ============================================================================
# MAIN DISCOVERY ORCHESTRATOR
# ============================================================================

discover_all_components() {
    log_discovery "INFO" "Starting auto-discovery..."

    local all_components=()

    # Run all discovery methods
    if [[ "$DISCOVERY_SYSTEMD" == "true" ]]; then
        local systemd_services=$(discover_systemd_services)
        all_components+=("$systemd_services")
    fi

    if [[ "$DISCOVERY_PROCESSES" == "true" ]]; then
        local processes=$(discover_running_processes)
        all_components+=("$processes")
    fi

    if [[ "$DISCOVERY_PORTS" == "true" ]]; then
        local ports=$(discover_listening_ports)
        all_components+=("$ports")
    fi

    if [[ "$DISCOVERY_DOCKER" == "true" ]]; then
        local containers=$(discover_docker_containers)
        all_components+=("$containers")
    fi

    if [[ "$DISCOVERY_LOGFILES" == "true" ]]; then
        local logfiles=$(discover_log_files)
        all_components+=("$logfiles")
    fi

    # Merge and deduplicate
    local merged=$(echo "${all_components[@]}" | jq -s 'add | group_by(.name) | map(add) | unique_by(.name)')

    # Save to component database
    ensure_component_db_dir
    echo "$merged" | jq '.' > "$COMPONENT_DB" 2>/dev/null || sudo tee "$COMPONENT_DB" > /dev/null

    log_discovery "INFO" "Discovery complete. Found $(echo "$merged" | jq 'length') components"

    echo "$merged"
}

# ============================================================================
# COMPONENT MONITORING
# ============================================================================

monitor_component() {
    local component_json="$1"

    local name=$(echo "$component_json" | jq -r '.name')
    local type=$(echo "$component_json" | jq -r '.type')
    local discovery_method=$(echo "$component_json" | jq -r '.discovery_method')

    local status="unknown"
    local health_score=0
    local issues=()

    case "$type" in
        "systemd-service")
            local state=$(systemctl is-active "$name" 2>/dev/null || echo "inactive")
            if [[ "$state" == "active" ]]; then
                status="healthy"
                health_score=100
            else
                status="unhealthy"
                health_score=0
                issues+=("Service is $state")
            fi
            ;;

        "docker-container")
            local container_status=$(docker inspect --format='{{.State.Status}}' "$name" 2>/dev/null || echo "unknown")
            if [[ "$container_status" == "running" ]]; then
                status="healthy"
                health_score=100
            else
                status="unhealthy"
                health_score=0
                issues+=("Container is $container_status")
            fi
            ;;

        "network-service")
            local port=$(echo "$component_json" | jq -r '.port // empty')
            if [[ -n "$port" ]]; then
                if nc -z localhost "$port" 2>/dev/null || timeout 1 bash -c "echo > /dev/tcp/localhost/$port" 2>/dev/null; then
                    status="healthy"
                    health_score=100
                else
                    status="unhealthy"
                    health_score=0
                    issues+=("Port $port not responding")
                fi
            fi
            ;;

        *)
            # Generic process-based monitoring
            local pid=$(pgrep -x "$name" 2>/dev/null | head -1 || echo "")
            if [[ -n "$pid" ]]; then
                status="healthy"
                health_score=100
            else
                status="unhealthy"
                health_score=0
                issues+=("Process not running")
            fi
            ;;
    esac

    # Return monitoring result
    echo "$component_json" | jq \
        --arg status "$status" \
        --argjson score "$health_score" \
        --argjson issues "$(printf '%s\n' "${issues[@]}" | jq -R . | jq -s .)" \
        '. + {
            monitoring: {
                status: $status,
                health_score: $score,
                issues: $issues,
                checked_at: now
            }
        }'
}

monitor_all_discovered_components() {
    log_discovery "INFO" "Monitoring discovered components..."

    # Load component database
    if [[ ! -f "$COMPONENT_DB" ]]; then
        log_discovery "WARN" "Component database not found. Running discovery first..."
        discover_all_components > /dev/null
    fi

    local components=$(cat "$COMPONENT_DB")
    local monitored=()

    # Monitor each component
    while IFS= read -r component; do
        local result=$(monitor_component "$component")
        monitored+=("$result")
    done < <(echo "$components" | jq -c '.[]')

    # Return monitored components
    if [[ ${#monitored[@]} -gt 0 ]]; then
        echo "${monitored[@]}" | jq -s '.'
    else
        echo "[]"
    fi
}

# ============================================================================
# LOGROTATE MANAGEMENT
# ============================================================================

check_logrotate_config() {
    local component_name="$1"
    local log_path="$2"

    # Check if logrotate config exists
    if [[ -f "$LOGROTATE_DIR/$component_name" ]]; then
        echo "exists"
        return 0
    fi

    # Check if log is mentioned in any logrotate config
    if grep -q "$log_path" "$LOGROTATE_DIR"/* 2>/dev/null; then
        echo "included"
        return 0
    fi

    echo "missing"
    return 1
}

suggest_logrotate_config() {
    local component_name="$1"
    local log_path="$2"

    cat <<EOF
# Suggested logrotate configuration for $component_name
# Save this to: $LOGROTATE_DIR/$component_name

$log_path {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
    sharedscripts
    postrotate
        # Add service reload command here if needed
        # systemctl reload $component_name || true
    endscript
}
EOF
}

# ============================================================================
# AUTO-HEALING
# ============================================================================

attempt_autohealing() {
    local component_json="$1"

    local name=$(echo "$component_json" | jq -r '.name')
    local type=$(echo "$component_json" | jq -r '.type')
    local issues=$(echo "$component_json" | jq -r '.monitoring.issues[]' 2>/dev/null || echo "")

    if [[ -z "$issues" ]]; then
        return 0
    fi

    log_discovery "INFO" "Component '$name' has issues. Attempting auto-healing..."

    # Ask user for permission if enabled
    if [[ "$AUTOHEALING_ASK_USER" == "true" ]]; then
        echo "Component '$name' ($type) has issues:"
        echo "$issues"
        read -p "Attempt auto-healing? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_discovery "INFO" "User declined auto-healing for '$name'"
            return 1
        fi
    fi

    # Healing strategies based on component type
    case "$type" in
        "systemd-service")
            log_discovery "INFO" "Restarting systemd service: $name"
            if systemctl restart "$name" 2>&1 | tee -a "$AUTOHEALING_LOG"; then
                echo "Successfully restarted $name"
                return 0
            else
                echo "Failed to restart $name"
                return 1
            fi
            ;;

        "docker-container")
            log_discovery "INFO" "Restarting Docker container: $name"
            if docker restart "$name" 2>&1 | tee -a "$AUTOHEALING_LOG"; then
                echo "Successfully restarted container $name"
                return 0
            else
                echo "Failed to restart container $name"
                return 1
            fi
            ;;

        *)
            log_discovery "WARN" "No auto-healing strategy for type: $type"
            return 1
            ;;
    esac
}

# ============================================================================
# MAIN ENTRY POINTS
# ============================================================================

# Export functions for use in health-check.sh
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    # Being sourced
    export -f discover_all_components
    export -f monitor_all_discovered_components
    export -f attempt_autohealing
    export -f check_logrotate_config
    export -f suggest_logrotate_config
fi

# Allow running standalone
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        discover)
            discover_all_components
            ;;
        monitor)
            monitor_all_discovered_components
            ;;
        heal)
            shift
            component_json=$(cat "$COMPONENT_DB" | jq ".[] | select(.name == \"$1\")")
            if [[ -n "$component_json" ]]; then
                attempt_autohealing "$component_json"
            else
                echo "Component not found: $1"
                exit 1
            fi
            ;;
        logrotate-check)
            shift
            check_logrotate_config "$1" "$2"
            ;;
        logrotate-suggest)
            shift
            suggest_logrotate_config "$1" "$2"
            ;;
        *)
            cat <<EOF
Usage: $0 <command> [args]

Commands:
    discover                    Run auto-discovery and save to component DB
    monitor                     Monitor all discovered components
    heal <component-name>       Attempt auto-healing for a component
    logrotate-check <name> <path>     Check if logrotate config exists
    logrotate-suggest <name> <path>   Suggest logrotate configuration

Examples:
    $0 discover
    $0 monitor | jq '.[] | select(.monitoring.status == "unhealthy")'
    $0 heal nginx
    $0 logrotate-suggest myapp /var/log/myapp/app.log
EOF
            exit 1
            ;;
    esac
fi

#!/usr/bin/env bash
#
# Component Discovery CLI Tool
# Manage auto-discovered components, monitoring, and healing
#
# Version: 1.0.0
# Author: System Health Monitor Team
#

set -euo pipefail

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Source the auto-discovery module
if [[ ! -f "$ROOT_DIR/lib/auto-discovery.sh" ]]; then
    echo "ERROR: Auto-discovery module not found at $ROOT_DIR/lib/auto-discovery.sh"
    exit 1
fi

# shellcheck source=../lib/auto-discovery.sh
source "$ROOT_DIR/lib/auto-discovery.sh"

# Component database
COMPONENT_DB="${COMPONENT_DB:-/var/lib/health-check/discovered-components.json}"

# ============================================================================
# CLI FUNCTIONS
# ============================================================================

show_help() {
    cat << EOF
Component Discovery Tool - Manage Auto-Discovered Components

USAGE:
    $(basename "$0") <command> [options]

COMMANDS:
    discover                    Run auto-discovery and update component database
    list                        List all discovered components
    monitor                     Monitor all discovered components
    show <component-name>       Show detailed info about a component
    heal <component-name>       Attempt auto-healing for a component
    heal-all                    Attempt healing for all unhealthy components
    logrotate-check             Check logrotate configuration for all components
    logrotate-suggest <name>    Suggest logrotate config for a component
    stats                       Show discovery statistics
    export [file]               Export component database to file (default: stdout)
    import <file>               Import component database from file
    clean                       Remove component database and start fresh

OPTIONS:
    -h, --help                  Show this help message
    -j, --json                  Output in JSON format (where applicable)
    -v, --verbose               Enable verbose output
    -q, --quiet                 Suppress non-essential output

EXAMPLES:
    # Discover all components on the system
    $(basename "$0") discover

    # List all discovered components in JSON
    $(basename "$0") list --json

    # Monitor components and show only unhealthy ones
    $(basename "$0") monitor | jq '.[] | select(.monitoring.status == "unhealthy")'

    # Show detailed info about nginx
    $(basename "$0") show nginx

    # Attempt healing for a specific component
    $(basename "$0") heal redis-server

    # Check logrotate configuration for all components
    $(basename "$0") logrotate-check

    # Suggest logrotate config for a custom application
    $(basename "$0") logrotate-suggest myapp

    # Export discovered components to a file
    $(basename "$0") export /tmp/components.json

    # Get discovery statistics
    $(basename "$0") stats

COMPONENT DATABASE:
    $COMPONENT_DB

EOF
}

cmd_discover() {
    echo "Running auto-discovery..."
    local result
    result=$(discover_all_components)

    local count
    count=$(echo "$result" | jq 'length')

    echo "Discovery complete! Found $count components."
    echo "Component database updated: $COMPONENT_DB"

    if [[ "${OUTPUT_JSON:-false}" == "true" ]]; then
        echo "$result"
    fi
}

cmd_list() {
    if [[ ! -f "$COMPONENT_DB" ]]; then
        echo "Component database not found. Run 'discover' first."
        exit 1
    fi

    local components
    components=$(cat "$COMPONENT_DB")

    if [[ "${OUTPUT_JSON:-false}" == "true" ]]; then
        echo "$components" | jq '.'
    else
        echo "Discovered Components:"
        echo "===================="
        echo
        echo "$components" | jq -r '.[] | "\(.name) (\(.type)) - discovered via \(.discovery_method)"'
    fi
}

cmd_monitor() {
    if [[ ! -f "$COMPONENT_DB" ]]; then
        echo "Component database not found. Run 'discover' first."
        exit 1
    fi

    echo "Monitoring discovered components..."
    local monitored
    monitored=$(monitor_all_discovered_components)

    if [[ "${OUTPUT_JSON:-false}" == "true" ]]; then
        echo "$monitored"
    else
        echo
        echo "Monitoring Results:"
        echo "==================="
        echo

        local healthy
        healthy=$(echo "$monitored" | jq -r '.[] | select(.monitoring.status == "healthy") | .name' | wc -l)
        local unhealthy
        unhealthy=$(echo "$monitored" | jq -r '.[] | select(.monitoring.status == "unhealthy") | .name' | wc -l)
        local total
        total=$(echo "$monitored" | jq 'length')

        echo "Total: $total | Healthy: $healthy | Unhealthy: $unhealthy"
        echo

        if [[ $unhealthy -gt 0 ]]; then
            echo "Unhealthy Components:"
            echo "$monitored" | jq -r '.[] | select(.monitoring.status == "unhealthy") |
                "  - \(.name) (\(.type)): \(.monitoring.issues | join(", "))"'
            echo
        fi

        echo "Healthy Components:"
        echo "$monitored" | jq -r '.[] | select(.monitoring.status == "healthy") | "  - \(.name) (\(.type))"'
    fi
}

cmd_show() {
    local name="$1"

    if [[ ! -f "$COMPONENT_DB" ]]; then
        echo "Component database not found. Run 'discover' first."
        exit 1
    fi

    local component
    component=$(cat "$COMPONENT_DB" | jq ".[] | select(.name == \"$name\")")

    if [[ -z "$component" ]]; then
        echo "Component '$name' not found in database."
        exit 1
    fi

    # Monitor the component to get current status
    local monitored
    monitored=$(monitor_component "$component")

    if [[ "${OUTPUT_JSON:-false}" == "true" ]]; then
        echo "$monitored" | jq '.'
    else
        echo "Component: $(echo "$monitored" | jq -r '.name')"
        echo "Type: $(echo "$monitored" | jq -r '.type')"
        echo "Discovery Method: $(echo "$monitored" | jq -r '.discovery_method')"
        echo "Status: $(echo "$monitored" | jq -r '.monitoring.status')"
        echo "Health Score: $(echo "$monitored" | jq -r '.monitoring.health_score')/100"

        local issues
        issues=$(echo "$monitored" | jq -r '.monitoring.issues[]' 2>/dev/null || echo "")
        if [[ -n "$issues" ]]; then
            echo "Issues:"
            echo "$issues" | sed 's/^/  - /'
        fi

        # Show type-specific details
        local type
        type=$(echo "$monitored" | jq -r '.type')

        case "$type" in
            systemd-service)
                echo "Systemd State: $(echo "$monitored" | jq -r '.state // "unknown"')"
                echo "Substate: $(echo "$monitored" | jq -r '.substate // "unknown"')"
                ;;
            docker-container)
                echo "Container ID: $(echo "$monitored" | jq -r '.container_id // "unknown"')"
                echo "Image: $(echo "$monitored" | jq -r '.image // "unknown"')"
                echo "Container Status: $(echo "$monitored" | jq -r '.status // "unknown"')"
                ;;
            network-service)
                echo "Port: $(echo "$monitored" | jq -r '.port // "unknown"')"
                echo "Process: $(echo "$monitored" | jq -r '.process // "unknown"')"
                ;;
            log-file)
                echo "Log Path: $(echo "$monitored" | jq -r '.log_path // "unknown"')"
                echo "Has Logrotate: $(echo "$monitored" | jq -r '.has_logrotate // false')"
                ;;
        esac
    fi
}

cmd_heal() {
    local name="$1"

    if [[ ! -f "$COMPONENT_DB" ]]; then
        echo "Component database not found. Run 'discover' first."
        exit 1
    fi

    local component
    component=$(cat "$COMPONENT_DB" | jq ".[] | select(.name == \"$name\")")

    if [[ -z "$component" ]]; then
        echo "Component '$name' not found in database."
        exit 1
    fi

    # Monitor first to get current status
    local monitored
    monitored=$(monitor_component "$component")

    # Attempt healing
    attempt_autohealing "$monitored"
}

cmd_heal_all() {
    if [[ ! -f "$COMPONENT_DB" ]]; then
        echo "Component database not found. Run 'discover' first."
        exit 1
    fi

    echo "Monitoring all components..."
    local monitored
    monitored=$(monitor_all_discovered_components)

    local unhealthy
    unhealthy=$(echo "$monitored" | jq -c '.[] | select(.monitoring.status == "unhealthy")')

    if [[ -z "$unhealthy" ]]; then
        echo "No unhealthy components found. All systems operational!"
        exit 0
    fi

    echo "Found unhealthy components. Attempting healing..."
    echo

    while IFS= read -r component; do
        local name
        name=$(echo "$component" | jq -r '.name')
        echo "Healing: $name"
        attempt_autohealing "$component" || true
        echo
    done <<< "$unhealthy"
}

cmd_logrotate_check() {
    if [[ ! -f "$COMPONENT_DB" ]]; then
        echo "Component database not found. Run 'discover' first."
        exit 1
    fi

    local components
    components=$(cat "$COMPONENT_DB")

    echo "Checking Logrotate Configuration:"
    echo "=================================="
    echo

    # Check log-file type components
    local logfiles
    logfiles=$(echo "$components" | jq -c '.[] | select(.type == "log-file")')

    if [[ -z "$logfiles" ]]; then
        echo "No log files discovered."
        exit 0
    fi

    local missing=0

    while IFS= read -r logfile; do
        local name
        name=$(echo "$logfile" | jq -r '.name')
        local path
        path=$(echo "$logfile" | jq -r '.log_path')
        local has_logrotate
        has_logrotate=$(echo "$logfile" | jq -r '.has_logrotate')

        if [[ "$has_logrotate" == "true" ]]; then
            echo "✓ $name ($path) - configured"
        else
            echo "✗ $name ($path) - MISSING"
            ((missing++)) || true
        fi
    done <<< "$logfiles"

    echo
    if [[ $missing -gt 0 ]]; then
        echo "Found $missing log files without logrotate configuration."
        echo "Use 'logrotate-suggest <component-name>' to generate configuration."
    else
        echo "All log files have logrotate configuration!"
    fi
}

cmd_logrotate_suggest() {
    local name="$1"

    if [[ ! -f "$COMPONENT_DB" ]]; then
        echo "Component database not found. Run 'discover' first."
        exit 1
    fi

    local component
    component=$(cat "$COMPONENT_DB" | jq ".[] | select(.name == \"$name\")")

    if [[ -z "$component" ]]; then
        echo "Component '$name' not found in database."
        exit 1
    fi

    local type
    type=$(echo "$component" | jq -r '.type')

    if [[ "$type" != "log-file" ]]; then
        echo "Component '$name' is not a log file. Cannot suggest logrotate config."
        exit 1
    fi

    local log_path
    log_path=$(echo "$component" | jq -r '.log_path')

    suggest_logrotate_config "$name" "$log_path"
}

cmd_stats() {
    if [[ ! -f "$COMPONENT_DB" ]]; then
        echo "Component database not found. Run 'discover' first."
        exit 1
    fi

    local components
    components=$(cat "$COMPONENT_DB")

    if [[ "${OUTPUT_JSON:-false}" == "true" ]]; then
        jq -nc \
            --argjson total "$(echo "$components" | jq 'length')" \
            --argjson by_type "$(echo "$components" | jq 'group_by(.type) | map({type: .[0].type, count: length})')" \
            --argjson by_method "$(echo "$components" | jq 'group_by(.discovery_method) | map({method: .[0].discovery_method, count: length})')" \
            '{
                total_components: $total,
                by_type: $by_type,
                by_discovery_method: $by_method
            }'
    else
        echo "Discovery Statistics:"
        echo "===================="
        echo
        echo "Total Components: $(echo "$components" | jq 'length')"
        echo
        echo "By Type:"
        echo "$components" | jq -r 'group_by(.type) | map("  \(.[0].type): \(length)") | .[]'
        echo
        echo "By Discovery Method:"
        echo "$components" | jq -r 'group_by(.discovery_method) | map("  \(.[0].discovery_method): \(length)") | .[]'
    fi
}

cmd_export() {
    local output_file="${1:-}"

    if [[ ! -f "$COMPONENT_DB" ]]; then
        echo "Component database not found. Run 'discover' first."
        exit 1
    fi

    if [[ -z "$output_file" ]]; then
        cat "$COMPONENT_DB"
    else
        cp "$COMPONENT_DB" "$output_file"
        echo "Component database exported to: $output_file"
    fi
}

cmd_import() {
    local input_file="$1"

    if [[ ! -f "$input_file" ]]; then
        echo "Input file not found: $input_file"
        exit 1
    fi

    # Validate JSON
    if ! jq empty "$input_file" 2>/dev/null; then
        echo "Invalid JSON in input file: $input_file"
        exit 1
    fi

    ensure_component_db_dir
    cp "$input_file" "$COMPONENT_DB"
    echo "Component database imported from: $input_file"
}

cmd_clean() {
    if [[ -f "$COMPONENT_DB" ]]; then
        rm -f "$COMPONENT_DB"
        echo "Component database cleaned: $COMPONENT_DB"
    else
        echo "Component database does not exist."
    fi
}

# ============================================================================
# MAIN
# ============================================================================

# Parse global options
OUTPUT_JSON=false
VERBOSE=false
QUIET=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -j|--json)
            OUTPUT_JSON=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -q|--quiet)
            QUIET=true
            shift
            ;;
        *)
            break
            ;;
    esac
done

# Get command
COMMAND="${1:-}"

if [[ -z "$COMMAND" ]]; then
    echo "ERROR: No command specified."
    echo
    show_help
    exit 1
fi

shift

# Execute command
case "$COMMAND" in
    discover)
        cmd_discover "$@"
        ;;
    list)
        cmd_list "$@"
        ;;
    monitor)
        cmd_monitor "$@"
        ;;
    show)
        if [[ $# -eq 0 ]]; then
            echo "ERROR: Component name required."
            echo "Usage: $(basename "$0") show <component-name>"
            exit 1
        fi
        cmd_show "$@"
        ;;
    heal)
        if [[ $# -eq 0 ]]; then
            echo "ERROR: Component name required."
            echo "Usage: $(basename "$0") heal <component-name>"
            exit 1
        fi
        cmd_heal "$@"
        ;;
    heal-all)
        cmd_heal_all "$@"
        ;;
    logrotate-check)
        cmd_logrotate_check "$@"
        ;;
    logrotate-suggest)
        if [[ $# -eq 0 ]]; then
            echo "ERROR: Component name required."
            echo "Usage: $(basename "$0") logrotate-suggest <component-name>"
            exit 1
        fi
        cmd_logrotate_suggest "$@"
        ;;
    stats)
        cmd_stats "$@"
        ;;
    export)
        cmd_export "$@"
        ;;
    import)
        if [[ $# -eq 0 ]]; then
            echo "ERROR: Input file required."
            echo "Usage: $(basename "$0") import <file>"
            exit 1
        fi
        cmd_import "$@"
        ;;
    clean)
        cmd_clean "$@"
        ;;
    *)
        echo "ERROR: Unknown command: $COMMAND"
        echo
        show_help
        exit 1
        ;;
esac

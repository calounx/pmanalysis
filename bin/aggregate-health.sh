#!/usr/bin/env bash
#######################################
# Multi-Host Health Aggregation
# Collects and aggregates health data from multiple hosts
#######################################

set -euo pipefail

readonly SCRIPT_VERSION="2.0.0"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

# Configuration
HOSTS_FILE="${HOSTS_FILE:-hosts.txt}"
SSH_USER="${SSH_USER:-monitor}"
SSH_KEY="${SSH_KEY:-}"
PARALLEL="${PARALLEL:-10}"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-json}"
TIMEOUT="${TIMEOUT:-30}"

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Aggregate health check data from multiple hosts via SSH.

OPTIONS:
    -h, --help              Show this help message
    -v, --version           Show version information
    -f, --file FILE         Hosts file (one hostname per line) [default: hosts.txt]
    -u, --user USER         SSH username [default: monitor]
    -i, --identity FILE     SSH private key file
    -p, --parallel N        Run N parallel SSH connections [default: 10]
    -o, --output FORMAT     Output format: json|summary|dashboard [default: json]
    -t, --timeout SECONDS   Timeout per host [default: 30]

HOSTS FILE FORMAT:
    hostname1
    hostname2.example.com
    192.168.1.100

EXAMPLES:
    # Basic aggregation
    $SCRIPT_NAME --file production-hosts.txt

    # Custom SSH key and user
    $SCRIPT_NAME -f hosts.txt -u admin -i ~/.ssh/id_rsa

    # Summary format
    $SCRIPT_NAME --output summary

    # High parallelism
    $SCRIPT_NAME --parallel 50

EOF
    exit 0
}

log_error() {
    echo "[$(date -Iseconds)] ERROR: $*" >&2
}

log_info() {
    echo "[$(date -Iseconds)] INFO: $*" >&2
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) usage ;;
        -v|--version) echo "$SCRIPT_VERSION"; exit 0 ;;
        -f|--file) HOSTS_FILE="$2"; shift 2 ;;
        -u|--user) SSH_USER="$2"; shift 2 ;;
        -i|--identity) SSH_KEY="$2"; shift 2 ;;
        -p|--parallel) PARALLEL="$2"; shift 2 ;;
        -o|--output) OUTPUT_FORMAT="$2"; shift 2 ;;
        -t|--timeout) TIMEOUT="$2"; shift 2 ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

# Validate hosts file
if [[ ! -f "$HOSTS_FILE" ]]; then
    log_error "Hosts file not found: $HOSTS_FILE"
    exit 1
fi

# Read hosts
mapfile -t HOSTS < <(grep -v '^#' "$HOSTS_FILE" | grep -v '^$' || true)

if [[ ${#HOSTS[@]} -eq 0 ]]; then
    log_error "No hosts found in $HOSTS_FILE"
    exit 1
fi

log_info "Collecting health data from ${#HOSTS[@]} hosts (parallel: $PARALLEL)"

# SSH options
SSH_OPTS="-o ConnectTimeout=$TIMEOUT -o StrictHostKeyChecking=no -o BatchMode=yes"
if [[ -n "$SSH_KEY" ]]; then
    SSH_OPTS="$SSH_OPTS -i $SSH_KEY"
fi

# Function to collect from single host
collect_host() {
    local host="$1"
    local output_file="$2"

    log_info "Collecting from $host"

    # Run health check on remote host
    if ssh $SSH_OPTS "${SSH_USER}@${host}" "/opt/health-check/health-check.sh --json" > "$output_file" 2>/dev/null; then
        log_info "✓ $host"
    else
        log_error "✗ $host (failed to collect)"
        echo '{"hostname": "'$host'", "error": "collection_failed", "score": 0}' > "$output_file"
    fi
}

# Create temp directory for results
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

# Parallel collection using xargs
export -f collect_host log_info log_error
export SSH_OPTS SSH_USER TEMP_DIR

printf '%s\n' "${HOSTS[@]}" | xargs -P "$PARALLEL" -I {} bash -c 'collect_host "$1" "$TEMP_DIR/$1.json"' _ {}

# Aggregate results
log_info "Aggregating results"

TOTAL_HOSTS=${#HOSTS[@]}
HEALTHY=0
WARNING=0
CRITICAL=0
FAILED=0
TOTAL_SCORE=0

declare -a HOST_RESULTS=()

for host in "${HOSTS[@]}"; do
    json_file="$TEMP_DIR/$host.json"

    if [[ ! -f "$json_file" ]]; then
        ((FAILED++)) || true
        continue
    fi

    score=$(jq -r '.score // 0' "$json_file" 2>/dev/null || echo "0")
    status=$(jq -r '.status // "unknown"' "$json_file" 2>/dev/null || echo "unknown")

    if [[ "$status" == "unknown" ]] || [[ "$status" == "error" ]]; then
        ((FAILED++)) || true
    elif (( $(echo "$score >= 80" | bc -l) )); then
        ((HEALTHY++)) || true
    elif (( $(echo "$score >= 50" | bc -l) )); then
        ((WARNING++)) || true
    else
        ((CRITICAL++)) || true
    fi

    ((TOTAL_SCORE += score)) || true
    HOST_RESULTS+=("$(cat "$json_file")")
done

AVG_SCORE=$(echo "scale=2; $TOTAL_SCORE / $TOTAL_HOSTS" | bc -l || echo "0")

# Output based on format
case "$OUTPUT_FORMAT" in
    json)
        jq -n \
            --argjson hosts "$(printf '%s\n' "${HOST_RESULTS[@]}" | jq -s .)" \
            --argjson total "$TOTAL_HOSTS" \
            --argjson healthy "$HEALTHY" \
            --argjson warning "$WARNING" \
            --argjson critical "$CRITICAL" \
            --argjson failed "$FAILED" \
            --arg avg_score "$AVG_SCORE" \
            --arg timestamp "$(date -Iseconds)" \
            '{
                timestamp: $timestamp,
                fleet_summary: {
                    total_hosts: $total,
                    healthy: $healthy,
                    warning: $warning,
                    critical: $critical,
                    failed: $failed,
                    average_score: ($avg_score | tonumber)
                },
                hosts: $hosts
            }'
        ;;

    summary)
        cat <<EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Fleet Health Summary
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Timestamp: $(date -Iseconds)

Fleet Statistics:
  Total Hosts:      $TOTAL_HOSTS
  ✅ Healthy:       $HEALTHY ($(echo "scale=1; $HEALTHY * 100 / $TOTAL_HOSTS" | bc)%)
  ⚠️  Warning:       $WARNING ($(echo "scale=1; $WARNING * 100 / $TOTAL_HOSTS" | bc)%)
  🔴 Critical:      $CRITICAL ($(echo "scale=1; $CRITICAL * 100 / $TOTAL_HOSTS" | bc)%)
  ❌ Failed:        $FAILED ($(echo "scale=1; $FAILED * 100 / $TOTAL_HOSTS" | bc)%)

  Average Score:    $AVG_SCORE/100

Critical/Warning Hosts:
EOF
        for host in "${HOSTS[@]}"; do
            json_file="$TEMP_DIR/$host.json"
            score=$(jq -r '.score // 0' "$json_file" 2>/dev/null || echo "0")
            if (( $(echo "$score < 80" | bc -l) )); then
                echo "  - $host: $score/100"
            fi
        done
        ;;

    dashboard)
        # ASCII dashboard
        cat <<EOF
╔══════════════════════════════════════════════════════════════╗
║              FLEET HEALTH DASHBOARD                          ║
╠══════════════════════════════════════════════════════════════╣
║ Total Hosts:    $TOTAL_HOSTS                                           ║
║ Average Score:  $AVG_SCORE/100                                      ║
╠══════════════════════════════════════════════════════════════╣
║ ✅ Healthy:     $HEALTHY hosts (>= 80)                               ║
║ ⚠️  Warning:     $WARNING hosts (50-79)                              ║
║ 🔴 Critical:    $CRITICAL hosts (< 50)                                ║
║ ❌ Failed:      $FAILED hosts (unreachable)                          ║
╚══════════════════════════════════════════════════════════════╝

Top 10 Lowest Scores:
EOF
        for host in "${HOSTS[@]}"; do
            json_file="$TEMP_DIR/$host.json"
            score=$(jq -r '.score // 0' "$json_file" 2>/dev/null || echo "0")
            echo "$score $host"
        done | sort -n | head -10 | while read score host; do
            printf "  %3d/100  %s\n" "$score" "$host"
        done
        ;;

    *)
        log_error "Unknown output format: $OUTPUT_FORMAT"
        exit 1
        ;;
esac

# Exit code based on fleet health
if (( CRITICAL > 0 )); then
    exit 2
elif (( WARNING > 0 )); then
    exit 1
else
    exit 0
fi

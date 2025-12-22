#!/usr/bin/env bash
#######################################
# Built-in Alerting for Health Check
# Sends alerts to Slack, Teams, or custom webhooks
#######################################

set -euo pipefail

readonly SCRIPT_VERSION="2.1.0"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

# Configuration (can be overridden by environment variables)
WEBHOOK_URL="${WEBHOOK_URL:-}"
WEBHOOK_TYPE="${WEBHOOK_TYPE:-slack}"  # slack, teams, discord, custom
ALERT_THRESHOLD="${ALERT_THRESHOLD:-80}"
HOSTNAME="$(hostname)"

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Built-in alerting for health-check.sh. Sends alerts when health score drops below threshold.

OPTIONS:
    -h, --help              Show this help message
    -v, --version           Show version information
    -u, --url URL           Webhook URL (required)
    -t, --type TYPE         Webhook type: slack|teams|discord|custom (default: slack)
    -s, --threshold SCORE   Alert if score below threshold (default: 80)
    -j, --json FILE         Read health check JSON from file instead of running script

ENVIRONMENT VARIABLES:
    WEBHOOK_URL         Webhook URL (alternative to -u flag)
    WEBHOOK_TYPE        Webhook type (alternative to -t flag)
    ALERT_THRESHOLD     Alert threshold (alternative to -s flag)

EXAMPLES:
    # Slack webhook
    $SCRIPT_NAME --url "https://hooks.slack.com/services/XXX" --type slack

    # Microsoft Teams webhook
    $SCRIPT_NAME --url "https://outlook.office.com/webhook/XXX" --type teams

    # From cron (environment variables)
    WEBHOOK_URL="https://hooks.slack.com/..." $SCRIPT_NAME

    # Custom threshold
    $SCRIPT_NAME --url "https://..." --threshold 70

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
JSON_FILE=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) usage ;;
        -v|--version) echo "$SCRIPT_VERSION"; exit 0 ;;
        -u|--url) WEBHOOK_URL="$2"; shift 2 ;;
        -t|--type) WEBHOOK_TYPE="$2"; shift 2 ;;
        -s|--threshold) ALERT_THRESHOLD="$2"; shift 2 ;;
        -j|--json) JSON_FILE="$2"; shift 2 ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

# Validate webhook URL
if [[ -z "$WEBHOOK_URL" ]]; then
    log_error "Webhook URL required (use -u or set WEBHOOK_URL)"
    exit 1
fi

# Get health check data
if [[ -n "$JSON_FILE" ]]; then
    if [[ ! -f "$JSON_FILE" ]]; then
        log_error "JSON file not found: $JSON_FILE"
        exit 1
    fi
    HEALTH_JSON="$(cat "$JSON_FILE")"
else
    # Run health check
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ ! -f "$SCRIPT_DIR/health-check.sh" ]]; then
        log_error "health-check.sh not found in $SCRIPT_DIR"
        exit 1
    fi
    HEALTH_JSON="$("$SCRIPT_DIR/health-check.sh" --json)"
fi

# Parse health data
SCORE=$(echo "$HEALTH_JSON" | jq -r '.score')
STATUS=$(echo "$HEALTH_JSON" | jq -r '.status')
ALERTS=$(echo "$HEALTH_JSON" | jq -r '.alerts[] | "• \(.severity | ascii_upcase): \(.message)"' | head -10)

# Check if alert needed
if (( $(echo "$SCORE >= $ALERT_THRESHOLD" | bc -l) )); then
    log_info "Score $SCORE >= $ALERT_THRESHOLD - No alert needed"
    exit 0
fi

log_info "Score $SCORE < $ALERT_THRESHOLD - Sending alert to $WEBHOOK_TYPE webhook"

# Determine color
if [[ "$STATUS" == "critical" ]]; then
    COLOR="danger"
    COLOR_HEX="#FF0000"
    EMOJI="🔴"
elif [[ "$STATUS" == "warning" ]]; then
    COLOR="warning"
    COLOR_HEX="#FFA500"
    EMOJI="⚠️"
else
    COLOR="good"
    COLOR_HEX="#00FF00"
    EMOJI="✅"
fi

# Build webhook payload based on type
case "$WEBHOOK_TYPE" in
    slack)
        PAYLOAD=$(cat <<EOF
{
    "text": "$EMOJI Health Alert: $HOSTNAME",
    "attachments": [{
        "color": "$COLOR",
        "fields": [
            {"title": "Hostname", "value": "$HOSTNAME", "short": true},
            {"title": "Score", "value": "$SCORE/100", "short": true},
            {"title": "Status", "value": "$STATUS", "short": true},
            {"title": "Timestamp", "value": "$(date -Iseconds)", "short": true},
            {"title": "Alerts", "value": "$ALERTS", "short": false}
        ],
        "footer": "Health Check Monitor",
        "footer_icon": "https://platform.slack-edge.com/img/default_application_icon.png",
        "ts": $(date +%s)
    }]
}
EOF
)
        ;;

    teams)
        PAYLOAD=$(cat <<EOF
{
    "@type": "MessageCard",
    "@context": "http://schema.org/extensions",
    "themeColor": "$COLOR_HEX",
    "summary": "Health Alert: $HOSTNAME",
    "sections": [{
        "activityTitle": "$EMOJI Health Alert: $HOSTNAME",
        "facts": [
            {"name": "Hostname", "value": "$HOSTNAME"},
            {"name": "Score", "value": "$SCORE/100"},
            {"name": "Status", "value": "$STATUS"},
            {"name": "Timestamp", "value": "$(date -Iseconds)"}
        ],
        "text": "$ALERTS"
    }],
    "potentialAction": [{
        "@type": "OpenUri",
        "name": "View Dashboard",
        "targets": [{
            "os": "default",
            "uri": "https://grafana.example.com"
        }]
    }]
}
EOF
)
        ;;

    discord)
        PAYLOAD=$(cat <<EOF
{
    "embeds": [{
        "title": "$EMOJI Health Alert: $HOSTNAME",
        "color": $((16#${COLOR_HEX:1})),
        "fields": [
            {"name": "Hostname", "value": "$HOSTNAME", "inline": true},
            {"name": "Score", "value": "$SCORE/100", "inline": true},
            {"name": "Status", "value": "$STATUS", "inline": true},
            {"name": "Alerts", "value": "$ALERTS", "inline": false}
        ],
        "timestamp": "$(date -Iseconds)",
        "footer": {"text": "Health Check Monitor"}
    }]
}
EOF
)
        ;;

    custom)
        PAYLOAD=$(cat <<EOF
{
    "hostname": "$HOSTNAME",
    "score": $SCORE,
    "status": "$STATUS",
    "timestamp": "$(date -Iseconds)",
    "alerts": $(echo "$HEALTH_JSON" | jq '.alerts')
}
EOF
)
        ;;

    *)
        log_error "Unknown webhook type: $WEBHOOK_TYPE"
        exit 1
        ;;
esac

# Send webhook
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD")

if [[ "$HTTP_CODE" =~ ^2 ]]; then
    log_info "Alert sent successfully (HTTP $HTTP_CODE)"
    exit 0
else
    log_error "Alert failed (HTTP $HTTP_CODE)"
    exit 1
fi

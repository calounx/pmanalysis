# CLAUDE.md - Debian 12 System Health Analyzer

## Project Context

**Purpose**: Production-grade system health analysis script for Debian 12 hosts
**Execution**: Non-root user with sudo privileges
**Output**: Structured JSON + human-readable report
**Target**: SRE/DevOps teams monitoring infrastructure health

## Tech Stack

- **Language**: Bash 5.2+ (Debian 12 native)
- **Requirements**: `jq`, `bc`, `sysstat`, `lsof`, `net-tools`
- **Exit Codes**: Standard POSIX (0=healthy, 1=warnings, 2=critical)
- **Logging**: JSON-structured + timestamped

## Architecture Patterns

### Script Structure (Hexagonal Approach)
```
health-check.sh
├── Core Domain: Health metrics collection
├── Adapters: System interface (sudo calls)
├── Ports: Output formatters (JSON, text, Prometheus)
└── Infrastructure: Logging, error handling
```

### Separation of Concerns
- **Collectors**: Pure data gathering functions (no sudo in function body)
- **Analyzers**: Threshold evaluation + scoring
- **Reporters**: Multi-format output (JSON, Markdown, Prometheus)
- **Orchestrator**: Main execution flow + error handling

## Security Requirements

### CRITICAL: Sudo Hardening
```bash
# Minimal sudo footprint - whitelist exact commands
# Script must validate sudo access before execution
# Never pass user input to sudo commands
# Log all sudo operations
```

### Mandatory Checks
- Verify sudo privileges at startup
- Validate all external command availability
- Sanitize ALL variables used in sudo context
- Fail-safe defaults (warn, don't crash)

## Health Metrics Scope

### System Resources (CRITICAL)
- CPU: load average, per-core usage, steal time
- Memory: used/available, swap usage, OOM events
- Disk: I/O wait, space usage, inode usage
- Network: throughput, errors, dropped packets

### Services & Processes (HIGH)
- Systemd unit failures
- Zombie/defunct processes
- High-memory processes (top 10)
- Long-running uninterruptible sleep (D state)

### Security & Stability (MEDIUM)
- Failed login attempts (last 24h)
- Open ports vs expected baseline
- Kernel messages (dmesg errors)
- Filesystem errors (ext4/xfs journals)

### Performance Indicators (LOW)
- Context switches rate
- CPU iowait trends
- Network retransmits
- DNS resolution latency

## Output Format Standards

### JSON Structure
```json
{
  "timestamp": "2025-12-20T10:30:00Z",
  "hostname": "prod-web-01",
  "status": "healthy|warning|critical",
  "score": 87,
  "metrics": {
    "cpu": {
      "load_1min": 1.2,
      "load_5min": 0.8,
      "load_15min": 0.5,
      "cores": 4,
      "usage_percent": 35.2,
      "iowait_percent": 2.1,
      "steal_percent": 0.0
    },
    "memory": {
      "total_mb": 4096,
      "used_mb": 2867,
      "available_mb": 1229,
      "usage_percent": 70.0,
      "swap_total_mb": 2048,
      "swap_used_mb": 512,
      "swap_percent": 25.0,
      "oom_events": 0
    },
    "disk": {
      "filesystems": [
        {
          "mount": "/",
          "usage_percent": 45,
          "inodes_percent": 12,
          "device": "/dev/sda1"
        },
        {
          "mount": "/var",
          "usage_percent": 82,
          "inodes_percent": 35,
          "device": "/dev/sda2"
        }
      ],
      "iowait_percent": 2.1,
      "iops": 45
    },
    "network": {
      "interfaces": [
        {
          "name": "eth0",
          "rx_errors": 0,
          "tx_errors": 0,
          "rx_dropped": 0,
          "tx_dropped": 0,
          "rx_bytes_sec": 1048576,
          "tx_bytes_sec": 524288
        }
      ],
      "retransmits": 12,
      "connections_established": 156
    },
    "services": {
      "failed_units": [],
      "zombie_processes": 0,
      "defunct_processes": 0,
      "d_state_processes": 0,
      "top_memory_processes": [
        {"name": "mysqld", "pid": 1234, "mem_mb": 512},
        {"name": "php-fpm", "pid": 5678, "mem_mb": 256}
      ]
    }
  },
  "alerts": [
    {
      "severity": "warning",
      "component": "disk",
      "message": "Disk usage high on /var",
      "value": 82,
      "threshold": 80
    },
    {
      "severity": "warning",
      "component": "memory",
      "message": "Swap in use",
      "value": 512,
      "threshold": 0
    }
  ],
  "recommendations": [
    "Investigate /var disk usage growth",
    "Consider disabling swap or adding RAM",
    "Review slow queries if database host"
  ]
}
```

### Markdown Report
```markdown
# System Health Report - prod-web-01
**Status**: ✓ HEALTHY (Score: 87/100)
**Generated**: 2025-12-20 10:30:00 UTC

## 🚨 Critical Alerts
None

## ⚠️ Warnings
- **Disk**: /var usage at 82% (threshold: 80%)
- **Memory**: Swap in use (512MB)

## 📊 Metrics Summary

### CPU
- Load Average: 1.2 / 0.8 / 0.5 (4 cores)
- Usage: 35.2%
- I/O Wait: 2.1%

### Memory
- Used: 2.8GB / 4.0GB (70%)
- Swap: 512MB / 2.0GB (25%)

### Disk
- /: 45%
- /var: 82% ⚠️

### Services
- Failed Units: 0
- Zombie Processes: 0

## 💡 Recommendations
1. Investigate /var disk usage growth
2. Consider disabling swap or adding RAM
3. Review slow queries if database host
```

### Prometheus Export
```prometheus
# HELP system_health_score Overall system health score (0-100)
# TYPE system_health_score gauge
system_health_score{hostname="prod-web-01"} 87

# HELP system_cpu_load_1min CPU load average 1 minute
# TYPE system_cpu_load_1min gauge
system_cpu_load_1min{hostname="prod-web-01"} 1.2

# HELP system_memory_usage_percent Memory usage percentage
# TYPE system_memory_usage_percent gauge
system_memory_usage_percent{hostname="prod-web-01"} 70.0

# HELP system_disk_usage_percent Disk usage percentage by mount
# TYPE system_disk_usage_percent gauge
system_disk_usage_percent{hostname="prod-web-01",mount="/"} 45
system_disk_usage_percent{hostname="prod-web-01",mount="/var"} 82
```

## Thresholds & Scoring

### Weighted Scoring Model
```bash
CPU_WEIGHT=25
MEMORY_WEIGHT=30
DISK_WEIGHT=25
SERVICES_WEIGHT=20

# Component scores (0-100) multiplied by weights
# Final score = (cpu_score * 0.25) + (mem_score * 0.30) + (disk_score * 0.25) + (svc_score * 0.20)
```

### Alert Thresholds
```bash
# CPU
CPU_LOAD_WARNING=70          # % of total cores (1min load)
CPU_LOAD_CRITICAL=90
CPU_IOWAIT_WARNING=10        # % time waiting for I/O
CPU_IOWAIT_CRITICAL=25
CPU_STEAL_WARNING=5          # % stolen by hypervisor

# Memory
MEM_USAGE_WARNING=80         # % of total RAM
MEM_USAGE_CRITICAL=95
SWAP_USAGE_WARNING=1         # Any swap usage is concerning
SWAP_USAGE_CRITICAL=50
OOM_EVENTS_CRITICAL=1        # Any OOM kill is critical

# Disk
DISK_USAGE_WARNING=80        # % per filesystem
DISK_USAGE_CRITICAL=90
INODE_USAGE_WARNING=80
INODE_USAGE_CRITICAL=90
DISK_IOWAIT_WARNING=10       # % I/O wait time
DISK_IOWAIT_CRITICAL=25

# Network
NET_ERRORS_WARNING=100       # Errors per interface (24h)
NET_ERRORS_CRITICAL=1000
NET_DROPPED_WARNING=100      # Dropped packets (24h)
NET_RETRANSMIT_WARNING=1000  # TCP retransmits (24h)

# Services
FAILED_SERVICES_CRITICAL=1   # Any failed systemd unit
ZOMBIE_PROCESSES_WARNING=5
DEFUNCT_PROCESSES_WARNING=3
D_STATE_PROCESSES_WARNING=2  # Uninterruptible sleep

# Security
FAILED_LOGINS_WARNING=50     # Last 24h
FAILED_LOGINS_CRITICAL=200
```

### Scoring Algorithm
```bash
# Each component gets 0-100 score based on thresholds
# Example for CPU:
# - Load < 70%: 100 points
# - Load 70-90%: Linear scale 100->50
# - Load > 90%: Linear scale 50->0

calculate_component_score() {
    local value=$1
    local warning=$2
    local critical=$3
    
    if (( $(echo "$value < $warning" | bc -l) )); then
        echo 100
    elif (( $(echo "$value < $critical" | bc -l) )); then
        # Linear interpolation between warning and critical
        echo "scale=0; 100 - ((($value - $warning) / ($critical - $warning)) * 50)" | bc
    else
        # Beyond critical: 0-50 based on how far over
        echo "scale=0; 50 - ((($value - $critical) / $critical) * 50)" | bc | awk '{print ($1 < 0) ? 0 : $1}'
    fi
}
```

## Code Standards

### Bash Best Practices
```bash
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Script metadata
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# All caps for constants
readonly LOG_FILE="/var/log/health-check.log"

# Lowercase for variables
local hostname
local timestamp

# Function naming: verb_noun
function collect_cpu_metrics() { ... }
function analyze_memory_usage() { ... }
function report_json_output() { ... }
```

### Error Handling Pattern
```bash
# Fail gracefully - never crash on collector errors
collect_metric() {
    local metric_name="$1"
    local result
    
    if ! result=$(timeout 5s command_to_run 2>/dev/null); then
        log_error "Failed to collect ${metric_name}: ${result}"
        echo "null"  # Return safe default
        return 1
    fi
    
    echo "${result}"
    return 0
}

# Aggregate errors in final report
declare -a COLLECTION_ERRORS=()

if ! cpu_data=$(collect_cpu_metrics); then
    COLLECTION_ERRORS+=("CPU metrics collection failed")
fi
```

### Logging Standards
```bash
# Structured logging to stderr
log_error() {
    echo "[$(date -Iseconds)] ERROR: $*" >&2
}

log_warn() {
    echo "[$(date -Iseconds)] WARN: $*" >&2
}

log_info() {
    echo "[$(date -Iseconds)] INFO: $*" >&2
}

# JSON logging for machine parsing
log_json() {
    local level="$1"
    local message="$2"
    jq -nc --arg ts "$(date -Iseconds)" \
           --arg lvl "$level" \
           --arg msg "$message" \
           '{timestamp: $ts, level: $lvl, message: $msg}' >&2
}
```

### Performance Optimization
```bash
# Parallel collection using background jobs
collect_all_metrics() {
    local -A results
    
    # Start collectors in background
    cpu_data=$(collect_cpu_metrics) &
    local cpu_pid=$!
    
    mem_data=$(collect_memory_metrics) &
    local mem_pid=$!
    
    disk_data=$(collect_disk_metrics) &
    local disk_pid=$!
    
    # Wait for all with timeout
    if ! wait_with_timeout 10 $cpu_pid $mem_pid $disk_pid; then
        log_error "Collection timeout exceeded"
    fi
    
    # Retrieve results
    wait $cpu_pid && results[cpu]=$cpu_data
    wait $mem_pid && results[mem]=$mem_data
    wait $disk_pid && results[disk]=$disk_data
}
```

### Input Validation
```bash
# Validate sudo access at startup
validate_sudo() {
    if ! sudo -n true 2>/dev/null; then
        log_error "This script requires passwordless sudo access"
        log_error "Add to /etc/sudoers.d/health-check:"
        log_error "username ALL=(root) NOPASSWD: /usr/bin/dmesg, /usr/bin/journalctl"
        exit 2
    fi
}

# Sanitize all variables in sudo context
safe_sudo_command() {
    local cmd="$1"
    
    # Whitelist allowed commands
    case "$cmd" in
        dmesg|journalctl|iotop|lsof)
            sudo "$cmd" "${@:2}"
            ;;
        *)
            log_error "Unauthorized sudo command: $cmd"
            return 1
            ;;
    esac
}
```

## Testing Requirements

### Unit Tests (bats-core)
```bash
# tests/collectors.bats
#!/usr/bin/env bats

setup() {
    load '../health-check.sh'
    export SUDO_MOCK=true
}

@test "collect_cpu_metrics returns valid JSON" {
    result=$(collect_cpu_metrics)
    echo "$result" | jq -e '.load_1min' > /dev/null
}

@test "calculate_score handles boundary conditions" {
    score=$(calculate_component_score 50 80 90)
    [[ $score -eq 100 ]]
    
    score=$(calculate_component_score 80 80 90)
    [[ $score -eq 100 ]]
    
    score=$(calculate_component_score 85 80 90)
    [[ $score -eq 75 ]]
}

@test "disk_usage handles missing filesystems gracefully" {
    export MOCK_DF_OUTPUT=""
    result=$(collect_disk_metrics)
    [[ "$result" == "null" ]]
}
```

### Integration Tests
```bash
# tests/integration.sh
#!/usr/bin/env bash

# Test on healthy system
test_healthy_system() {
    output=$(./health-check.sh --json)
    status=$(echo "$output" | jq -r '.status')
    [[ "$status" == "healthy" ]]
}

# Test with artificial load
test_high_cpu_detection() {
    stress-ng --cpu 4 --timeout 30s &
    sleep 5
    output=$(./health-check.sh --json)
    score=$(echo "$output" | jq -r '.metrics.cpu.usage_percent')
    (( $(echo "$score > 80" | bc -l) ))
}

# Test disk full scenario
test_disk_full_alert() {
    # Requires test environment with small partition
    dd if=/dev/zero of=/tmp/testfs/fill bs=1M count=900
    output=$(./health-check.sh --json)
    alerts=$(echo "$output" | jq -r '.alerts[] | select(.component=="disk")')
    [[ -n "$alerts" ]]
    rm -f /tmp/testfs/fill
}
```

### Validation Checklist
- [ ] shellcheck clean (SC2086, SC2162 explicitly handled)
- [ ] All functions have doc comments
- [ ] JSON output validates against schema
- [ ] Exit codes conform to POSIX
- [ ] No execution as root (must fail)
- [ ] All timeouts enforced
- [ ] Error paths tested
- [ ] Memory leaks checked (long-running mode)

## Dependencies Management

### Required Packages (Script aborts if missing)
```bash
REQUIRED_COMMANDS=(
    "jq"          # JSON processing
    "bc"          # Float arithmetic
    "awk"         # Text processing
    "date"        # Timestamp generation
    "df"          # Disk usage
    "free"        # Memory info
    "uptime"      # Load average
)

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
}
```

### Optional Packages (Degraded functionality)
```bash
OPTIONAL_COMMANDS=(
    "sysstat:iostat"      # I/O statistics
    "lsof:lsof"           # Open files/connections
    "net-tools:netstat"   # Network statistics
    "iotop:iotop"         # I/O monitoring (requires sudo)
    "dstat:dstat"         # System resource stats
)

check_optional_deps() {
    local missing=()
    
    for entry in "${OPTIONAL_COMMANDS[@]}"; do
        IFS=':' read -r package cmd <<< "$entry"
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$package")
            log_warn "Optional command missing: $cmd (install $package)"
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_info "Install optional packages: apt install -y ${missing[*]}"
        log_info "Some metrics will be unavailable"
    fi
}
```

## Operational Usage

### Command-Line Interface
```bash
Usage: health-check.sh [OPTIONS]

OPTIONS:
    -h, --help              Show this help message
    -v, --version           Show version information
    -q, --quiet             Suppress output (exit code only)
    -j, --json              Output JSON only (no markdown)
    -f, --format FORMAT     Output format: json|markdown|prometheus
    -o, --output FILE       Write output to file instead of stdout
    -m, --monitor INTERVAL  Continuous monitoring mode (seconds)
    -b, --baseline FILE     Compare against baseline file
    -s, --score-only        Output health score only
    --no-color              Disable colored output
    --debug                 Enable debug logging

EXIT CODES:
    0   System healthy (score >= 80)
    1   Warnings detected (score 50-79)
    2   Critical issues (score < 50) or script error

EXAMPLES:
    # Interactive mode with markdown report
    ./health-check.sh

    # JSON output for monitoring system
    ./health-check.sh --json | jq '.score'

    # Continuous monitoring every 60 seconds
    ./health-check.sh --monitor 60 --json >> /var/log/health.jsonl

    # Compare against baseline
    ./health-check.sh --baseline /etc/health-baseline.json

    # Quiet mode for cron (exit code only)
    ./health-check.sh --quiet || alert-team "Health check failed"
```

### Integration Examples

#### Cron Job
```bash
# /etc/cron.d/health-check
*/5 * * * * monitor /usr/local/bin/health-check.sh --json >> /var/log/health.jsonl 2>&1

# Alert on failure
*/5 * * * * monitor /usr/local/bin/health-check.sh --quiet || /usr/local/bin/alert-team "Health check failed on $(hostname)"
```

#### Systemd Timer
```ini
# /etc/systemd/system/health-check.timer
[Unit]
Description=System Health Check Timer
Requires=health-check.service

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
AccuracySec=1s

[Install]
WantedBy=timers.target

# /etc/systemd/system/health-check.service
[Unit]
Description=System Health Check
After=network.target

[Service]
Type=oneshot
User=monitor
ExecStart=/usr/local/bin/health-check.sh --json --output /var/log/health-latest.json
StandardOutput=journal
StandardError=journal
```

#### Prometheus Integration
```bash
# Export as textfile for node_exporter
TEXTFILE_DIR=/var/lib/node_exporter/textfile_collector

/usr/local/bin/health-check.sh --format prometheus > "${TEXTFILE_DIR}/health.prom.$$"
mv "${TEXTFILE_DIR}/health.prom.$$" "${TEXTFILE_DIR}/health.prom"
```

#### Slack/Teams Webhook
```bash
#!/bin/bash
# /usr/local/bin/alert-team

WEBHOOK_URL="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"

health_output=$(health-check.sh --json)
score=$(echo "$health_output" | jq -r '.score')
status=$(echo "$health_output" | jq -r '.status')

if [[ "$status" != "healthy" ]]; then
    alerts=$(echo "$health_output" | jq -r '.alerts[] | "• \(.severity): \(.message)"')
    
    curl -X POST "$WEBHOOK_URL" \
         -H 'Content-Type: application/json' \
         -d @- <<EOF
{
    "text": "🚨 Health Alert: $(hostname)",
    "attachments": [{
        "color": "$([[ "$status" == "critical" ]] && echo "danger" || echo "warning")",
        "fields": [
            {"title": "Score", "value": "$score/100", "short": true},
            {"title": "Status", "value": "$status", "short": true},
            {"title": "Alerts", "value": "$alerts", "short": false}
        ]
    }]
}
EOF
fi
```

## DevOps Agent Skills Required

### Expected Claude Code Capabilities

1. **Deep System Knowledge**
   - /proc filesystem internals (`/proc/stat`, `/proc/meminfo`, `/proc/loadavg`)
   - /sys filesystem (`/sys/block/*/stat`, `/sys/class/net/*/statistics`)
   - systemd internals (`systemctl`, `journalctl`, unit states)
   - Kernel ring buffer (`dmesg`, log levels, facility codes)

2. **Advanced Bash Programming**
   - Parameter expansion (`${var%%pattern}`, `${var#pattern}`)
   - Process substitution (`<(command)`, `>(command)`)
   - Associative arrays (`declare -A metrics`)
   - Parallel execution (`&`, `wait`, job control)
   - Trap handling (cleanup, signal handling)

3. **Text Processing Mastery**
   - awk: field extraction, aggregation, calculations
   - sed: stream editing, pattern replacement
   - grep: pattern matching, context extraction
   - Regular expressions (ERE, PCRE where supported)

4. **JSON Manipulation**
   - jq: filtering, transforming, schema validation
   - Safe escaping (quotes, newlines, special chars)
   - Nested object construction
   - Array aggregation

5. **Performance Engineering**
   - Command timeouts (`timeout`, `alarm`)
   - Parallel execution without race conditions
   - Memory-efficient processing (pipes vs temp files)
   - Caching expensive operations

6. **Security Hardening**
   - Input sanitization (prevent injection)
   - Principle of least privilege (minimal sudo)
   - Secure temporary file handling (`mktemp`)
   - Path traversal prevention

7. **Error Recovery**
   - Graceful degradation (missing commands)
   - Partial failure handling (continue on error)
   - Retry logic with exponential backoff
   - Comprehensive logging

### Debian 12 Specific Knowledge

- **systemd 252**: `systemctl --state=failed --no-pager --no-legend`
- **procps-ng**: Output format changes in `ps`, `top`, `free`
- **util-linux 2.38**: New flags in `lsblk`, `findmnt`
- **coreutils 9.1**: `df` output format, `numfmt` for human-readable
- **iproute2**: `ip -s link`, `ss -s` statistics
- **Journal location**: `/var/log/journal/` or `/run/log/journal/`

## Anti-Patterns to Avoid

### ❌ NEVER DO THIS

```bash
# Parsing ls output
files=$(ls -l | awk '{print $9}')  # WRONG - brittle, breaks on spaces

# Use this instead
files=(*)
for file in "${files[@]}"; do
    [[ -f "$file" ]] && echo "$file"
done

# Using eval on untrusted input
eval "$user_input"  # DANGEROUS - arbitrary code execution

# Unbounded loops
while true; do
    check_something
done  # WRONG - no exit condition, no rate limiting

# Use this instead
max_iterations=100
count=0
while [[ $count -lt $max_iterations ]]; do
    check_something
    ((count++))
    sleep 1
done

# Storing secrets in script
API_KEY="sk-1234567890"  # WRONG - committed to git, visible in ps

# Use environment variables or secrets manager
API_KEY="${API_KEY:-$(cat /run/secrets/api_key)}"

# Unquoted variables
rm -rf $temp_dir/*  # DANGEROUS - word splitting, globbing

# Always quote
rm -rf "${temp_dir:?}/"*

# Using sudo su
sudo su - root -c "commands"  # WRONG - unnecessary privilege escalation

# Call specific commands
sudo dmesg
sudo journalctl
```

### ⚠️ Common Pitfalls

```bash
# Ignoring exit codes
grep pattern file
echo "Found"  # WRONG - runs even if grep failed

# Check exit codes
if grep -q pattern file; then
    echo "Found"
fi

# Not handling spaces in filenames
for file in $(find . -name "*.log"); do  # WRONG
    process "$file"
done

# Use null-delimited or while read
find . -name "*.log" -print0 | while IFS= read -r -d '' file; do
    process "$file"
done

# Inefficient piping
cat file | grep pattern | awk '{print $1}'  # USELESS cat

# Direct input redirection
grep pattern < file | awk '{print $1}'
# Or even better
awk '/pattern/ {print $1}' file
```

## Deliverables

### Phase 1: Core Functionality (MVP)
- [x] Script structure with argument parsing
- [x] All metric collectors implemented
  - [x] CPU (load, usage, iowait, steal)
  - [x] Memory (usage, swap, OOM events)
  - [x] Disk (space, inodes, I/O)
  - [x] Network (errors, drops, retransmits)
  - [x] Services (systemd failures, zombies)
- [x] Scoring algorithm with weighted components
- [x] JSON output with full schema
- [x] Markdown report generation
- [x] Error handling and logging
- [x] Sudo validation and minimization

### Phase 2: Enhanced Functionality
- [ ] Prometheus export format
- [ ] Baseline comparison mode
- [ ] Historical trending (store last 10 runs)
- [ ] Diff mode (changes since last run)
- [ ] Alert suppression (known issues whitelist)
- [ ] Continuous monitoring mode
- [ ] Custom threshold configuration file

### Phase 3: Production Readiness
- [ ] Comprehensive test suite (bats + integration)
- [ ] Man page documentation
- [ ] Debian package (.deb with systemd units)
- [ ] Installation script (dependency check + setup)
- [ ] Grafana dashboard JSON export
- [ ] Ansible/Puppet deployment modules
- [ ] CI/CD pipeline (GitHub Actions)

### Phase 4: Advanced Features
- [ ] Predictive analytics (trend analysis)
- [ ] Machine learning anomaly detection
- [ ] Multi-host aggregation mode
- [ ] Remote execution via SSH
- [ ] Web dashboard (optional CGI interface)
- [ ] Plugin system for custom collectors

## Documentation Standards

### Inline Documentation
```bash
#######################################
# Collect CPU metrics including load average and usage
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   JSON object with CPU metrics to stdout
# Returns:
#   0 on success, 1 on failure
#######################################
collect_cpu_metrics() {
    local load_1min load_5min load_15min
    local cpu_count cpu_usage iowait steal
    
    # Read load average from /proc
    read -r load_1min load_5min load_15min _ < /proc/loadavg || return 1
    
    # Get CPU count
    cpu_count=$(nproc) || return 1
    
    # Calculate CPU usage from /proc/stat
    # ... implementation ...
    
    jq -nc \
        --arg l1 "$load_1min" \
        --arg l5 "$load_5min" \
        --arg l15 "$load_15min" \
        --arg cores "$cpu_count" \
        --arg usage "$cpu_usage" \
        --arg iow "$iowait" \
        --arg steal "$steal" \
        '{
            load_1min: ($l1 | tonumber),
            load_5min: ($l5 | tonumber),
            load_15min: ($l15 | tonumber),
            cores: ($cores | tonumber),
            usage_percent: ($usage | tonumber),
            iowait_percent: ($iow | tonumber),
            steal_percent: ($steal | tonumber)
        }'
}
```

### README.md Template
```markdown
# Debian 12 System Health Analyzer

Production-grade health monitoring script for Debian 12 hosts.

## Features
- Comprehensive system metrics (CPU, Memory, Disk, Network)
- Service health monitoring (systemd, processes)
- Multiple output formats (JSON, Markdown, Prometheus)
- Configurable thresholds and scoring
- Minimal sudo footprint

## Requirements
- Debian 12 (Bookworm)
- Bash 5.2+
- Non-root user with sudo access
- Dependencies: `jq bc` (required), `sysstat lsof net-tools` (optional)

## Installation
```bash
# Download script
curl -O https://raw.githubusercontent.com/user/repo/main/health-check.sh
chmod +x health-check.sh

# Install dependencies
sudo apt install -y jq bc sysstat lsof net-tools

# Configure sudo (replace 'monitor' with your username)
echo 'monitor ALL=(root) NOPASSWD: /usr/bin/dmesg, /usr/bin/journalctl' | \
    sudo tee /etc/sudoers.d/health-check

# Test
./health-check.sh --version
./health-check.sh --json | jq .
```

## Usage
See `./health-check.sh --help` for full options.

## License
MIT
```

## References & Resources

### Official Documentation
- [Debian Administrator's Handbook](https://www.debian.org/doc/manuals/debian-handbook/)
- [systemd.unit(5)](https://www.freedesktop.org/software/systemd/man/systemd.unit.html)
- [proc(5)](https://man7.org/linux/man-pages/man5/proc.5.html)
- [Bash Reference Manual](https://www.gnu.org/software/bash/manual/)

### Best Practices
- [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html)
- [Bash Strict Mode](http://redsymbol.net/articles/unofficial-bash-strict-mode/)
- [ShellCheck Wiki](https://www.shellcheck.net/wiki/)
- [jq Manual](https://stedolan.github.io/jq/manual/)

### Monitoring Standards
- [Prometheus Naming Conventions](https://prometheus.io/docs/practices/naming/)
- [OpenMetrics Specification](https://github.com/OpenObservability/OpenMetrics)
- [SRE Book - Monitoring Distributed Systems](https://sre.google/sre-book/monitoring-distributed-systems/)

### Security
- [CIS Debian Benchmark](https://www.cisecurity.org/benchmark/debian_linux)
- [NIST Security Guidelines](https://csrc.nist.gov/publications)
- [sudo Best Practices](https://www.sudo.ws/docs/man/1.9.15/sudoers.man/)

---

**Document Version**: 1.0.0
**Last Updated**: 2025-12-20T14:30:00Z
**Maintainer**: CalouNX (DevOps/SRE)
**Project Status**: Ready for Development
**License**: MIT


# Debian 12 System Health Analyzer

Production-grade health monitoring script for Debian 12 (Bookworm) hosts. Provides comprehensive system metrics, intelligent scoring, and multiple output formats for integration with monitoring systems.

## Features

- **Comprehensive Metrics Collection**
  - CPU: load average, usage, I/O wait, steal time
  - Memory: usage, swap, OOM events detection
  - Disk: space usage, inode usage, I/O statistics
  - Network: errors, dropped packets, retransmits, connections
  - Services: systemd failures, zombie/defunct processes, top memory consumers

- **Intelligent Health Scoring**
  - Weighted scoring model (CPU: 25%, Memory: 30%, Disk: 25%, Services: 20%)
  - Configurable thresholds for warnings and critical alerts
  - Overall health score from 0-100 with status: healthy/warning/critical

- **Multiple Output Formats**
  - JSON: Machine-readable for monitoring systems
  - Markdown: Human-readable reports with emoji indicators
  - Score-only mode: Simple numeric output for scripting

- **Production-Ready**
  - Minimal sudo footprint with security hardening
  - Graceful degradation when optional tools unavailable
  - Comprehensive error handling and logging
  - POSIX-compliant exit codes

## Requirements

### System Requirements
- Debian 12 (Bookworm)
- Bash 5.2+
- Non-root user with sudo access (optional, for enhanced metrics)

### Required Dependencies
```bash
sudo apt install -y jq bc
```

### Optional Dependencies
For enhanced metrics collection:
```bash
sudo apt install -y sysstat lsof net-tools
```

## Installation

### Quick Install
```bash
# Download the script
curl -O https://raw.githubusercontent.com/username/pmanalysis/main/health-check.sh
chmod +x health-check.sh

# Install required dependencies
sudo apt install -y jq bc

# Test installation
./health-check.sh --version
./health-check.sh --help
```

### Production Installation
```bash
# Install to system path
sudo cp health-check.sh /usr/local/bin/health-check
sudo chmod +x /usr/local/bin/health-check

# Configure sudo (optional - for enhanced metrics)
# Replace 'monitoring' with your username
echo 'monitoring ALL=(root) NOPASSWD: /usr/bin/dmesg, /usr/bin/journalctl' | \
    sudo tee /etc/sudoers.d/health-check
sudo chmod 440 /etc/sudoers.d/health-check

# Test
health-check --version
```

## Usage

### Command-Line Options

```bash
Usage: health-check.sh [OPTIONS]

OPTIONS:
    -h, --help              Show help message
    -v, --version           Show version information
    -q, --quiet             Suppress output (exit code only)
    -j, --json              Output JSON only
    -f, --format FORMAT     Output format: json|markdown
    -o, --output FILE       Write output to file
    -s, --score-only        Output health score only
    --no-color              Disable colored output
    --debug                 Enable debug logging

EXIT CODES:
    0   System healthy (score >= 80)
    1   Warnings detected (score 50-79)
    2   Critical issues (score < 50) or script error
```

### Examples

#### Interactive Health Report
```bash
./health-check.sh
```

Output:
```markdown
# System Health Report - webserver-01
**Status**: ✓ HEALTHY (Score: 87/100)
**Generated**: 2025-12-20T10:30:00Z

## 🚨 Critical Alerts
None

## ⚠️ Warnings
- **disk**: Disk usage high on /var (82%)

## 📊 Metrics Summary

### CPU
- Load Average: 1.2 / 0.8 / 0.5 (4 cores)
- Usage: 35.2%
- I/O Wait: 2.1%

### Memory
- Used: 2GB / 4GB (70%)
- Swap: 512MB / 2GB (25%)

### Disk
- /: 45%
- /var: 82% ⚠️

### Services
- Failed Units: 0
- Zombie Processes: 0
```

#### JSON Output for Monitoring
```bash
./health-check.sh --json | jq '.score'
# Output: 87

./health-check.sh --json | jq '.alerts[].message'
# Output: "Disk usage high on /var"
```

#### Automated Monitoring
```bash
# Simple health check with exit code
./health-check.sh --quiet
echo "Exit code: $?"  # 0 = healthy, 1 = warning, 2 = critical

# Get numeric score only
SCORE=$(./health-check.sh --score-only)
if [[ $SCORE -lt 80 ]]; then
    echo "Health degraded: $SCORE/100"
fi
```

#### Save Report to File
```bash
# JSON report
./health-check.sh --json --output /var/log/health-$(date +%Y%m%d-%H%M%S).json

# Markdown report
./health-check.sh --format markdown --output /tmp/health-report.md
```

## Integration Examples

### Cron Job
Monitor system health every 5 minutes:

```bash
# /etc/cron.d/health-check
*/5 * * * * monitor /usr/local/bin/health-check --json >> /var/log/health.jsonl 2>&1

# Alert on failure
*/5 * * * * monitor /usr/local/bin/health-check --quiet || /usr/local/bin/alert-team
```

### Systemd Timer
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
```

```ini
# /etc/systemd/system/health-check.service
[Unit]
Description=System Health Check
After=network.target

[Service]
Type=oneshot
User=monitoring
ExecStart=/usr/local/bin/health-check --json --output /var/log/health-latest.json
StandardOutput=journal
StandardError=journal
```

Enable and start:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now health-check.timer
sudo systemctl status health-check.timer
```

### Prometheus Integration
Export metrics for Prometheus node_exporter:

```bash
#!/bin/bash
# /usr/local/bin/health-to-prometheus

TEXTFILE_DIR=/var/lib/node_exporter/textfile_collector

# Generate Prometheus metrics
/usr/local/bin/health-check --json | jq -r '
"# HELP system_health_score Overall system health score (0-100)",
"# TYPE system_health_score gauge",
("system_health_score{hostname=\"" + .hostname + "\"} " + (.score|tostring)),
"",
"# HELP system_cpu_load_1min CPU load average 1 minute",
"# TYPE system_cpu_load_1min gauge",
("system_cpu_load_1min{hostname=\"" + .hostname + "\"} " + (.metrics.cpu.load_1min|tostring)),
"",
"# HELP system_memory_usage_percent Memory usage percentage",
"# TYPE system_memory_usage_percent gauge",
("system_memory_usage_percent{hostname=\"" + .hostname + "\"} " + (.metrics.memory.usage_percent|tostring))
' > "${TEXTFILE_DIR}/health.prom.$$"

mv "${TEXTFILE_DIR}/health.prom.$$" "${TEXTFILE_DIR}/health.prom"
```

### Slack/Teams Webhook
Alert team on health issues:

```bash
#!/bin/bash
# /usr/local/bin/alert-team

WEBHOOK_URL="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"

health_output=$(health-check --json)
status=$(echo "$health_output" | jq -r '.status')

if [[ "$status" != "healthy" ]]; then
    score=$(echo "$health_output" | jq -r '.score')
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

## Configuration

### Alert Thresholds

Thresholds are configured in the script (lines 24-62). Modify these values to adjust sensitivity:

```bash
# CPU
readonly CPU_LOAD_WARNING=70          # % of total cores
readonly CPU_LOAD_CRITICAL=90
readonly CPU_IOWAIT_WARNING=10        # % time waiting for I/O
readonly CPU_IOWAIT_CRITICAL=25

# Memory
readonly MEM_USAGE_WARNING=80         # % of total RAM
readonly MEM_USAGE_CRITICAL=95
readonly SWAP_USAGE_WARNING=1         # Any swap usage warns
readonly SWAP_USAGE_CRITICAL=50

# Disk
readonly DISK_USAGE_WARNING=80        # % per filesystem
readonly DISK_USAGE_CRITICAL=90
readonly INODE_USAGE_WARNING=80
readonly INODE_USAGE_CRITICAL=90

# Services
readonly FAILED_SERVICES_CRITICAL=1   # Any failed unit is critical
readonly ZOMBIE_PROCESSES_WARNING=5
```

### Scoring Weights

Adjust component weights (lines 64-67):

```bash
readonly CPU_WEIGHT=25        # 25% of total score
readonly MEMORY_WEIGHT=30     # 30% of total score
readonly DISK_WEIGHT=25       # 25% of total score
readonly SERVICES_WEIGHT=20   # 20% of total score
```

## Output Format

### JSON Schema
```json
{
  "timestamp": "2025-12-20T10:30:00Z",
  "hostname": "webserver-01",
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
        }
      ],
      "iowait_percent": 2.1,
      "iops": 45
    },
    "network": {
      "interfaces": [],
      "retransmits": 12,
      "connections_established": 156
    },
    "services": {
      "failed_units": [],
      "zombie_processes": 0,
      "defunct_processes": 0,
      "d_state_processes": 0,
      "top_memory_processes": [
        {"name": "mysqld", "pid": 1234, "mem_mb": 512}
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
    }
  ],
  "recommendations": [
    "Investigate /var disk usage growth"
  ]
}
```

## Troubleshooting

### Script reports "Missing required commands"
Install dependencies:
```bash
sudo apt install -y jq bc
```

### Warning: "Optional command missing: iostat"
Install sysstat for I/O statistics:
```bash
sudo apt install -y sysstat
```

### Sudo warnings for dmesg/journalctl
Configure passwordless sudo for enhanced metrics:
```bash
echo 'username ALL=(root) NOPASSWD: /usr/bin/dmesg, /usr/bin/journalctl' | \
    sudo tee /etc/sudoers.d/health-check
sudo chmod 440 /etc/sudoers.d/health-check
```

### Script takes too long to run
The script includes a 1-second sleep for CPU usage calculation. This is normal and required for accuracy.

## Security Considerations

- Script requires NO root privileges for basic operation
- Optional sudo access provides enhanced metrics (OOM events, kernel messages)
- Sudo access is restricted to specific read-only commands
- All variables in sudo context are sanitized
- No user input is executed directly
- Follows principle of least privilege

## Performance

- Typical execution time: 2-3 seconds
- Memory footprint: < 10MB
- CPU usage: Minimal (brief sampling period)
- Safe for frequent execution (every 1-5 minutes)

## Roadmap

See CLAUDE.md for planned features:

**Phase 2**: Prometheus export, baseline comparison, historical trending
**Phase 3**: Comprehensive test suite, Debian package, Grafana dashboard
**Phase 4**: Predictive analytics, multi-host aggregation, web dashboard

## Contributing

Contributions are welcome! Please ensure:
- Code follows Google Shell Style Guide
- All functions include doc comments
- Changes pass shellcheck validation
- New features include usage examples

## License

MIT License - see LICENSE file for details

## Author

**CalouNX** - DevOps/SRE Engineer

For issues, questions, or feature requests, please open an issue on GitHub.

---

**Version**: 1.0.0
**Last Updated**: 2025-12-20
**Status**: Production Ready

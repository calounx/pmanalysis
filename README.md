# System Health Analyzer for Debian 12

A production-grade system health monitoring script that provides comprehensive insights into your Debian 12 server's performance and stability.

![Version](https://img.shields.io/badge/version-1.0.0-blue)
![Debian](https://img.shields.io/badge/debian-12%20(bookworm)-red)
![License](https://img.shields.io/badge/license-MIT-green)
![Bash](https://img.shields.io/badge/bash-5.2%2B-orange)

## 🎯 Overview

**health-check.sh** is a lightweight, comprehensive health monitoring solution designed specifically for Debian 12 systems. It collects metrics from multiple system components, analyzes them against configurable thresholds, and generates actionable reports in multiple formats.

**Perfect for:**
- 🖥️ SRE/DevOps teams monitoring infrastructure
- 📊 Automated health checks in CI/CD pipelines
- ⚡ Quick system diagnostics
- 📈 Integration with monitoring platforms (Prometheus, Grafana)
- 🔔 Proactive alerting systems

## ✨ Key Features

### Comprehensive Monitoring
- **CPU Metrics**: Load average, usage percentage, I/O wait, steal time (for VMs)
- **Memory**: RAM usage, swap consumption, OOM (Out-of-Memory) event detection
- **Disk**: Filesystem usage, inode consumption, I/O operations per second
- **Network**: Interface statistics, TCP retransmit rates, connection counts
- **Services**: Failed systemd units, zombie processes, top memory consumers

### Intelligent Scoring System
- Weighted health score (0-100) based on all metrics
- Configurable thresholds for warnings and critical alerts
- Component-specific scoring with automatic aggregation
- Exit codes aligned with monitoring best practices

### Root Cause Analysis (NEW)
- **Automatic correlation** of performance degradation with system changes
- **Change detection**: Tracks package installs/upgrades, config modifications, service restarts
- **Historical tracking**: Monitors score trends to identify degradation patterns
- **Smart diagnosis**: Links score drops to recent changes (packages, configs, services)
- **Actionable recommendations**: Context-specific guidance based on detected changes
- **24-hour lookback**: Analyzes changes in the last 24 hours to find likely culprits

### Multiple Output Formats
- **JSON**: Machine-readable for automation and integrations
- **Markdown**: Human-readable reports with emojis and formatting
- **Score-only**: Simple numeric output for dashboards
- **Quiet mode**: Exit codes only for cron jobs

### Production-Ready
- ✅ Security hardened (prevents root execution, minimal sudo)
- ✅ Graceful error handling and degradation
- ✅ Timeout protection (won't hang on NFS or slow I/O)
- ✅ Signal handling (clean shutdown on Ctrl+C)
- ✅ Schema versioning for API stability

## 📋 Requirements

### System Requirements
- **OS**: Debian 12 (Bookworm) or compatible
- **Shell**: Bash 5.2 or higher
- **User**: Non-root user with sudo privileges

### Required Dependencies
These packages must be installed:
```bash
sudo apt install -y jq bc coreutils procps
```

| Package | Purpose |
|---------|---------|
| `jq` | JSON processing |
| `bc` | Floating-point arithmetic |
| `coreutils` | timeout, date, df, etc. |
| `procps` | ps, uptime, free |

### Optional Dependencies
For enhanced functionality:
```bash
sudo apt install -y sysstat lsof net-tools
```

| Package | Provides | Impact if Missing |
|---------|----------|-------------------|
| `sysstat` | iostat (I/O statistics) | Disk IOPS unavailable |
| `lsof` | Open files tracking | Enhanced diagnostics unavailable |
| `net-tools` | netstat (network stats) | TCP retransmit count unavailable |

### Sudo Configuration
For OOM detection and system logs, configure passwordless sudo:

```bash
# Create sudoers file for health-check
sudo tee /etc/sudoers.d/health-check <<EOF
# Allow health-check to read system logs
your-username ALL=(root) NOPASSWD: /usr/bin/dmesg
your-username ALL=(root) NOPASSWD: /usr/bin/journalctl
EOF

# Set correct permissions
sudo chmod 0440 /etc/sudoers.d/health-check
```

Replace `your-username` with your actual username.

## 🚀 Installation

### Quick Install

```bash
# Download the script
curl -O https://raw.githubusercontent.com/your-repo/pmanalysis/master/health-check.sh

# Make it executable
chmod +x health-check.sh

# Install dependencies
sudo apt update
sudo apt install -y jq bc sysstat lsof net-tools

# Configure sudo (replace 'username')
echo 'username ALL=(root) NOPASSWD: /usr/bin/dmesg, /usr/bin/journalctl' | \
    sudo tee /etc/sudoers.d/health-check
sudo chmod 0440 /etc/sudoers.d/health-check

# Test it!
./health-check.sh --version
```

### System-Wide Installation

```bash
# Install to system path
sudo cp health-check.sh /usr/local/bin/health-check
sudo chmod 755 /usr/local/bin/health-check

# Verify installation
health-check --version
```

## 💻 Usage

### Basic Commands

```bash
# Default: Markdown report to stdout
./health-check.sh

# JSON output for automation
./health-check.sh --json

# Get just the health score
./health-check.sh --score-only

# Quiet mode (exit code only)
./health-check.sh --quiet

# Save to file
./health-check.sh --json --output /var/log/health.json

# Debug mode
./health-check.sh --debug
```

### Command-Line Options

| Option | Description |
|--------|-------------|
| `-h, --help` | Show help message |
| `-v, --version` | Show version information |
| `-q, --quiet` | Suppress output (exit code only) |
| `-j, --json` | Output JSON format |
| `-f, --format FORMAT` | Output format: json\|markdown |
| `-o, --output FILE` | Write to file instead of stdout |
| `-s, --score-only` | Output health score only (0-100) |
| `--no-color` | Disable colored output |
| `--debug` | Enable debug logging |

### Exit Codes

| Code | Meaning | Health Status |
|------|---------|---------------|
| `0` | Healthy | Score ≥ 80 |
| `1` | Warnings | Score 50-79 |
| `2` | Critical | Score < 50 or script error |

## 📊 Output Examples

### JSON Output

```json
{
  "schema_version": "1.0.0",
  "script_version": "1.0.0",
  "timestamp": "2025-12-20T10:00:00+00:00",
  "hostname": "web-server-01",
  "status": "healthy",
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
          "device": "/dev/sda1",
          "mount": "/",
          "usage_percent": 45,
          "inodes_percent": 12
        }
      ],
      "iowait_percent": 2.1,
      "iops": 450
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
      "component": "memory",
      "message": "Swap in use",
      "value": 512,
      "threshold": 0
    }
  ],
  "recommendations": [
    "Consider disabling swap or adding RAM"
  ],
  "root_cause_analysis": {
    "enabled": false,
    "reason": "No significant score degradation detected"
  }
}
```

### Markdown Output

```markdown
# System Health Report - web-server-01
**Status**: ✓ HEALTHY (Score: 87/100)
**Generated**: 2025-12-20 10:00:00 UTC

## 🚨 Critical Alerts
None

## ⚠️ Warnings
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

### Services
- Failed Units: 0
- Zombie Processes: 0

## 💡 Recommendations
1. Consider disabling swap or adding RAM
```

### Root Cause Analysis Output (When Triggered)

When the health score drops by 5+ points, RCA automatically activates:

```markdown
## 🔍 Root Cause Analysis

### Performance Degradation Detected
- Previous Score: 95/100
- Current Score: 85/100
- Drop: 10 points (-10.5%)

### Diagnosis
**Performance degraded after package update(s) and configuration change(s)**

Suspicion: Package: nginx, Config: /etc/nginx/nginx.conf

### Recent System Changes (Last 24 hours)

**Package Updates:**
- 2025-12-20 14:23:15: package_upgrade - nginx (1.22.1 → 1.24.0)
- 2025-12-20 14:23:18: package_install - nginx-extras

**Configuration Changes:**
- 2025-12-20T14:25:32+00:00: /etc/nginx/nginx.conf
- 2025-12-20T14:25:35+00:00: /etc/nginx/sites-available/default

**Service Restarts:**
- 2025-12-20T14:26:12+00:00: nginx.service (restart)

### Recommended Actions
1. Review recently updated packages for known issues
2. Consider rolling back suspect package updates
3. Review recent configuration changes
4. Compare current config with previous versions
```

**How RCA Works:**
1. **Score Tracking**: Each run saves the health score to `/var/lib/health-check/history.json`
2. **Change Detection**: Monitors package logs, config file modifications, and service restarts
3. **Correlation**: Links score drops to changes within the same time window
4. **Diagnosis**: Provides context-specific analysis and recommendations

**RCA Configuration:**
- **Trigger Threshold**: Score drop ≥ 5 points
- **Lookback Window**: 24 hours
- **History Retention**: Last 100 scores
- **Storage**: `/var/lib/health-check/` (auto-created, gracefully degrades if unwritable)

## 🔧 Integration Examples

### Cron Job (Every 5 Minutes)

```bash
# Add to crontab: crontab -e
*/5 * * * * /usr/local/bin/health-check --json >> /var/log/health.jsonl 2>&1

# Or for alerts only
*/5 * * * * /usr/local/bin/health-check --quiet || /usr/local/bin/send-alert
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

[Install]
WantedBy=timers.target
```

```ini
# /etc/systemd/system/health-check.service
[Unit]
Description=System Health Check

[Service]
Type=oneshot
User=monitor
ExecStart=/usr/local/bin/health-check --json --output /var/log/health-latest.json
StandardOutput=journal
```

Enable the timer:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now health-check.timer
```

### Prometheus Node Exporter (Textfile Collector)

```bash
#!/bin/bash
# /usr/local/bin/health-check-prometheus.sh

TEXTFILE_DIR=/var/lib/node_exporter/textfile_collector

# Generate Prometheus metrics
{
    echo "# HELP system_health_score Overall system health score (0-100)"
    echo "# TYPE system_health_score gauge"

    JSON=$(/usr/local/bin/health-check --json)
    SCORE=$(echo "$JSON" | jq -r '.score')
    HOSTNAME=$(echo "$JSON" | jq -r '.hostname')

    echo "system_health_score{hostname=\"$HOSTNAME\"} $SCORE"

    # CPU metrics
    CPU_LOAD=$(echo "$JSON" | jq -r '.metrics.cpu.load_1min')
    echo "system_cpu_load_1min{hostname=\"$HOSTNAME\"} $CPU_LOAD"

    # Memory metrics
    MEM_USAGE=$(echo "$JSON" | jq -r '.metrics.memory.usage_percent')
    echo "system_memory_usage_percent{hostname=\"$HOSTNAME\"} $MEM_USAGE"

} > "${TEXTFILE_DIR}/health.prom.$$"

mv "${TEXTFILE_DIR}/health.prom.$$" "${TEXTFILE_DIR}/health.prom"
```

### Slack/Discord Webhook Alert

```bash
#!/bin/bash
# /usr/local/bin/alert-health.sh

WEBHOOK_URL="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"

OUTPUT=$(health-check --json)
STATUS=$(echo "$OUTPUT" | jq -r '.status')
SCORE=$(echo "$OUTPUT" | jq -r '.score')

if [[ "$STATUS" != "healthy" ]]; then
    ALERTS=$(echo "$OUTPUT" | jq -r '.alerts[] | "• \(.severity): \(.message)"')

    curl -X POST "$WEBHOOK_URL" \
         -H 'Content-Type: application/json' \
         -d @- <<EOF
{
    "text": "🚨 Health Alert: $(hostname)",
    "attachments": [{
        "color": "$([[ "$STATUS" == "critical" ]] && echo "danger" || echo "warning")",
        "fields": [
            {"title": "Score", "value": "$SCORE/100", "short": true},
            {"title": "Status", "value": "$STATUS", "short": true},
            {"title": "Alerts", "value": "$ALERTS", "short": false}
        ]
    }]
}
EOF
fi
```

## ⚙️ Configuration

### Health Thresholds

The script uses predefined thresholds. To customize, edit the constants at the top of `health-check.sh`:

```bash
# CPU Thresholds (percentage of cores)
readonly CPU_LOAD_WARNING=70
readonly CPU_LOAD_CRITICAL=90
readonly CPU_IOWAIT_WARNING=10
readonly CPU_IOWAIT_CRITICAL=25

# Memory Thresholds (percentage)
readonly MEM_USAGE_WARNING=80
readonly MEM_USAGE_CRITICAL=95
readonly SWAP_USAGE_WARNING=1
readonly SWAP_USAGE_CRITICAL=50

# Disk Thresholds (percentage)
readonly DISK_USAGE_WARNING=80
readonly DISK_USAGE_CRITICAL=90
readonly INODE_USAGE_WARNING=80
readonly INODE_USAGE_CRITICAL=90

# Network Thresholds (counts)
readonly NET_ERRORS_WARNING=100
readonly NET_ERRORS_CRITICAL=1000
readonly NET_DROPPED_WARNING=100
readonly NET_RETRANSMIT_WARNING=1000

# Services Thresholds
readonly FAILED_SERVICES_CRITICAL=1
readonly ZOMBIE_PROCESSES_WARNING=5
readonly D_STATE_PROCESSES_WARNING=2
```

### Scoring Weights

Adjust component importance by modifying weights (must sum to 100):

```bash
readonly CPU_WEIGHT=20
readonly MEMORY_WEIGHT=30
readonly DISK_WEIGHT=20
readonly NETWORK_WEIGHT=10
readonly SERVICES_WEIGHT=20
```

### Root Cause Analysis Settings

Customize RCA behavior by editing these constants:

```bash
# Root Cause Analysis
readonly RCA_HISTORY_DIR="/var/lib/health-check"
readonly RCA_HISTORY_FILE="$RCA_HISTORY_DIR/history.json"
readonly RCA_LOOKBACK_HOURS=24

# RCA triggers when score drops by this amount
# Set to 0 to always enable RCA, or higher value (e.g., 10) to reduce noise
SCORE_DROP_THRESHOLD=5  # Default: 5 points
```

**Notes:**
- RCA requires write permission to `/var/lib/health-check/`
- If directory creation fails, RCA gracefully degrades (no errors)
- History file stores last 100 score entries (circular buffer)
- Change detection parses `/var/log/dpkg.log`, `/etc` mtime, and `journalctl`

## 🐛 Troubleshooting

### "Missing required commands" Error

**Problem**: Script exits with dependency error

**Solution**:
```bash
sudo apt update
sudo apt install -y jq bc procps coreutils
```

### "Cannot run sudo dmesg without password" Warning

**Problem**: OOM detection unavailable

**Solution**: Configure passwordless sudo (see [Sudo Configuration](#sudo-configuration))

### Empty Disk Filesystems Array

**Problem**: No disk metrics in output

**Possible Causes**:
1. Running in container with no `/dev/` mounts
2. All filesystems filtered out (e.g., tmpfs, loop devices)

**Solution**: Test on bare metal or VM with real filesystems

### Network Interfaces Empty

**Problem**: No network metrics in output

**Cause**: Script only detects physical network interfaces (checks `/sys/class/net/*/device`)

**Solution**: Normal on VMs with virtual interfaces. Physical servers will show data.

### "Script must NOT be run as root" Error

**Problem**: Trying to run with sudo

**Solution**: Run as regular user with sudo permissions configured:
```bash
./health-check.sh  # NOT: sudo ./health-check.sh
```

### Script Hangs or Times Out

**Possible Causes**:
1. NFS mount not responding
2. Slow disk I/O

**Built-in Protection**: Script has timeouts (5s for df, 3s for iostat). If issues persist:
```bash
# Check for hung processes
ps aux | grep health-check

# Kill if necessary
killall health-check.sh
```

### RCA Not Showing in Output

**Problem**: Root Cause Analysis section missing from reports

**Possible Reasons**:
1. No score degradation (RCA only triggers on 5+ point drop)
2. First run (no previous score in history)
3. Score improved instead of degraded

**Solution**: Check JSON output for RCA status:
```bash
./health-check.sh --json | jq '.root_cause_analysis'

# Example when RCA is disabled:
# {
#   "enabled": false,
#   "reason": "No significant score degradation detected"
# }
```

**To test RCA manually**:
```bash
# Create history directory
sudo mkdir -p /var/lib/health-check
sudo chown $USER:$USER /var/lib/health-check

# Simulate a previous high score
echo '[{"timestamp":"2025-12-20T10:00:00+00:00","score":95}]' > /var/lib/health-check/history.json

# Make a change (install package, modify config, etc.)
sudo apt install tree

# Run health check - RCA may trigger if score drops
./health-check.sh
```

### RCA History File Permission Denied

**Problem**: Cannot write to `/var/lib/health-check/`

**Solution**: RCA gracefully degrades if it can't write history. To enable full RCA:
```bash
sudo mkdir -p /var/lib/health-check
sudo chown $USER:$USER /var/lib/health-check
```

## 📈 Performance

### Execution Time
- **Typical**: 3-4 seconds
- **Target**: < 5 seconds
- **Factors**: CPU speed, disk I/O, number of processes

### Resource Usage
- **Memory**: < 50 MB
- **CPU**: < 10% (brief spike during execution)
- **Disk**: Minimal (< 1KB temp files)

### Optimization Tips
1. Use `--quiet` mode for cron jobs (no output formatting)
2. Use `--score-only` if you only need the numeric score
3. Redirect stderr to `/dev/null` in production cron jobs
4. Consider increasing check interval if system is slow

## 🔒 Security Considerations

### Principle of Least Privilege
- ✅ Script refuses to run as root
- ✅ Only requests sudo for specific commands (dmesg, journalctl)
- ✅ No user input parsing (no injection risk)
- ✅ All paths are sanitized

### Sudo Best Practices
The script only requires sudo for:
1. `dmesg` - Reading kernel ring buffer for OOM events
2. `journalctl` - Reading system logs (fallback for OOM detection)

**Recommendation**: Use passwordless sudo only for these specific commands (see [Sudo Configuration](#sudo-configuration))

### Data Privacy
- ✅ No sensitive data collected
- ✅ No external network calls
- ✅ All data stays local
- ✅ Process names visible in top 10 (informational only)

## 🤝 Contributing

Contributions are welcome! Here's how you can help:

### Reporting Issues
1. Check existing issues first
2. Include system information (Debian version, kernel version)
3. Provide script output with `--debug` flag
4. Include steps to reproduce

### Feature Requests
1. Describe the use case
2. Explain the expected behavior
3. Consider backward compatibility

### Pull Requests
1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure shellcheck passes: `shellcheck health-check.sh`
5. Update documentation

### Development Guidelines
- Follow existing code style
- Use meaningful variable names
- Add comments for complex logic
- Test on Debian 12
- Keep backward compatibility

## 📜 License

MIT License

Copyright (c) 2025 CalouNX

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## 🙏 Acknowledgments

- Built with [Claude Code](https://claude.com/claude-code)
- Inspired by monitoring best practices from the SRE community
- Thanks to the Debian and open-source communities

## 📞 Support

### Documentation
- Full specification: See [CLAUDE.md](CLAUDE.md) for detailed technical documentation
- This README: User guide and integration examples

### Getting Help
1. Check the [Troubleshooting](#troubleshooting) section
2. Search existing [GitHub Issues](https://github.com/your-repo/pmanalysis/issues)
3. Create a new issue with details

### Useful Resources
- [Debian 12 Documentation](https://www.debian.org/releases/bookworm/)
- [Bash Scripting Guide](https://www.gnu.org/software/bash/manual/)
- [jq Manual](https://stedolan.github.io/jq/manual/)
- [Prometheus Best Practices](https://prometheus.io/docs/practices/naming/)

---

**Made with ❤️ for the Debian community**

*Last Updated: 2025-12-20 | Version: 1.0.0*

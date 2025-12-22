# Frequently Asked Questions (FAQ)

## General Questions

### Q: What is the health-check system?
**A:** A production-grade monitoring tool for Debian 12 that provides comprehensive system health analysis with Root Cause Analysis, automated alerting, and multi-format output (JSON, Markdown, Prometheus).

### Q: Why can't I run it as root?
**A:** Security best practice. The script explicitly refuses root execution (exit 2) to enforce least-privilege principles. Run as a non-root user with sudo configured for specific commands only (dmesg, journalctl).

### Q: What's the difference between v1.0.0 and v1.1.0?
**A:** v1.1.0 adds:
- Built-in prerequisite checker (`--check-prerequisites`)
- Automated deployment validation (8 tests)
- Production runbook and deployment checklist
- CI/CD pipeline (GitHub Actions)
- Ansible deployment automation
- Grafana dashboards
- Multi-host aggregation
- Built-in alerting (Slack/Teams/Discord)

### Q: Is it compatible with Debian 11 or Ubuntu?
**A:** Designed for Debian 12 (Bookworm). May work on Debian 11 or Ubuntu 22.04+ but not officially tested. systemd is required.

---

## Installation & Setup

### Q: How do I install dependencies?
**A:**
```bash
# Required
sudo apt update
sudo apt install -y jq bc

# Optional (for enhanced metrics)
sudo apt install -y sysstat lsof net-tools

# Verify
./health-check.sh --check-prerequisites
```

### Q: How do I configure sudo?
**A:**
```bash
echo 'monitor ALL=(root) NOPASSWD: /usr/bin/dmesg, /usr/bin/journalctl' | \
    sudo tee /etc/sudoers.d/health-check

sudo chmod 440 /etc/sudoers.d/health-check
sudo visudo -c  # Validate syntax
```

### Q: Where should I install the script?
**A:** Recommended: `/opt/health-check/health-check.sh` with symlink in `/usr/local/bin/health-check`

### Q: How do I set up automated monitoring?
**A:** Use systemd timer (recommended) or cron:

**Systemd:**
```bash
# See ansible/roles/health-check/templates/health-check.service.j2
sudo systemctl enable health-check.timer
sudo systemctl start health-check.timer
```

**Cron:**
```bash
*/5 * * * * /opt/health-check/health-check.sh --json >> /var/log/health.jsonl 2>&1
```

---

## Usage

### Q: How do I get a quick health score?
**A:**
```bash
./health-check.sh --score-only
# Output: 87
```

### Q: How do I see detailed metrics?
**A:**
```bash
# Human-readable
./health-check.sh

# JSON (for parsing)
./health-check.sh --json | jq .

# Specific component
./health-check.sh --json | jq '.metrics.cpu'
```

### Q: How do I set up alerting?
**A:**
```bash
# Slack
export WEBHOOK_URL="https://hooks.slack.com/services/XXX"
./alert-webhook.sh --type slack --threshold 80

# From cron
*/5 * * * * WEBHOOK_URL="https://..." /opt/health-check/alert-webhook.sh
```

### Q: How do I monitor multiple hosts?
**A:**
```bash
# Create hosts file
cat > hosts.txt <<EOF
prod-web-01
prod-web-02
prod-db-01
EOF

# Aggregate
./aggregate-health.sh --file hosts.txt --output summary
```

---

## Troubleshooting

### Q: Script says "must NOT be run as root" - what do I do?
**A:** Run as a non-root user:
```bash
# Wrong
sudo ./health-check.sh

# Correct
./health-check.sh
```

### Q: Error: "command not found: jq"
**A:**
```bash
sudo apt install -y jq bc
./health-check.sh --check-prerequisites
```

### Q: Error: "Permission denied" when accessing /var/lib/health-check
**A:**
```bash
sudo mkdir -p /var/lib/health-check
sudo chown $USER:$USER /var/lib/health-check
chmod 755 /var/lib/health-check
```

### Q: Script execution takes > 10 seconds
**A:** Check for hung commands:
```bash
# Test individual commands
timeout 5 df -h
timeout 5 free -h
timeout 5 systemctl --failed

# Debug mode
./health-check.sh --debug 2>&1 | grep "Collecting"

# Common cause: NFS mounts (add timeout to /etc/fstab)
```

### Q: RCA says wrong component caused the issue
**A:** RCA is **advisory only** - it correlates changes with score drops but correlation ≠ causation. Always validate manually:
```bash
# Review actual changes
./health-check.sh --json | jq '.root_cause_analysis.recent_changes'

# Compare with system logs
journalctl --since "24 hours ago" | grep -E "install|upgrade|modified"
```

### Q: JSON output is malformed
**A:**
```bash
# Validate JSON
./health-check.sh --json | jq .

# Check for stderr mixing
./health-check.sh --json 2>/dev/null | jq .

# Debug
./health-check.sh --debug
```

### Q: Cron job not running
**A:**
```bash
# Check cron status
systemctl status cron

# Check crontab
crontab -l | grep health-check

# Check logs
grep health-check /var/log/syslog

# Test cron environment
env -i PATH=/usr/bin:/bin ./health-check.sh --quiet
```

---

## Performance & Scaling

### Q: How much CPU/memory does it use?
**A:** Minimal: ~5-15 MB RAM, < 5% CPU for < 5 seconds. Safe to run every 5 minutes on all hosts.

### Q: Can I run it on thousands of hosts?
**A:** Yes. Use `aggregate-health.sh` with high parallelism:
```bash
./aggregate-health.sh --file hosts.txt --parallel 100
```

### Q: Can I reduce execution time?
**A:** Caching is coming in next release. Current optimizations:
- Parallel metric collection (background jobs)
- Direct /proc parsing (minimal external commands)
- Timeouts on slow operations (5s per collector)

### Q: How much disk space for logs?
**A:** JSON: ~1-2 KB per run. At 5-minute intervals: ~500 KB/day, ~15 MB/month per host.

---

## Integration

### Q: How do I integrate with Prometheus?
**A:**
```bash
# Option 1: Textfile collector
./health-check.sh --format prometheus > /var/lib/node_exporter/textfile_collector/health.prom

# Option 2: Use provided script
# See ansible/roles/health-check/templates/prometheus-export.sh.j2
```

### Q: How do I create Grafana dashboards?
**A:** Import `grafana-dashboard.json`:
1. Grafana → Dashboards → Import
2. Upload `grafana-dashboard.json`
3. Select Prometheus datasource

### Q: How do I integrate with PagerDuty/Opsgenie?
**A:** Use `alert-webhook.sh` with custom webhook:
```bash
./alert-webhook.sh --url "https://events.pagerduty.com/v2/enqueue" --type custom
```

### Q: Can I use it with Ansible/Puppet/Chef?
**A:** Yes. Ansible role included in `ansible/roles/health-check/`. For Puppet/Chef, adapt the Ansible tasks.

---

## Scoring & Thresholds

### Q: How is the health score calculated?
**A:** Weighted average of component scores:
- CPU: 25%
- Memory: 30%
- Disk: 25%
- Services: 20%

Each component: 100 (< warning) → 50 (at critical) → 0 (severe).

### Q: Can I customize thresholds?
**A:** Yes. Edit constants in `health-check.sh`:
```bash
# CPU
readonly CPU_LOAD_WARNING=70
readonly CPU_LOAD_CRITICAL=90

# Memory
readonly MEM_USAGE_WARNING=80
readonly MEM_USAGE_CRITICAL=95
```

### Q: What's a "good" health score?
**A:**
- 90-100: Excellent
- 80-89: Good (production ready)
- 50-79: Warning (needs attention)
- < 50: Critical (immediate action)

### Q: Why is my score always 100?
**A:** Your system is healthy! Score will drop when issues occur. You can test by artificially creating load:
```bash
stress-ng --cpu 4 --timeout 60s
./health-check.sh --score-only  # Should show lower score
```

---

## Security

### Q: Is it safe to run in production?
**A:** Yes. Security hardened:
- ✅ Refuses root execution
- ✅ Minimal sudo (dmesg, journalctl only)
- ✅ No user input in sudo commands
- ✅ Secure temp file handling
- ✅ No secrets in code/logs
- ✅ Validated against command injection

### Q: Does it expose sensitive information?
**A:** No. Outputs only metrics (CPU, memory, disk, network stats). No passwords, tokens, or private data.

### Q: Can I use SELinux/AppArmor?
**A:** Yes. Profiles included in `security/` directory (v1.2.0+).

### Q: How do I audit sudo usage?
**A:**
```bash
# Check what requires sudo
grep -n "sudo" health-check.sh | grep -v "^#"

# Audit sudo calls
sudo ausearch -c health-check
```

---

## Advanced

### Q: How do I create a baseline?
**A:**
```bash
# Capture baseline
./health-check.sh --json > /etc/health-baseline.json

# Compare against baseline
./health-check.sh --baseline /etc/health-baseline.json
```

### Q: Can I extend it with custom metrics?
**A:** Yes. Add custom collector functions:
```bash
collect_custom_metrics() {
    local custom_value
    custom_value=$(your_command)

    jq -nc --arg val "$custom_value" \
        '{custom_metric: ($val | tonumber)}'
}

# Add to main metrics collection
```

### Q: How do I contribute?
**A:** See CONTRIBUTING.md (if exists) or:
1. Fork repository
2. Create feature branch
3. Add tests
4. Submit pull request

---

## Support

### Q: Where do I report bugs?
**A:** GitHub Issues: https://github.com/calounx/pmanalysis/issues

Include:
- `./health-check.sh --version`
- `./health-check.sh --debug` output
- `uname -a`
- `cat /etc/os-release`

### Q: Is there commercial support?
**A:** This is an open-source project (MIT license). For commercial support, contact the maintainer.

### Q: Can I hire someone to deploy this?
**A:** Yes. Use the Ansible playbook or contact DevOps consultants familiar with Debian/systemd.

---

**Last Updated**: 2025-12-22
**Version**: 2.1.0

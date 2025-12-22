# Production Deployment Runbook

## 🎯 Purpose

This runbook provides step-by-step procedures for deploying, operating, and troubleshooting the Health Check system in production environments.

---

## 📋 Pre-Deployment Checklist

### ☑️ Environment Validation

```bash
# 1. Verify Debian 12
cat /etc/os-release | grep "VERSION_ID"
# Expected: VERSION_ID="12"

# 2. Check user permissions
id
# Should NOT be root, should have sudo access

# 3. Verify disk space
df -h
# Minimum 1GB free on /

# 4. Check system health baseline
uptime; free -h; df -h
# Document current state for comparison
```

### ☑️ Prerequisites Check

```bash
# Run automated prerequisite checker
./health-check.sh --check-prerequisites

# Expected output: ✅ All required prerequisites met!
```

### ☑️ Validation Tests

```bash
# Run quick deployment validation
./validate-deployment.sh

# Expected output: ✅ DEPLOYMENT VALIDATED - Ready for production
```

---

## 🚀 Deployment Procedures

### Phase 1: Canary Deployment (Week 1)

**Objective**: Deploy to 5 non-critical servers for validation

**Steps**:

1. **Select Canary Servers**
   ```bash
   # Criteria:
   # - Non-production OR low-criticality production
   # - Diverse configurations (different workloads)
   # - Representative of fleet

   CANARY_SERVERS="dev-01 staging-01 test-api-01 test-web-01 test-db-01"
   ```

2. **Deploy to Canary**
   ```bash
   for server in $CANARY_SERVERS; do
       ssh $server "mkdir -p /opt/health-check"
       scp health-check.sh $server:/opt/health-check/
       ssh $server "cd /opt/health-check && ./health-check.sh --check-prerequisites"
   done
   ```

3. **Configure Cron (Observation Only)**
   ```bash
   # Run every 5 minutes, log to file
   */5 * * * * /opt/health-check/health-check.sh --json >> /var/log/health-canary.jsonl 2>&1
   ```

4. **Monitor for 7 Days**
   ```bash
   # Daily checks:
   # - No execution failures
   # - Metrics look reasonable
   # - No performance impact

   ssh $server "tail -100 /var/log/health-canary.jsonl | jq -r '.score'"
   ```

**Success Criteria**:
- ✅ 0 script execution failures
- ✅ All canary servers reporting
- ✅ Scores correlate with manual observation
- ✅ No system performance degradation

### Phase 2: Staged Rollout (Weeks 2-4)

**Week 2: Development/Staging (100%)**

```bash
# Deploy to all dev/staging servers
ansible-playbook -i inventory/staging deploy-health-check.yml
```

**Week 3: Production (25%)**

```bash
# Select 25% of production fleet
# Prioritize: non-customer-facing, backend services

ansible-playbook -i inventory/prod -l "prod_batch_1" deploy-health-check.yml
```

**Week 4: Production (100%)**

```bash
# Full production rollout
ansible-playbook -i inventory/prod deploy-health-check.yml
```

### Phase 3: Integration with Monitoring

**Prometheus Integration**:

```bash
# Create textfile collector script
cat > /usr/local/bin/health-check-prometheus.sh <<'EOF'
#!/bin/bash
TEXTFILE_DIR=/var/lib/node_exporter/textfile_collector
JSON=$(/opt/health-check/health-check.sh --json)
SCORE=$(echo "$JSON" | jq -r '.score')
HOSTNAME=$(hostname)

cat > "${TEXTFILE_DIR}/health.prom.$$" <<PROM
# HELP system_health_score Overall system health (0-100)
# TYPE system_health_score gauge
system_health_score{host="$HOSTNAME"} $SCORE
PROM

mv "${TEXTFILE_DIR}/health.prom.$$" "${TEXTFILE_DIR}/health.prom"
EOF

chmod +x /usr/local/bin/health-check-prometheus.sh

# Add to cron
*/5 * * * * /usr/local/bin/health-check-prometheus.sh
```

**Alerting Rules** (Prometheus):

```yaml
groups:
  - name: health_check
    interval: 5m
    rules:
      - alert: SystemHealthCritical
        expr: system_health_score < 50
        for: 10m
        labels:
          severity: critical
        annotations:
          summary: "System health critical on {{ $labels.host }}"
          description: "Health score {{ $value }} (< 50) for 10 minutes"

      - alert: SystemHealthDegraded
        expr: system_health_score < 80
        for: 30m
        labels:
          severity: warning
        annotations:
          summary: "System health degraded on {{ $labels.host }}"
          description: "Health score {{ $value }} (< 80) for 30 minutes"
```

---

## 🔧 Operations

### Daily Operations

**Morning Health Check**:

```bash
# Check fleet-wide health
ssh jump-host "for s in \$(cat /etc/hosts | grep prod | awk '{print \$2}'); do
    echo -n \"\$s: \";
    ssh \$s '/opt/health-check/health-check.sh --score-only';
done"

# Expected: All scores > 80
```

**Log Review**:

```bash
# Check for anomalies
journalctl -u health-check.timer --since "24 hours ago" | grep -i error

# Review RCA activations
grep '"enabled":true' /var/log/health*.jsonl | tail -20
```

### Weekly Operations

**Trend Analysis**:

```bash
# Weekly health score trend
jq -r '[.timestamp, .score] | @csv' /var/log/health.jsonl | \
    awk -F, '{print $1, $2}' | \
    tail -2000 > /tmp/health-trend.csv

# Plot or import to dashboard
```

**RCA Review**:

```bash
# Review all RCA activations this week
jq 'select(.root_cause_analysis.enabled == true)' /var/log/health.jsonl | \
    jq -r '[.timestamp, .root_cause_analysis.diagnosis] | @csv'

# Identify patterns
# Action items: Fix recurring issues
```

---

## 🚨 Troubleshooting

### Issue: Script Not Running

**Symptoms**: No new entries in log file

**Diagnosis**:

```bash
# Check cron status
systemctl status cron
crontab -l | grep health-check

# Manual execution test
/opt/health-check/health-check.sh --debug 2>&1 | tee /tmp/debug.log

# Check permissions
ls -la /opt/health-check/health-check.sh
ls -la /var/lib/health-check/
```

**Resolution**:

```bash
# Fix permissions
chmod +x /opt/health-check/health-check.sh
sudo chown $USER:$USER /var/lib/health-check/

# Restart cron if needed
sudo systemctl restart cron
```

### Issue: Low Health Score

**Symptoms**: Score < 80

**Diagnosis**:

```bash
# Get detailed report
/opt/health-check/health-check.sh

# Check which component is failing
/opt/health-check/health-check.sh --json | jq '.alerts'

# Review RCA if available
/opt/health-check/health-check.sh --json | jq '.root_cause_analysis'
```

**Resolution**: Follow component-specific runbooks (see below)

### Issue: RCA False Positive

**Symptoms**: RCA blames wrong component

**Diagnosis**:

```bash
# Review actual changes
/opt/health-check/health-check.sh --json | \
    jq '.root_cause_analysis.recent_changes'

# Compare with manual observation
journalctl --since "24 hours ago" | grep -E "install|upgrade|modified"
```

**Resolution**:
- RCA is advisory only - validate manually
- Document false positives for pattern analysis
- Consider threshold adjustments if frequent

### Issue: High Execution Time

**Symptoms**: Execution > 10 seconds

**Diagnosis**:

```bash
# Time individual components
time /opt/health-check/health-check.sh --debug 2>&1 | grep "Collecting"

# Check for slow commands
timeout 30 df -h  # Test if disk commands hang
timeout 30 free -h
```

**Resolution**:

```bash
# Common causes:
# 1. NFS mount hangs - add nfsvers=3 or soft mount option
# 2. Slow disk I/O - check disk health: smartctl -a /dev/sda
# 3. Network issues - check interface: ethtool eth0
```

---

## 📊 Component-Specific Runbooks

### CPU Issues (Score Low)

```bash
# Identify CPU hogs
ps aux --sort=-%cpu | head -20

# Check load average trend
uptime

# Review CPU steal (VMs)
/opt/health-check/health-check.sh --json | jq '.metrics.cpu.steal_percent'

# Action:
# - If steal > 5%: Contact cloud provider (neighbor noise)
# - If load high: Identify and address heavy processes
# - If I/O wait high: Check disk performance
```

### Memory Issues (Score Low)

```bash
# Check OOM events
/opt/health-check/health-check.sh --json | jq '.metrics.memory.oom_events'
dmesg | grep -i "out of memory"

# Identify memory hogs
ps aux --sort=-%mem | head -20

# Check swap usage
free -h

# Action:
# - If OOM events: Add memory or reduce workload
# - If swap active: Add RAM or tune applications
# - If memory leak suspected: Restart service, monitor
```

### Disk Issues (Score Low)

```bash
# Check which filesystem is full
df -h

# Find large files/directories
du -sh /* | sort -hr | head -20

# Check inode usage
df -i

# Action:
# - Clean old logs: journalctl --vacuum-time=7d
# - Rotate logs: logrotate -f /etc/logrotate.conf
# - Archive old data
# - Expand disk if needed
```

### Network Issues (Score Low)

```bash
# Check for errors
/opt/health-check/health-check.sh --json | jq '.metrics.network'

# Interface statistics
ip -s link

# Check retransmits
netstat -s | grep -i retrans

# Action:
# - If errors/drops: Check physical connection
# - If retransmits: Check network congestion, MTU
# - Contact network team if persistent
```

### Services Issues (Score Low)

```bash
# Check failed services
systemctl --failed

# Review specific service
journalctl -u <service-name> --since "1 hour ago"

# Action:
# - Restart failed services: systemctl restart <service>
# - Review logs for root cause
# - Fix configuration if needed
```

---

## 🔄 Rollback Procedures

### Emergency Rollback

**When**: Critical production impact

**Steps**:

```bash
# 1. Disable cron immediately
crontab -e
# Comment out health-check lines

# 2. Stop any running instances
pkill -f health-check.sh

# 3. Document issue
echo "$(date -Iseconds) - Rollback initiated: [REASON]" >> /var/log/health-check-rollback.log

# 4. Notify team
# Use incident management system
```

### Graceful Rollback

**When**: Non-urgent issues during rollout

**Steps**:

```bash
# 1. Pause rollout
# Don't deploy to additional servers

# 2. Keep existing deployments for investigation
# Collect diagnostic data

# 3. Fix issue in dev/staging

# 4. Re-validate

# 5. Resume rollout when confident
```

---

## 📈 Success Metrics

### Key Performance Indicators (KPIs)

- **Uptime**: > 99.9% execution success rate
- **Performance**: < 5 second average execution time
- **Coverage**: > 95% of fleet reporting
- **Accuracy**: < 5% RCA false positive rate
- **MTTR**: Mean time to resolution for issues < 1 hour

### Monitoring Dashboards

**Grafana Dashboard** (recommended panels):

1. **Fleet Health Overview**
   - Gauge: Average health score across fleet
   - Graph: Score trend (24h, 7d, 30d)
   - Heatmap: Score distribution by host

2. **Execution Metrics**
   - Graph: Execution time trend
   - Counter: Execution failures (should be 0)
   - Graph: Scripts per minute

3. **RCA Insights**
   - Counter: RCA activations per day
   - Table: Recent RCA diagnoses
   - Graph: Score drops correlated with changes

4. **Component Breakdown**
   - Gauges: CPU, Memory, Disk, Services scores
   - Graphs: Per-component trends
   - Tables: Hosts below threshold per component

---

## 📞 Escalation

### Level 1: Automated Alerts
- Monitor dashboards
- Check logs
- Follow troubleshooting guide

### Level 2: On-Call Engineer
- Complex issues
- Require code changes
- Multiple hosts affected

### Level 3: Development Team
- Script bugs
- Feature requests
- Architecture changes

**Contact**: [Your team's contact info here]

---

## 📝 Change Log

| Date | Version | Change | Owner |
|------|---------|--------|-------|
| 2025-12-22 | 2.0.0 | Added nginx, apache, mysql, redis, wordops monitoring | DevOps Team |
| 2025-12-20 | 1.1.0 | Initial production runbook | DevOps Team |

---

## ✅ Deployment Sign-Off

**Before production deployment, confirm**:

- [ ] All prerequisites met on target servers
- [ ] Validation tests pass (8/8)
- [ ] Monitoring/alerting configured
- [ ] Runbook reviewed by team
- [ ] Rollback procedure tested
- [ ] Stakeholders notified
- [ ] Change request approved

**Deployment Lead**: _____________________
**Date**: _____________________
**Approval**: _____________________

# Incident Response Playbook

## Purpose

This playbook provides step-by-step procedures for responding to health check alerts and system degradation incidents.

---

## Alert Severity Levels

| Severity | Score Range | Response Time | Escalation |
|----------|-------------|---------------|------------|
| 🟢 **Normal** | 80-100 | N/A | None |
| 🟡 **Warning** | 50-79 | < 30 min | On-call engineer |
| 🔴 **Critical** | < 50 | < 5 min | On-call + team lead |
| ⚫ **Outage** | 0 or no data | Immediate | All hands |

---

## Incident Response Workflow

```
Alert Received
    ↓
Initial Assessment (2 min)
    ↓
Triage & Classify (3 min)
    ↓
Investigate & Diagnose (10-15 min)
    ↓
Remediate (varies)
    ↓
Verify Resolution (5 min)
    ↓
Post-Incident Review (24h later)
```

---

## IR-001: Critical Health Score (< 50)

### Initial Response (< 5 minutes)

1. **Acknowledge Alert**
   ```bash
   # Get current status
   ssh $HOST /opt/health-check/health-check.sh
   ```

2. **Quick Triage**
   ```bash
   # Identify failing component
   ssh $HOST /opt/health-check/health-check.sh --json | jq '.alerts'
   ```

3. **Check if multiple hosts affected**
   ```bash
   ./aggregate-health.sh --file production-hosts.txt --output summary
   ```

### Diagnosis (< 10 minutes)

4. **Review Root Cause Analysis**
   ```bash
   ssh $HOST /opt/health-check/health-check.sh --json | jq '.root_cause_analysis'
   ```

5. **Component-Specific Investigation**
   - **CPU High** → Go to IR-010
   - **Memory Issues** → Go to IR-011
   - **Disk Full** → Go to IR-012
   - **Services Failed** → Go to IR-013
   - **Network Problems** → Go to IR-014

### Communication

6. **Notify Stakeholders**
   - Update incident channel (Slack/Teams)
   - Page relevant teams if critical service impacted
   - Update status page if customer-facing

### Resolution

7. **Follow component-specific playbook** (see below)

8. **Verify health score recovered**
   ```bash
   ssh $HOST /opt/health-check/health-check.sh --score-only
   # Expected: > 80
   ```

### Post-Incident

9. **Document actions taken**

10. **Schedule post-incident review** (within 24 hours)

---

## IR-010: CPU Overload

### Symptoms
- Score < 80
- CPU load > 90% of cores
- High I/O wait or steal time

### Immediate Actions

1. **Identify CPU hogs**
   ```bash
   ssh $HOST 'ps aux --sort=-%cpu | head -20'
   ```

2. **Check load average trend**
   ```bash
   ssh $HOST 'uptime'
   ssh $HOST 'cat /proc/loadavg'
   ```

3. **Review recent process starts**
   ```bash
   ssh $HOST 'journalctl --since "1 hour ago" | grep -i "started\|launched"'
   ```

### Root Causes & Fixes

| Cause | Detection | Fix |
|-------|-----------|-----|
| Runaway process | High CPU, single PID | `kill -9 <PID>` |
| Too many workers | High CPU, multiple PIDs | Reduce worker count |
| CPU steal (VM) | steal > 5% | Contact cloud provider |
| I/O wait | iowait > 25% | Go to IR-012 (disk) |

### Escalation
If CPU remains high after 15 minutes, escalate to infrastructure team.

---

## IR-011: Memory Exhaustion

### Symptoms
- Score < 80
- Memory usage > 95%
- OOM events > 0
- Swap usage active

### Immediate Actions

1. **Check OOM killer events**
   ```bash
   ssh $HOST 'dmesg | grep -i "out of memory"'
   ssh $HOST 'journalctl --since "1 hour ago" | grep -i "oom"'
   ```

2. **Identify memory hogs**
   ```bash
   ssh $HOST 'ps aux --sort=-%mem | head -20'
   ```

3. **Check for memory leaks**
   ```bash
   # Compare RSS over time
   ssh $HOST 'watch -n 5 "ps aux --sort=-%mem | head -5"'
   ```

### Root Causes & Fixes

| Cause | Detection | Fix |
|-------|-----------|-----|
| Memory leak | RSS growing over time | Restart service |
| Cache buildup | High cache, low available | `sync; echo 3 > /proc/sys/vm/drop_caches` |
| Too many processes | High process count | Reduce workers/connections |
| Insufficient RAM | Persistent 95% usage | Add RAM or scale horizontally |

### Escalation
If OOM events continue, immediately add memory or migrate workload.

---

## IR-012: Disk Full

### Symptoms
- Score < 80
- Disk usage > 90%
- Inode usage > 90%
- I/O wait > 25%

### Immediate Actions

1. **Identify full filesystem**
   ```bash
   ssh $HOST 'df -h'
   ssh $HOST 'df -i'  # Check inodes
   ```

2. **Find large files/directories**
   ```bash
   ssh $HOST 'du -sh /* | sort -hr | head -20'
   ssh $HOST 'find /var/log -type f -size +100M'
   ```

3. **Quick cleanup**
   ```bash
   # Rotate logs
   ssh $HOST 'sudo journalctl --vacuum-time=3d'

   # Clean package cache
   ssh $HOST 'sudo apt clean'

   # Remove old kernels
   ssh $HOST 'sudo apt autoremove --purge'
   ```

### Root Causes & Fixes

| Cause | Detection | Fix |
|-------|-----------|-----|
| Log explosion | /var/log full | Rotate logs, fix source |
| Database growth | /var/lib full | Purge old data, add disk |
| Core dumps | Large files in /var/crash | Remove core dumps |
| Inode exhaustion | df -i shows 100% | Find/remove small files |

### Escalation
If disk cannot be freed, provision additional storage immediately.

---

## IR-013: Service Failures

### Symptoms
- Score < 80
- Failed systemd units > 0
- Zombie/defunct processes

### Immediate Actions

1. **List failed services**
   ```bash
   ssh $HOST 'systemctl --failed'
   ```

2. **Check service logs**
   ```bash
   ssh $HOST 'journalctl -u <service-name> --since "1 hour ago"'
   ```

3. **Attempt restart**
   ```bash
   ssh $HOST 'sudo systemctl restart <service-name>'
   ssh $HOST 'systemctl status <service-name>'
   ```

### Root Causes & Fixes

| Cause | Detection | Fix |
|-------|-----------|-----|
| Configuration error | Logs show config issue | Fix config, restart |
| Dependency failure | Service depends on failed service | Fix dependency chain |
| Resource exhaustion | OOM/disk full | Fix resource issue first |
| Crash loop | Repeated restarts | Check logs, disable if needed |

### Escalation
If service cannot be restarted, fail over to backup or disable feature.

---

## IR-014: Network Issues

### Symptoms
- Score < 80
- High network errors/drops
- TCP retransmits elevated

### Immediate Actions

1. **Check interface stats**
   ```bash
   ssh $HOST 'ip -s link'
   ssh $HOST 'netstat -s | grep -i retrans'
   ```

2. **Test connectivity**
   ```bash
   ssh $HOST 'ping -c 5 8.8.8.8'
   ssh $HOST 'curl -I https://www.google.com'
   ```

3. **Check network services**
   ```bash
   ssh $HOST 'ss -tuln | grep LISTEN'
   ```

### Root Causes & Fixes

| Cause | Detection | Fix |
|-------|-----------|-----|
| Interface errors | RX/TX errors high | Check physical connection |
| Packet drops | Drops > 1000/day | Check MTU, switch config |
| DNS issues | Slow resolution | Check /etc/resolv.conf |
| Firewall blocking | Connection timeouts | Check iptables rules |

### Escalation
If network issues persist, contact network operations team.

---

## IR-020: Multiple Hosts Affected

### Symptoms
- 25%+ of fleet showing warnings/critical
- Similar failure pattern across hosts

### Immediate Actions

1. **Identify blast radius**
   ```bash
   ./aggregate-health.sh --file all-hosts.txt --output summary
   ```

2. **Look for common factors**
   - Same rack/datacenter?
   - Recent deployment?
   - Shared dependencies?

3. **Check for systemic issues**
   - Network outage
   - Shared storage failure
   - Load balancer misconfiguration
   - DNS/external service outage

### Communication

- Declare major incident
- Notify all stakeholders
- Update status page
- Start incident bridge

### Escalation
Immediately escalate to incident commander and all technical leads.

---

## IR-030: No Data / Host Unreachable

### Symptoms
- Host not reporting health data
- SSH connection fails
- Ping fails

### Immediate Actions

1. **Verify host status**
   ```bash
   ping -c 5 $HOST
   ssh -v $HOST
   ```

2. **Check via out-of-band management**
   - IPMI/iLO console
   - Cloud provider console
   - Physical datacenter access

3. **Attempt recovery**
   - Soft reboot via IPMI
   - Hard reboot if unresponsive
   - Investigate after reboot

### Root Causes

- Kernel panic
- Network isolation
- Power failure
- Hardware failure

### Escalation
If host cannot be reached, escalate to infrastructure/datacenter team immediately.

---

## Communication Templates

### Initial Alert
```
🚨 Health Alert - [HOST]

Severity: [Warning/Critical]
Score: [XX]/100
Component: [CPU/Memory/Disk/Services]
Time: [HH:MM UTC]
On-call: @engineer

Investigating...
```

### Status Update
```
📊 Update - [HOST]

Status: [Investigating/Identified/Mitigating]
Root Cause: [Brief description]
Impact: [Scope]
ETA: [Time to resolution]
Next Update: [HH:MM UTC]
```

### Resolution
```
✅ Resolved - [HOST]

Issue: [Brief description]
Duration: [X minutes]
Resolution: [What was done]
Prevention: [Future steps]

Post-incident review scheduled: [Date/Time]
```

---

## Post-Incident Review Checklist

- [ ] Timeline of events documented
- [ ] Root cause identified and confirmed
- [ ] Impact assessment completed
- [ ] Response time measured (target vs actual)
- [ ] Action items created
- [ ] Monitoring/alerting improvements identified
- [ ] Documentation updated
- [ ] Team feedback collected
- [ ] Lessons learned shared

---

## Escalation Contacts

| Role | Contact | Response SLA |
|------|---------|--------------|
| On-Call Engineer | [Contact] | < 5 min |
| Team Lead | [Contact] | < 15 min |
| Infrastructure Team | [Contact] | < 30 min |
| Incident Commander | [Contact] | < 10 min (major incidents) |

---

**Last Updated**: 2025-12-22
**Version**: 2.0.0

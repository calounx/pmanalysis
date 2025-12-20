# SELF-HEALING SYSTEMS - Deep Dive Analysis
**Critical Examination of Autonomous Remediation**

**Version**: 1.0.0
**Date**: 2025-12-20
**Status**: Proposal / No Implementation
**Warning**: ⚠️ **HIGH-RISK FEATURE** - Requires extensive testing before production use

---

## I. WHAT IS SELF-HEALING? (The Real Definition)

### The Truth About Self-Healing

**NOT**: Magic AI that fixes everything automatically
**NOT**: Replacing human operators
**NOT**: Production-ready out of the box

**IS**: Automated execution of **well-known, tested, reversible** remediation procedures
**IS**: Codifying expert knowledge into executable runbooks
**IS**: Buying time for humans to investigate root causes

### The Self-Healing Spectrum

```
Level 0: DETECTION ONLY
├─ Alert fires → Human investigates → Human fixes
├─ Current state of health-check.sh
└─ Safe but labor-intensive

Level 1: SUGGESTION MODE (Recommended Start)
├─ Alert fires → System suggests fix → Human approves → System executes
├─ Example: "Delete 156 log files (3.4GB)? [Y/n]"
└─ Safe, educational, builds trust

Level 2: SUPERVISED AUTOMATION (Production Sweet Spot)
├─ Alert fires → System executes LOW-RISK actions automatically
├─ Example: Restart failed services, clean package cache
├─ Requires: Approval lists, blast radius limits, circuit breakers
└─ 80% of toil eliminated, 100% audit trail

Level 3: AUTONOMOUS REMEDIATION (Dangerous Territory)
├─ Alert fires → System executes ANY action in runbook
├─ Example: Kill processes, modify configs, resize volumes
├─ Requires: Extensive testing, chaos engineering, insurance
└─ High risk of cascading failures

Level 4: PREDICTIVE SELF-HEALING (Theoretical)
├─ ML predicts failure → System acts BEFORE alert
├─ Example: Preemptively move workloads off degrading disk
├─ Requires: Advanced ML, significant investment
└─ Not recommended for bash scripts
```

**Recommended Implementation**: Start at Level 1, graduate to Level 2 over 6 months

---

## II. WHY SELF-HEALING? (The Business Case)

### The Economics of Manual Operations

**Typical Incident Timeline** (Without Self-Healing):
```
00:00 - Disk reaches 90% capacity
00:05 - Alert fires → PagerDuty → SMS to on-call engineer
00:15 - Engineer wakes up, grabs laptop
00:25 - SSH into server, runs `df -h`
00:30 - Investigates: "Oh, old logs again"
00:35 - Runs `find /var/log -name "*.gz" -mtime +30 -delete`
00:40 - Verifies disk now at 78%, clears alert
00:45 - Goes back to sleep (but can't fall asleep for 1 hour)

Total Time: 45 minutes human effort
Cost: $150 (1h on-call @ $150/h) + sleep disruption
Frequency: 2-3x per week = $31,200/year for ONE repetitive issue
```

**Same Incident** (With Self-Healing):
```
00:00 - Disk reaches 90% capacity
00:00 - Alert fires → Self-healing evaluates
00:01 - Executes: Delete logs older than 30 days
00:02 - Verification: Disk now at 78%
00:02 - Notification: "✅ Auto-resolved: Disk cleanup freed 3.2GB"
00:03 - Human reads message in morning, logs show what happened

Total Time: 3 minutes computer effort, 0 minutes human effort
Cost: $0 (automated)
```

### The Toil Problem

**Toil**: Work that is:
- Manual (requires human action)
- Repetitive (same issue, same fix)
- Automatable (can be scripted)
- Tactical (no enduring value)
- Scales linearly (more servers = more toil)

**Toil Statistics** (Industry Average):
- 60% of SRE time spent on toil
- 70% of incidents are repeats of previous incidents
- Average fix time: 15-45 minutes per incident
- 10 servers = 10 incidents/week
- 1000 servers = 1000 incidents/week (untenable)

**Self-Healing Goal**: Eliminate toil, focus humans on strategic work

---

## III. THE SAFETY FRAMEWORK (How to Not Shoot Yourself)

### Rule #1: Never Trust Your Code

**Principle**: Every action must be:
1. **Reversible** (or have rollback plan)
2. **Idempotent** (safe to run multiple times)
3. **Blast-radius limited** (can't break everything)
4. **Logged** (full audit trail)
5. **Circuit-broken** (fails safely)

### Rule #2: Approval Tiers

**Action Risk Classification**:

```yaml
SAFE_LIST: # Auto-approve, no questions asked
  - systemctl restart <service> (non-database)
  - apt-get clean
  - journalctl --vacuum-time=7d
  - docker system prune --volumes=false
  - Clear /tmp files older than 7 days

APPROVAL_REQUIRED: # Prompt human
  - Delete ANY logs
  - Restart database services
  - Kill ANY process
  - Modify configuration files
  - Resize filesystems

FORBIDDEN: # Never automate
  - rm -rf on system directories
  - chmod/chown on /etc, /usr, /var
  - iptables FLUSH
  - systemctl stop <critical-service>
  - Anything involving user data
```

### Rule #3: Circuit Breaker Pattern

**Problem**: What if the self-healing action CAUSES the problem?

**Example Failure Loop**:
```
1. Nginx crashes due to bad config
2. Self-healing: systemctl restart nginx
3. Nginx crashes again (same bad config)
4. Self-healing: systemctl restart nginx
5. Repeat 1000 times → systemd rate limiting → complete outage
```

**Circuit Breaker Solution**:
```bash
# Track action frequency
ACTION_LOG="/var/lib/health-check/action-history.db"

check_circuit_breaker() {
    local action="$1"
    local max_attempts=3
    local time_window=3600  # 1 hour

    # Count recent attempts
    recent_attempts=$(sqlite3 "$ACTION_LOG" \
        "SELECT COUNT(*) FROM actions
         WHERE action='$action'
         AND timestamp > datetime('now', '-1 hour')")

    if [[ $recent_attempts -ge $max_attempts ]]; then
        log_error "Circuit breaker OPEN for $action ($recent_attempts attempts in 1h)"
        log_error "Manual intervention required - disabling self-healing for this issue"
        send_escalation_alert "Self-healing failed 3x for $action - human needed"
        return 1  # Block execution
    fi

    return 0  # Allow execution
}
```

### Rule #4: Progressive Permissions

**Stage 1: Dry-Run Mode** (Week 1-2)
```bash
SELF_HEAL_MODE="dry-run"
# System logs what it WOULD do, but doesn't actually do it
# Review logs to ensure logic is correct
```

**Stage 2: Suggest Mode** (Week 3-4)
```bash
SELF_HEAL_MODE="suggest"
# System executes ONLY with human approval
# Builds confidence in automation
```

**Stage 3: Auto Mode** (Month 2+)
```bash
SELF_HEAL_MODE="auto"
SELF_HEAL_SAFE_LIST="systemctl-restart,apt-clean,log-cleanup"
# System executes approved actions automatically
# Still prompts for risky actions
```

---

## IV. REAL-WORLD EXAMPLES (Practical Runbooks)

### Example 1: Disk Space Cleanup (Low Risk)

**Trigger**: Disk usage > 90%

**Decision Tree**:
```
Is usage > 90%?
├─ YES → What's consuming space?
│  ├─ Old log files (*.gz older than 30 days)?
│  │  ├─ YES → SAFE to delete
│  │  │  ├─ Would free > 2GB?
│  │  │  │  ├─ YES → Execute cleanup
│  │  │  │  └─ NO → Alert human (insufficient cleanup)
│  │  │  └─ Execute: find /var/log -name "*.gz" -mtime +30 -delete
│  │  └─ NO → Check next candidate
│  │
│  ├─ APT package cache?
│  │  ├─ YES → Execute: apt-get clean
│  │  └─ Typical recovery: 200-500MB
│  │
│  ├─ Docker images (unused > 30 days)?
│  │  ├─ YES → Execute: docker image prune -a --filter "until=720h"
│  │  └─ Typical recovery: 1-5GB
│  │
│  ├─ Systemd journal (older than 14 days)?
│  │  ├─ YES → Execute: journalctl --vacuum-time=14d
│  │  └─ Typical recovery: 100-500MB
│  │
│  └─ User data in /tmp or /var/tmp?
│     ├─ YES → DANGEROUS - Alert human
│     └─ Manual review required
│
└─ NO → No action needed
```

**Implementation**:
```bash
#!/bin/bash
# Runbook: Disk Cleanup for /var

set -euo pipefail

readonly MOUNT_POINT="/var"
readonly THRESHOLD=90
readonly MIN_RECOVERY_MB=2000
readonly DRY_RUN="${DRY_RUN:-false}"

main() {
    local current_usage
    current_usage=$(df "$MOUNT_POINT" | awk 'NR==2 {print $5}' | tr -d '%')

    if [[ $current_usage -lt $THRESHOLD ]]; then
        echo "Usage at ${current_usage}% - below threshold"
        exit 0
    fi

    echo "⚠️  Disk usage at ${current_usage}% - executing cleanup"

    local total_freed=0

    # Strategy 1: Old compressed logs
    total_freed=$((total_freed + cleanup_old_logs))

    # Strategy 2: APT cache
    total_freed=$((total_freed + cleanup_apt_cache))

    # Strategy 3: Systemd journal
    total_freed=$((total_freed + cleanup_journal))

    # Strategy 4: Docker (if installed)
    if command -v docker &>/dev/null; then
        total_freed=$((total_freed + cleanup_docker))
    fi

    # Verify result
    local new_usage
    new_usage=$(df "$MOUNT_POINT" | awk 'NR==2 {print $5}' | tr -d '%')

    echo "Cleanup complete: ${current_usage}% → ${new_usage}% (freed ${total_freed}MB)"

    if [[ $new_usage -lt $THRESHOLD ]]; then
        exit 0  # Success
    else
        echo "⚠️  Cleanup insufficient - human intervention required"
        exit 1  # Escalate
    fi
}

cleanup_old_logs() {
    local before after freed
    before=$(df "$MOUNT_POINT" | awk 'NR==2 {print $3}')

    if [[ $DRY_RUN == "true" ]]; then
        echo "[DRY-RUN] Would delete: $(find /var/log -name "*.gz" -mtime +30 | wc -l) files"
        return 0
    fi

    find /var/log -name "*.gz" -mtime +30 -type f -delete

    after=$(df "$MOUNT_POINT" | awk 'NR==2 {print $3}')
    freed=$(( (after - before) / 1024 ))  # Convert to MB

    echo "  └─ Deleted old logs: ${freed}MB freed"
    echo "$freed"
}

cleanup_apt_cache() {
    if [[ $DRY_RUN == "true" ]]; then
        echo "[DRY-RUN] Would run: apt-get clean"
        return 0
    fi

    local before after freed
    before=$(df "$MOUNT_POINT" | awk 'NR==2 {print $3}')

    apt-get clean -qq

    after=$(df "$MOUNT_POINT" | awk 'NR==2 {print $3}')
    freed=$(( (after - before) / 1024 ))

    echo "  └─ Cleaned APT cache: ${freed}MB freed"
    echo "$freed"
}

cleanup_journal() {
    if [[ $DRY_RUN == "true" ]]; then
        echo "[DRY-RUN] Would run: journalctl --vacuum-time=14d"
        return 0
    fi

    local before after freed
    before=$(df "$MOUNT_POINT" | awk 'NR==2 {print $3}')

    journalctl --vacuum-time=14d --quiet

    after=$(df "$MOUNT_POINT" | awk 'NR==2 {print $3}')
    freed=$(( (after - before) / 1024 ))

    echo "  └─ Vacuumed journal: ${freed}MB freed"
    echo "$freed"
}

cleanup_docker() {
    if [[ $DRY_RUN == "true" ]]; then
        echo "[DRY-RUN] Would run: docker image prune"
        return 0
    fi

    local freed
    freed=$(docker image prune -a --filter "until=720h" --force 2>&1 | \
            grep "Total reclaimed space" | awk '{print $4}' | sed 's/[^0-9.]//g')

    echo "  └─ Pruned Docker images: ${freed}MB freed"
    echo "${freed:-0}"
}

main "$@"
```

---

### Example 2: Failed Service Restart (Medium Risk)

**Trigger**: systemd service in failed state

**Safety Checks**:
```bash
#!/bin/bash
# Runbook: Safe Service Restart

set -euo pipefail

readonly SERVICE="$1"
readonly MAX_RESTART_RATE=3  # Max 3 restarts per hour

can_restart_service() {
    local service="$1"

    # Check 1: Is it a critical service?
    case "$service" in
        mysql|postgresql|mariadb|mongod)
            echo "CRITICAL: Database service - manual restart required"
            return 1
            ;;
        sshd)
            echo "CRITICAL: SSH service - manual restart required"
            return 1
            ;;
    esac

    # Check 2: Has it been restarted too many times?
    local restart_count
    restart_count=$(systemctl show "$service" -p NRestarts --value)

    if [[ $restart_count -ge $MAX_RESTART_RATE ]]; then
        echo "ERROR: Service restarted $restart_count times - circuit breaker active"
        return 1
    fi

    # Check 3: Is the service in a crash loop?
    local active_enter_timestamp
    local current_timestamp
    active_enter_timestamp=$(systemctl show "$service" -p ActiveEnterTimestamp --value)
    current_timestamp=$(date +%s)

    if [[ -n "$active_enter_timestamp" ]]; then
        local uptime_seconds
        uptime_seconds=$((current_timestamp - $(date -d "$active_enter_timestamp" +%s)))

        if [[ $uptime_seconds -lt 60 ]]; then
            echo "ERROR: Service keeps crashing (uptime < 60s) - manual intervention needed"
            return 1
        fi
    fi

    return 0  # Safe to restart
}

restart_service_safely() {
    local service="$1"

    echo "Attempting safe restart of $service..."

    # Pre-restart snapshot
    systemctl status "$service" > "/tmp/${service}-pre-restart.log" || true

    # Graceful restart (reload if possible)
    if systemctl reload "$service" 2>/dev/null; then
        echo "✅ Service reloaded gracefully"
    else
        echo "⚠️  Reload not supported, performing full restart"
        systemctl restart "$service"
    fi

    # Wait for stabilization
    sleep 5

    # Verify restart succeeded
    if systemctl is-active "$service" &>/dev/null; then
        echo "✅ Service restart successful"
        systemctl status "$service" > "/tmp/${service}-post-restart.log"
        return 0
    else
        echo "❌ Service restart failed"
        systemctl status "$service" || true
        return 1
    fi
}

main() {
    local service="$1"

    if ! can_restart_service "$service"; then
        echo "Escalating to human operator"
        exit 1
    fi

    if restart_service_safely "$service"; then
        echo "Remediation successful"
        exit 0
    else
        echo "Remediation failed - manual intervention required"
        exit 1
    fi
}

main "$@"
```

---

### Example 3: Memory Leak Detection & Remediation (High Risk)

**Trigger**: Process RSS growing >5% per hour

**Conservative Approach**:
```bash
#!/bin/bash
# Runbook: Memory Leak Remediation

set -euo pipefail

readonly PROCESS_NAME="$1"
readonly APPROVAL_REQUIRED=true

detect_memory_leak() {
    local process="$1"
    local history_file="/var/lib/health-check/mem-history/${process}.dat"

    # Get current RSS
    local current_rss
    current_rss=$(ps aux | grep "$process" | grep -v grep | awk '{sum+=$6} END {print sum}')

    # Record current measurement
    echo "$(date +%s) $current_rss" >> "$history_file"

    # Keep only last 24 hours of data
    local cutoff=$(($(date +%s) - 86400))
    sed -i "/^[0-9]\{1,10\} /!d; /^$cutoff /q" "$history_file"

    # Calculate growth rate (linear regression would be better)
    local first_measure last_measure time_diff rss_diff
    first_measure=$(head -n1 "$history_file")
    last_measure=$(tail -n1 "$history_file")

    local first_time first_rss last_time last_rss
    read -r first_time first_rss <<< "$first_measure"
    read -r last_time last_rss <<< "$last_measure"

    time_diff=$((last_time - first_time))
    rss_diff=$((last_rss - first_rss))

    # Require at least 4 hours of data
    if [[ $time_diff -lt 14400 ]]; then
        echo "Insufficient data (need 4h, have $((time_diff / 3600))h)"
        return 1
    fi

    # Calculate growth rate (MB per hour)
    local growth_rate_per_hour
    growth_rate_per_hour=$(echo "scale=2; ($rss_diff / $time_diff) * 3600 / 1024" | bc)

    echo "Memory growth: ${growth_rate_per_hour}MB/hour"

    # Threshold: 50MB/hour growth
    if (( $(echo "$growth_rate_per_hour > 50" | bc -l) )); then
        echo "⚠️  LEAK DETECTED: Growing at ${growth_rate_per_hour}MB/hour"
        return 0
    fi

    return 1
}

restart_process_safely() {
    local process="$1"

    echo "⚠️  HIGH-RISK OPERATION: Restarting $process due to memory leak"

    if [[ $APPROVAL_REQUIRED == "true" ]]; then
        read -p "Approve restart? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Restart cancelled by operator"
            return 1
        fi
    fi

    # Find the service name (might be different from process name)
    local service
    service=$(systemctl list-units --type=service --all | grep "$process" | awk '{print $1}')

    if [[ -z "$service" ]]; then
        echo "ERROR: Cannot find systemd service for $process"
        echo "Manual intervention required"
        return 1
    fi

    echo "Restarting service: $service"
    systemctl restart "$service"

    # Verify
    sleep 5
    if systemctl is-active "$service" &>/dev/null; then
        echo "✅ Process restarted successfully"

        # Reset memory history
        rm -f "/var/lib/health-check/mem-history/${process}.dat"

        return 0
    else
        echo "❌ Process restart failed"
        return 1
    fi
}

main() {
    local process="$1"

    if detect_memory_leak "$process"; then
        restart_process_safely "$process"
    else
        echo "No memory leak detected for $process"
    fi
}

main "$@"
```

---

## V. WHEN SELF-HEALING GOES WRONG (Horror Stories)

### Case Study 1: The Cascading Restart Loop

**Company**: E-commerce SaaS
**Date**: 2019-03-15
**Impact**: 4-hour total outage, $2M revenue loss

**What Happened**:
```
1. Load balancer detects backend server unhealthy
2. Self-healing: Restart backend server
3. Server restarts, but takes 2 minutes to warm up
4. During warmup, healthcheck fails
5. Self-healing: Restart backend server (again)
6. Repeat 100 times
7. No backends ever become healthy
8. Total outage
```

**Root Cause**: No "grace period" after restart

**Fix**:
```bash
# Wait for warmup before declaring failure
restart_with_warmup() {
    systemctl restart backend

    # Wait up to 5 minutes for warmup
    for i in {1..30}; do
        sleep 10
        if healthcheck_passes; then
            echo "Service healthy after $((i * 10))s"
            return 0
        fi
    done

    echo "Service failed to become healthy after 5min"
    return 1
}
```

---

### Case Study 2: The Disk Cleanup Disaster

**Company**: Financial services
**Date**: 2020-11-22
**Impact**: Deleted 6 months of audit logs, SEC violation

**What Happened**:
```
1. Disk /var at 95% capacity
2. Self-healing: Delete files older than 30 days
3. Included /var/log/audit/* (required to keep for 7 years by regulation)
4. Deleted 6 months of legally-required audit logs
5. SEC investigation, $500K fine
```

**Root Cause**: No whitelist/blacklist for protected files

**Fix**:
```bash
# Protected directories - NEVER auto-delete
PROTECTED_PATHS=(
    "/var/log/audit"
    "/var/log/secure"
    "/var/backups"
    "/home"
)

cleanup_old_files() {
    local target_dir="$1"

    # Check if path is protected
    for protected in "${PROTECTED_PATHS[@]}"; do
        if [[ "$target_dir" == "$protected"* ]]; then
            echo "ERROR: Cannot auto-delete from protected path: $target_dir"
            return 1
        fi
    done

    # Proceed with cleanup
    find "$target_dir" -name "*.gz" -mtime +30 -delete
}
```

---

### Case Study 3: The Database Kill

**Company**: SaaS CRM
**Date**: 2021-07-08
**Impact**: 45 minutes of data loss, customer trust damaged

**What Happened**:
```
1. PostgreSQL process consuming 90% RAM (large query)
2. Self-healing: Kill high-memory process
3. Killed PostgreSQL mid-transaction
4. Database corruption
5. Had to restore from backup (45min old)
6. Lost 45 minutes of customer data
```

**Root Cause**: No understanding of process criticality

**Fix**:
```bash
# NEVER kill these processes automatically
CRITICAL_PROCESSES=(
    "postgres"
    "mysql"
    "mongod"
    "redis-server"
    "sshd"
)

is_critical_process() {
    local process="$1"

    for critical in "${CRITICAL_PROCESSES[@]}"; do
        if [[ "$process" == "$critical" ]]; then
            return 0  # Is critical
        fi
    done

    return 1  # Not critical
}

kill_high_memory_process() {
    local process="$1"

    if is_critical_process "$process"; then
        echo "CRITICAL PROCESS: $process - manual intervention required"
        send_escalation_alert "High memory in critical process: $process"
        return 1
    fi

    # Safe to kill non-critical process
    killall "$process"
}
```

---

## VI. THE DECISION FRAMEWORK (Should You Implement This?)

### Questions to Answer

**1. Do you have repetitive, well-understood incidents?**
- ✅ YES → Self-healing likely helps
- ❌ NO → Focus on monitoring/alerting first

**2. Do you have comprehensive logging and observability?**
- ✅ YES → Safe to automate (you can debug what went wrong)
- ❌ NO → Too risky (blind automation is dangerous)

**3. Can you test in non-production first?**
- ✅ YES → Proceed with caution
- ❌ NO → Do not implement

**4. Do you have rollback capability?**
- ✅ YES → Acceptable risk
- ❌ NO → Too risky

**5. Is your team bought in?**
- ✅ YES → Smooth adoption
- ❌ NO → Will be circumvented/disabled

### Implementation Readiness Checklist

```
[ ] We have >50 incidents/month from repetitive issues
[ ] We have documented runbooks for common fixes
[ ] We have staging/QA environment for testing
[ ] We have comprehensive monitoring (can detect bad auto-actions)
[ ] We have incident response process (for when auto-healing fails)
[ ] We have executive buy-in (some risk accepted)
[ ] We have legal approval (especially for log deletion)
[ ] We have at least 2 SREs who understand the code
[ ] We can roll back changes within 5 minutes
[ ] We have tested in dry-run mode for 2+ weeks
```

**Scoring**:
- 10/10 checked: Ready to implement
- 7-9/10: Proceed with extra caution
- 4-6/10: Not ready, address gaps first
- <4/10: Do NOT implement

---

## VII. ALTERNATIVES TO SELF-HEALING

### Option 1: Chatops (Human-in-the-Loop Automation)

Instead of fully automated, use Slack/Teams for approval:

```
[Alert Bot] 🚨 Disk /var at 95%
[Alert Bot] Suggested fix: Delete logs older than 30 days (would free 3.2GB)
[Alert Bot] React with ✅ to approve, ❌ to cancel

[Alice] ✅

[Alert Bot] Executing cleanup...
[Alert Bot] ✅ Cleanup complete: 95% → 82%
```

**Pros**: Human approval, but fast
**Cons**: Requires someone awake and available

---

### Option 2: Scheduled Preventive Maintenance

Instead of reactive self-healing, proactive cleanup:

```bash
# Cron job: Daily at 3 AM
0 3 * * * /usr/local/bin/preventive-cleanup.sh

# Cleanup before disk fills
if [[ $DISK_USAGE -gt 80 ]]; then
    cleanup_old_logs
fi
```

**Pros**: Prevents issues before they happen
**Cons**: Doesn't help with unexpected issues

---

### Option 3: Improved Alerting (Not Self-Healing)

Sometimes the answer is just better alerts:

```bash
# Instead of auto-deleting, alert EARLIER
DISK_WARNING=70    # Alert at 70% instead of 90%
DISK_CRITICAL=85   # Give humans more time to respond
```

**Pros**: Simplest, safest
**Cons**: Still requires human intervention

---

## VIII. FINAL RECOMMENDATION

### For health-check.sh Specifically

**My Opinion**: Implement **Level 1 (Suggestion Mode)** ONLY

**Reasoning**:
1. health-check.sh is a **monitoring tool**, not an orchestration platform
2. Users expect detection, not remediation
3. Scope creep risk is high
4. Liability concerns (what if auto-action causes damage?)

**Recommended Approach**:
```bash
# Add a --suggest-fix flag
./health-check.sh --json --suggest-fix

# Output includes suggested remediation:
{
  "alerts": [{
    "severity": "warning",
    "component": "disk",
    "message": "Disk usage high on /var",
    "value": 92,
    "threshold": 90,
    "suggested_fix": {
      "description": "Delete compressed logs older than 30 days",
      "command": "find /var/log -name '*.gz' -mtime +30 -delete",
      "estimated_recovery_mb": 3200,
      "risk_level": "low",
      "approval_required": true
    }
  }]
}
```

**Benefits**:
- Educational (users learn how to fix issues)
- Safe (no automatic execution)
- Useful (provides copy-paste commands)
- Auditable (suggestions logged)

**Excludes**:
- Automatic execution
- Complex runbook system
- Circuit breakers, retry logic, etc.

**Leave Advanced Self-Healing to Specialized Tools**:
- Ansible
- SaltStack
- Kubernetes Operators
- Commercial platforms (PagerDuty Runbook Automation, etc.)

---

## CONCLUSION

**Self-healing is powerful but dangerous.**

Use it for:
- ✅ Well-understood, repetitive issues
- ✅ Non-critical systems (dev/staging first)
- ✅ Actions with clear rollback paths
- ✅ Toil elimination when staffing is limited

Avoid it for:
- ❌ Novel issues
- ❌ Production databases
- ❌ Anything involving user data
- ❌ Systems you don't fully understand

**For health-check.sh**: Suggest fixes, don't execute them automatically.

---

**Document End**

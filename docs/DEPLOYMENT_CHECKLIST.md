# 🚀 Production Deployment Checklist

## ✅ Pre-Deployment (Complete ALL before deploying)

### Environment Readiness
- [ ] Debian 12 (Bookworm) confirmed: `cat /etc/os-release`
- [ ] Non-root user with sudo access: `id && sudo -v`
- [ ] Minimum 1GB free disk space: `df -h /`
- [ ] All required packages available: `./health-check.sh --check-prerequisites`

### Script Validation
- [ ] Downloaded latest version: `./health-check.sh --version` shows **2.0.0**
- [ ] Script is executable: `ls -la health-check.sh`
- [ ] Quick validation passes: `./validate-deployment.sh` shows **8/8 passed**
- [ ] Manual test run successful: `./health-check.sh`

### Configuration Setup
- [ ] RCA directory created: `sudo mkdir -p /var/lib/health-check && sudo chown $USER:$USER /var/lib/health-check`
- [ ] Sudo configured for health-check (if needed for OOM detection)
- [ ] Output log directory exists: `mkdir -p /var/log/health-check`

### Monitoring Integration (Choose One)
- [ ] Cron job configured (simple deployments)
- [ ] Systemd timer configured (recommended)
- [ ] Prometheus exporter configured (advanced)
- [ ] Custom monitoring integration tested

### Documentation Review
- [ ] Team has reviewed [PRODUCTION_RUNBOOK.md](PRODUCTION_RUNBOOK.md)
- [ ] Escalation contacts updated
- [ ] Rollback procedure understood

---

## 🎯 Deployment Phases

### Phase 1: Canary (5 servers, Week 1)
- [ ] Canary servers selected (non-critical)
- [ ] Deployed to canary hosts
- [ ] Cron/timer configured (observation mode)
- [ ] Monitoring dashboard created
- [ ] **Success criteria**: 7 days, 0 failures, scores reasonable

### Phase 2: Staging (Week 2)
- [ ] All dev/staging servers deployed
- [ ] Integration tests passing
- [ ] Performance validated
- [ ] **Success criteria**: 7 days, no issues

### Phase 3: Production 25% (Week 3)
- [ ] 25% of production fleet identified
- [ ] Deployed to batch 1
- [ ] Alerts configured
- [ ] **Success criteria**: 7 days, < 2 false positives

### Phase 4: Production 100% (Week 4)
- [ ] Remaining 75% deployed
- [ ] Full fleet monitoring confirmed
- [ ] Runbook tested in production
- [ ] **Success criteria**: 30 days stable operation

---

## 🔍 Post-Deployment Validation

### Immediate (First Hour)
- [ ] All hosts reporting: `check_fleet_status.sh`
- [ ] No execution errors: `tail -f /var/log/health.jsonl`
- [ ] Scores within expected range (typically 80-100)
- [ ] Performance acceptable (< 5s execution time)

### Day 1
- [ ] All cron/timer jobs running
- [ ] Monitoring dashboards populated
- [ ] No alerts fired
- [ ] RCA directory writable and functional

### Week 1
- [ ] Review all RCA activations
- [ ] Validate score trends
- [ ] Team trained on troubleshooting
- [ ] No rollbacks required

### Month 1
- [ ] Establish baseline scores per host
- [ ] Tune alert thresholds if needed
- [ ] Document any edge cases
- [ ] Collect feedback from team

---

## ⚠️ Rollback Triggers

**Initiate rollback immediately if**:
- Script execution failure rate > 5%
- Performance degradation (MTBF > 10s)
- False positive rate > 20%
- Production impact detected

**Rollback Procedure**:
```bash
# 1. Disable cron
crontab -e  # Comment out health-check

# 2. Stop running instances
pkill -f health-check.sh

# 3. Document and escalate
echo "$(date -Iseconds) Rollback: [REASON]" >> /var/log/rollback.log
```

---

## 📊 Success Metrics

### Week 1 Goals
- [ ] 100% execution success rate
- [ ] Average execution time < 5s
- [ ] 0 critical production issues
- [ ] Team confidence: High

### Month 1 Goals
- [ ] 99.9% uptime
- [ ] < 5% RCA false positive rate
- [ ] Mean Time To Resolution (MTTR) < 1 hour
- [ ] Positive team feedback

### Month 3 Goals
- [ ] Integrated into standard operations
- [ ] Prevented at least 1 incident
- [ ] Reduced manual health checks by 80%
- [ ] Team dependency: Medium-High

---

## 🔐 Security Verification

- [ ] Script refuses root execution
- [ ] Minimal sudo usage (only dmesg, journalctl)
- [ ] No secrets in code or logs
- [ ] Permissions properly restricted
- [ ] No shell injection vulnerabilities

---

## 📋 Final Sign-Off

**I confirm that**:
- [ ] All prerequisite checks passed
- [ ] Validation tests passed (8/8)
- [ ] Deployment phases planned
- [ ] Monitoring configured
- [ ] Rollback procedure tested
- [ ] Team trained
- [ ] Change request approved

**Deployer**: ________________
**Date**: ________________
**Approver**: ________________

---

## 📞 Emergency Contacts

| Role | Contact | Response Time |
|------|---------|---------------|
| On-Call Engineer | [Your contact] | < 15 min |
| DevOps Lead | [Your contact] | < 30 min |
| Development Team | [Your contact] | < 2 hours |

---

**Version**: 2.0.0
**Last Updated**: 2025-12-22
**Next Review**: 2026-01-22

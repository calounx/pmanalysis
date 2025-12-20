# Service Level Agreements (SLA) & Objectives (SLO)

## Overview

This document defines the Service Level Objectives (SLOs) and Service Level Agreements (SLAs) for the Health Check monitoring system.

---

## Definitions

- **SLI (Service Level Indicator)**: Quantitative measure of service level
- **SLO (Service Level Objective)**: Target value or range for an SLI
- **SLA (Service Level Agreement)**: Business agreement with consequences for missing SLOs
- **Error Budget**: Allowed downtime/degradation before SLA is breached

---

## System Availability SLOs

### Health Check Script Execution

| Metric | SLO | Measurement | Error Budget (30 days) |
|--------|-----|-------------|------------------------|
| **Availability** | 99.9% | Successful executions / Total attempts | 43 minutes |
| **Execution Time** | p95 < 5s, p99 < 10s | Script runtime distribution | 5% can exceed |
| **Memory Usage** | < 50 MB peak | RSS during execution | N/A |
| **CPU Usage** | < 10% average | CPU time / wall time | N/A |

### Data Collection Accuracy

| Metric | SLO | Measurement |
|--------|-----|-------------|
| **Metric Coverage** | 100% required metrics | Missing fields in JSON output |
| **Metric Freshness** | < 5 minutes old | Data timestamp vs collection time |
| **RCA Accuracy** | > 80% correct correlation | Manual validation of RCA findings |
| **False Positive Rate** | < 5% | Incorrect alerts / total alerts |

### Alert Delivery

| Metric | SLO | Measurement |
|--------|-----|-------------|
| **Alert Latency** | < 5 minutes | Time from issue to alert sent |
| **Alert Reliability** | 99.9% delivery | Successful webhooks / total attempts |
| **Alert Accuracy** | > 95% | True positives / all alerts |

---

## Performance SLOs

### Response Times

| Percentile | Target | Critical Threshold |
|------------|--------|-------------------|
| p50 (median) | < 2s | < 5s |
| p95 | < 5s | < 10s |
| p99 | < 10s | < 20s |
| p99.9 | < 20s | < 30s |

### Throughput

| Metric | SLO |
|--------|-----|
| **Executions/minute** | Support 1000+ hosts × 1 exec/5min = 200 exec/min |
| **Concurrent Executions** | Handle 100+ parallel runs |

---

## Reliability SLOs

### Uptime

| Service Component | SLO | Downtime/Month | Measurement |
|-------------------|-----|----------------|-------------|
| **Health Check Script** | 99.9% | 43 minutes | Cron/systemd execution success rate |
| **Aggregation Service** | 99.5% | 3.6 hours | Multi-host collection success rate |
| **Alert Webhooks** | 99.0% | 7.2 hours | Webhook delivery success rate |

### Error Rates

| Error Type | SLO | Measurement |
|------------|-----|-------------|
| **Script Failures** | < 0.1% | Exit code != 0,1,2 |
| **Collection Timeouts** | < 1% | Collector timeouts / total |
| **JSON Malformations** | 0% | Invalid JSON outputs |

---

## Data Quality SLOs

### Metric Accuracy

| Metric | SLO | Validation Method |
|--------|-----|-------------------|
| **CPU Load** | ± 5% of actual | Compare with `top`, `vmstat` |
| **Memory Usage** | ± 2% of actual | Compare with `free -m` |
| **Disk Usage** | ± 1% of actual | Compare with `df -h` |
| **Network Stats** | Exact match | Compare with `ip -s link` |

### Historical Data

| Metric | SLO |
|--------|-----|
| **Data Retention** | 100 runs per host (circular buffer) |
| **Data Corruption** | 0% corrupted entries |
| **Timestamp Accuracy** | Within 1 second of wall clock |

---

## Operational SLOs

### Deployment

| Metric | SLO | Measurement |
|--------|-----|-------------|
| **Deployment Success Rate** | > 99% | Successful deployments / total |
| **Rollback Time** | < 10 minutes | Time to restore previous version |
| **Validation Pass Rate** | 100% | All 8 validation tests must pass |

### Monitoring

| Metric | SLO | Measurement |
|--------|-----|-------------|
| **Dashboard Availability** | 99.9% | Grafana uptime |
| **Metric Gaps** | < 0.1% | Missing data points in Prometheus |
| **Alert Noise** | < 10 false positives/day | Manually validated |

### Support

| Metric | SLO |
|--------|-----|
| **Incident Response Time** | < 15 minutes (business hours) |
| **Issue Resolution Time** | < 4 hours (critical), < 24 hours (normal) |
| **Documentation Coverage** | 100% of features documented |

---

## SLAs (Business Agreements)

### Tier 1: Critical Production Systems

**Availability SLA**: 99.9% uptime (43 minutes downtime/month)

**Penalties**:
- 99.0-99.9%: 10% service credit
- 98.0-99.0%: 25% service credit
- < 98.0%: 50% service credit

**Response SLAs**:
- Critical incidents (score < 50): < 15 minutes
- Major incidents (score < 80): < 1 hour
- Minor issues: < 4 hours

### Tier 2: Non-Critical Systems

**Availability SLA**: 99.5% uptime (3.6 hours downtime/month)

**Response SLAs**:
- Critical: < 1 hour
- Major: < 4 hours
- Minor: < 24 hours

---

## Error Budget Management

### Monthly Error Budget

**Calculation**:
- SLO: 99.9% availability
- Total minutes/month: 43,200
- Error budget: 43.2 minutes (0.1%)

### Budget Consumption

| Incident Type | Budget Cost |
|---------------|-------------|
| Complete outage | 1 minute = 1 minute budget |
| Partial degradation (50% capacity) | 1 minute = 0.5 minute budget |
| Slow performance (2x SLO) | 1 minute = 0.5 minute budget |

### Budget Policies

| Budget Remaining | Actions |
|------------------|---------|
| > 50% | Normal operations, deploy new features |
| 25-50% | Cautious deployments, increase testing |
| 10-25% | Freeze non-critical deployments, focus on reliability |
| < 10% | Emergency freeze, all hands on reliability |
| Exhausted | Stop all deployments until next period |

---

## Monitoring & Reporting

### SLO Dashboards

**Required Metrics**:
- Real-time SLO compliance (gauge)
- Error budget burn rate (graph)
- SLI trends (7d, 30d)
- Alert volume and accuracy

**Access**: Grafana dashboard `/slo-monitoring`

### Reporting Cadence

| Report Type | Frequency | Audience |
|-------------|-----------|----------|
| SLO Status | Weekly | Engineering team |
| Error Budget | Weekly | Engineering + Management |
| SLA Compliance | Monthly | Management + Customers |
| Incident Review | After each incident | Engineering team |

---

## SLO Review & Adjustment

### Review Cycle

- **Quarterly**: Review all SLOs, adjust based on reality
- **Post-Incident**: Assess if SLOs are too aggressive or too lenient
- **Major Changes**: Review SLOs when system architecture changes

### Adjustment Criteria

**Tighten SLO** when:
- Consistently exceeding targets by > 20%
- Users requesting higher reliability
- Business criticality increases

**Loosen SLO** when:
- Repeatedly burning error budget
- Cost of reliability exceeds value
- Technical limitations prevent achievement

---

## Measurement Tools

### Automated Collection

```bash
# SLI data collection script (run every 5 minutes)
#!/bin/bash
START=$(date +%s)
RESULT=$(./health-check.sh --json 2>&1)
END=$(date +%s)
DURATION=$((END - START))

# Log SLI metrics
echo "{
    \"timestamp\": \"$(date -Iseconds)\",
    \"execution_time\": $DURATION,
    \"success\": $(echo $RESULT | jq -e '.score' &>/dev/null && echo true || echo false),
    \"score\": $(echo $RESULT | jq -r '.score // 0')
}" >> /var/log/sli-metrics.jsonl
```

### Prometheus Queries

**Availability**:
```promql
sum(rate(health_check_executions_total{result="success"}[30d])) /
sum(rate(health_check_executions_total[30d]))
```

**Error Budget Remaining**:
```promql
1 - ((1 - (sum(rate(health_check_executions_total{result="success"}[30d])) /
sum(rate(health_check_executions_total[30d])))) / (1 - 0.999))
```

**P95 Execution Time**:
```promql
histogram_quantile(0.95, rate(health_check_duration_seconds_bucket[5m]))
```

---

## Escalation Matrix

| SLO Breach | Severity | Escalation |
|------------|----------|------------|
| < 90% error budget | Low | Team notification |
| < 50% error budget | Medium | Manager notification |
| < 25% error budget | High | Deployment freeze, all-hands |
| 0% error budget | Critical | Executive escalation |

---

## Continuous Improvement

### SLO-Driven Development

1. **Prioritize reliability** when error budget is low
2. **Innovate freely** when error budget is healthy
3. **Balance** velocity with reliability using error budget as guide

### Reliability Projects (when budget low)

- Improve timeout handling
- Add retries and circuit breakers
- Enhance error handling
- Increase test coverage
- Add redundancy

---

**Last Updated**: 2025-12-20
**Version**: 1.0.0
**Review Date**: 2026-03-20 (Quarterly)

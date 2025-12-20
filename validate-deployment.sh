#!/usr/bin/env bash
#######################################
# Quick Deployment Validation
# Fast smoke tests for production deployment
#######################################

set +e  # Don't exit on errors, we're testing
set -u
set -o pipefail

PASS=0
FAIL=0

pass() {
    echo "✅ $1"
    ((PASS++)) || true
}

fail() {
    echo "❌ $1"
    ((FAIL++)) || true
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Quick Deployment Validation"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 1. Prerequisites
if ./health-check.sh --check-prerequisites >/dev/null 2>&1; then
    pass "Prerequisites met"
else
    fail "Prerequisites missing"
fi

# 2. Basic execution
if ./health-check.sh --quiet 2>/dev/null; then
    pass "Basic execution"
else
    fail "Execution failed"
fi

# 3. JSON valid
if ./health-check.sh --json 2>/dev/null | jq -e . >/dev/null 2>&1; then
    pass "JSON output valid"
else
    fail "JSON malformed"
fi

# 4. Score in range
SCORE=$(./health-check.sh --score-only 2>/dev/null || echo "-1")
if [[ $SCORE =~ ^[0-9]+$ ]] && [[ $SCORE -ge 0 ]] && [[ $SCORE -le 100 ]]; then
    pass "Score valid ($SCORE)"
else
    fail "Score out of range ($SCORE)"
fi

# 5. Performance < 10s
START=$(date +%s)
./health-check.sh --quiet 2>/dev/null
END=$(date +%s)
DURATION=$((END - START))
if [[ $DURATION -lt 10 ]]; then
    pass "Performance OK (${DURATION}s)"
else
    fail "Too slow (${DURATION}s)"
fi

# 6. No root
sudo ./health-check.sh >/dev/null 2>&1
ROOT_EXIT=$?
if [[ $ROOT_EXIT -eq 2 ]]; then
    pass "Root prevention (exit 2)"
else
    fail "Allows root (exit $ROOT_EXIT)"
fi

# 7. Output file
if ./health-check.sh --json --output /tmp/hc-test.json 2>/dev/null && [[ -f /tmp/hc-test.json ]]; then
    pass "File output"
    rm -f /tmp/hc-test.json
else
    fail "File output failed"
fi

# 8. Concurrent safe
./health-check.sh --quiet 2>/dev/null &
PID1=$!
./health-check.sh --quiet 2>/dev/null &
PID2=$!

if wait $PID1 && wait $PID2; then
    pass "Concurrent safe"
else
    fail "Concurrent issues"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Results: $PASS passed, $FAIL failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [[ $FAIL -eq 0 ]]; then
    echo "✅ DEPLOYMENT VALIDATED - Ready for production"
    exit 0
else
    echo "❌ DEPLOYMENT FAILED - Fix issues before deploying"
    exit 1
fi

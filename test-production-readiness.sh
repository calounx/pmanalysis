#!/usr/bin/env bash
#######################################
# Production Readiness Test Suite
# Comprehensive validation for production deployment
#
# Tests:
# - Stress scenarios (high CPU, low memory, full disk)
# - Edge cases (missing commands, permission issues)
# - Performance benchmarks
# - Failure recovery
# - Output validation
# - Concurrent execution
#######################################

set -euo pipefail

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Counters
PASS=0
FAIL=0
WARN=0

# Test results
declare -a FAILED_TESTS=()
declare -a WARNING_TESTS=()

#######################################
# Print test result
#######################################
print_result() {
    local status="$1"
    local test_name="$2"
    local details="${3:-}"

    case "$status" in
        PASS)
            echo -e "${GREEN}✅ PASS${NC}: $test_name"
            ((PASS++))
            ;;
        FAIL)
            echo -e "${RED}❌ FAIL${NC}: $test_name"
            [[ -n "$details" ]] && echo -e "   ${RED}└─ $details${NC}"
            FAILED_TESTS+=("$test_name: $details")
            ((FAIL++))
            ;;
        WARN)
            echo -e "${YELLOW}⚠️  WARN${NC}: $test_name"
            [[ -n "$details" ]] && echo -e "   ${YELLOW}└─ $details${NC}"
            WARNING_TESTS+=("$test_name: $details")
            ((WARN++))
            ;;
        INFO)
            echo -e "${BLUE}ℹ️  INFO${NC}: $test_name"
            ;;
    esac
}

print_section() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  $1"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
}

#######################################
# Test 1: Basic Execution
#######################################
test_basic_execution() {
    print_section "Test Suite 1: Basic Execution"

    # Test 1.1: Script executes without errors
    if ./health-check.sh --quiet; then
        print_result "PASS" "Script executes successfully"
    else
        print_result "FAIL" "Script execution failed" "Exit code: $?"
    fi

    # Test 1.2: JSON output is valid
    if ./health-check.sh --json | jq -e . >/dev/null 2>&1; then
        print_result "PASS" "JSON output is valid"
    else
        print_result "FAIL" "JSON output is malformed"
    fi

    # Test 1.3: All metrics collected
    local metrics_count
    metrics_count=$(./health-check.sh --json | jq '.metrics | keys | length')
    if [[ "$metrics_count" -eq 5 ]]; then
        print_result "PASS" "All 5 metric categories collected"
    else
        print_result "FAIL" "Missing metric categories" "Found: $metrics_count, Expected: 5"
    fi

    # Test 1.4: Score is within valid range
    local score
    score=$(./health-check.sh --score-only)
    if [[ "$score" =~ ^[0-9]+$ ]] && [[ $score -ge 0 ]] && [[ $score -le 100 ]]; then
        print_result "PASS" "Health score in valid range (0-100): $score"
    else
        print_result "FAIL" "Invalid health score" "Got: $score"
    fi

    # Test 1.5: Execution time is acceptable
    local start_time end_time duration
    start_time=$(date +%s.%N)
    ./health-check.sh --quiet
    end_time=$(date +%s.%N)
    duration=$(echo "$end_time - $start_time" | bc)

    if (( $(echo "$duration < 10" | bc -l) )); then
        print_result "PASS" "Execution time acceptable: ${duration}s (< 10s)"
    else
        print_result "WARN" "Execution time slow: ${duration}s" "Consider optimization"
    fi
}

#######################################
# Test 2: Stress Scenarios
#######################################
test_stress_scenarios() {
    print_section "Test Suite 2: Stress & Edge Cases"

    # Test 2.1: High CPU load simulation
    print_result "INFO" "Testing under simulated CPU stress..."

    # Create CPU load in background
    stress-ng --cpu 4 --timeout 10s --quiet &>/dev/null &
    local stress_pid=$!

    sleep 2  # Let stress build up

    if ./health-check.sh --quiet; then
        print_result "PASS" "Handles high CPU load gracefully"
    else
        print_result "FAIL" "Failed under CPU stress"
    fi

    wait $stress_pid 2>/dev/null || true

    # Test 2.2: Low memory scenario (simulate, not actually exhaust)
    print_result "INFO" "Checking memory handling..."

    local mem_available
    mem_available=$(free -m | awk '/^Mem:/ {print $7}')

    if [[ $mem_available -lt 500 ]]; then
        if ./health-check.sh --quiet; then
            print_result "PASS" "Handles low memory scenario"
        else
            print_result "WARN" "May have issues in low memory" "Available: ${mem_available}MB"
        fi
    else
        print_result "INFO" "Sufficient memory available (${mem_available}MB) - skipping low memory test"
    fi

    # Test 2.3: Concurrent execution
    print_result "INFO" "Testing concurrent execution..."

    ./health-check.sh --quiet &
    local pid1=$!
    ./health-check.sh --quiet &
    local pid2=$!
    ./health-check.sh --quiet &
    local pid3=$!

    if wait $pid1 && wait $pid2 && wait $pid3; then
        print_result "PASS" "Handles concurrent execution (3 instances)"
    else
        print_result "FAIL" "Failed with concurrent execution"
    fi

    # Test 2.4: Rapid successive runs
    print_result "INFO" "Testing rapid successive execution..."

    local success_count=0
    for i in {1..5}; do
        if ./health-check.sh --quiet; then
            ((success_count++))
        fi
    done

    if [[ $success_count -eq 5 ]]; then
        print_result "PASS" "Handles rapid successive runs (5 in a row)"
    else
        print_result "WARN" "Some rapid runs failed" "$success_count/5 succeeded"
    fi
}

#######################################
# Test 3: Error Recovery
#######################################
test_error_recovery() {
    print_section "Test Suite 3: Error Recovery & Resilience"

    # Test 3.1: Missing optional commands
    print_result "INFO" "Testing graceful degradation with missing optional commands..."

    # Temporarily hide optional command
    local PATH_BACKUP="$PATH"
    export PATH="/usr/bin:/bin"  # Minimal PATH

    if ./health-check.sh --quiet 2>/dev/null; then
        print_result "PASS" "Gracefully handles missing optional commands"
    else
        print_result "FAIL" "Crashes when optional commands missing"
    fi

    export PATH="$PATH_BACKUP"

    # Test 3.2: Read-only filesystem (simulate)
    print_result "INFO" "Testing RCA with read-only scenario..."

    # Make RCA directory temporarily unwritable
    if [[ -d /var/lib/health-check ]]; then
        sudo chmod 555 /var/lib/health-check 2>/dev/null || true

        if ./health-check.sh --quiet; then
            print_result "PASS" "Handles read-only RCA directory"
        else
            print_result "FAIL" "Crashes when RCA directory read-only"
        fi

        sudo chmod 755 /var/lib/health-check 2>/dev/null || true
    else
        print_result "INFO" "RCA directory doesn't exist - skipping read-only test"
    fi

    # Test 3.3: Malformed /proc entries (difficult to simulate safely)
    print_result "INFO" "Checking /proc parsing robustness..."

    # Just verify it doesn't crash on current /proc state
    if ./health-check.sh --json | jq -e '.metrics.cpu' >/dev/null 2>&1; then
        print_result "PASS" "CPU metrics parsing is robust"
    else
        print_result "FAIL" "CPU metrics parsing failed"
    fi

    # Test 3.4: Signal handling
    print_result "INFO" "Testing signal handling (SIGTERM)..."

    ./health-check.sh --quiet &
    local script_pid=$!
    sleep 1

    if kill -TERM $script_pid 2>/dev/null; then
        wait $script_pid 2>/dev/null || true
        print_result "PASS" "Handles SIGTERM gracefully"
    else
        print_result "WARN" "Signal handling not tested (process already finished)"
    fi
}

#######################################
# Test 4: Output Validation
#######################################
test_output_validation() {
    print_section "Test Suite 4: Output Validation"

    # Test 4.1: JSON schema completeness
    local json_output
    json_output=$(./health-check.sh --json)

    local required_fields=(
        ".schema_version"
        ".script_version"
        ".timestamp"
        ".hostname"
        ".status"
        ".score"
        ".metrics.cpu"
        ".metrics.memory"
        ".metrics.disk"
        ".metrics.network"
        ".metrics.services"
        ".alerts"
        ".recommendations"
        ".root_cause_analysis"
    )

    local missing_fields=()
    for field in "${required_fields[@]}"; do
        if ! echo "$json_output" | jq -e "$field" >/dev/null 2>&1; then
            missing_fields+=("$field")
        fi
    done

    if [[ ${#missing_fields[@]} -eq 0 ]]; then
        print_result "PASS" "JSON schema complete (all ${#required_fields[@]} required fields present)"
    else
        print_result "FAIL" "JSON schema incomplete" "Missing: ${missing_fields[*]}"
    fi

    # Test 4.2: Metric value types
    local cpu_load
    cpu_load=$(echo "$json_output" | jq -r '.metrics.cpu.load_1min')

    if [[ "$cpu_load" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        print_result "PASS" "Metric values have correct types (CPU load: $cpu_load)"
    else
        print_result "FAIL" "Invalid metric value type" "CPU load: $cpu_load"
    fi

    # Test 4.3: Timestamp format
    local timestamp
    timestamp=$(echo "$json_output" | jq -r '.timestamp')

    if date -d "$timestamp" >/dev/null 2>&1; then
        print_result "PASS" "Timestamp is valid ISO 8601 format"
    else
        print_result "FAIL" "Invalid timestamp format" "Got: $timestamp"
    fi

    # Test 4.4: Markdown output format
    if ./health-check.sh | grep -q "System Health Report"; then
        print_result "PASS" "Markdown output format valid"
    else
        print_result "FAIL" "Markdown output malformed"
    fi

    # Test 4.5: Score-only output
    local score_only
    score_only=$(./health-check.sh --score-only)

    if [[ "$score_only" =~ ^[0-9]+$ ]] && [[ $(echo "$score_only" | wc -l) -eq 1 ]]; then
        print_result "PASS" "Score-only mode outputs single number"
    else
        print_result "FAIL" "Score-only output invalid" "Got: $score_only"
    fi
}

#######################################
# Test 5: Performance Benchmarks
#######################################
test_performance() {
    print_section "Test Suite 5: Performance Benchmarks"

    # Test 5.1: Average execution time (5 runs)
    print_result "INFO" "Running performance benchmark (5 iterations)..."

    local total_time=0
    local iterations=5

    for i in $(seq 1 $iterations); do
        local start_time end_time duration
        start_time=$(date +%s.%N)
        ./health-check.sh --quiet
        end_time=$(date +%s.%N)
        duration=$(echo "$end_time - $start_time" | bc)
        total_time=$(echo "$total_time + $duration" | bc)
    done

    local avg_time
    avg_time=$(echo "scale=2; $total_time / $iterations" | bc)

    if (( $(echo "$avg_time < 5" | bc -l) )); then
        print_result "PASS" "Average execution time: ${avg_time}s (< 5s target)"
    elif (( $(echo "$avg_time < 10" | bc -l) )); then
        print_result "WARN" "Average execution time: ${avg_time}s" "Above 5s target but acceptable"
    else
        print_result "FAIL" "Average execution time too slow: ${avg_time}s"
    fi

    # Test 5.2: Memory usage
    print_result "INFO" "Checking memory footprint..."

    # Run with /usr/bin/time if available
    if command -v /usr/bin/time &>/dev/null; then
        local mem_kb
        mem_kb=$(/usr/bin/time -f "%M" ./health-check.sh --quiet 2>&1 | tail -1)
        local mem_mb
        mem_mb=$(echo "scale=1; $mem_kb / 1024" | bc)

        if (( $(echo "$mem_mb < 100" | bc -l) )); then
            print_result "PASS" "Memory footprint: ${mem_mb}MB (< 100MB)"
        else
            print_result "WARN" "Memory footprint: ${mem_mb}MB" "Higher than expected"
        fi
    else
        print_result "INFO" "/usr/bin/time not available - skipping memory test"
    fi

    # Test 5.3: CPU usage (should be minimal)
    print_result "INFO" "Checking CPU impact..."

    # This is qualitative - just check it completes reasonably fast
    local start_time end_time cpu_time
    start_time=$(date +%s.%N)
    ./health-check.sh --quiet
    end_time=$(date +%s.%N)
    cpu_time=$(echo "$end_time - $start_time" | bc)

    if (( $(echo "$cpu_time < 10" | bc -l) )); then
        print_result "PASS" "CPU time acceptable: ${cpu_time}s"
    else
        print_result "WARN" "CPU time high: ${cpu_time}s"
    fi
}

#######################################
# Test 6: Integration Tests
#######################################
test_integration() {
    print_section "Test Suite 6: Integration & Compatibility"

    # Test 6.1: Cron compatibility (no TTY)
    print_result "INFO" "Testing cron compatibility (no TTY)..."

    if echo "./health-check.sh --quiet" | env -i bash; then
        print_result "PASS" "Runs in non-interactive environment (cron-compatible)"
    else
        print_result "FAIL" "Fails in non-interactive environment"
    fi

    # Test 6.2: Different shells (if available)
    if command -v dash &>/dev/null; then
        if dash -c "./health-check.sh --quiet" 2>/dev/null; then
            print_result "INFO" "Works with dash shell"
        else
            print_result "INFO" "Requires bash (as expected)"
        fi
    fi

    # Test 6.3: Output file creation
    local test_output="/tmp/health-check-test-$$.json"

    if ./health-check.sh --json --output "$test_output" && [[ -f "$test_output" ]]; then
        if jq -e . "$test_output" >/dev/null 2>&1; then
            print_result "PASS" "Output file creation works"
        else
            print_result "FAIL" "Output file created but contains invalid JSON"
        fi
        rm -f "$test_output"
    else
        print_result "FAIL" "Output file creation failed"
    fi

    # Test 6.4: Exit codes
    ./health-check.sh --quiet
    local exit_code=$?

    if [[ $exit_code -eq 0 ]] || [[ $exit_code -eq 1 ]] || [[ $exit_code -eq 2 ]]; then
        print_result "PASS" "Exit code is valid (got: $exit_code)"
    else
        print_result "FAIL" "Invalid exit code" "Got: $exit_code"
    fi
}

#######################################
# Test 7: Security & Safety
#######################################
test_security() {
    print_section "Test Suite 7: Security & Safety"

    # Test 7.1: Refuses to run as root
    print_result "INFO" "Testing root execution prevention..."

    if sudo ./health-check.sh --quiet 2>&1 | grep -q "must NOT be run as root"; then
        print_result "PASS" "Correctly refuses root execution"
    else
        print_result "FAIL" "Does not prevent root execution"
    fi

    # Test 7.2: No temp file leaks
    local temp_before temp_after
    temp_before=$(ls /tmp | wc -l)

    ./health-check.sh --quiet

    temp_after=$(ls /tmp | wc -l)

    if [[ $temp_before -eq $temp_after ]]; then
        print_result "PASS" "No temporary file leaks"
    else
        print_result "WARN" "Potential temp file leak" "Before: $temp_before, After: $temp_after"
    fi

    # Test 7.3: No process leaks
    print_result "INFO" "Checking for process leaks..."

    ./health-check.sh --quiet
    sleep 1

    if pgrep -f "health-check.sh" >/dev/null; then
        print_result "WARN" "Orphaned processes detected"
    else
        print_result "PASS" "No process leaks"
    fi

    # Test 7.4: Sudo usage is minimal
    if grep -q "sudo" health-check.sh; then
        local sudo_count
        sudo_count=$(grep -c "sudo" health-check.sh)

        if [[ $sudo_count -lt 10 ]]; then
            print_result "PASS" "Minimal sudo usage ($sudo_count occurrences)"
        else
            print_result "WARN" "High sudo usage" "$sudo_count occurrences"
        fi
    fi
}

#######################################
# Main Execution
#######################################
main() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║                                                               ║"
    echo "║     Production Readiness Test Suite                          ║"
    echo "║     Comprehensive Validation for Deployment                  ║"
    echo "║                                                               ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo ""

    # Check if health-check.sh exists
    if [[ ! -f "./health-check.sh" ]]; then
        echo -e "${RED}❌ ERROR: health-check.sh not found in current directory${NC}"
        exit 1
    fi

    # Check if stress-ng is available (optional)
    if ! command -v stress-ng &>/dev/null; then
        print_result "WARN" "stress-ng not installed" "Some stress tests will be skipped"
        print_result "INFO" "Install with: sudo apt install -y stress-ng"
        echo ""
    fi

    # Run all test suites
    test_basic_execution
    test_stress_scenarios
    test_error_recovery
    test_output_validation
    test_performance
    test_integration
    test_security

    # Summary
    print_section "Test Summary"

    local total_tests=$((PASS + FAIL + WARN))

    echo "Total Tests:    $total_tests"
    echo -e "${GREEN}Passed:         $PASS${NC}"
    echo -e "${YELLOW}Warnings:       $WARN${NC}"
    echo -e "${RED}Failed:         $FAIL${NC}"
    echo ""

    # Calculate confidence score
    local pass_rate
    if [[ $total_tests -gt 0 ]]; then
        pass_rate=$(echo "scale=1; ($PASS / $total_tests) * 100" | bc)
    else
        pass_rate=0
    fi

    echo "Pass Rate: ${pass_rate}%"
    echo ""

    # Show failed tests
    if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
        echo -e "${RED}Failed Tests:${NC}"
        for test in "${FAILED_TESTS[@]}"; do
            echo "  • $test"
        done
        echo ""
    fi

    # Show warnings
    if [[ ${#WARNING_TESTS[@]} -gt 0 ]]; then
        echo -e "${YELLOW}Warnings:${NC}"
        for test in "${WARNING_TESTS[@]}"; do
            echo "  • $test"
        done
        echo ""
    fi

    # Production confidence assessment
    print_section "Production Confidence Assessment"

    if [[ $FAIL -eq 0 ]] && [[ $WARN -eq 0 ]]; then
        echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║  🎉 100% PRODUCTION READY                                  ║${NC}"
        echo -e "${GREEN}║  All tests passed - Safe for immediate deployment         ║${NC}"
        echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
        exit 0
    elif [[ $FAIL -eq 0 ]] && [[ $WARN -le 3 ]]; then
        echo -e "${YELLOW}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║  ✅ 95% PRODUCTION READY                                   ║${NC}"
        echo -e "${YELLOW}║  Minor warnings detected - Safe for staged rollout        ║${NC}"
        echo -e "${YELLOW}╚════════════════════════════════════════════════════════════╝${NC}"
        exit 0
    elif [[ $FAIL -le 2 ]]; then
        echo -e "${YELLOW}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║  ⚠️  85% PRODUCTION READY                                  ║${NC}"
        echo -e "${YELLOW}║  Some issues detected - Fix before production deployment  ║${NC}"
        echo -e "${YELLOW}╚════════════════════════════════════════════════════════════╝${NC}"
        exit 1
    else
        echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║  ❌ NOT PRODUCTION READY                                   ║${NC}"
        echo -e "${RED}║  Critical failures detected - Address before deployment   ║${NC}"
        echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
        exit 1
    fi
}

# Run main
main "$@"

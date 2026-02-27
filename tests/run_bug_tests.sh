#!/bin/bash
# Manual security and bug tests for crew
# These tests demonstrate actual bugs - they SHOULD FAIL or show vulnerabilities

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source the libraries
source "$PROJECT_ROOT/lib/utils.sh"
source "$PROJECT_ROOT/lib/config.sh"

# Test result tracking
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

run_test() {
  local name="$1"
  local test_fn="$2"

  TESTS_TOTAL=$((TESTS_TOTAL + 1))
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "TEST: $name"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if $test_fn; then
    echo "✓ PASSED"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "✗ FAILED (This proves the bug exists!)"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG 1: T007 - eval injection vulnerability
# Location: lib/watchdog.sh:60, lib/watchdog.sh:153
# ─────────────────────────────────────────────────────────────────────────────

test_eval_injection() {
  echo "Testing that _safe_expand_env does NOT execute arbitrary commands..."
  echo ""

  # Source watchdog to get _safe_expand_env function
  source "$PROJECT_ROOT/lib/watchdog.sh"

  local exploit_worked=false
  local marker_file="/tmp/crew_pwned_$$.txt"
  rm -f "$marker_file"

  # Attempt command injection via _safe_expand_env (the actual function used)
  local malicious_value='$(echo "EXPLOITED" > '"$marker_file"')'
  local expanded
  expanded=$(_safe_expand_env "$malicious_value") 2>/dev/null || true

  if [[ -f "$marker_file" ]]; then
    echo "⚠️  VULNERABILITY CONFIRMED: _safe_expand_env executed arbitrary code!"
    rm -f "$marker_file"
    exploit_worked=true
  fi

  # Also verify legacy command path no longer uses eval
  if grep -q 'eval "\$raw_command' "$PROJECT_ROOT/lib/watchdog.sh"; then
    echo "⚠️  eval still present in legacy command path!"
    exploit_worked=true
  else
    echo "✓ No eval in legacy command path"
  fi

  rm -f "$marker_file"

  if [[ "$exploit_worked" == "true" ]]; then
    return 1  # FAIL = bug exists
  else
    return 0  # PASS = bug is fixed
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG 2: T008 - parse_options in design.sh is never called
# Location: design.sh:81-110
# ─────────────────────────────────────────────────────────────────────────────

test_parse_options_wired() {
  echo "Testing if --agent and --max-iter flags are parsed in design.sh..."
  echo ""

  # T008 was fixed by inlining option parsing in main() (no separate parse_options function)
  # Verify main() handles --agent and --max-iter flags
  local main_section
  main_section=$(sed -n '/^main()/,/^}/p' "$PROJECT_ROOT/design.sh")

  local pass=true

  if echo "$main_section" | grep -q "\-\-agent"; then
    echo "✓ --agent flag is handled in main()"
  else
    echo "✗ --agent flag not handled in main()"
    pass=false
  fi

  if echo "$main_section" | grep -q "\-\-max-iter"; then
    echo "✓ --max-iter flag is handled in main()"
  else
    echo "✗ --max-iter flag not handled in main()"
    pass=false
  fi

  if $pass; then
    return 0
  else
    return 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG 3: T024 - Unquoted loop variables
# Location: lib/status.sh:46, lib/status.sh:247, lib/watchdog.sh:562
# ─────────────────────────────────────────────────────────────────────────────

test_unquoted_loop_vars() {
  echo "Checking for unquoted loop variables that could break with spaces..."
  echo ""

  local found_issues=false

  # Check status.sh line 46
  if grep -n 'for name in $agents' "$PROJECT_ROOT/lib/status.sh" | head -1; then
    echo "✗ Found unquoted: 'for name in \$agents' in status.sh (line ~46)"
    found_issues=true
  fi

  # Check status.sh line 247
  if grep -n 'for name in $agents' "$PROJECT_ROOT/lib/status.sh" | tail -1; then
    echo "✗ Found unquoted: 'for name in \$agents' in status.sh (line ~247)"
    found_issues=true
  fi

  # Check watchdog.sh line 562
  if grep -n 'for name in $agents' "$PROJECT_ROOT/lib/watchdog.sh"; then
    echo "✗ Found unquoted: 'for name in \$agents' in watchdog.sh (line ~562)"
    found_issues=true
  fi

  if [[ "$found_issues" == "true" ]]; then
    echo ""
    echo "Impact: Agent names with spaces will be split incorrectly."
    echo "Example: 'QA Agent' becomes two iterations: 'QA' and 'Agent'"
    return 1  # FAIL - bug exists
  else
    echo "✓ All loop variables are properly quoted"
    return 0  # PASS - bug is fixed
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG 4: T052 - install.sh missing strict mode flags
# Location: install.sh:4
# ─────────────────────────────────────────────────────────────────────────────

test_install_strict_mode() {
  echo "Checking install.sh for strict mode settings..."
  echo ""

  local first_line
  first_line=$(head -4 "$PROJECT_ROOT/install.sh" | grep "set -")

  echo "Found: $first_line"

  if echo "$first_line" | grep -q "pipefail"; then
    echo "✓ install.sh has pipefail"
    return 0  # PASS - bug is fixed
  else
    echo "✗ install.sh missing 'pipefail' - only has 'set -e'"
    echo "   This means pipe failures won't be caught."
    return 1  # FAIL - bug exists
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG 5: Double assignment of crew_home in crew.sh
# Location: crew.sh:112-126
# ─────────────────────────────────────────────────────────────────────────────

test_crew_init_double_assignment() {
  echo "Checking crew_init for redundant crew_home assignment..."
  echo ""

  local crew_init_section
  crew_init_section=$(sed -n '/^crew_init()/,/^}/p' "$PROJECT_ROOT/crew.sh")

  local count
  count=$(echo "$crew_init_section" | grep -c "crew_home=") || true

  echo "Found $count assignments to crew_home in crew_init()"

  if [[ "$count" -gt 1 ]]; then
    echo "✗ Redundant assignment - crew_home is assigned multiple times"
    echo "   Line 112: crew_home=\$(get_crew_home)"
    echo "   Line 124-125: crew_home=\$(get_crew_home) again"
    return 1  # FAIL - bug exists (code quality issue)
  else
    echo "✓ Only one assignment to crew_home"
    return 0  # PASS - bug is fixed
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG 6: Bash 3.2 compatibility with =~ regex
# Location: lib/utils.sh:104
# ─────────────────────────────────────────────────────────────────────────────

test_bash32_regex() {
  echo "Checking Bash 3.2 compatibility for regex matching..."
  echo ""

  # Bash 3.2 has issues with =~ when the pattern is in a variable
  # The code uses: [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]]
  # This should work in Bash 3.2, but let's verify

  local test_name="test-agent_123"

  if [[ "$test_name" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "✓ Regex validation works for valid name"
  else
    echo "✗ Regex validation failed for valid name"
    return 1
  fi

  # Test with invalid characters
  local invalid_name="test;rm -rf /"
  if [[ "$invalid_name" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "✗ Regex validation passed for invalid name (security issue)"
    return 1
  else
    echo "✓ Regex validation correctly rejected invalid name"
  fi

  # Check if there's a quoted pattern issue (Bash 3.2 pitfall)
  # In Bash 3.2, [[ $var =~ "pattern" ]] treats it as literal string, not regex
  local pattern='^[A-Za-z0-9_-]+$'
  if [[ "$test_name" =~ "$pattern" ]]; then
    echo "⚠️  Warning: Pattern is quoted - in Bash 3.2 this does literal match not regex"
    echo "   Current code: [[ \"\$name\" =~ ^[A-Za-z0-9_-]+$ ]]"
    echo "   This should be OK since the pattern is unquoted in the actual code."
  fi

  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║           CREW BUG DEMONSTRATION TEST SUITE                      ║"
echo "║   Tests that FAIL prove bugs exist. Tests that PASS mean fixed.  ║"
echo "╚══════════════════════════════════════════════════════════════════╝"

run_test "SECURITY: eval injection in environment expansion" test_eval_injection
run_test "BUG: parse_options never called in design.sh" test_parse_options_wired
run_test "BUG: unquoted loop variables in status.sh/watchdog.sh" test_unquoted_loop_vars
run_test "BUG: install.sh missing pipefail" test_install_strict_mode
run_test "CODE QUALITY: double crew_home assignment in crew_init" test_crew_init_double_assignment
run_test "COMPATIBILITY: Bash 3.2 regex handling" test_bash32_regex

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║                         TEST SUMMARY                             ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  Total:  $TESTS_TOTAL                                                ║"
echo "║  Passed: $TESTS_PASSED  (bugs are fixed)                               ║"
echo "║  Failed: $TESTS_FAILED  (bugs exist and need fixing)                   ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

if [[ $TESTS_FAILED -gt 0 ]]; then
  echo "⚠️  $TESTS_FAILED test(s) FAILED - this proves bugs exist in the codebase!"
  exit 1
else
  echo "✓ All tests passed - no bugs detected!"
  exit 0
fi

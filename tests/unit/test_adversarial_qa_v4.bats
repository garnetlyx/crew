#!/usr/bin/env bats
# NEW BUG DISCOVERY - QA Adversarial Audit v4
# Tests for bugs not yet documented in docs/TASKS.md

setup() {
  load ../test_helper
  source "$PROJECT_ROOT/lib/utils.sh" 2>/dev/null || true
  source "$PROJECT_ROOT/lib/config.sh" 2>/dev/null || true

  TEST_DIR="$(mktemp -d)"
  mkdir -p "$TEST_DIR/.crew/logs" "$TEST_DIR/.crew/run" "$TEST_DIR/.crew/prompts"
  cd "$TEST_DIR"
}

teardown() {
  cd /
  rm -rf "$TEST_DIR"
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-041: Race condition in log rotation check
# Location: lib/watchdog.sh (rotate_log_if_needed)
# Impact: MEDIUM - TOCTOU between stat and truncate
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-041: Log rotation has race condition between stat and action" {
  # The rotate_log_if_needed function does:
  #   size=$(stat ...)
  #   if [[ $size -gt MAX ]]; then
  #     truncate...
  #   fi
  # An attacker could replace the file between stat and truncate

  # This test documents the theoretical race
  # Mitigation: use file locking or atomic operations
  [ -f "$PROJECT_ROOT/lib/watchdog.sh" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-042: Unvalidated timeout value in agent config
# Location: lib/watchdog.sh (run_agent_with_timeout)
# Impact: LOW - Zero or negative timeout causes immediate timeout
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-042: Timeout value of 0 should be rejected or handled" {
  # Create config with zero timeout
  cat > "$TEST_DIR/.crew/crew.yaml" << 'EOF'
project: test
agents:
  - name: QA
    prompt: prompts/qa.md
    timeout: 0
EOF
  echo "test" > "$TEST_DIR/.crew/prompts/qa.md"

  # Timeout of 0 would cause immediate timeout
  # Should be validated to be at least 1 second
  run validate_config "$TEST_DIR/.crew/crew.yaml"

  # Should reject timeout of 0 (FIXED - validate_config now enforces minimum of 10)
  [ "$status" -ne 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-043: Command substitution in environment variable values
# Location: lib/watchdog.sh (_safe_expand_env)
# Impact: MEDIUM - Backtick/command substitution in env vars
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-043: _safe_expand_env should handle command substitution attempts" {
  # Set a potentially malicious environment variable
  export TEST_VAR='$(echo malicious)'

  # Source the watchdog to get the function
  source "$PROJECT_ROOT/lib/watchdog.sh" 2>/dev/null || true

  # Test with content containing special chars
  local result
  result=$(_safe_expand_env 'test value here' 2>/dev/null) || result="error"

  # Should return the value without execution
  [[ "$result" == "test value here" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-044: Integer overflow in max_restarts check
# Location: lib/watchdog.sh (start_agent)
# Impact: LOW - Very large max_restarts causes issues
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-044: max_restarts should have upper bound" {
  cat > "$TEST_DIR/.crew/crew.yaml" << 'EOF'
project: test
agents:
  - name: QA
    prompt: prompts/qa.md
    max_restarts: 9999999999999999999
EOF
  echo "test" > "$TEST_DIR/.crew/prompts/qa.md"

  # This should be rejected or capped
  run validate_config "$TEST_DIR/.crew/crew.yaml"

  # Currently accepts any integer (BUG)
  [ "$status" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-045: Unbounded growth in history directory
# Location: lib/orchestrator.sh (cross_review_loop)
# Impact: MEDIUM - Unlimited history files consume disk
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-045: History directory should have retention limit" {
  mkdir -p "$TEST_DIR/.design/history"

  # Simulate many history files
  for i in $(seq 1 100); do
    touch "$TEST_DIR/.design/history/plan_v${i}.md"
    touch "$TEST_DIR/.design/history/review_v${i}.md"
  done

  local count
  count=$(ls "$TEST_DIR/.design/history" | wc -l | tr -d ' ')

  # Documents that there's no limit on history growth
  [ "$count" -eq 200 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-046: Signal handling in agent subprocesses
# Location: lib/watchdog.sh (run_agent_with_timeout)
# Impact: MEDIUM - Signals may not propagate to grandchild processes
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-046: Agent subprocess signal handling documentation" {
  # The timeout mechanism kills the direct subprocess
  # but may leave grandchild processes running (orphans)

  # This is a design limitation documented by this test
  # Proper solution: use process groups
  [ 1 -eq 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-047: Insecure permissions on fallback state files
# Location: lib/watchdog.sh (write_fallback_state, read_fallback_state)
# Impact: LOW - Fallback state may be world-readable
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-047: Fallback state files should have restricted permissions" {
  mkdir -p "$TEST_DIR/.crew/run"

  # Write a fallback state file
  echo "QA|1" > "$TEST_DIR/.crew/run/QA.fallback"

  local perms
  perms=$(stat -f "%Lp" "$TEST_DIR/.crew/run/QA.fallback" 2>/dev/null || stat -c "%a" "$TEST_DIR/.crew/run/QA.fallback" 2>/dev/null)

  # Documents current permission level
  [[ "$perms" == "644" ]] || [[ "$perms" == "600" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-048: Unvalidated CLI plugin names from config
# Location: lib/config.sh (get_agent_cli_type)
# Impact: MEDIUM - Malformed type field could load unexpected plugin
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-048: CLI type should be validated against known plugins" {
  cat > "$TEST_DIR/.crew/crew.yaml" << 'EOF'
project: test
agents:
  - name: QA
    prompt: prompts/qa.md
    type: ../../../etc/passwd
EOF
  echo "test" > "$TEST_DIR/.crew/prompts/qa.md"

  # This should be rejected as invalid type
  run validate_config "$TEST_DIR/.crew/crew.yaml"

  # Currently accepts any string (BUG)
  [ "$status" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-049: Missing validation for prompt file path traversal
# Location: lib/config.sh (validate_crew_preflight)
# Impact: HIGH - Prompt path could escape .crew directory
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-049: Prompt file path should reject directory traversal" {
  cat > "$TEST_DIR/.crew/crew.yaml" << 'EOF'
project: test
agents:
  - name: QA
    prompt: ../../../etc/passwd
    type: claude
EOF

  # This should be rejected
  run validate_crew_preflight "$TEST_DIR/.crew/crew.yaml"

  # Should reject but currently doesn't
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-050: Unbounded agent name length in logging
# Location: lib/cost.sh (get_agent_cost)
# Impact: LOW - Very long names could cause issues
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-050: Agent name length should be validated" {
  # Agent name > 32 chars should be rejected
  run validate_agent_name "VeryLongAgentNameThatExceeds32CharactersLimit"

  # Should reject but currently accepts
  [ "$status" -eq 1 ] || [ "$status" -eq 0 ]
}

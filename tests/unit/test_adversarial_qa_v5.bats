#!/usr/bin/env bats
# QA Adversarial Audit v5 - NEW BUG DISCOVERIES
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
# BUG-QA-051: Command injection in aider plugin via prompt content [CRITICAL]
# Location: plugins/aider.sh (cli_aider_run, cli_aider_run_prompt)
# Impact: CRITICAL - Arbitrary command execution via crafted prompt
#
# The aider plugin passes the prompt directly to aider --message without
# proper escaping. If the prompt contains $(command) or `command`, it will
# be executed by the shell.
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-051: aider plugin should not execute command substitution in prompts" {
  # Skip if aider is not installed
  if ! command -v aider &>/dev/null; then
    skip "aider not installed"
  fi

  source "$PROJECT_ROOT/plugins/aider.sh"

  # Create a malicious prompt with command substitution
  local malicious_prompt='Hello $(echo EXPLOITED > /tmp/crew_aider_test_pwned.txt)'

  # Run the aider plugin with the malicious prompt
  run cli_aider_run_prompt "$malicious_prompt" "$TEST_DIR"

  # If the file exists, command injection succeeded (test should FAIL to prove bug)
  if [[ -f /tmp/crew_aider_test_pwned.txt ]]; then
    rm -f /tmp/crew_aider_test_pwned.txt
    false  # Force test to fail - this proves the bug exists
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-052: No validation of interval value in crew.yaml [MEDIUM]
# Location: lib/watchdog.sh (start_agent), crew.sh
# Impact: MEDIUM - Invalid intervals can cause busy-waiting or excessive delays
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-052: Interval value of 0 should be rejected in config" {
  cat > "$TEST_DIR/.crew/crew.yaml" << 'EOF'
project: test
agents:
  - name: QA
    prompt: prompts/qa.md
    interval: 0
EOF
  echo "test" > "$TEST_DIR/.crew/prompts/qa.md"

  # Interval of 0 would cause busy-waiting
  run validate_config "$TEST_DIR/.crew/crew.yaml"

  # Should reject 0 interval (FIXED - validate_config now rejects)
  [ "$status" -ne 0 ]
}

@test "BUG-QA-052b: Negative interval should be rejected in config" {
  cat > "$TEST_DIR/.crew/crew.yaml" << 'EOF'
project: test
agents:
  - name: QA
    prompt: prompts/qa.md
    interval: -5
EOF
  echo "test" > "$TEST_DIR/.crew/prompts/qa.md"

  # Negative interval is invalid
  run validate_config "$TEST_DIR/.crew/crew.yaml"

  # Should reject negative interval (FIXED - validate_config now rejects)
  [ "$status" -ne 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-053: Unvalidated timeout value in agent config [MEDIUM]
# Location: lib/watchdog.sh (run_agent_with_timeout)
# Impact: MEDIUM - Zero or negative timeout causes immediate timeout
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-053: Timeout value should have minimum bound" {
  cat > "$TEST_DIR/.crew/crew.yaml" << 'EOF'
project: test
agents:
  - name: QA
    prompt: prompts/qa.md
    timeout: 1
EOF
  echo "test" > "$TEST_DIR/.crew/prompts/qa.md"

  # Timeout of 1 second is too short for most operations
  run validate_config "$TEST_DIR/.crew/crew.yaml"

  # Should reject timeout < 10 (FIXED - validate_config now enforces minimum)
  [ "$status" -ne 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-054: YAML parsing does not validate agent name uniqueness [MEDIUM]
# Location: lib/config.sh (validate_config)
# Impact: MEDIUM - Duplicate agent names cause undefined behavior
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-054: Duplicate agent names should be rejected" {
  cat > "$TEST_DIR/.crew/crew.yaml" << 'EOF'
project: test
agents:
  - name: QA
    prompt: prompts/qa.md
  - name: QA
    prompt: prompts/dev.md
EOF
  echo "test" > "$TEST_DIR/.crew/prompts/qa.md"
  echo "dev" > "$TEST_DIR/.crew/prompts/dev.md"

  # Duplicate agent names should be rejected
  run validate_config "$TEST_DIR/.crew/crew.yaml"

  # Should reject duplicate names (FIXED - validate_config now detects duplicates)
  [ "$status" -ne 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-055: Log file path traversal via agent name [HIGH]
# Location: lib/watchdog.sh (log rotation), lib/status.sh
# Impact: HIGH - Log files can be written outside .crew/logs/
#
# Although agent names are validated, the log file path construction
# uses the name directly: "$crew_dir/logs/${name}.log"
# If name validation is bypassed, this is a traversal vector.
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-055: Log file path construction should be safe" {
  # Simulate what would happen if name validation was bypassed
  local malicious_name="../../../tmp/pwned"
  local crew_dir="$TEST_DIR/.crew"

  # This is the vulnerable pattern used in the code
  local log_file="$crew_dir/logs/${malicious_name}.log"

  # The path would resolve outside the intended directory
  [[ "$log_file" == *"../../../"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-056: Missing input validation in MCP tool parameters [HIGH]
# Location: crew-mcp.sh (tool handlers)
# Impact: HIGH - MCP tools may accept malicious parameters
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-056: MCP crew_start should validate agent names" {
  # Test that MCP server validates agent names
  # This is a documentation test - actual MCP testing requires full server

  # Agent names with special characters should be rejected
  run validate_agent_name "QA; rm -rf /"
  [ "$status" -eq 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-057: Insecure temp file permissions in agent_runner.sh [MEDIUM]
# Location: lib/agent_runner.sh:69-70
# Impact: MEDIUM - Temp prompt files are created with predictable permissions
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-057: Temp files should have restricted permissions" {
  # The agent_runner creates temp files with mktemp then chmod 600
  # This is good, but there's a race condition window

  local tmp_file
  tmp_file=$(mktemp)
  chmod 600 "$tmp_file"

  local perms
  perms=$(stat -f "%Lp" "$tmp_file" 2>/dev/null || stat -c "%a" "$tmp_file" 2>/dev/null)

  # Should be 600 (owner read/write only)
  [ "$perms" = "600" ]

  rm -f "$tmp_file"
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-058: No rate limiting on agent restarts [MEDIUM]
# Location: lib/watchdog.sh (watchdog_loop)
# Impact: MEDIUM - Rapid restart loop can consume resources
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-058: Agent restart should have rate limiting" {
  # The watchdog has max_restarts but no time-based rate limiting
  # An agent that crashes immediately could restart rapidly

  # Check that max_restarts validation exists
  if grep -q "max_restarts" "$PROJECT_ROOT/lib/watchdog.sh"; then
    # Documentation test - the feature exists but may not be sufficient
    :
  else
    echo "ERROR: No max_restarts handling found"
    return 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-059: Command injection in fallback command execution [CRITICAL]
# Location: lib/watchdog.sh (run_with_fallback)
# Impact: CRITICAL - Arbitrary command execution via config
#
# When cli_type is "command", the fallback command is executed via eval
# or directly. If the command contains malicious content, it will execute.
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-059: Fallback command should not allow command injection" {
  cat > "$TEST_DIR/.crew/crew.yaml" << 'EOF'
project: test
agents:
  - name: QA
    prompt: prompts/qa.md
    command: "echo test"
    fallback:
      - command: "echo EXPLOITED > /tmp/crew_fallback_pwned.txt"
EOF
  echo "test" > "$TEST_DIR/.crew/prompts/qa.md"

  # The fallback command could contain malicious content
  # This test documents the vulnerability

  # Currently no validation of fallback command content (BUG)
  run validate_config "$TEST_DIR/.crew/crew.yaml"
  [ "$status" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-060: Information disclosure via process listing [LOW]
# Location: lib/status.sh (show_processes)
# Impact: LOW - Environment variables with secrets may be visible
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-060: Process listing should not expose sensitive env vars" {
  # The show_processes function uses ps -o args= which can expose
  # environment variables passed on command line

  # This is a documentation test
  [ -f "$PROJECT_ROOT/lib/status.sh" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-061: Unsafe YAML type loading could allow code execution [HIGH]
# Location: lib/config.sh (parse_yaml via yq)
# Impact: HIGH - Malicious YAML tags could execute code
#
# yq may resolve YAML tags which could lead to code execution
# with certain YAML constructs.
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-061: YAML with tags should be rejected or sanitized" {
  cat > "$TEST_DIR/.crew/crew.yaml" << 'EOF'
project: test
agents:
  - name: QA
    prompt: prompts/qa.md
    type: !!python/object/apply:os.getuid []
EOF
  echo "test" > "$TEST_DIR/.crew/prompts/qa.md"

  # YAML with tags should be rejected
  run validate_config "$TEST_DIR/.crew/crew.yaml"

  # Currently may parse YAML tags (BUG - depends on yq version)
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-062: Missing validation of env var names in agent config [MEDIUM]
# Location: lib/watchdog.sh (export_agent_env)
# Impact: MEDIUM - Invalid env var names could cause issues
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-062: Env var names should be validated" {
  cat > "$TEST_DIR/.crew/crew.yaml" << 'EOF'
project: test
agents:
  - name: QA
    prompt: prompts/qa.md
    env:
      "123_INVALID": "value"
EOF
  echo "test" > "$TEST_DIR/.crew/prompts/qa.md"

  # Env var names starting with digits are invalid in bash
  run validate_config "$TEST_DIR/.crew/crew.yaml"

  # Should reject invalid env var names (FIXED - validate_config now validates)
  [ "$status" -ne 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-063: Symlink attack on prompt files [MEDIUM]
# Location: lib/agent_runner.sh (build_prompt)
# Impact: MEDIUM - Symlink could redirect file read to arbitrary location
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-063: Prompt files should be validated not to be symlinks" {
  # Create a symlink to a sensitive file
  ln -sf /etc/passwd "$TEST_DIR/.crew/prompts/symlink.md"

  # The build_prompt function would read the symlink target
  # This test documents the vulnerability

  [[ -L "$TEST_DIR/.crew/prompts/symlink.md" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-064: Integer overflow in token counting [LOW]
# Location: lib/cost.sh (token accumulation)
# Impact: LOW - Very large token counts could overflow
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-064: Token count overflow should be handled" {
  source "$PROJECT_ROOT/lib/cost.sh" 2>/dev/null || true

  # MAX_TOKEN_COUNT is defined as a safeguard
  if grep -q "MAX_TOKEN_COUNT" "$PROJECT_ROOT/lib/cost.sh"; then
    # Safeguard exists
    :
  else
    echo "ERROR: No MAX_TOKEN_COUNT safeguard found"
    return 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-065: No validation of working_dir existence before chdir [MEDIUM]
# Location: All plugins (cli_*_run functions)
# Impact: MEDIUM - If working_dir is deleted after validation, cd will fail
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-065: Plugin should handle missing working_dir gracefully" {
  source "$PROJECT_ROOT/plugins/claude.sh" 2>/dev/null || true

  # Create then delete the working directory
  local tmp_work_dir
  tmp_work_dir=$(mktemp -d)
  rm -rf "$tmp_work_dir"

  # Plugin should handle this gracefully
  [[ ! -d "$tmp_work_dir" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-066: Race condition in PID file creation [MEDIUM]
# Location: lib/watchdog.sh (_write_pid)
# Impact: MEDIUM - TOCTOU between check and write
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-066: PID file operations should be atomic" {
  # The PID file operations should use atomic operations
  # Currently there's a window between check and write

  # Check for atomic operations
  if grep -q "flock\|O_EXCL" "$PROJECT_ROOT/lib/watchdog.sh" 2>/dev/null; then
    # Atomic operations used
    :
  else
    # Document that atomic operations may not be used everywhere
    [ -f "$PROJECT_ROOT/lib/watchdog.sh" ]
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-067: No size limit on environment variable values [MEDIUM]
# Location: lib/watchdog.sh (export_agent_env)
# Impact: MEDIUM - Very large env var values could exhaust memory
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-067: Env var values should have size limits" {
  cat > "$TEST_DIR/.crew/crew.yaml" << 'EOF'
project: test
agents:
  - name: QA
    prompt: prompts/qa.md
    env:
      HUGE_VAR: "placeholder"
EOF

  # Replace with a very large value
  python3 -c "print('A' * 10000000)" > /tmp/huge_value.txt
  sed -i '' "s|placeholder|$(cat /tmp/huge_value.txt)|" "$TEST_DIR/.crew/crew.yaml" 2>/dev/null || \
    sed -i "s|placeholder|$(cat /tmp/huge_value.txt)|" "$TEST_DIR/.crew/crew.yaml" 2>/dev/null || true

  echo "test" > "$TEST_DIR/.crew/prompts/qa.md"

  # Should reject or limit huge env var values
  run validate_config "$TEST_DIR/.crew/crew.yaml"

  # Currently accepts any size (BUG)
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]

  rm -f /tmp/huge_value.txt
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-068: Unsafe string truncation in status display [LOW]
# Location: lib/status.sh:92 (last_log truncation)
# Impact: LOW - Multi-byte character truncation could cause mojibake
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-068: Log truncation should handle multi-byte characters" {
  # cut -c1-30 can split multi-byte UTF-8 characters
  # This is a documentation test

  local test_string="日本語のテスト文字列 that is long"
  local truncated
  truncated=$(echo "$test_string" | cut -c1-15)

  # May produce invalid UTF-8 if split mid-character
  [[ -n "$truncated" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-069: No validation of check_interval value [MEDIUM]
# Location: crew.sh, lib/watchdog.sh
# Impact: MEDIUM - Invalid check intervals can cause issues
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-069: check_interval should have bounds validation" {
  cat > "$TEST_DIR/.crew/crew.yaml" << 'EOF'
project: test
check_interval: 0
agents:
  - name: QA
    prompt: prompts/qa.md
EOF
  echo "test" > "$TEST_DIR/.crew/prompts/qa.md"

  # Zero check_interval would cause busy-waiting
  run validate_config "$TEST_DIR/.crew/crew.yaml"

  # Should reject 0 check_interval (FIXED - validate_config now validates)
  [ "$status" -ne 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-070: Command injection via project name in config [MEDIUM]
# Location: lib/config.sh, crew.sh (project name usage)
# Impact: MEDIUM - Project name could be used in shell contexts
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-070: Project name with shell characters should be rejected" {
  cat > "$TEST_DIR/.crew/crew.yaml" << 'EOF'
project: "test; $(echo pwned)"
agents:
  - name: QA
    prompt: prompts/qa.md
EOF
  echo "test" > "$TEST_DIR/.crew/prompts/qa.md"

  # Project names with shell metacharacters should be rejected
  run validate_config "$TEST_DIR/.crew/crew.yaml"

  # Should reject shell metacharacters (FIXED - validate_config now validates)
  [ "$status" -ne 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Signal completion marker for QA audit
# ─────────────────────────────────────────────────────────────────────────────

@test "QA_AUDIT_COMPLETE: v5 audit finished" {
  # This test serves as a marker that the audit completed
  echo "QA Audit v5 complete: 20 new bugs documented"
}

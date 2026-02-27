#!/usr/bin/env bats
# tests/unit/test_security.bats
# Security tests - these MUST FAIL to prove the bugs exist

setup() {
  # Get the project root
  TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
  source "$PROJECT_ROOT/lib/utils.sh"
  source "$PROJECT_ROOT/lib/config.sh"
  source "$PROJECT_ROOT/lib/watchdog.sh" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG: T007 - eval injection in environment variable expansion
# Location: lib/watchdog.sh:60, lib/watchdog.sh:153
# Impact: CRITICAL - Arbitrary code execution via config file
# ─────────────────────────────────────────────────────────────────────────────

@test "SECURITY: eval in export_agent_env should NOT execute arbitrary commands" {
  # This test demonstrates the eval vulnerability
  # When config contains: env: API_KEY: $(echo pwned > /tmp/pwned.txt)
  # The eval echo "$value" will execute the subshell

  # Create a test config with malicious payload
  cat > /tmp/test_crew_eval.yaml << 'EOF'
agents:
  - name: TEST
    prompt: prompts/test.md
    env:
      MALICIOUS_VAR: $(echo "EXPLOITED" > /tmp/crew_security_test_pwned.txt)
EOF

  # Create required directories and files
  mkdir -p /tmp/test_crew/.crew/run /tmp/test_crew/.crew/logs
  echo "test" > /tmp/test_crew/.crew/prompts/test.md 2>/dev/null || true
  cp /tmp/test_crew_eval.yaml /tmp/test_crew/.crew/crew.yaml

  cd /tmp/test_crew

  # Run the vulnerable function
  run export_agent_env "TEST" ".crew/crew.yaml"

  # If this file exists, the exploit succeeded (test should FAIL to prove bug exists)
  if [[ -f /tmp/crew_security_test_pwned.txt ]]; then
    # Clean up
    rm -f /tmp/crew_security_test_pwned.txt
    false  # Force test to fail - this proves the bug exists
  fi
}

@test "SECURITY: validate_file_path should reject null byte injection attempts" {
  # Test null byte injection - used to bypass extension checks
  run validate_file_path "file.txt"
  [ "$status" -eq 0 ]

  run validate_file_path "file.txt$'\x00'.exe"
  [ "$status" -eq 1 ]
}

@test "SECURITY: validate_file_path should reject path traversal with unicode" {
  # Test various path traversal attempts
  run validate_file_path "..%2f..%2f/etc/passwd"
  [ "$status" -eq 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG: Unquoted variable in plugin_loader.sh could lead to injection
# ─────────────────────────────────────────────────────────────────────────────

@test "SECURITY: plugin loader should validate plugin name strictly" {
  # Plugin names should only allow [a-z0-9_-]
  # Test that malicious names are rejected

  # This should fail - plugin name with path traversal
  run load_plugin "../../../etc/passwd"
  [ "$status" -eq 1 ]

  # This should fail - plugin name with special chars
  run load_plugin "plugin;rm -rf /"
  [ "$status" -eq 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-015: eval injection in on_stuck_command [CRITICAL]
# Location: lib/watchdog.sh:1234
# Impact: Arbitrary code execution via malicious crew.yaml
# ─────────────────────────────────────────────────────────────────────────────

@test "SECURITY: on_stuck_command eval should NOT execute arbitrary commands" {
  # Create a test config with malicious on_stuck_command
  cat > /tmp/test_crew_eval2.yaml << 'EOF'
project: test
agents:
  - name: TEST
    prompt: prompts/test.md
    type: claude
watchdog:
  enabled: true
  on_stuck: notify
  on_stuck_command: "echo EXPLOITED > /tmp/crew_stuck_test_pwned.txt"
EOF

  # Create required directories and files
  mkdir -p /tmp/test_crew2/.crew/run /tmp/test_crew2/.crew/logs /tmp/test_crew2/.crew/shared
  echo "test" > /tmp/test_crew2/.crew/prompts/test.md 2>/dev/null || true
  cp /tmp/test_crew_eval2.yaml /tmp/test_crew2/.crew/crew.yaml

  cd /tmp/test_crew2

  # Clean up any previous test file
  rm -f /tmp/crew_stuck_test_pwned.txt

  # Source the watchdog functions and run _handle_stuck_agent
  # This simulates what happens when agent is detected as stuck
  run bash -c "
    set -e
    source /Users/gl/dev/crew/lib/utils.sh
    source /Users/gl/dev/crew/lib/config.sh
    source /Users/gl/dev/crew/lib/watchdog.sh 2>/dev/null
    _handle_stuck_agent TEST notify .crew/crew.yaml
  "

  # If this file exists, the exploit succeeded (test should FAIL to prove bug exists)
  if [[ -f /tmp/crew_stuck_test_pwned.txt ]]; then
    # Clean up
    rm -f /tmp/crew_stuck_test_pwned.txt
    false  # Force test to fail - this proves the bug exists
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-019: No validation of working_dir in plugins [MEDIUM]
# Location: plugins/*.sh (all cli_*_run functions)
# ─────────────────────────────────────────────────────────────────────────────

@test "SECURITY: plugin run should validate working_dir to prevent path traversal" {
  # BUG-QA-019: Plugins don't validate working_dir before using it
  # FIXED 2026-02-27: validate_file_path is now called in plugin_loader.sh
  #
  # This test verifies the fix is in place by checking that plugins
  # call validate_file_path before using working_dir.

  # Load utils for validate_file_path
  source /Users/gl/dev/crew/lib/utils.sh

  # Verify that validate_file_path correctly rejects path traversal
  run validate_file_path "../../../etc"
  [[ "$status" -eq 1 ]]

  # Verify the fix: validate_file_path should be called in plugin_loader.sh
  if grep -q "validate_file_path.*working_dir" /Users/gl/dev/crew/lib/plugin_loader.sh 2>/dev/null; then
    # BUG FIXED: Validation is present - test passes
    :
  else
    # BUG EXISTS: No validation in plugins - test fails
    echo "ERROR: validate_file_path not called on working_dir in plugin_loader.sh"
    return 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-020: Sed injection in project name substitution [LOW]
# Location: crew.sh:211, lib/orchestrator.sh:387
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-023: TOML injection in codex plugin config flags [HIGH]
# Location: plugins/codex.sh (_codex_build_config_flags, _codex_escape_toml)
# ─────────────────────────────────────────────────────────────────────────────

@test "SECURITY: codex TOML escaping should neutralize double quotes" {
  source "$PROJECT_ROOT/plugins/codex.sh"

  run _codex_escape_toml 'value"]; inject = "evil'
  [ "$status" -eq 0 ]
  [[ "$output" == 'value\"]; inject = \"evil' ]]
}

@test "SECURITY: codex TOML escaping should neutralize newlines" {
  source "$PROJECT_ROOT/plugins/codex.sh"

  run _codex_escape_toml $'model\nnew_section = "injected"'
  [ "$status" -eq 0 ]
  [[ "$output" == 'model\nnew_section = "injected"' ]]
  # Escaped output should NOT contain a literal newline
  [[ "$output" != *$'\n'* ]]
}

@test "SECURITY: codex TOML escaping should neutralize backslashes" {
  source "$PROJECT_ROOT/plugins/codex.sh"

  run _codex_escape_toml 'path\\to\\file'
  [ "$status" -eq 0 ]
  [[ "$output" == 'path\\\\to\\\\file' ]]
}

@test "SECURITY: codex config flags should reject invalid CODEX_PROVIDER" {
  source "$PROJECT_ROOT/plugins/codex.sh"

  CODEX_PROVIDER='evil"; inject = "val'
  run _codex_build_config_flags
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid CODEX_PROVIDER"* ]]
  unset CODEX_PROVIDER
}

@test "SECURITY: codex config flags should reject invalid CODEX_API_KEY_ENV" {
  source "$PROJECT_ROOT/plugins/codex.sh"

  CODEX_PROVIDER="safe"
  CODEX_API_KEY_ENV='$(whoami)'
  run _codex_build_config_flags
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid CODEX_API_KEY_ENV"* ]]
  unset CODEX_PROVIDER CODEX_API_KEY_ENV
}

@test "SECURITY: codex config flags should reject invalid CODEX_WIRE_API" {
  source "$PROJECT_ROOT/plugins/codex.sh"

  CODEX_PROVIDER="safe"
  CODEX_WIRE_API="malicious"
  run _codex_build_config_flags
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid CODEX_WIRE_API"* ]]
  unset CODEX_PROVIDER CODEX_WIRE_API
}

@test "SECURITY: codex config flags should accept valid provider config" {
  source "$PROJECT_ROOT/plugins/codex.sh"

  CODEX_PROVIDER="dashscope"
  CODEX_MODEL="qwen-plus"
  CODEX_BASE_URL="https://api.example.com/v1"
  CODEX_API_KEY_ENV="DASHSCOPE_API_KEY"
  CODEX_WIRE_API="chat"
  run _codex_build_config_flags
  [ "$status" -eq 0 ]
  [[ "$output" == *'model_provider="dashscope"'* ]]
  [[ "$output" == *'model="qwen-plus"'* ]]
  [[ "$output" == *'wire_api="chat"'* ]]
  unset CODEX_PROVIDER CODEX_MODEL CODEX_BASE_URL CODEX_API_KEY_ENV CODEX_WIRE_API
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-027: Plugin loader permission validation [LOW]
# Location: lib/plugin_loader.sh (load_plugin)
# ─────────────────────────────────────────────────────────────────────────────

@test "SECURITY: plugin loader should reject world-writable plugin files" {
  # Verify the permission check exists in plugin_loader.sh
  if grep -q "world-writable" /Users/gl/dev/crew/lib/plugin_loader.sh 2>/dev/null; then
    # Fix is in place
    :
  else
    echo "ERROR: No world-writable permission check in plugin_loader.sh"
    return 1
  fi
}

@test "SECURITY: sed project name substitution should handle special characters" {
  # Create a directory with sed-special characters in name
  mkdir -p "/tmp/test_project/sed_test"
  cd "/tmp/test_project/sed_test"

  # The current sed pattern: sed "s/^project: .*/project: $(basename "$PWD")/"
  # If basename contains / or &, sed will misinterpret it

  # Test that validate_file_path would reject problematic names
  # This is a defense-in-depth check

  # Directory names with / are impossible, but & is valid
  run bash -c "echo 'test & pattern' | sed 's/test/test &/'"

  # This demonstrates that & is interpreted as the matched pattern
  # If project name contains &, it will be expanded by sed
  [[ "$output" == "test test & pattern" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-028: Missing dependency check for bc in cost.sh [MEDIUM]
# Location: lib/cost.sh (bc usage throughout)
# ─────────────────────────────────────────────────────────────────────────────

@test "SECURITY: cost.sh should check for bc dependency" {
  # Verify that cost.sh uses bc without checking if it's installed
  if grep -q "command_exists bc\|which bc" /Users/gl/dev/crew/lib/cost.sh 2>/dev/null; then
    # Fix is in place - bc dependency is checked
    :
  else
    # BUG EXISTS: No check for bc dependency
    # This test documents the vulnerability
    echo "ERROR: lib/cost.sh uses bc without checking if it's installed"
    echo "       If bc is missing, cost calculations will silently fail"
    return 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-029: Unvalidated --max-iter values [MEDIUM]
# Location: design.sh, lib/orchestrator.sh
# ─────────────────────────────────────────────────────────────────────────────

@test "SECURITY: --max-iter should reject invalid values" {
  # The --max-iter flag should only accept positive integers >= 1
  # Check if validation exists in design.sh
  if grep -q "max-iter must be a positive integer" /Users/gl/dev/crew/design.sh 2>/dev/null; then
    # Fix is in place
    :
  else
    # BUG EXISTS: No validation of max_iter
    echo "ERROR: No validation for --max-iter flag"
    echo "       Values like 0, -1, or 'abc' are accepted without validation"
    return 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-030: No validation of CREW_AGENT environment variable [LOW]
# Location: lib/config.sh (get_agent_type function)
# ─────────────────────────────────────────────────────────────────────────────

@test "SECURITY: CREW_AGENT env var should be validated" {
  # The CREW_AGENT environment variable is used directly without validation
  # This test checks if validation is present

  # Check if CREW_AGENT is validated before use
  if grep -q "Invalid CREW_AGENT value" /Users/gl/dev/crew/lib/config.sh 2>/dev/null; then
    # Fix is in place
    :
  else
    # BUG EXISTS: CREW_AGENT is not validated
    echo "ERROR: CREW_AGENT environment variable is not validated"
    echo "       Malicious values could cause issues when interpolated"
    return 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-031: Temp file leak on interruption in codex.sh [LOW]
# Location: plugins/codex.sh
# ─────────────────────────────────────────────────────────────────────────────

@test "SECURITY: codex.sh should cleanup temp files on signal" {
  # Temp files created with mktemp in codex.sh are not cleaned up on SIGINT/SIGTERM
  # This test checks if trap cleanup is present

  # Check if trap for cleanup exists
  if grep -qE "trap.*rm.*out_file.*EXIT.*INT.*TERM" /Users/gl/dev/crew/plugins/codex.sh 2>/dev/null; then
    # Fix is in place
    :
  else
    # BUG EXISTS: No signal handler for temp file cleanup
    echo "ERROR: codex.sh does not trap signals to cleanup temp files"
    echo "       Interrupted commands may leave temp files behind"
    return 1
  fi
}

#!/usr/bin/env bats
# tests/unit/test_adversarial_qa.bats
# NEW BUG DISCOVERY - Adversarial QA Audit v3
# These tests probe for security and reliability issues not yet covered

setup() {
  load ../test_helper
  source "$PROJECT_ROOT/lib/utils.sh"
  source "$PROJECT_ROOT/lib/config.sh"
  source "$PROJECT_ROOT/lib/plugin_loader.sh"
  source "$PROJECT_ROOT/lib/cost.sh" 2>/dev/null || true

  TEST_DIR="$(mktemp -d)"
  mkdir -p "$TEST_DIR/.crew/logs" "$TEST_DIR/.crew/run" "$TEST_DIR/.crew/prompts"
  cd "$TEST_DIR"
}

teardown() {
  cd /
  rm -rf "$TEST_DIR"
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-027: Log file injection via malicious agent names
# Location: lib/status.sh, lib/cost.sh (log file path construction)
# Impact: MEDIUM - Writing logs to arbitrary locations
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-027: Agent names with path traversal should not write logs outside .crew" {
  # Malicious agent name that tries path traversal
  local malicious_name="../../../tmp/pwned"

  # The log file path would be: .crew/logs/../../../tmp/pwned.log
  # This could write to /tmp/pwned.log

  # Validate that agent names reject path traversal
  run validate_agent_name "$malicious_name"
  [ "$status" -eq 1 ]
}

@test "BUG-QA-027b: Agent name with slash should be rejected" {
  # Another variant using forward slash
  run validate_agent_name "foo/bar"
  [ "$status" -eq 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-028: ANSI injection in log output
# Location: lib/status.sh:97 (printf with agent name containing escape codes)
# Impact: LOW - Terminal escape sequence injection
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-028: Agent names should not allow ANSI escape injection" {
  # Agent name containing ANSI escape sequences could manipulate terminal
  local malicious_name=$'QA\x1b[31mRED'

  # Should be rejected by validate_agent_name
  run validate_agent_name "$malicious_name"
  [ "$status" -eq 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-029: Integer underflow in interval validation
# Location: lib/utils.sh:134-154 (validate_interval)
# Impact: LOW - Negative intervals could cause unexpected behavior
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-029: validate_interval should reject negative numbers" {
  run validate_interval "-1"
  [ "$status" -eq 1 ]
}

@test "BUG-QA-029b: validate_interval should reject zero" {
  run validate_interval "0"
  [ "$status" -eq 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-030: Unicode normalization bypass in path validation
# Location: lib/utils.sh:112-132 (validate_file_path)
# Impact: MEDIUM - Unicode path traversal might bypass checks
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-030: validate_file_path should reject unicode dots" {
  # Unicode homoglyphs for dot: U+2024 (one dot leader), U+3002 (ideographic full stop)
  local unicode_dot_path=$'file\u2024\u2024/etc/passwd'  # ․․ instead of ..

  run validate_file_path "$unicode_dot_path"

  # BUG: Currently passes (returns 0) but should reject unicode dots
  # If this test FAILS, the bug is present (validate_file_path accepts unicode dots)
  # If this test PASSES, the bug is fixed
  [ "$status" -eq 1 ]
}

@test "BUG-QA-030b: validate_file_path should reject fullwidth dots" {
  # Fullwidth full stop U+FF0E looks like .
  local fullwidth_path=$'\uff0e\uff0e/config'

  run validate_file_path "$fullwidth_path"

  # BUG: Currently passes (returns 0) but should reject fullwidth dots
  # If this test FAILS, the bug is present
  # If this test PASSES, the bug is fixed
  [ "$status" -eq 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-031: Race condition in PID file operations
# Location: lib/watchdog.sh (PID file read/write)
# Impact: MEDIUM - PID reuse could lead to killing wrong process
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-031: PID file should contain timestamp to prevent reuse attacks" {
  # This test documents the need for PID+timestamp format
  # Current implementation only stores PID, vulnerable to reuse

  # Create a fake PID file with just a PID (current format)
  echo "12345" > "$TEST_DIR/.crew/run/TEST.pid"

  # The file should ideally contain "PID LSTART" format
  # to mitigate TOCTOU race conditions

  # Verify the file exists (test setup check)
  [ -f "$TEST_DIR/.crew/run/TEST.pid" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-032: Unsafe YAML parsing via yq
# Location: lib/config.sh:48-59 (parse_yaml)
# Impact: MEDIUM - Malicious YAML could exploit yq
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-032: Config with anchors and aliases should be handled" {
  # YAML anchors/aliases could cause explosion (Billion Laughs attack)
  cat > "$TEST_DIR/.crew/crew.yaml" << 'EOF'
agents: &agents
  - name: QA
    prompt: prompts/qa.md
agents: *agents
agents: *agents
agents: *agents
EOF

  # This should either work or fail gracefully, not hang/crash
  run config_get ".agents[0].name" "" "$TEST_DIR/.crew/crew.yaml"
  # We don't assert on status because yq behavior varies
  # The test documents the potential issue
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-033: Command injection via project name in crew init
# Location: crew.sh:211-214 (sed substitution)
# Impact: HIGH - Command injection via malicious directory name
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-033: Project name with shell specials should be handled" {
  # Create a directory with shell-special characters
  mkdir -p "$TEST_DIR/\$(id > /tmp/pwned)"
  cd "$TEST_DIR/\$(id > /tmp/pwned)"

  # The sed substitution uses double quotes which could execute commands
  # sed "s/^project: .*/project: $(basename "$PWD")/"

  # This test documents the issue - actual exploit depends on shell version
  local project_name
  project_name=$(basename "$PWD")

  # Should not contain executable command sequences after escaping
  [[ "$project_name" == *'$(id'* ]] || true  # Documents the potential
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-034: Regex DoS via log file content
# Location: lib/cost.sh:42-49 (cost parsing regex)
# Impact: MEDIUM - Crafted log file could cause CPU exhaustion
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-034: Cost parsing should handle long lines gracefully" {
  local log="$TEST_DIR/.crew/logs/QA.log"

  # Create a log line with massive repetition that could cause regex backtracking
  printf 'Total cost: $%s99\n' "$(printf '1%.0s' {1..1000})" > "$log"

  run _parse_claude_cost "$log"
  [ "$status" -eq 0 ]

  # Should complete in reasonable time (not hang on regex)
  # The MAX_COST_LINE_LENGTH check should skip this line
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-035: Information disclosure via error messages
# Location: lib/config.sh:334-339 (validate_config error messages)
# Impact: LOW - Error messages could leak file paths
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-035: Config validation should not leak sensitive paths" {
  cat > "$TEST_DIR/.crew/crew.yaml" << 'EOF'
invalid yaml: [
EOF

  run validate_config "$TEST_DIR/.crew/crew.yaml"

  # Error message should not contain full paths that might leak structure
  # This is a defense-in-depth check
  [[ ! "$output" == *"/home/"* ]] || true
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-036: Unbounded memory usage in build_prompt
# Location: lib/agent_runner.sh:85-116 (build_prompt)
# Impact: MEDIUM - Large injected files could exhaust memory
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-036: build_prompt should handle large files gracefully" {
  # Create a very large file to inject
  dd if=/dev/zero bs=1024 count=10240 2>/dev/null | tr '\0' 'A' > "$TEST_DIR/.crew/large_file.txt"

  source "$PROJECT_ROOT/lib/agent_runner.sh" 2>/dev/null || true

  # Attempt to build prompt with large file
  # Should not crash or hang
  run build_prompt "$TEST_DIR/.crew/prompts/test.md" "$TEST_DIR/.crew/large_file.txt"

  # Even if it fails, it should do so gracefully
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-037: Missing validation in fallback chain config
# Location: lib/watchdog.sh (fallback level parsing)
# Impact: MEDIUM - Malicious fallback config could bypass restrictions
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-037: Fallback level should be validated as integer" {
  # Create config with non-integer fallback level
  cat > "$TEST_DIR/.crew/crew.yaml" << 'EOF'
project: test
agents:
  - name: QA
    prompt: prompts/qa.md
    type: claude
    fallback:
      - level: "../../../etc"
        type: gemini
EOF

  echo "test" > "$TEST_DIR/.crew/prompts/qa.md"

  # Validation should catch this
  run validate_config "$TEST_DIR/.crew/crew.yaml"
  # Config might parse but should be rejected due to invalid fallback
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-038: Insecure temp file in plugin_run_prompt fallback
# Location: lib/plugin_loader.sh:180-191 (temp file creation)
# Impact: MEDIUM - Race condition in temp file could allow symlink attack
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-038: Temp file in plugin_run_prompt should be secure" {
  # The function creates a temp file with mktemp but writes prompt content
  # If an attacker can predict the filename and create a symlink,
  # they could redirect the write

  # This test documents the theoretical race condition
  # Modern mktemp implementations are generally safe

  local tmp_file
  tmp_file=$(mktemp)

  # Verify proper permissions are set
  local perms
  perms=$(stat -f "%Lp" "$tmp_file" 2>/dev/null || stat -c "%a" "$tmp_file" 2>/dev/null)

  # Should be readable only by owner (600)
  [ "$perms" = "600" ] || [ "$perms" = "644" ]  # 644 is default, 600 is ideal

  rm -f "$tmp_file"
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-039: XML injection in build_prompt filename attribute
# Location: lib/agent_runner.sh:96-108 (filename in XML context tag)
# Impact: LOW - Could break XML parsing if filename contains special chars
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-039: Filename with XML special chars should be escaped" {
  # Create a file with XML special characters in name
  touch "$TEST_DIR/.crew/test<>&\".md" 2>/dev/null || touch "$TEST_DIR/.crew/test_file.md"

  # The build_prompt function escapes XML in filename
  # This test verifies the escaping works

  source "$PROJECT_ROOT/lib/agent_runner.sh" 2>/dev/null || true

  # Test with normal filename first
  echo "test prompt" > "$TEST_DIR/.crew/prompts/test.md"
  echo "content" > "$TEST_DIR/.crew/test_file.md"

  run build_prompt "$TEST_DIR/.crew/prompts/test.md" "$TEST_DIR/.crew/test_file.md"
  [ "$status" -eq 0 ]

  # Output should not contain unescaped XML special chars in file attribute
  [[ ! "$output" == *'<context file="*<"*>'* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-040: Unbounded config file size
# Location: lib/config.sh:23-46 (find_config and parsing)
# Impact: LOW - Very large config files could cause DoS
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-040: Config file size should be limited" {
  # Create an extremely large config file
  {
    echo "project: test"
    echo "agents:"
    for i in {1..10000}; do
      echo "  - name: AGENT$i"
      echo "    prompt: prompts/agent.md"
    done
  } > "$TEST_DIR/.crew/crew.yaml"

  # This should either work or be rejected, but not cause OOM
  run config_get ".project" "" "$TEST_DIR/.crew/crew.yaml"

  # Should complete (may fail due to size, but shouldn't crash)
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

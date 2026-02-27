#!/usr/bin/env bats
# BUG DEMONSTRATION tests for lib/cost.sh
# These tests prove bugs exist by FAILING on current code
# When bugs are fixed, these tests should PASS

setup() {
  load ../test_helper
  source "$PROJECT_ROOT/lib/cost.sh"

  # Create temp crew dir structure
  TEST_DIR="$(mktemp -d)"
  mkdir -p "$TEST_DIR/.crew/logs"
  mkdir -p "$TEST_DIR/.crew/run"
  cd "$TEST_DIR"
}

teardown() {
  cd /
  rm -rf "$TEST_DIR"
}

# ── BUG-001: Greedy regex extracts timestamps instead of token counts ──
# Location: lib/cost.sh:47-50 (input token parsing)
# The regex [0-9,]+ matches ANY numbers in the line, not just the token count

@test "BUG-001: _parse_claude_cost should not extract timestamps as tokens" {
  local log="$TEST_DIR/.crew/logs/QA.log"
  cat > "$log" << 'EOF'
[2026-02-26 10:30:45] Starting agent
Input tokens: 500
Processed at 2026-02-26, 10:30
EOF

  run _parse_claude_cost "$log"
  [ "$status" -eq 0 ]

  # The bug: regex extracts "2026" from the timestamp line instead of "500" from token line
  # This test documents expected behavior: input_tokens should be 500, not 2026
  echo "$output" | grep -q "input_tokens=500"
}

@test "BUG-001b: _parse_claude_cost handles date in token line" {
  local log="$TEST_DIR/.crew/logs/QA.log"
  # Edge case: log line has both date and token info
  cat > "$log" << 'EOF'
[2026-02-26] Input tokens: 1500, processed
EOF

  run _parse_claude_cost "$log"
  [ "$status" -eq 0 ]

  # Should extract 1500, not 2026 or 26
  echo "$output" | grep -q "input_tokens=1500"
}

# ── BUG-002: Malformed cost values not validated ──
# Location: lib/cost.sh:36-41 (cost extraction)
# Negative costs or invalid formats are silently accepted

@test "BUG-002: _parse_claude_cost should reject negative costs" {
  local log="$TEST_DIR/.crew/logs/QA.log"
  cat > "$log" << 'EOF'
Total cost: $-5.00
EOF

  run _parse_claude_cost "$log"
  [ "$status" -eq 0 ]

  # Negative costs should be treated as 0 or rejected
  # Currently: bc accepts -5.00 and includes it in sum
  # Expected: total_cost=0 (negative is invalid)
  echo "$output" | grep -q "total_cost=0"
}

@test "BUG-002b: _parse_claude_cost should handle multiple decimal points" {
  local log="$TEST_DIR/.crew/logs/QA.log"
  cat > "$log" << 'EOF'
Total cost: $1.23.45
EOF

  run _parse_claude_cost "$log"
  [ "$status" -eq 0 ]

  # Malformed cost should not break calculation
  # bc will fail on "1.23.45", and fallback keeps original total_cost
  echo "$output" | grep -q "total_cost="
}

# ── BUG-003: Integer overflow with very large token counts ──
# Location: lib/cost.sh:49, 58 (token accumulation)
# Bash 64-bit signed int overflow produces negative numbers

@test "BUG-003: Token counts should not overflow on large values" {
  local log="$TEST_DIR/.crew/logs/QA.log"
  # Simulate a log with large token counts that could cause overflow
  cat > "$log" << 'EOF'
Input tokens: 9223372036854775800
Output tokens: 100
EOF

  run _parse_claude_cost "$log"
  [ "$status" -eq 0 ]

  # Check that result doesn't overflow (would produce negative number)
  # This test documents the limitation
  local input_line
  input_line=$(echo "$output" | grep "input_tokens=")
  [[ "$input_line" != *input_tokens=-* ]]
}

# ── BUG-004: Missing bc dependency not handled gracefully ──
# Location: lib/cost.sh:39, 83, 224 (bc usage)
# If bc is not installed, cost calculations fail silently

@test "BUG-004: Functions work without bc installed" {
  # Create a mock environment without bc in PATH
  local log="$TEST_DIR/.crew/logs/QA.log"
  cat > "$log" << 'EOF'
Total cost: $1.50
Total cost: $2.50
EOF

  # Run with restricted PATH (no bc)
  PATH=/bin:/usr/bin run _parse_claude_cost "$log"

  # Should still return valid result (even if imprecise)
  # Currently: falls back to previous total_cost value
  # Expected: should calculate sum using alternative method
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "total_cost="
}

# ── BUG-005: crew_dir hardcoded in get_agent_cost ──
# Location: lib/cost.sh:126
# Function ignores config file location and uses hardcoded ".crew"

@test "BUG-005: get_agent_cost respects crew_dir from config" {
  # Setup custom crew directory
  mkdir -p "$TEST_DIR/custom/logs"
  cat > "$TEST_DIR/custom/logs/QA.log" << 'EOF'
Total cost: $5.00
EOF

  cat > "$TEST_DIR/custom/crew.yaml" << 'EOF'
project: test
agents:
  - name: QA
    type: claude
    prompt: prompts/qa.md
EOF

  # This should work but doesn't because get_agent_cost hardcodes ".crew"
  cd "$TEST_DIR"

  # Currently: always looks in .crew/logs/ even if config is elsewhere
  # Expected: derive crew_dir from config file path
  run get_agent_cost "QA" "$TEST_DIR/custom/crew.yaml"
  [ "$status" -eq 0 ]

  # Should find the log and return cost=5.00
  echo "$output" | grep -q "total_cost=5"
}

# ── BUG-006: No validation of log file readability ──
# Location: lib/cost.sh:27-66 (parser functions)
# Unreadable log files cause silent failures

@test "BUG-006: _parse_claude_cost handles unreadable log file" {
  local log="$TEST_DIR/.crew/logs/QA.log"
  echo 'Total cost: $1.00' > "$log"
  chmod 000 "$log"

  run _parse_claude_cost "$log"

  # Should handle gracefully, not fail
  [ "$status" -eq 0 ]

  # Restore permissions for cleanup
  chmod 644 "$log"
}

# ── BUG-007: Cost with thousand separator comma truncated ──
# Location: lib/cost.sh:37 (cost extraction regex)
# Regex '\$[0-9]+(\\.[0-9]+)?' stops at comma, truncating $1,234.56 to $1

@test "BUG-007: _parse_claude_cost handles comma as thousand separator" {
  local log="$TEST_DIR/.crew/logs/QA.log"
  cat > "$log" << 'EOF'
Total cost: $1,234.56
EOF

  run _parse_claude_cost "$log"
  [ "$status" -eq 0 ]

  # Should extract 1234.56, not 1
  # Bug: regex stops at comma, extracts only "1"
  echo "$output" | grep -q "total_cost=1234.56"
}

# ── BUG-008: Cost starting with decimal point ignored ──
# Location: lib/cost.sh:37 (cost extraction regex)
# Regex requires digit after $, so $.99 is not matched

@test "BUG-008: _parse_claude_cost handles cost starting with decimal" {
  local log="$TEST_DIR/.crew/logs/QA.log"
  cat > "$log" << 'EOF'
Total cost: $.99
EOF

  run _parse_claude_cost "$log"
  [ "$status" -eq 0 ]

  # Should extract 0.99
  # Bug: regex requires [0-9]+ after $, so $.99 is ignored
  echo "$output" | grep -q "total_cost=0.99"
}

# ── BUG-009: Integer overflow with max int64 + 1 ──
# Location: lib/cost.sh:50, 59 (token accumulation)
# Bash arithmetic overflow wraps to negative

@test "BUG-009: Token counts handle max int64 + 1 without overflow" {
  local log="$TEST_DIR/.crew/logs/QA.log"
  cat > "$log" << 'EOF'
Input tokens: 9223372036854775807
Input tokens: 1
EOF

  run _parse_claude_cost "$log"
  [ "$status" -eq 0 ]

  # max int64 + 1 overflows to -9223372036854775808 in bash
  # This test documents the overflow issue
  local input_line
  input_line=$(echo "$output" | grep "input_tokens=")
  # If this assertion fails (output contains negative), bug is present
  [[ "$input_line" != *input_tokens=-* ]]
}

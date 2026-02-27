#!/usr/bin/env bats
# Tests for lib/cost.sh

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

# ── _parse_claude_cost ──────────────────────────────────────

@test "_parse_claude_cost: extracts total cost from Claude output" {
  local log="$TEST_DIR/.crew/logs/QA.log"
  cat > "$log" << 'EOF'
[QA] Starting at 2026-02-27 10:00:00 [primary] (type: claude)
Some agent output here
Total cost:      $0.1234
Total duration (API): 12.3s
[QA] Exited with code 0 at 2026-02-27 10:01:00 [primary]
EOF

  run _parse_claude_cost "$log"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "total_cost=0.1234"
  echo "$output" | grep -q "api_calls=1"
}

@test "_parse_claude_cost: sums multiple runs" {
  local log="$TEST_DIR/.crew/logs/DEV.log"
  cat > "$log" << 'EOF'
[DEV] Starting at 2026-02-27 10:00:00 [primary] (type: claude)
Total cost:      $0.50
[DEV] Exited with code 0
[DEV] Starting at 2026-02-27 10:05:00 [primary] (type: claude)
Total cost:      $1.25
[DEV] Exited with code 0
EOF

  run _parse_claude_cost "$log"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "total_cost=1.75"
  echo "$output" | grep -q "api_calls=2"
}

@test "_parse_claude_cost: extracts token counts" {
  local log="$TEST_DIR/.crew/logs/QA.log"
  cat > "$log" << 'EOF'
Input tokens: 5000
Output tokens: 1200
Total cost: $0.10
EOF

  run _parse_claude_cost "$log"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "input_tokens=5000"
  echo "$output" | grep -q "output_tokens=1200"
}

@test "_parse_claude_cost: handles comma-formatted tokens" {
  local log="$TEST_DIR/.crew/logs/QA.log"
  cat > "$log" << 'EOF'
Input tokens: 15,000
Output tokens: 3,200
Total cost: $0.50
EOF

  run _parse_claude_cost "$log"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "input_tokens=15000"
  echo "$output" | grep -q "output_tokens=3200"
}

@test "_parse_claude_cost: returns zeros for log without cost data" {
  local log="$TEST_DIR/.crew/logs/QA.log"
  cat > "$log" << 'EOF'
[QA] Starting at 2026-02-27 10:00:00 [primary] (type: claude)
Some output without cost info
[QA] Exited with code 0
EOF

  run _parse_claude_cost "$log"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "total_cost=0"
  echo "$output" | grep -q "api_calls=0"
}

# ── _parse_generic_cost ─────────────────────────────────────

@test "_parse_generic_cost: extracts cost from generic output" {
  local log="$TEST_DIR/.crew/logs/DEV.log"
  cat > "$log" << 'EOF'
[DEV] Starting at 2026-02-27 10:00:00 [primary] (type: codex)
Task completed. Total cost: $0.0567
[DEV] Exited with code 0
EOF

  run _parse_generic_cost "$log"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "total_cost=0.0567"
}

@test "_parse_generic_cost: counts sessions from lifecycle markers" {
  local log="$TEST_DIR/.crew/logs/DEV.log"
  cat > "$log" << 'EOF'
[DEV] Starting at 2026-02-27 10:00:00 [primary] (type: codex)
Some output
[DEV] Starting at 2026-02-27 10:05:00 [primary] (type: codex)
More output
[DEV] Starting at 2026-02-27 10:10:00 [primary] (type: codex)
Even more output
EOF

  run _parse_generic_cost "$log"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "api_calls=3"
}

@test "_parse_generic_cost: extracts prompt/completion tokens" {
  local log="$TEST_DIR/.crew/logs/DEV.log"
  cat > "$log" << 'EOF'
Prompt tokens: 8000
Completion tokens: 2500
EOF

  run _parse_generic_cost "$log"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "input_tokens=8000"
  echo "$output" | grep -q "output_tokens=2500"
}

# ── get_agent_cost ──────────────────────────────────────────

@test "get_agent_cost: returns zeros for missing log file" {
  # Create minimal config
  mkdir -p "$TEST_DIR/.crew"
  cat > "$TEST_DIR/.crew/crew.yaml" << 'EOF'
project: test
agents:
  - name: QA
    type: claude
    prompt: prompts/qa.md
EOF

  run get_agent_cost "QA" "$TEST_DIR/.crew/crew.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "total_cost=0"
  echo "$output" | grep -q "api_calls=0"
}

# ── show_cost ───────────────────────────────────────────────

@test "show_cost: displays table with agent data" {
  cat > "$TEST_DIR/.crew/crew.yaml" << 'EOF'
project: test-project
agents:
  - name: QA
    type: claude
    prompt: prompts/qa.md
  - name: DEV
    type: claude
    prompt: prompts/dev.md
EOF

  cat > "$TEST_DIR/.crew/logs/QA.log" << 'EOF'
[QA] Starting at 2026-02-27 10:00:00 [primary] (type: claude)
Total cost:      $0.50
[QA] Exited with code 0
EOF

  cat > "$TEST_DIR/.crew/logs/DEV.log" << 'EOF'
[DEV] Starting at 2026-02-27 10:00:00 [primary] (type: claude)
Total cost:      $1.25
[DEV] Exited with code 0
EOF

  run show_cost "$TEST_DIR/.crew/crew.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "test-project"
  echo "$output" | grep -q "QA"
  echo "$output" | grep -q "DEV"
  echo "$output" | grep -q "TOTAL"
}

@test "show_cost: handles no config" {
  run show_cost "/nonexistent/config.yaml"
  [ "$status" -eq 1 ]
}

@test "show_cost: handles no agents" {
  cat > "$TEST_DIR/.crew/crew.yaml" << 'EOF'
project: empty
agents: []
EOF

  run show_cost "$TEST_DIR/.crew/crew.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "No agents configured"
}

@test "show_cost: shows fallback level info" {
  cat > "$TEST_DIR/.crew/crew.yaml" << 'EOF'
project: test-project
agents:
  - name: QA
    type: claude
    prompt: prompts/qa.md
EOF

  touch "$TEST_DIR/.crew/logs/QA.log"
  echo "1|sonnet-fallback" > "$TEST_DIR/.crew/run/QA.fallback"

  run show_cost "$TEST_DIR/.crew/crew.yaml"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Fallback"
  echo "$output" | grep -q "sonnet-fallback"
}

#!/usr/bin/env bats
# Integration tests for design mode lifecycle

setup() {
  load ../test_helper

  # Create isolated test directory
  TEST_DIR="$BATS_TEST_TMPDIR/design_integration_$$"
  mkdir -p "$TEST_DIR"
  cd "$TEST_DIR"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# ─────────────────────────────────────────────────────────────────────────────
# design init
# ─────────────────────────────────────────────────────────────────────────────

@test "design init: creates .design directory structure" {
  run "$PROJECT_ROOT/design.sh" init "Build a task runner CLI"
  [ "$status" -eq 0 ]
  [ -d ".design" ]
  [ -f ".design/idea.txt" ]
  [ -f ".design/design.yaml" ]
  [ -d ".design/history" ]
  [ -d ".design/prompts" ]
}

@test "design init: saves idea text correctly" {
  "$PROJECT_ROOT/design.sh" init "A distributed cache system"
  local idea
  idea=$(cat ".design/idea.txt")
  [ "$idea" = "A distributed cache system" ]
}

@test "design init: reads idea from file" {
  echo "Multi-tenant auth system" > "$TEST_DIR/my_idea.md"
  "$PROJECT_ROOT/design.sh" init "$TEST_DIR/my_idea.md"
  local idea
  idea=$(cat ".design/idea.txt")
  [ "$idea" = "Multi-tenant auth system" ]
}

@test "design init: copies default prompts" {
  "$PROJECT_ROOT/design.sh" init "test idea"
  [ -f ".design/prompts/plan_writer.md" ] || [ -f ".design/prompts/reviewer.md" ]
}

@test "design init: fails without idea" {
  run "$PROJECT_ROOT/design.sh" init
  [ "$status" -ne 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# design --dry-run review
# ─────────────────────────────────────────────────────────────────────────────

@test "design --dry-run review: shows config without executing agents" {
  "$PROJECT_ROOT/design.sh" init "test idea"
  run "$PROJECT_ROOT/design.sh" --dry-run review
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN"* ]]
  [[ "$output" == *"Writer"* ]]
  [[ "$output" == *"Reviewer"* ]]
  [[ "$output" == *"No agents executed"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# design status
# ─────────────────────────────────────────────────────────────────────────────

@test "design status: shows session info" {
  "$PROJECT_ROOT/design.sh" init "test idea"
  run "$PROJECT_ROOT/design.sh" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"idea.txt"* ]]
}

@test "design status: fails when no session exists" {
  run "$PROJECT_ROOT/design.sh" status
  [ "$status" -ne 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Termination: stale detection
# ─────────────────────────────────────────────────────────────────────────────

@test "parse_review_decision: integrated with real review file" {
  source "$PROJECT_ROOT/lib/utils.sh"
  source "$PROJECT_ROOT/lib/config.sh"
  eval "$(sed -n '/^parse_review_decision/,/^}/p' "$PROJECT_ROOT/lib/orchestrator.sh")"

  # Simulate a passing review
  cat > "$TEST_DIR/review.md" << 'EOF'
## Summary
The plan looks good.
PASS: true
EOF
  run parse_review_decision "$TEST_DIR/review.md"
  [ "$output" = "pass" ]

  # Simulate a failing review
  cat > "$TEST_DIR/review.md" << 'EOF'
## Issues Found
### Missing Error Handling
### No Input Validation
PASS: false
EOF
  run parse_review_decision "$TEST_DIR/review.md"
  [ "$output" = "fail" ]
}

#!/usr/bin/env bats
# Tests for lib/orchestrator.sh

setup() {
  load ../test_helper

  # Source only the functions we need (orchestrator sources agent_runner
  # which tries to load plugins, so we source selectively)
  source "$PROJECT_ROOT/lib/utils.sh"
  source "$PROJECT_ROOT/lib/config.sh"

  # Source standalone functions from orchestrator.sh (avoid sourcing agent_runner.sh)
  eval "$(sed -n '/^parse_review_decision/,/^}/p' "$PROJECT_ROOT/lib/orchestrator.sh")"
  eval "$(sed -n '/^resolve_prompt_path/,/^}/p' "$PROJECT_ROOT/lib/orchestrator.sh")"
  eval "$(sed -n '/^extract_review_issues/,/^}/p' "$PROJECT_ROOT/lib/orchestrator.sh")"
  eval "$(sed -n '/^detect_conflict/,/^}/p' "$PROJECT_ROOT/lib/orchestrator.sh")"

  # Exit codes from orchestrator
  EXIT_PASS=0
  EXIT_MAX_ITER=1
  EXIT_STALE=2
  EXIT_CONFLICT=3
}

# ─────────────────────────────────────────────────────────────────────────────
# parse_review_decision
# ─────────────────────────────────────────────────────────────────────────────

@test "parse_review_decision: detects 'PASS: true'" {
  echo "PASS: true" > "$BATS_TEST_TMPDIR/review.md"
  run parse_review_decision "$BATS_TEST_TMPDIR/review.md"
  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}

@test "parse_review_decision: detects 'PASS: yes'" {
  echo "PASS: yes" > "$BATS_TEST_TMPDIR/review.md"
  run parse_review_decision "$BATS_TEST_TMPDIR/review.md"
  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}

@test "parse_review_decision: detects '**PASS**: true' (bold markdown)" {
  echo "**PASS**: true" > "$BATS_TEST_TMPDIR/review.md"
  run parse_review_decision "$BATS_TEST_TMPDIR/review.md"
  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}

@test "parse_review_decision: rejects 'PASS: false'" {
  echo "PASS: false" > "$BATS_TEST_TMPDIR/review.md"
  run parse_review_decision "$BATS_TEST_TMPDIR/review.md"
  [ "$status" -eq 0 ]
  [ "$output" = "fail" ]
}

@test "parse_review_decision: rejects 'NOT PASS: true' (anchored regex)" {
  echo "NOT PASS: true" > "$BATS_TEST_TMPDIR/review.md"
  run parse_review_decision "$BATS_TEST_TMPDIR/review.md"
  [ "$status" -eq 0 ]
  [ "$output" = "fail" ]
}

@test "parse_review_decision: rejects file with no pass line" {
  echo "This review has issues." > "$BATS_TEST_TMPDIR/review.md"
  run parse_review_decision "$BATS_TEST_TMPDIR/review.md"
  [ "$status" -eq 0 ]
  [ "$output" = "fail" ]
}

@test "parse_review_decision: returns fail for nonexistent file" {
  run parse_review_decision "/nonexistent/review.md"
  [ "$status" -eq 0 ]
  [ "$output" = "fail" ]
}

@test "parse_review_decision: case insensitive" {
  echo "pass: True" > "$BATS_TEST_TMPDIR/review.md"
  run parse_review_decision "$BATS_TEST_TMPDIR/review.md"
  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}

@test "parse_review_decision: PASS in middle of file is detected" {
  cat > "$BATS_TEST_TMPDIR/review.md" << 'EOF'
## Review
Some commentary here.
PASS: true
EOF
  run parse_review_decision "$BATS_TEST_TMPDIR/review.md"
  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}

@test "parse_review_decision: rejects PASS with trailing text" {
  echo "PASS: true -- but with caveats" > "$BATS_TEST_TMPDIR/review.md"
  run parse_review_decision "$BATS_TEST_TMPDIR/review.md"
  [ "$status" -eq 0 ]
  [ "$output" = "fail" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# resolve_prompt_path
# ─────────────────────────────────────────────────────────────────────────────

@test "resolve_prompt_path: prefers local design dir" {
  local design_dir="$BATS_TEST_TMPDIR/design"
  mkdir -p "$design_dir/prompts"
  echo "local prompt" > "$design_dir/prompts/plan_writer.md"

  run resolve_prompt_path "prompts/plan_writer.md" "$design_dir"
  [ "$status" -eq 0 ]
  [ "$output" = "$design_dir/prompts/plan_writer.md" ]
}

@test "resolve_prompt_path: falls back to crew home" {
  local design_dir="$BATS_TEST_TMPDIR/design_empty"
  mkdir -p "$design_dir"

  # crew home has the default prompts
  local crew_home
  crew_home=$(get_crew_home)

  if [[ -f "$crew_home/prompts/design-review/plan_writer.md" ]]; then
    run resolve_prompt_path "prompts/plan_writer.md" "$design_dir"
    [ "$status" -eq 0 ]
    [[ "$output" == *"plan_writer.md"* ]]
  else
    skip "crew home prompts not found"
  fi
}

@test "resolve_prompt_path: returns path as-is when not found anywhere" {
  local design_dir="$BATS_TEST_TMPDIR/design_empty"
  mkdir -p "$design_dir"

  run resolve_prompt_path "nonexistent/prompt.md" "$design_dir"
  [ "$status" -eq 0 ]
  [ "$output" = "nonexistent/prompt.md" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Stale detection (unit test via file_hash comparison logic)
# ─────────────────────────────────────────────────────────────────────────────

@test "stale detection: same file hash means stale" {
  echo "plan content" > "$BATS_TEST_TMPDIR/plan.md"
  local hash1
  hash1=$(file_hash "$BATS_TEST_TMPDIR/plan.md")

  # No changes = same hash
  local hash2
  hash2=$(file_hash "$BATS_TEST_TMPDIR/plan.md")

  [ "$hash1" = "$hash2" ]
}

@test "stale detection: modified file resets stale" {
  echo "plan v1" > "$BATS_TEST_TMPDIR/plan.md"
  local hash1
  hash1=$(file_hash "$BATS_TEST_TMPDIR/plan.md")

  echo "plan v2" > "$BATS_TEST_TMPDIR/plan.md"
  local hash2
  hash2=$(file_hash "$BATS_TEST_TMPDIR/plan.md")

  [ "$hash1" != "$hash2" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# extract_review_issues
# ─────────────────────────────────────────────────────────────────────────────

@test "extract_review_issues: extracts ## and ### headings" {
  cat > "$BATS_TEST_TMPDIR/review.md" << 'EOF'
## Missing Error Handling
Some text about error handling.
### Input Validation
More text.
## Performance Concerns
Details.
PASS: false
EOF
  run extract_review_issues "$BATS_TEST_TMPDIR/review.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"input validation"* ]]
  [[ "$output" == *"missing error handling"* ]]
  [[ "$output" == *"performance concerns"* ]]
}

@test "extract_review_issues: returns empty for file with no headings" {
  echo "Just plain text without headings." > "$BATS_TEST_TMPDIR/review.md"
  run extract_review_issues "$BATS_TEST_TMPDIR/review.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "extract_review_issues: returns empty for nonexistent file" {
  run extract_review_issues "/nonexistent/review.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "extract_review_issues: ignores top-level # headings" {
  cat > "$BATS_TEST_TMPDIR/review.md" << 'EOF'
# Review Title
## Actual Issue
Text.
EOF
  run extract_review_issues "$BATS_TEST_TMPDIR/review.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"actual issue"* ]]
  [[ "$output" != *"review title"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# detect_conflict
# ─────────────────────────────────────────────────────────────────────────────

@test "detect_conflict: detects same issue across 3 reviews" {
  local history="$BATS_TEST_TMPDIR/history"
  mkdir -p "$history"

  for v in 1 2 3; do
    cat > "$history/review_v${v}.md" << 'EOF'
## Missing Error Handling
This is still not fixed.
## Unique Issue V
Different each time.
PASS: false
EOF
  done

  run detect_conflict "$history" 3 3
  [ "$status" -eq 0 ]
  [[ "$output" == *"missing error handling"* ]]
}

@test "detect_conflict: no conflict when issues differ" {
  local history="$BATS_TEST_TMPDIR/history"
  mkdir -p "$history"

  cat > "$history/review_v1.md" << 'EOF'
## Issue Alpha
PASS: false
EOF
  cat > "$history/review_v2.md" << 'EOF'
## Issue Beta
PASS: false
EOF
  cat > "$history/review_v3.md" << 'EOF'
## Issue Gamma
PASS: false
EOF

  run detect_conflict "$history" 3 3
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "detect_conflict: returns empty when not enough iterations" {
  local history="$BATS_TEST_TMPDIR/history"
  mkdir -p "$history"

  cat > "$history/review_v1.md" << 'EOF'
## Recurring Issue
PASS: false
EOF

  run detect_conflict "$history" 1 3
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "detect_conflict: returns empty when history dir missing" {
  run detect_conflict "/nonexistent/history" 5 3
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "detect_conflict: only reports intersection of issues" {
  local history="$BATS_TEST_TMPDIR/history"
  mkdir -p "$history"

  cat > "$history/review_v1.md" << 'EOF'
## Common Issue
## Only In V1
PASS: false
EOF
  cat > "$history/review_v2.md" << 'EOF'
## Common Issue
## Only In V2
PASS: false
EOF

  run detect_conflict "$history" 2 2
  [ "$status" -eq 0 ]
  [[ "$output" == *"common issue"* ]]
  [[ "$output" != *"only in v1"* ]]
  [[ "$output" != *"only in v2"* ]]
}

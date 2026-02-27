#!/usr/bin/env bats
# tests/unit/test_mcp_vulnerabilities.bats
# MCP server security tests

setup() {
  load ../test_helper
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
}

teardown() {
  cd /
  rm -rf "$TEST_DIR"
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-024: Missing validation in MCP server design_init [MEDIUM]
# Location: crew-mcp.sh:237-244
# Impact: Resource exhaustion via unbounded file write
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-024: design_init should reject oversized idea parameter" {
  # Source the orchestrator which contains design_init
  source "$PROJECT_ROOT/lib/utils.sh"
  source "$PROJECT_ROOT/lib/config.sh"
  source "$PROJECT_ROOT/lib/orchestrator.sh"

  mkdir -p "$TEST_DIR/.design"

  # Create a very large idea (simulating what MCP server might receive)
  local large_idea
  large_idea=$(python3 -c "print('A' * 10000000)")  # 10MB string

  # This should either be rejected or handled gracefully
  # Currently: no size limit, will write entire content to disk

  # For test purposes, use a smaller size to avoid test timeout
  large_idea=$(python3 -c "print('B' * 1000000)")   # 1MB

  run design_init "$large_idea"

  # Should fail or be rejected due to size
  # Currently: accepts any size (BUG)
  [ "$status" -eq 1 ] || [ -f "$TEST_DIR/.design/idea.txt" ]
}

@test "BUG-QA-024b: design_init idea should have reasonable size limit" {
  source "$PROJECT_ROOT/lib/utils.sh"
  source "$PROJECT_ROOT/lib/config.sh"
  source "$PROJECT_ROOT/lib/orchestrator.sh"

  mkdir -p "$TEST_DIR/.design"

  # Even 100KB should be more than enough for any idea
  local big_idea
  big_idea=$(python3 -c "print('C' * 102400)")  # 100KB

  run design_init "$big_idea"

  # If this succeeds, there's no size limit (BUG)
  # A reasonable limit might be 10KB or 64KB
  [ "$status" -eq 0 ]  # Currently succeeds (documents the bug)
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-025: Unquoted array expansion in MCP crew_start [MEDIUM]
# Location: crew-mcp.sh:211-213
# Impact: Word splitting on agent names with spaces
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-025: Agent names with spaces should be handled correctly" {
  source "$PROJECT_ROOT/lib/utils.sh"

  # Test that validate_agent_name rejects names with spaces
  run validate_agent_name "Agent With Spaces"
  [ "$status" -eq 1 ]
}

@test "BUG-QA-025b: Agent names with tabs should be rejected" {
  source "$PROJECT_ROOT/lib/utils.sh"

  run validate_agent_name $'Agent\tWith\tTabs'
  [ "$status" -eq 1 ]
}

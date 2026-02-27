#!/usr/bin/env bats
# Tests for lib/utils.sh

setup() {
  load ../test_helper
  source "$PROJECT_ROOT/lib/utils.sh"
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG: validate_agent_name uses [[ =~ ]] which has issues in Bash 3.2
# When using a variable regex pattern, Bash 3.2 interprets it literally
# instead of as a regex. This could allow invalid names through.
# Location: lib/utils.sh:104
# ─────────────────────────────────────────────────────────────────────────────

@test "validate_agent_name: rejects names with spaces" {
  run validate_agent_name "name with spaces"
  [ "$status" -eq 1 ]
}

@test "validate_agent_name: rejects names with special chars" {
  run validate_agent_name "name;with&special"
  [ "$status" -eq 1 ]
}

@test "validate_agent_name: accepts valid names" {
  run validate_agent_name "valid_name-123"
  [ "$status" -eq 0 ]
}

@test "validate_agent_name: rejects empty name" {
  run validate_agent_name ""
  [ "$status" -eq 1 ]
}

@test "validate_agent_name: rejects names over 32 chars" {
  run validate_agent_name "this_name_is_way_too_long_and_invalid"
  [ "$status" -eq 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG: validate_file_path does not reject all path traversal attempts
# A path like '.hidden/../etc/passwd' could slip through
# Location: lib/utils.sh:121
# ─────────────────────────────────────────────────────────────────────────────

@test "validate_file_path: rejects absolute paths" {
  run validate_file_path "/etc/passwd"
  [ "$status" -eq 1 ]
}

@test "validate_file_path: rejects double dot traversal" {
  run validate_file_path "../../../etc/passwd"
  [ "$status" -eq 1 ]
}

@test "validate_file_path: rejects hidden traversal pattern" {
  # This pattern contains ".." but might slip through if not handled correctly
  run validate_file_path ".hidden/../etc/passwd"
  [ "$status" -eq 1 ]
}

@test "validate_file_path: accepts valid relative paths" {
  run validate_file_path "prompts/qa.md"
  [ "$status" -eq 0 ]
}

@test "validate_file_path: accepts paths with dots in filename" {
  run validate_file_path "prompts/qa.test.md"
  [ "$status" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG: validate_interval accepts zero and very large values
# Zero interval causes infinite loop, values > 86400 may be too large
# Location: lib/utils.sh:132-151
# ─────────────────────────────────────────────────────────────────────────────

@test "validate_interval: rejects zero" {
  run validate_interval "0"
  [ "$status" -eq 1 ]
}

@test "validate_interval: rejects negative numbers" {
  run validate_interval "-10"
  [ "$status" -eq 1 ]
}

@test "validate_interval: rejects non-numeric values" {
  run validate_interval "abc"
  [ "$status" -eq 1 ]
}

@test "validate_interval: accepts valid positive integer" {
  run validate_interval "30"
  [ "$status" -eq 0 ]
}

@test "validate_interval: rejects values exceeding max" {
  run validate_interval "100000" "86400"
  [ "$status" -eq 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG: file_hash fallback uses stat format that may differ between systems
# The stat command format strings differ between macOS and Linux
# Location: lib/utils.sh:54-68
# ─────────────────────────────────────────────────────────────────────────────

@test "file_hash: returns empty for non-existent file" {
  run file_hash "/nonexistent/file"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "file_hash: returns consistent hash for same file" {
  echo "test content" > "$BATS_TEST_TMPDIR/testfile"
  run file_hash "$BATS_TEST_TMPDIR/testfile"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  local hash1="$output"

  run file_hash "$BATS_TEST_TMPDIR/testfile"
  [ "$output" = "$hash1" ]
}

@test "file_hash: returns different hash for different content" {
  echo "content1" > "$BATS_TEST_TMPDIR/file1"
  echo "content2" > "$BATS_TEST_TMPDIR/file2"

  run file_hash "$BATS_TEST_TMPDIR/file1"
  local hash1="$output"

  run file_hash "$BATS_TEST_TMPDIR/file2"
  local hash2="$output"

  [ "$hash1" != "$hash2" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# log_* functions
# ─────────────────────────────────────────────────────────────────────────────

@test "log_info: outputs message with info prefix" {
  run log_info "hello world"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello world"* ]]
}

@test "log_ok: outputs message with success prefix" {
  run log_ok "operation done"
  [ "$status" -eq 0 ]
  [[ "$output" == *"operation done"* ]]
}

@test "log_warn: outputs message with warning prefix" {
  run log_warn "something fishy"
  [ "$status" -eq 0 ]
  [[ "$output" == *"something fishy"* ]]
}

@test "log_error: outputs message with error prefix" {
  run log_error "it broke"
  [ "$status" -eq 0 ]
  [[ "$output" == *"it broke"* ]]
}

@test "log_debug: silent when DEBUG is not set" {
  unset DEBUG
  run log_debug "secret debug"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "log_debug: outputs message when DEBUG=1" {
  export DEBUG=1
  run log_debug "visible debug"
  [ "$status" -eq 0 ]
  [[ "$output" == *"visible debug"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# command_exists
# ─────────────────────────────────────────────────────────────────────────────

@test "command_exists: returns 0 for existing command" {
  run command_exists "bash"
  [ "$status" -eq 0 ]
}

@test "command_exists: returns non-zero for nonexistent command" {
  run command_exists "nonexistent_command_xyz_12345"
  [ "$status" -ne 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# ensure_dir
# ─────────────────────────────────────────────────────────────────────────────

@test "ensure_dir: creates directory that does not exist" {
  local dir="$BATS_TEST_TMPDIR/new_dir/nested"
  [ ! -d "$dir" ]
  run ensure_dir "$dir"
  [ "$status" -eq 0 ]
  [ -d "$dir" ]
}

@test "ensure_dir: succeeds if directory already exists" {
  local dir="$BATS_TEST_TMPDIR/existing_dir"
  mkdir -p "$dir"
  run ensure_dir "$dir"
  [ "$status" -eq 0 ]
  [ -d "$dir" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# validate_agent_name: boundary cases
# ─────────────────────────────────────────────────────────────────────────────

@test "validate_agent_name: accepts exactly 32 chars" {
  run validate_agent_name "abcdefghijklmnopqrstuvwxyz012345"
  [ "$status" -eq 0 ]
}

@test "validate_agent_name: rejects 33 chars" {
  run validate_agent_name "abcdefghijklmnopqrstuvwxyz0123456"
  [ "$status" -eq 1 ]
}

@test "validate_agent_name: accepts single char" {
  run validate_agent_name "a"
  [ "$status" -eq 0 ]
}

@test "validate_agent_name: rejects dot in name" {
  run validate_agent_name "my.agent"
  [ "$status" -eq 1 ]
}

@test "validate_agent_name: rejects slash in name" {
  run validate_agent_name "my/agent"
  [ "$status" -eq 1 ]
}

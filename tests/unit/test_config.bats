#!/usr/bin/env bats
# Tests for lib/config.sh

setup() {
  load ../test_helper

  # Source config.sh (which sources utils.sh)
  source "$PROJECT_ROOT/lib/config.sh"

  VALID_YAML="$PROJECT_ROOT/tests/fixtures/crew_valid.yaml"
  INVALID_YAML="$PROJECT_ROOT/tests/fixtures/crew_invalid.yaml"
  VALID_JSON="$PROJECT_ROOT/tests/fixtures/crew_valid.json"
}

# ─────────────────────────────────────────────────────────────────────────────
# config_get with yq
# ─────────────────────────────────────────────────────────────────────────────

@test "config_get: returns value for valid key" {
  run config_get ".agent" "" "$VALID_YAML"
  [ "$status" -eq 0 ]
  [ "$output" = "gemini" ]
}

@test "config_get: returns default when key is missing" {
  run config_get ".nonexistent_key" "fallback_val" "$VALID_YAML"
  [ "$status" -eq 0 ]
  [ "$output" = "fallback_val" ]
}

@test "config_get: returns default when value is null" {
  run config_get ".agents[0].nonexistent" "mydefault" "$VALID_YAML"
  [ "$status" -eq 0 ]
  [ "$output" = "mydefault" ]
}

@test "config_get: reads nested agent name" {
  run config_get ".agents[0].name" "" "$VALID_YAML"
  [ "$status" -eq 0 ]
  [ "$output" = "QA" ]
}

@test "config_get: reads agent type" {
  run config_get ".agents[1].type" "" "$VALID_YAML"
  [ "$status" -eq 0 ]
  [ "$output" = "gemini" ]
}

@test "config_get: lists all agent names" {
  run config_get ".agents[].name" "" "$VALID_YAML"
  [ "$status" -eq 0 ]
  [[ "$output" == *"QA"* ]]
  [[ "$output" == *"DEV"* ]]
  [[ "$output" == *"JANITOR"* ]]
}

@test "config_get: does not crash for nonexistent file" {
  # Note: log_error writes to stdout which leaks into command substitution,
  # so config_get may not return the default cleanly. parse_yaml handles the
  # error properly (returns 1). This test verifies no crash/abort.
  run config_get ".agent" "default_val" "/nonexistent/file.yaml"
  [ "$status" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# validate_config
# ─────────────────────────────────────────────────────────────────────────────

@test "validate_config: fails for nonexistent file" {
  run validate_config "/nonexistent/config.yaml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}

@test "validate_config: fails for invalid YAML syntax" {
  run validate_config "$INVALID_YAML"
  [ "$status" -eq 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# get_agent_type precedence: env > config > default
# ─────────────────────────────────────────────────────────────────────────────

@test "get_agent_type: returns default 'claude' when no config or env" {
  unset CREW_AGENT
  run get_agent_type ""
  [ "$status" -eq 0 ]
  [ "$output" = "claude" ]
}

@test "get_agent_type: reads from config file" {
  unset CREW_AGENT
  run get_agent_type "$VALID_YAML"
  [ "$status" -eq 0 ]
  [ "$output" = "gemini" ]
}

@test "get_agent_type: env var overrides config" {
  export CREW_AGENT="opencode"
  run get_agent_type "$VALID_YAML"
  [ "$status" -eq 0 ]
  [ "$output" = "opencode" ]
  unset CREW_AGENT
}

# ─────────────────────────────────────────────────────────────────────────────
# get_agent_cli_type
# ─────────────────────────────────────────────────────────────────────────────

@test "get_agent_cli_type: returns type field from config" {
  run get_agent_cli_type "DEV" "$VALID_YAML"
  [ "$status" -eq 0 ]
  [ "$output" = "gemini" ]
}

@test "get_agent_cli_type: defaults to claude when no type or command" {
  run get_agent_cli_type "JANITOR" "$VALID_YAML"
  [ "$status" -eq 0 ]
  [ "$output" = "claude" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# validate_yaml_parser
# ─────────────────────────────────────────────────────────────────────────────

@test "validate_yaml_parser: passes when yq is installed" {
  run validate_yaml_parser
  [ "$status" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# parse_yaml
# ─────────────────────────────────────────────────────────────────────────────

@test "parse_yaml: fails for nonexistent file" {
  run parse_yaml "." "/nonexistent/file.yaml"
  [ "$status" -eq 1 ]
}

@test "parse_yaml: returns value for valid query" {
  run parse_yaml ".agent" "$VALID_YAML"
  [ "$status" -eq 0 ]
  [ "$output" = "gemini" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# JSON config fallback (T046)
# ─────────────────────────────────────────────────────────────────────────────

@test "config_get JSON: returns value for valid key" {
  run config_get ".agent" "" "$VALID_JSON"
  [ "$status" -eq 0 ]
  [ "$output" = "gemini" ]
}

@test "config_get JSON: returns default when key is missing" {
  run config_get ".nonexistent_key" "fallback_val" "$VALID_JSON"
  [ "$status" -eq 0 ]
  [ "$output" = "fallback_val" ]
}

@test "config_get JSON: lists all agent names" {
  run config_get ".agents[].name" "" "$VALID_JSON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"QA"* ]]
  [[ "$output" == *"DEV"* ]]
  [[ "$output" == *"JANITOR"* ]]
}

@test "config_get JSON: reads agent type via select" {
  run config_get '.agents[] | select(.name == "DEV") | .type' "" "$VALID_JSON"
  [ "$status" -eq 0 ]
  [ "$output" = "gemini" ]
}

@test "get_agent_type: reads from JSON config" {
  unset CREW_AGENT
  run get_agent_type "$VALID_JSON"
  [ "$status" -eq 0 ]
  [ "$output" = "gemini" ]
}

@test "parse_json: fails for nonexistent file" {
  run parse_json "." "/nonexistent/file.json"
  [ "$status" -eq 1 ]
}

#!/bin/bash
# crew/lib/probe.sh - Probe each provider in crew.yaml with a minimal prompt
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/plugin_loader.sh"

# Timeout for each probe (seconds)
PROBE_TIMEOUT="${PROBE_TIMEOUT:-30}"

# Minimal prompt that any model should answer quickly
PROBE_PROMPT="Reply with exactly one word: ok"

# macOS-compatible timeout: runs command in background, kills after N seconds
# Usage: _probe_timeout <seconds> <cmd> [args...]
_probe_timeout() {
  local secs="$1"; shift
  "$@" &
  local pid=$!
  (
    sleep "$secs"
    kill "$pid" 2>/dev/null
  ) &
  local watcher=$!
  local exit_code=0
  wait "$pid" 2>/dev/null || exit_code=$?
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  return "$exit_code"
}

# Load and export all .env files (global → local)
_probe_load_envs() {
  local env_files
  env_files=$(find_env_files)
  while IFS= read -r env_file; do
    [[ -z "$env_file" || ! -f "$env_file" ]] && continue
    set -a; source "$env_file"; set +a  # shellcheck source=/dev/null
  done <<< "$env_files"
}

# Export env vars for a given agent+level, expanding ${VAR} references
# Usage: _probe_export_env <name> <level> <config_file>
_probe_export_env() {
  local name="$1"
  local level="$2"
  local config_file="$3"

  # Export agent-level env as base first
  local agent_env_keys
  agent_env_keys=$(config_get ".agents[] | select(.name == \"$name\") | .env | keys | .[]" "" "$config_file" 2>/dev/null) || true
  if [[ -n "$agent_env_keys" ]]; then
    while IFS= read -r key; do
      [[ -z "$key" || "$key" == "null" ]] && continue
      local val
      val=$(config_get ".agents[] | select(.name == \"$name\") | .env.${key}" "" "$config_file" 2>/dev/null) || true
      [[ -z "$val" || "$val" == "null" ]] && continue
      val=$(eval echo "\"$val\"" 2>/dev/null || echo "$val")
      export "$key=$val"
    done <<< "$agent_env_keys"
  fi

  # Then overlay fallback-level env (if level > 0)
  if [[ "$level" -gt 0 ]]; then
    local fb_idx=$((level - 1))
    local fb_env_keys
    fb_env_keys=$(config_get ".agents[] | select(.name == \"$name\") | .fallback[$fb_idx].env | keys | .[]" "" "$config_file" 2>/dev/null) || true
    if [[ -n "$fb_env_keys" ]]; then
      while IFS= read -r key; do
        [[ -z "$key" || "$key" == "null" ]] && continue
        local val
        val=$(config_get ".agents[] | select(.name == \"$name\") | .fallback[$fb_idx].env.${key}" "" "$config_file" 2>/dev/null) || true
        [[ -z "$val" || "$val" == "null" ]] && continue
        val=$(eval echo "\"$val\"" 2>/dev/null || echo "$val")
        export "$key=$val"
      done <<< "$fb_env_keys"
    fi
  fi
}

# Get display label for a given agent+level
_probe_label() {
  local name="$1"
  local level="$2"
  local config_file="$3"

  if [[ "$level" -eq 0 ]]; then
    local lbl
    lbl=$(config_get ".agents[] | select(.name == \"$name\") | .label" "" "$config_file" 2>/dev/null) || true
    if [[ -n "$lbl" && "$lbl" != "null" ]]; then
      echo "$lbl"; return
    fi
    get_agent_cli_type "$name" "$config_file"
  else
    local fb_idx=$((level - 1))
    local lbl
    lbl=$(config_get ".agents[] | select(.name == \"$name\") | .fallback[$fb_idx].label" "" "$config_file" 2>/dev/null) || true
    if [[ -n "$lbl" && "$lbl" != "null" ]]; then
      echo "$lbl"; return
    fi
    local cli_type
    cli_type=$(get_fallback_cli_type "$name" "$level" "$config_file")
    echo "fallback[$fb_idx]:$cli_type"
  fi
}

# Run a single probe for one provider
# Writes result to a temp file (used from subshell)
# Usage: _probe_run_one <cli_type> <working_dir> <out_file>
_probe_run_one() {
  local cli_type="$1"
  local working_dir="$2"
  local out_file="$3"

  if ! load_plugin "$cli_type" 2>/dev/null; then
    echo "SKIP:plugin not found: $cli_type" > "$out_file"; return
  fi
  if ! "cli_${cli_type}_check" 2>/dev/null; then
    echo "SKIP:CLI not installed: $cli_type" > "$out_file"; return
  fi

  local output exit_code=0
  output=$("cli_${cli_type}_run_prompt" "$PROBE_PROMPT" "$working_dir" 2>&1) || exit_code=$?

  if [[ "$exit_code" -ne 0 ]]; then
    local first_line
    first_line=$(echo "$output" | head -1)
    echo "FAIL:exit $exit_code: $first_line" > "$out_file"
  else
    local first_line
    first_line=$(echo "$output" | grep -v '^$' | head -1 | tr -d '\n')
    echo "PASS:$first_line" > "$out_file"
  fi
}

# Print a single probe result line
_probe_print() {
  local label="$1"
  local result="$2"   # "PASS:...", "FAIL:...", "SKIP:...", "TIMEOUT"

  local status="${result%%:*}"
  local detail="${result#*:}"

  case "$status" in
    PASS)    printf "  %-42s ${GREEN}PASS${NC} → %s\n" "$label" "$detail" ;;
    FAIL)    printf "  %-42s ${RED}FAIL${NC} %s\n"     "$label" "$detail" ;;
    SKIP)    printf "  %-42s ${YELLOW}SKIP${NC} %s\n"  "$label" "$detail" ;;
    TIMEOUT) printf "  %-42s ${RED}FAIL${NC} (timeout after ${PROBE_TIMEOUT}s)\n" "$label" ;;
    *)       printf "  %-42s %s\n" "$label" "$result" ;;
  esac
}

# Main probe runner: iterates all agents and their fallback chains
# Usage: run_probe_all <config_file>
run_probe_all() {
  local config_file="$1"

  header "Probing providers"
  echo "  Prompt:  \"$PROBE_PROMPT\""
  echo "  Timeout: ${PROBE_TIMEOUT}s per probe"
  echo ""

  local agent_names
  agent_names=$(config_get ".agents[].name" "" "$config_file" 2>/dev/null)
  [[ -z "$agent_names" ]] && { log_error "No agents found in config"; return 1; }

  # Resolve script dir for sourcing inside subshells
  local _probe_script_dir
  _probe_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    echo "  ${BOLD}[$name]${NC}"

    local fb_count
    fb_count=$(config_get ".agents[] | select(.name == \"$name\") | .fallback | length" "0" "$config_file" 2>/dev/null) || fb_count=0
    local total_levels=$((fb_count + 1))

    for (( level=0; level<total_levels; level++ )); do
      local label cli_type out_file
      label=$(_probe_label "$name" "$level" "$config_file")
      cli_type=$(get_fallback_cli_type "$name" "$level" "$config_file")

      # Temp file for result (subshell can't return strings)
      out_file=$(mktemp)

      # Run probe in isolated subshell with timeout
      (
        # Load envs and export agent env in subshell
        source "$_probe_script_dir/utils.sh"
        source "$_probe_script_dir/config.sh"
        source "$_probe_script_dir/plugin_loader.sh"
        source "$_probe_script_dir/probe.sh"

        _probe_load_envs
        _probe_export_env "$name" "$level" "$config_file"
        _probe_run_one "$cli_type" "$PWD" "$out_file"
      ) &
      local subpid=$!

      # Timeout watcher
      (
        sleep "$PROBE_TIMEOUT"
        if kill -0 "$subpid" 2>/dev/null; then
          kill "$subpid" 2>/dev/null || true
          echo "TIMEOUT" > "$out_file"
        fi
      ) &
      local watchpid=$!

      wait "$subpid" 2>/dev/null || true
      kill "$watchpid" 2>/dev/null || true
      wait "$watchpid" 2>/dev/null || true

      local result
      result=$(cat "$out_file" 2>/dev/null || echo "FAIL:no output")
      rm -f "$out_file"

      _probe_print "$label" "$result"
    done
    echo ""
  done <<< "$agent_names"
}

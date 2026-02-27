#!/bin/bash
# crew/lib/plugin_loader.sh - CLI plugin discovery, loading, and dispatch
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

# Track loaded plugins as colon-delimited string (Bash 3.2 compatible)
_LOADED_PLUGINS=""

# Check if a plugin is already loaded
_is_plugin_loaded() {
  local name="$1"
  [[ ":${_LOADED_PLUGINS}:" == *":${name}:"* ]]
}

# Mark a plugin as loaded
_mark_plugin_loaded() {
  local name="$1"
  if [[ -z "$_LOADED_PLUGINS" ]]; then
    _LOADED_PLUGINS="$name"
  else
    _LOADED_PLUGINS="${_LOADED_PLUGINS}:${name}"
  fi
}

# Get plugin search paths in priority order
# Usage: _plugin_search_paths [mode]
#   mode: "crew" (default) or "design"
_plugin_search_paths() {
  local mode="${1:-crew}"
  local paths=()

  # 1. Project-local (mode-specific)
  case "$mode" in
    design)
      [[ -d ".design/cli.d" ]] && paths+=(".design/cli.d")
      ;;
    *)
      [[ -d ".crew/cli.d" ]] && paths+=(".crew/cli.d")
      ;;
  esac

  # 2. User-global
  [[ -d "$HOME/.crew/cli.d" ]] && paths+=("$HOME/.crew/cli.d")

  # 3. Built-in (crew install dir)
  local crew_home
  crew_home=$(get_crew_home)
  [[ -d "$crew_home/plugins" ]] && paths+=("$crew_home/plugins")

  printf '%s\n' "${paths[@]}"
}

# Load a plugin by name. Idempotent.
# Usage: load_plugin <name> [mode]
load_plugin() {
  local name="$1"
  local mode="${2:-crew}"

  # Already loaded?
  if _is_plugin_loaded "$name"; then
    return 0
  fi

  # Validate plugin name
  if ! echo "$name" | grep -qE '^[a-z0-9_-]+$'; then
    log_error "Invalid plugin name: $name"
    return 1
  fi

  # Search for plugin file
  local search_paths
  search_paths=$(_plugin_search_paths "$mode")

  while IFS= read -r dir; do
    [[ -z "$dir" ]] && continue
    local plugin_file="$dir/${name}.sh"
    if [[ -f "$plugin_file" ]]; then
      # Reject world-writable plugin files to prevent privilege escalation
      if [[ "$(uname)" == "Darwin" ]]; then
        local perms
        perms=$(stat -f '%Lp' "$plugin_file" 2>/dev/null || echo "")
      else
        local perms
        perms=$(stat -c '%a' "$plugin_file" 2>/dev/null || echo "")
      fi
      if [[ -n "$perms" ]] && [[ "${perms: -1}" =~ [2367] ]]; then
        log_error "Plugin file is world-writable (mode $perms), refusing to load: $plugin_file"
        return 1
      fi

      log_debug "Loading plugin: $name from $plugin_file"
      # shellcheck source=/dev/null
      source "$plugin_file"

      # Validate required functions
      if ! type "cli_${name}_check" > /dev/null 2>&1; then
        log_error "Plugin '$name' missing required function: cli_${name}_check"
        return 1
      fi
      if ! type "cli_${name}_run" > /dev/null 2>&1; then
        log_error "Plugin '$name' missing required function: cli_${name}_run"
        return 1
      fi

      _mark_plugin_loaded "$name"
      return 0
    fi
  done <<< "$search_paths"

  log_error "Plugin not found: $name"
  return 1
}

# Check if a CLI type is available (installed)
# Usage: plugin_check <name> [mode]
plugin_check() {
  local name="$1"
  local mode="${2:-crew}"
  load_plugin "$name" "$mode" || return 1
  "cli_${name}_check"
}

# Run a CLI plugin with a prompt file (crew mode)
# Usage: plugin_run <name> <prompt_file> <working_dir> [mode]
plugin_run() {
  local name="$1"
  local prompt_file="$2"
  local working_dir="${3:-$PWD}"
  local mode="${4:-crew}"

  # Validate working_dir to prevent path traversal
  if [[ "$working_dir" != "$PWD" ]]; then
    validate_file_path "$working_dir" || { log_error "Invalid working_dir: $working_dir"; return 1; }
  fi
  if [[ ! -d "$working_dir" ]]; then
    log_error "working_dir does not exist: $working_dir"
    return 1
  fi

  load_plugin "$name" "$mode" || return 1

  if ! "cli_${name}_check"; then
    log_error "$name CLI not found."
    if type "cli_${name}_install_hint" > /dev/null 2>&1; then
      "cli_${name}_install_hint"
    fi
    return 1
  fi

  # Optional pre-run hook
  if type "cli_${name}_pre_run" > /dev/null 2>&1; then
    "cli_${name}_pre_run"
  fi

  "cli_${name}_run" "$prompt_file" "$working_dir"
}

# Run a CLI plugin with a prompt string (design mode)
# Usage: plugin_run_prompt <name> <prompt> <working_dir> [mode]
plugin_run_prompt() {
  local name="$1"
  local prompt="$2"
  local working_dir="${3:-$PWD}"
  local mode="${4:-design}"

  # Validate working_dir to prevent path traversal
  if [[ "$working_dir" != "$PWD" ]]; then
    validate_file_path "$working_dir" || { log_error "Invalid working_dir: $working_dir"; return 1; }
  fi
  if [[ ! -d "$working_dir" ]]; then
    log_error "working_dir does not exist: $working_dir"
    return 1
  fi

  load_plugin "$name" "$mode" || return 1

  if ! "cli_${name}_check"; then
    log_error "$name CLI not found."
    if type "cli_${name}_install_hint" > /dev/null 2>&1; then
      "cli_${name}_install_hint"
    fi
    return 1
  fi

  # Optional pre-run hook
  if type "cli_${name}_pre_run" > /dev/null 2>&1; then
    "cli_${name}_pre_run"
  fi

  if type "cli_${name}_run_prompt" > /dev/null 2>&1; then
    "cli_${name}_run_prompt" "$prompt" "$working_dir"
  else
    # Fallback: write to temp file and use _run
    local tmp_file old_umask
    old_umask=$(umask)
    umask 077
    tmp_file=$(mktemp)
    umask "$old_umask"
    echo "$prompt" > "$tmp_file"
    "cli_${name}_run" "$tmp_file" "$working_dir"
    local rc=$?
    rm -f "$tmp_file"
    return $rc
  fi
}

# List all discoverable plugins with install status
# Usage: list_plugins [mode]
list_plugins() {
  local mode="${1:-crew}"
  local found=""
  local search_paths
  search_paths=$(_plugin_search_paths "$mode")

  while IFS= read -r dir; do
    [[ -z "$dir" ]] && continue
    for plugin_file in "$dir"/*.sh; do
      [[ -f "$plugin_file" ]] || continue
      local name
      name=$(basename "$plugin_file" .sh)
      # Skip duplicates (higher-priority already found)
      if [[ ":${found}:" == *":${name}:"* ]]; then
        continue
      fi
      if [[ -z "$found" ]]; then
        found="$name"
      else
        found="${found}:${name}"
      fi
    done
  done <<< "$search_paths"

  echo "Available CLI plugins:"
  IFS=: read -ra plugin_list <<< "$found"
  for name in "${plugin_list[@]}"; do
    [[ -z "$name" ]] && continue
    load_plugin "$name" "$mode" 2>/dev/null || continue
    if "cli_${name}_check" 2>/dev/null; then
      echo -e "  ${GREEN}✓${NC} $name"
    else
      echo -e "  ${RED}✗${NC} $name (not installed)"
    fi
  done
}

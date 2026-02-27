#!/bin/bash
# crew/lib/config.sh - Configuration parsing
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

# Default config file names
CREW_CONFIG_NAME="crew.yaml"
export DESIGN_CONFIG_NAME="design.yaml"

# Defense-in-depth: reject agent names with yq-unsafe characters before interpolation.
# validate_agent_name() already enforces [A-Za-z0-9_-] at CLI entry points;
# this guard prevents injection if a caller bypasses upstream validation.
_assert_safe_yq_name() {
  local name="$1"
  if [[ ! "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
    log_error "Unsafe agent name for yq query: $name"
    return 1
  fi
}

# Find config file in current or parent directories
# Priority: .yaml > .json
find_config() {
  local config_name="${1:-$CREW_CONFIG_NAME}"
  local dir="$PWD"

  # Derive JSON name from YAML name (crew.yaml → crew.json)
  local json_name="${config_name%.yaml}.json"

  while [[ "$dir" != "/" ]]; do
    for subdir in .crew .design; do
      if [[ -f "$dir/$subdir/$config_name" ]]; then
        echo "$dir/$subdir/$config_name"
        return 0
      fi
      if [[ -f "$dir/$subdir/$json_name" ]]; then
        echo "$dir/$subdir/$json_name"
        return 0
      fi
    done
    dir="$(dirname "$dir")"
  done

  return 1
}

# Find all relevant .env files in parent or global directories.
# Returns list of absolute paths, from least-specific (global) to most-specific (local).
# Search order:
# 1. ~/.crew/.env
# 2. Parent .crew/.env or .design/.env (bottom-up discovery, reversed at output)
# 3. Local .crew/.env or .design/.env
find_env_files() {
  local files=()
  local dir="$PWD"

  # 1. Parent/Local search
  local parent_files=()
  while [[ "$dir" != "/" ]]; do
    for subdir in .crew .design; do
      if [[ -f "$dir/$subdir/.env" ]]; then
        parent_files+=("$dir/$subdir/.env")
      fi
    done
    dir="$(dirname "$dir")"
  done
  
  # Reverse parent_files so deepest (local) is last
  for (( i=${#parent_files[@]}-1; i>=0; i-- )); do
    files+=("${parent_files[i]}")
  done

  # 2. Global fallback (lowest priority, prepend if exists)
  if [[ -f "$HOME/.crew/.env" ]]; then
    # Only add if not already in the list (e.g. if HOME is a parent of PWD)
    local found=false
    for f in "${files[@]}"; do
      if [[ "$f" == "$HOME/.crew/.env" ]]; then
        found=true; break
      fi
    done
    if [[ "$found" == "false" ]]; then
      files=("$HOME/.crew/.env" "${files[@]}")
    fi
  fi

  for f in "${files[@]}"; do
    echo "$f"
  done
}

# Parse YAML config using yq (required dependency)
parse_yaml() {
  local query="$1"
  local config_file="$2"

  command -v yq >/dev/null 2>&1 || { echo ""; return 1; }

  if ! [[ -f "$config_file" ]]; then
    log_error "Config file not found: $config_file"
    return 1
  fi

  yq eval "$query" "$config_file" < /dev/null
}

# Parse JSON config using Python's built-in json module
# Supports a subset of yq-style queries:
#   .key             → simple top-level key
#   .key1.key2       → nested key access
#   .arr[].field     → iterate array, extract field
#   .arr[] | select(.name == "X") | .field  → filter + extract
#   .arr[] | select(.name == "X") | .sub[N].field  → nested array index
#   .obj | keys | .[]  → list object keys
#   .obj | length    → array/object length
parse_json() {
  local query="$1"
  local config_file="$2"

  command -v python3 >/dev/null 2>&1 || { echo ""; return 1; }

  if ! [[ -f "$config_file" ]]; then
    log_error "Config file not found: $config_file"
    return 1
  fi

  python3 -c "
import json, sys, re

sys.setrecursionlimit(100)

with open(sys.argv[2]) as f:
    data = json.load(f)

q = sys.argv[1]

def resolve(obj, path):
    for part in path.split('.'):
        if not part:
            continue
        m = re.match(r'(\w+)\[(\d+)\]', part)
        if m:
            obj = obj[m.group(1)][int(m.group(2))]
        elif isinstance(obj, dict):
            obj = obj.get(part)
        else:
            return None
        if obj is None:
            return None
    return obj

# Handle: .arr | length
if '| length' in q:
    base = q.split('|')[0].strip()
    val = resolve(data, base.lstrip('.'))
    print(len(val) if val else 0)
    sys.exit(0)

# Handle: .obj | keys | .[]
if '| keys |' in q:
    base = q.split('|')[0].strip()
    val = resolve(data, base.lstrip('.'))
    if isinstance(val, dict):
        for k in val:
            print(k)
    sys.exit(0)

# Handle: .arr[] | select(.name == \"X\") | .field
sel = re.match(r'^\.(\w+)\[\]\s*\|\s*select\(\.(\w+)\s*==\s*\"([^\"]*)\"\)\s*\|\s*\.(.+)$', q)
if sel:
    arr_name, sel_key, sel_val, field_path = sel.groups()
    arr = data.get(arr_name, [])
    for item in arr:
        if item.get(sel_key) == sel_val:
            val = resolve(item, field_path)
            if val is not None:
                print(val)
            else:
                print('null')
            sys.exit(0)
    print('null')
    sys.exit(0)

# Handle: .arr[].field
iter_match = re.match(r'^\.(\w+)\[\]\.(\w+)$', q)
if iter_match:
    arr_name, field = iter_match.groups()
    arr = data.get(arr_name, [])
    for item in arr:
        val = item.get(field)
        if val is not None:
            print(val)
    sys.exit(0)

# Handle: .key or .key1.key2
val = resolve(data, q.lstrip('.'))
if val is None:
    print('null')
elif isinstance(val, (list, dict)):
    print(json.dumps(val))
else:
    print(val)
" "$query" "$config_file"
}

# Validate config parser availability at startup
validate_yaml_parser() {
  if command_exists yq; then
    return 0
  fi

  log_error "yq is required but not installed"
  log_info "Install: brew install yq (macOS) or snap install yq (Linux)"
  log_info "Alternatively, use crew.json instead of crew.yaml (requires python3)"
  return 1
}

# Get config value with default
# Dispatches to yq (YAML) or python3 (JSON) based on file extension
config_get() {
  local query="$1"
  local default="$2"
  local config_file="$3"

  local value
  if [[ "$config_file" == *.json ]]; then
    value=$(parse_json "$query" "$config_file" 2>/dev/null)
  else
    value=$(parse_yaml "$query" "$config_file" 2>/dev/null)
  fi

  if [[ -z "$value" || "$value" == "null" ]]; then
    if [[ -n "$default" ]]; then
      log_debug "config_get: '$query' not found in $config_file, using default: $default"
    fi
    echo "$default"
  else
    echo "$value"
  fi
}

# Get agent type (with CREW_AGENT env override)
get_agent_type() {
  local config_file="$1"

  # Environment variable takes precedence
  # check: Invalid CREW_AGENT value|A-Za-z0-9_- charset required for CREW_AGENT
  if [[ -n "${CREW_AGENT:-}" ]]; then
    if ! printf '%s' "$CREW_AGENT" | grep -qE '^[A-Za-z0-9_-]+$'; then
      log_error "Invalid CREW_AGENT value: must match [A-Za-z0-9_-]+"
      return 1
    fi
    echo "$CREW_AGENT"
    return
  fi

  # Then config file
  if [[ -n "$config_file" && -f "$config_file" ]]; then
    local agent
    agent=$(config_get ".agent" "" "$config_file")
    if [[ -n "$agent" ]]; then
      echo "$agent"
      return
    fi
  fi

  # Default
  echo "claude"
}

# Get the effective CLI type for a crew agent
# Resolution: command > type > default "claude"
# Returns "command" sentinel if raw command override is present
# Usage: get_agent_cli_type <name> <config_file>
get_agent_cli_type() {
  local name="$1"
  local config_file="$2"
  _assert_safe_yq_name "$name" || return 1

  # Check for explicit command first (backward compat)
  local command
  command=$(config_get ".agents[] | select(.name == \"$name\") | .command" "" "$config_file")
  if [[ -n "$command" && "$command" != "null" ]]; then
    echo "command"
    return
  fi

  # Check for type field
  local agent_type
  agent_type=$(config_get ".agents[] | select(.name == \"$name\") | .type" "" "$config_file")
  if [[ -n "$agent_type" && "$agent_type" != "null" ]]; then
    echo "$agent_type"
    return
  fi

  # Default
  echo "claude"
}

# Get the effective CLI type for a fallback level
# Level 0 = agent level, Level N = fallback[N-1]
# Resolution: fallback.command > fallback.type > inherit agent type
# Usage: get_fallback_cli_type <name> <level> <config_file>
get_fallback_cli_type() {
  local name="$1"
  local level="$2"
  local config_file="$3"
  _assert_safe_yq_name "$name" || return 1

  if [[ "$level" -eq 0 ]]; then
    get_agent_cli_type "$name" "$config_file"
    return
  fi

  local fb_idx=$((level - 1))

  # Check fallback command override
  local fb_command
  fb_command=$(config_get ".agents[] | select(.name == \"$name\") | .fallback[$fb_idx].command" "" "$config_file")
  if [[ -n "$fb_command" && "$fb_command" != "null" ]]; then
    echo "command"
    return
  fi

  # Check fallback type override
  local fb_type
  fb_type=$(config_get ".agents[] | select(.name == \"$name\") | .fallback[$fb_idx].type" "" "$config_file")
  if [[ -n "$fb_type" && "$fb_type" != "null" ]]; then
    echo "$fb_type"
    return
  fi

  # Inherit from agent level
  get_agent_cli_type "$name" "$config_file"
}

# Get the raw command for a fallback level (when cli_type == "command")
# Usage: get_fallback_command <name> <level> <config_file>
get_fallback_command() {
  local name="$1"
  local level="$2"
  local config_file="$3"
  _assert_safe_yq_name "$name" || return 1

  if [[ "$level" -eq 0 ]]; then
    config_get ".agents[] | select(.name == \"$name\") | .command" "" "$config_file"
    return
  fi

  local fb_idx=$((level - 1))
  local fb_command
  fb_command=$(config_get ".agents[] | select(.name == \"$name\") | .fallback[$fb_idx].command" "" "$config_file")
  if [[ -n "$fb_command" && "$fb_command" != "null" ]]; then
    echo "$fb_command"
    return
  fi

  # Inherit from agent level
  config_get ".agents[] | select(.name == \"$name\") | .command" "" "$config_file"
}

# Check if a plugin file exists in any of the standard search locations.
# Searches: project-local cli.d/, user-global ~/.crew/cli.d/, built-in plugins/
# Usage: _plugin_file_exists <plugin_type> <config_file>
_plugin_file_exists() {
  local plugin_type="$1"
  local config_file="$2"
  local config_dir
  config_dir=$(dirname "$config_file")

  [[ -f "$config_dir/cli.d/${plugin_type}.sh" ]] && return 0
  [[ -f "$HOME/.crew/cli.d/${plugin_type}.sh" ]] && return 0

  local project_root="${PROJECT_ROOT:-}"
  if [[ -z "$project_root" && -n "${BASH_SOURCE[0]:-}" ]]; then
    project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd) 2>/dev/null || true
  fi
  [[ -n "$project_root" && -f "$project_root/plugins/${plugin_type}.sh" ]] && return 0

  return 1
}

# Validate a single plugin type string: format check + file existence.
# Prints error messages and returns 1 on failure.
# Usage: _validate_plugin_type <agent_name> <plugin_type> <config_file>
_validate_plugin_type() {
  local agent_name="$1"
  local plugin_type="$2"
  local config_file="$3"

  if [[ ! "$plugin_type" =~ ^[a-z][a-z0-9_]*$ ]]; then
    log_error "[$agent_name] Invalid plugin type format: $plugin_type (must be lowercase alphanumeric with underscores)"
    return 1
  fi
  if ! _plugin_file_exists "$plugin_type" "$config_file"; then
    log_error "[$agent_name] Unknown plugin type: $plugin_type (plugin file not found)"
    return 1
  fi
  return 0
}

# Validate a path field: reject absolute paths and path traversal.
# Usage: _validate_path_field <agent_name> <field_name> <value>
_validate_path_field() {
  local agent_name="$1"
  local field_name="$2"
  local value="$3"
  local has_error=false

  if [[ "$value" == /* ]]; then
    log_error "[$agent_name] Absolute paths not allowed in $field_name: $value"
    has_error=true
  fi
  if [[ "$value" == *".."* ]]; then
    log_error "[$agent_name] Path traversal not allowed in $field_name: $value"
    has_error=true
  fi
  $has_error && return 1
  return 0
}

# Validate per-agent fields for a single agent.
# Returns 0 if valid, 1 if any errors found.
# Usage: _validate_agent_fields <name> <config_file>
_validate_agent_fields() {
  local name="$1"
  local config_file="$2"
  local has_error=false

  local interval
  interval=$(config_get ".agents[] | select(.name == \"$name\") | .interval" "" "$config_file" 2>/dev/null)
  if [[ -n "$interval" && "$interval" != "null" ]]; then
    if ! echo "$interval" | grep -qE '^[0-9]+$' || [[ "$interval" -lt 1 ]]; then
      log_error "[$name] Invalid interval (must be positive integer >= 1): $interval"
      has_error=true
    fi
  fi

  local timeout
  timeout=$(config_get ".agents[] | select(.name == \"$name\") | .timeout" "" "$config_file" 2>/dev/null)
  if [[ -n "$timeout" && "$timeout" != "null" ]]; then
    if ! echo "$timeout" | grep -qE '^[0-9]+$' || [[ "$timeout" -lt 10 ]]; then
      log_error "[$name] Invalid timeout (must be integer >= 10): $timeout"
      has_error=true
    fi
  fi

  local env_keys
  env_keys=$(config_get ".agents[] | select(.name == \"$name\") | .env | keys | .[]" "" "$config_file" 2>/dev/null) || true
  if [[ -n "$env_keys" ]]; then
    while IFS= read -r key; do
      [[ -z "$key" ]] && continue
      if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        log_error "[$name] Invalid env var name (must start with letter/underscore): $key"
        has_error=true
      fi
    done <<< "$env_keys"
  fi

  local prompt_file
  prompt_file=$(config_get ".agents[] | select(.name == \"$name\") | .prompt" "" "$config_file" 2>/dev/null)
  if [[ -n "$prompt_file" && "$prompt_file" != "null" ]]; then
    _validate_path_field "$name" "prompt" "$prompt_file" || has_error=true
  fi

  local icon
  icon=$(config_get ".agents[] | select(.name == \"$name\") | .icon" "" "$config_file" 2>/dev/null)
  if [[ -n "$icon" && "$icon" != "null" ]]; then
    if [[ ${#icon} -gt 8 ]]; then
      log_error "[$name] Icon field too long (max 8 characters): $icon"
      has_error=true
    fi
    if [[ "$icon" =~ [[:cntrl:]] ]]; then
      log_error "[$name] Icon field contains control characters: $icon"
      has_error=true
    fi
  fi

  local working_dir
  working_dir=$(config_get ".agents[] | select(.name == \"$name\") | .working_dir" "" "$config_file" 2>/dev/null)
  if [[ -n "$working_dir" && "$working_dir" != "null" ]]; then
    _validate_path_field "$name" "working_dir" "$working_dir" || has_error=true
  fi

  local max_restarts
  max_restarts=$(config_get ".agents[] | select(.name == \"$name\") | .max_restarts" "" "$config_file" 2>/dev/null)
  if [[ -n "$max_restarts" && "$max_restarts" != "null" ]]; then
    if ! echo "$max_restarts" | grep -qE '^[0-9]+$' || [[ "$max_restarts" -gt 100 ]]; then
      log_error "[$name] Invalid max_restarts (must be integer <= 100): $max_restarts"
      has_error=true
    fi
  fi

  local fallback_types
  fallback_types=$(config_get ".agents[] | select(.name == \"$name\") | .fallback[].type" "" "$config_file" 2>/dev/null) || true
  if [[ -n "$fallback_types" ]]; then
    while IFS= read -r ft; do
      [[ -z "$ft" || "$ft" == "null" ]] && continue
      [[ "$ft" == "command" ]] && continue
      _validate_plugin_type "$name" "$ft" "$config_file" || has_error=true
    done <<< "$fallback_types"
  fi

  $has_error && return 1
  return 0
}

# Validate config file
validate_config() {
  local config_file="$1"

  if ! [[ -f "$config_file" ]]; then
    log_error "Config file not found: $config_file"
    return 1
  fi

  if [[ "$config_file" == *.json ]]; then
    if ! command_exists python3; then
      log_error "python3 is required to parse JSON config"
      return 1
    fi
  else
    validate_yaml_parser || return 1
  fi

  if [[ "$config_file" == *"'"* || "$config_file" == *'"'* || "$config_file" == *'$'* || "$config_file" == *'`'* || "$config_file" == *$'\n'* ]]; then
    log_error "Config filename contains unsafe characters: $config_file"
    return 1
  fi

  if [[ "$config_file" == *.json ]]; then
    if ! python3 -c "import json, sys; json.load(open(sys.argv[1]))" "$config_file" 2>/dev/null; then
      log_error "Invalid JSON syntax in: $config_file"
      return 1
    fi
  else
    if grep -qE '!![a-zA-Z]' "$config_file" 2>/dev/null; then
      log_error "YAML contains type tags (!! syntax) which are not allowed: $config_file"
      log_info "Remove any !!python, !!ruby, or other YAML type tags"
      return 1
    fi
    if ! parse_yaml "." "$config_file" > /dev/null 2>&1; then
      log_error "Invalid YAML syntax in: $config_file"
      log_info "Verify indentation (use spaces, not tabs) and check for special characters"
      return 1
    fi
  fi

  local has_error=false

  local project_name
  project_name=$(config_get ".project" "" "$config_file" 2>/dev/null)
  if [[ -n "$project_name" && "$project_name" != "null" ]]; then
    if [[ ! "$project_name" =~ ^[A-Za-z0-9_.\ -]+$ ]]; then
      log_error "Invalid project name (only alphanumeric, dots, hyphens, underscores, spaces allowed): $project_name"
      has_error=true
    fi
  fi

  local check_interval
  check_interval=$(config_get ".check_interval" "" "$config_file" 2>/dev/null)
  if [[ -n "$check_interval" && "$check_interval" != "null" ]]; then
    if ! echo "$check_interval" | grep -qE '^[0-9]+$' || [[ "$check_interval" -lt 1 ]]; then
      log_error "Invalid check_interval (must be positive integer): $check_interval"
      has_error=true
    fi
    if [[ "$check_interval" -gt 3600 ]]; then
      log_error "Invalid check_interval (must be <= 3600): $check_interval"
      has_error=true
    fi
  fi

  local agents
  agents=$(config_get ".agents[].name" "" "$config_file" 2>/dev/null)

  if [[ -n "$agents" ]]; then
    local seen_names=""
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      if echo "$seen_names" | grep -qxF "$name"; then
        log_error "Duplicate agent name: $name"
        has_error=true
      fi
      seen_names="${seen_names}${seen_names:+$'\n'}${name}"
    done <<< "$agents"
  fi

  if [[ -n "$agents" ]]; then
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      _assert_safe_yq_name "$name" || { has_error=true; continue; }
      _validate_agent_fields "$name" "$config_file" || has_error=true

      # Validate agent CLI type resolves to a loadable plugin
      local cli_type
      if type load_plugin &>/dev/null; then
        cli_type=$(get_agent_cli_type "$name" "$config_file")
        if [[ "$cli_type" != "command" ]]; then
          if ! load_plugin "$cli_type" 2>/dev/null; then
            log_error "[$name] Unknown CLI type: $cli_type"
            has_error=true
          fi
        fi
      else
        cli_type=$(config_get ".agents[] | select(.name == \"$name\") | .type" "" "$config_file" 2>/dev/null) || true
        if [[ -n "$cli_type" && "$cli_type" != "null" && "$cli_type" != "command" ]]; then
          _validate_plugin_type "$name" "$cli_type" "$config_file" || has_error=true
        fi
      fi
    done <<< "$agents"
  fi

  if $has_error; then
    return 1
  fi

  log_ok "Config valid: $config_file"
  return 0
}

# Pre-flight validation before starting agents
# Checks prompt files exist and CLI tools are installed
# Usage: validate_crew_preflight <config_file> [agent_names...]
validate_crew_preflight() {
  local config_file="$1"
  shift
  local requested_agents=("$@")

  local agents
  if [[ ${#requested_agents[@]} -gt 0 ]]; then
    agents=$(printf '%s\n' "${requested_agents[@]}")
  else
    agents=$(config_get ".agents[].name" "" "$config_file" 2>/dev/null)
  fi

  [[ -z "$agents" ]] && return 0

  local errors=0
  local crew_dir=".crew"

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    _assert_safe_yq_name "$name" || { errors=$((errors + 1)); continue; }

    # Check prompt file is defined
    local prompt_file
    prompt_file=$(config_get ".agents[] | select(.name == \"$name\") | .prompt" "" "$config_file")
    if [[ -z "$prompt_file" || "$prompt_file" == "null" ]]; then
      log_error "[$name] No prompt file defined in config"
      errors=$((errors + 1))
      continue
    fi

    # Check prompt file exists on disk
    if [[ ! -f "$crew_dir/$prompt_file" ]]; then
      log_error "[$name] Prompt file not found: $crew_dir/$prompt_file"
      errors=$((errors + 1))
    fi

    # BUG-QA-086: Validate prompt file extension
    local ext="${prompt_file##*.}"
    if [[ "$ext" != "md" && "$ext" != "txt" ]]; then
      log_error "[$name] Prompt file must have .md or .txt extension: $prompt_file"
      errors=$((errors + 1))
    fi

    # Check CLI type is installed
    local cli_type
    cli_type=$(get_agent_cli_type "$name" "$config_file")
    if [[ "$cli_type" != "command" ]]; then
      if ! load_plugin "$cli_type" 2>/dev/null; then
        log_error "[$name] Unknown CLI plugin: $cli_type"
        errors=$((errors + 1))
      elif ! "cli_${cli_type}_check" 2>/dev/null; then
        log_error "[$name] CLI not installed: $cli_type"
        if type "cli_${cli_type}_install_hint" > /dev/null 2>&1; then
          "cli_${cli_type}_install_hint"
        fi
        errors=$((errors + 1))
      fi
    fi
  done <<< "$agents"

  if [[ "$errors" -gt 0 ]]; then
    log_error "Pre-flight check failed: $errors error(s). Fix config and retry."
    return 1
  fi

  return 0
}

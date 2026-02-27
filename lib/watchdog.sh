#!/bin/bash
# crew/lib/watchdog.sh - Agent lifecycle management, health monitoring, and auto-restart.
#
# PID Management:
#   PID files store "PID LSTART" format (process birth timestamp from ps -o lstart=).
#   This mitigates TOCTOU race conditions where the OS reuses a PID for a different
#   process. Locking uses mkdir (atomic on all POSIX systems, no flock dependency).
#
# Fallback Chain:
#   Each agent has a primary CLI type and optional fallback levels defined in crew.yaml.
#   When max_restarts is exhausted at one level, the agent advances to the next fallback
#   (e.g., claude → gemini → aider). Each level has its own env vars, timeout, and
#   max_restarts. The chain terminates with an "exhausted" marker file, preventing the
#   watchdog from attempting further restarts.
#
# Timeout:
#   A background "sleep N && kill" watchdog runs alongside the agent process. On timeout,
#   it writes a marker file and sends SIGTERM. The main loop detects the marker and
#   reports exit code 124 (matching coreutils timeout convention).
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/plugin_loader.sh"

# BUG-QA-055: Defense-in-depth path sanitization for agent file paths.
# Ensures constructed paths don't escape the expected base directory.
# validate_agent_name already prevents traversal chars, but this guards against bypass.
_safe_agent_file() {
  local base_dir="$1"
  local name="$2"
  local suffix="$3"
  local path="$base_dir/${name}${suffix}"
  # Reject if path contains .. (traversal attempt)
  if [[ "$path" == *".."* ]]; then
    log_error "Path traversal detected in agent file path: $path"
    return 1
  fi
  echo "$path"
}

# Safe environment variable expansion without eval
# Expands ${VAR_NAME} and $VAR references using envsubst or pure-Bash fallback
# Does NOT execute subshells, backticks, or any command substitution
_safe_expand_env() {
  local input="$1"

  # BUG-QA-079: Reject command substitution patterns before expansion
  # This prevents $(), backticks, and other shell injection attempts
  if printf '%s' "$input" | grep -qE '\$\(|`|[\\]\$'; then
    log_warn "Rejecting unsafe characters in env value: command substitution not allowed"
    # Return the input literally - no expansion at all for safety
    printf '%s' "$input"
    return 0
  fi

  # Prefer envsubst (part of GNU gettext)
  if command_exists envsubst; then
    printf '%s' "$input" | envsubst
    return 0
  fi

  # Pure Bash fallback: expand ${VAR_NAME} patterns via indirect reference
  local result="$input"
  local var_refs
  var_refs=$(printf '%s' "$result" | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' || true)

  if [[ -n "$var_refs" ]]; then
    while IFS= read -r match; do
      [[ -z "$match" ]] && continue
      local var_name="${match#\$\{}"
      var_name="${var_name%\}}"
      local var_value="${!var_name:-}"
      result="${result//"$match"/$var_value}"
    done <<< "$var_refs"
  fi

  printf '%s' "$result"
}

# Default values
DEFAULT_CHECK_INTERVAL=30
DEFAULT_TIMEOUT=0  # 0 = no timeout; set per-agent in crew.yaml
DEFAULT_RESTART_DELAY=5
DEFAULT_MAX_RESTARTS=5
MAX_BACKOFF_DELAY=300
GRACEFUL_SHUTDOWN_TIMEOUT=10
MAX_LOG_SIZE=10485760  # 10MB

# Progress watchdog defaults (T049)
DEFAULT_WD_CHECK_INTERVAL=900    # 15min between progress checks
DEFAULT_WD_IDLE_TIMEOUT=1800     # 30min no progress → SUSPECT
DEFAULT_WD_ON_STUCK="notify"     # Action when stuck: fallback|restart|notify|stop
MAX_AI_JUDGE_INTERVAL=3600       # Max 1 AI judge call per agent per hour

# Read PID from a PID file (handles both legacy "PID" and new "PID LSTART" formats).
# Only returns the PID portion; callers needing birth time should use _verify_pid_owner.
_read_pid() {
  local pid_file="$1"
  [[ -f "$pid_file" ]] || return 1
  # First field is always the PID
  awk '{print $1; exit}' "$pid_file"
}

# Write PID file with process birth time for TOCTOU mitigation.
# Format: "PID LSTART" where LSTART is from ps -p PID -o lstart=
_write_pid() {
  local pid="$1"
  local pid_file="$2"
  local lstart
  lstart=$(ps -p "$pid" -o lstart= 2>/dev/null || echo "unknown")
  echo "$pid $lstart" > "$pid_file"
}

# Verify a PID file's process is genuinely ours (not a recycled PID).
# Compares stored lstart with the actual process lstart. This prevents the
# scenario where an agent dies, its PID is reused by an unrelated process,
# and crew mistakenly reports the agent as "running". Falls back to kill-0
# check for legacy PID files that lack lstart data.
_verify_pid_owner() {
  local pid_file="$1"
  [[ -f "$pid_file" ]] || return 1

  local stored
  stored=$(cat "$pid_file")
  local pid="${stored%% *}"
  local stored_lstart="${stored#* }"

  # BUG-QA-091: Validate PID is numeric
  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  # Process must be alive
  kill -0 "$pid" 2>/dev/null || return 1

  # If no lstart stored (legacy format), fall back to kill-0-only check
  if [[ "$stored_lstart" == "$pid" || "$stored_lstart" == "unknown" ]]; then
    return 0
  fi

  # BUG-QA-092: Validate lstart format before comparison
  # Expected format: "Thu Feb 27 10:30:45 2026" or locale-dependent
  if [[ -z "$stored_lstart" ]]; then
    return 1
  fi

  # Compare actual process birth time with stored birth time
  local actual_lstart
  actual_lstart=$(ps -p "$pid" -o lstart= 2>/dev/null || echo "")

  # Validate ps output format
  if [[ -z "$actual_lstart" ]]; then
    return 1
  fi

  [[ "$actual_lstart" == "$stored_lstart" ]]
}

# Rotate log file if it exceeds MAX_LOG_SIZE (atomic operation)
rotate_log_if_needed() {
  local log_file="$1"
  [[ ! -f "$log_file" ]] && return 0

  # BUG-QA-087: Use atomic check-and-rotate with locking to prevent race conditions
  local lock_file="${log_file}.lock"
  local size
  local rotated
  local result=0

  # Try to acquire lock atomically
  if ! mkdir "$lock_file" 2>/dev/null; then
    # Another process is rotating, skip this round
    return 0
  fi

  # Re-check size after acquiring lock (another process may have rotated)
  size=$(stat -f%z "$log_file" 2>/dev/null || stat -c%s "$log_file" 2>/dev/null || echo 0)

  if [[ "$size" -gt "$MAX_LOG_SIZE" ]]; then
    rotated="${log_file}.$(date +%Y%m%d%H%M%S).bak"
    mv "$log_file" "$rotated" || result=$?
    echo "[log] Rotated to $rotated (was ${size} bytes)" > "$log_file"
  fi

  # Always release lock
  rm -rf "$lock_file"

  return $result
}

# Export per-agent env vars from config
# Usage: export_agent_env <name> <config_file>
export_agent_env() {
  local name="$1"
  local config_file="$2"

  # Load .crew/.env if it exists
  # BUG-QA-100: Safe line-by-line parser instead of `source` to prevent command injection.
  # Only accepts KEY=VALUE lines where KEY is a valid env var name and VALUE does not
  # contain command substitution ($(), backticks), function definitions, or semicolons.
  if [[ -f ".crew/.env" ]]; then
    local _env_line _env_key _env_val
    while IFS= read -r _env_line || [[ -n "$_env_line" ]]; do
      # Skip comments and blank lines
      [[ -z "$_env_line" || "$_env_line" == \#* ]] && continue
      # Must be KEY=VALUE format
      if [[ ! "$_env_line" == *=* ]]; then
        log_warn "Skipping invalid .env line (no =): ${_env_line:0:40}"
        continue
      fi
      _env_key="${_env_line%%=*}"
      _env_val="${_env_line#*=}"
      # Strip optional quotes from value
      if [[ "$_env_val" == \"*\" || "$_env_val" == \'*\' ]]; then
        _env_val="${_env_val:1:${#_env_val}-2}"
      fi
      # Validate key is a valid env var name
      if [[ ! "$_env_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        log_warn "Skipping invalid .env key: $_env_key"
        continue
      fi
      # Reject values with command substitution, backticks, or shell operators
      if printf '%s' "$_env_val" | grep -qE '\$\(|`|;|\|' 2>/dev/null; then
        log_warn "Skipping unsafe .env value for $_env_key: contains shell operators"
        continue
      fi
      export "$_env_key=$_env_val"
    done < ".crew/.env"
  fi

  [[ -z "$config_file" || ! -f "$config_file" ]] && return 0

  local env_keys
  env_keys=$(config_get ".agents[] | select(.name == \"$name\") | .env | keys | .[]" "" "$config_file")
  [[ -z "$env_keys" || "$env_keys" == "null" ]] && return 0

  # BUG-QA-067: Maximum env var value size (64KB)
  local max_env_value_size=65536

  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    # Validate env key against yq injection before interpolation
    _assert_safe_yq_name "$key" || { log_warn "Skipping unsafe env key: $key"; continue; }
    # BUG-QA-062: Validate env var name is a valid bash identifier
    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      log_warn "Skipping invalid env var name: $key"
      continue
    fi
    local value
    value=$(config_get ".agents[] | select(.name == \"$name\") | .env.$key" "" "$config_file")
    if [[ -n "$value" && "$value" != "null" ]]; then
      if [[ ${#value} -gt $max_env_value_size ]]; then
        log_warn "[$name] Env var $key value exceeds ${max_env_value_size} bytes, skipping"
        continue
      fi
      local expanded_value
      expanded_value=$(_safe_expand_env "$value")
      export "$key=$expanded_value"
    fi
  done <<< "$env_keys"
}

# Get the number of fallback entries for an agent
# Usage: get_fallback_count <name> <config_file>
get_fallback_count() {
  local name="$1"
  local config_file="$2"

  [[ -z "$config_file" || ! -f "$config_file" ]] && echo 0 && return 0

  local count
  count=$(config_get ".agents[] | select(.name == \"$name\") | .fallback | length" "0" "$config_file")
  [[ -z "$count" || "$count" == "null" ]] && count=0
  echo "$count"
}

# Get human-readable label for a fallback level
# Level 0 = "primary", level N = fallback[N-1].label or "fallback-N"
# Usage: get_fallback_label <name> <level> <config_file>
get_fallback_label() {
  local name="$1"
  local level="$2"
  local config_file="$3"

  if [[ "$level" -eq 0 ]]; then
    echo "primary"
    return 0
  fi

  local fb_idx=$((level - 1))
  local label
  label=$(config_get ".agents[] | select(.name == \"$name\") | .fallback[$fb_idx].label" "" "$config_file")

  if [[ -z "$label" || "$label" == "null" ]]; then
    echo "fallback-$level"
  else
    echo "$label"
  fi
}

# Get max_restarts for a fallback level
# Level 0 reads from agent.max_restarts, level N from fallback[N-1].max_restarts
# Usage: get_fallback_max_restarts <name> <level> <config_file>
get_fallback_max_restarts() {
  local name="$1"
  local level="$2"
  local config_file="$3"

  if [[ "$level" -eq 0 ]]; then
    local val
    val=$(config_get ".agents[] | select(.name == \"$name\") | .max_restarts" "" "$config_file")
    [[ -z "$val" || "$val" == "null" ]] && val="$DEFAULT_MAX_RESTARTS"
    echo "$val"
    return 0
  fi

  local fb_idx=$((level - 1))
  local val
  val=$(config_get ".agents[] | select(.name == \"$name\") | .fallback[$fb_idx].max_restarts" "" "$config_file")
  [[ -z "$val" || "$val" == "null" ]] && val="$DEFAULT_MAX_RESTARTS"
  echo "$val"
}

# Get timeout for a fallback level (seconds, 0 = no timeout)
# Level 0 reads from agent.timeout, level N from fallback[N-1].timeout
# Usage: get_fallback_timeout <name> <level> <config_file>
get_fallback_timeout() {
  local name="$1"
  local level="$2"
  local config_file="$3"

  if [[ "$level" -eq 0 ]]; then
    local val
    val=$(config_get ".agents[] | select(.name == \"$name\") | .timeout" "" "$config_file")
    [[ -z "$val" || "$val" == "null" ]] && val="$DEFAULT_TIMEOUT"
    echo "$val"
    return 0
  fi

  local fb_idx=$((level - 1))
  local val
  val=$(config_get ".agents[] | select(.name == \"$name\") | .fallback[$fb_idx].timeout" "" "$config_file")
  # BUG-QA-109: Inherit base agent timeout if fallback level doesn't define one.
  # Without this, fallback agents default to DEFAULT_TIMEOUT (0 = no timeout),
  # causing them to hang indefinitely if the fallback CLI waits for input.
  if [[ -z "$val" || "$val" == "null" ]]; then
    val=$(config_get ".agents[] | select(.name == \"$name\") | .timeout" "" "$config_file")
    [[ -z "$val" || "$val" == "null" ]] && val="$DEFAULT_TIMEOUT"
  fi
  echo "$val"
}

# Export env vars for a specific fallback level
# Level 0 = primary env only, level N = primary env + fallback[N-1].env overlay
# Usage: export_fallback_env <name> <level> <config_file>
export_fallback_env() {
  local name="$1"
  local level="$2"
  local config_file="$3"

  # Always start with primary agent env
  export_agent_env "$name" "$config_file"

  [[ "$level" -eq 0 ]] && return 0
  [[ -z "$config_file" || ! -f "$config_file" ]] && return 0

  # Overlay fallback-level env vars
  local fb_idx=$((level - 1))
  local env_keys
  env_keys=$(config_get ".agents[] | select(.name == \"$name\") | .fallback[$fb_idx].env | keys | .[]" "" "$config_file")
  [[ -z "$env_keys" || "$env_keys" == "null" ]] && return 0

  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    # Validate env key against yq injection before interpolation
    _assert_safe_yq_name "$key" || { log_warn "Skipping unsafe fallback env key: $key"; continue; }
    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      log_warn "Skipping invalid fallback env var name: $key"
      continue
    fi
    local value
    value=$(config_get ".agents[] | select(.name == \"$name\") | .fallback[$fb_idx].env.$key" "" "$config_file")
    if [[ -n "$value" && "$value" != "null" ]]; then
      local expanded_value
      expanded_value=$(_safe_expand_env "$value")
      export "$key=$expanded_value"
    fi
  done <<< "$env_keys"
}

# Acquire lock on PID file (non-blocking).
# Uses mkdir for atomic locking: mkdir is guaranteed atomic on all POSIX filesystems,
# unlike flock which is unavailable on some macOS/BSD systems. Returns 1 if lock
# is already held, which callers interpret as "another start/stop operation in progress".
acquire_pid_lock() {
  local pid_file="$1"
  local lock_dir="${pid_file}.lock"
  mkdir "$lock_dir" 2>/dev/null || return 1
}

# Release PID lock
release_pid_lock() {
  local pid_file="$1"
  local lock_dir="${pid_file}.lock"
  rmdir "$lock_dir" 2>/dev/null || true
}

# ── Shared Context (T065) ──────────────────────────────────────────────────
# Prepend shared context from .crew/shared/context.md into the agent prompt.
# Returns path to a temp file with shared context + original prompt combined.
# If no shared context exists, returns the original prompt_file unchanged.
_build_shared_prompt() {
  local prompt_file="$1"
  local crew_dir=".crew"
  local shared_context="$crew_dir/shared/context.md"

  if [[ ! -f "$shared_context" ]] || [[ ! -s "$shared_context" ]]; then
    echo "$prompt_file"
    return 0
  fi

  # BUG-QA-107: Enforce size limit on shared context file (1MB max)
  local context_size
  context_size=$(stat -f%z "$shared_context" 2>/dev/null || stat -c%s "$shared_context" 2>/dev/null || echo 0)
  if [[ "$context_size" -gt 1048576 ]]; then
    log_warn "Shared context file exceeds 1MB limit (${context_size} bytes), skipping injection"
    echo "$prompt_file"
    return 0
  fi

  # BUG-QA-101: Use umask for atomic 600 permissions instead of chmod
  local tmp_prompt
  local old_umask
  old_umask=$(umask)
  umask 077
  tmp_prompt=$(mktemp)
  umask "$old_umask"

  {
    echo "<shared-context>"
    cat "$shared_context"
    echo "</shared-context>"
    echo ""
    cat "$prompt_file"
  } > "$tmp_prompt"

  echo "$tmp_prompt"
}

# Acquire a lock on the shared context file for writing.
# Uses mkdir for atomic locking (same pattern as PID locks).
acquire_shared_lock() {
  local crew_dir=".crew"
  local lock_dir="$crew_dir/shared/.context.lock"
  local max_wait=5
  local waited=0

  while ! mkdir "$lock_dir" 2>/dev/null; do
    waited=$((waited + 1))
    if [[ "$waited" -ge "$max_wait" ]]; then
      log_warn "Could not acquire shared context lock after ${max_wait}s"
      return 1
    fi
    sleep 1
  done
  return 0
}

# Release shared context write lock.
release_shared_lock() {
  local crew_dir=".crew"
  local lock_dir="$crew_dir/shared/.context.lock"
  rmdir "$lock_dir" 2>/dev/null || true
}

# Start an agent in a background subshell with automatic restart and fallback chain.
#
# The subshell runs two nested loops:
#   Outer loop: iterates through fallback levels (0=primary, 1..N=fallback entries)
#   Inner loop: retries at the current level with exponential backoff
#
# The inner loop breaks to the outer loop when max_restarts is exhausted.
# The outer loop exits when all levels are exhausted (writes .exhausted marker).
# Normal stop is signaled by removing the PID file (checked after each agent run).
#
# Signal handling uses deferred traps during the critical window between
# plugin_run & child_pid=$! to prevent orphaned agent processes (D010).
#
# Usage: start_agent <name> <prompt_file> <interval> <working_dir> <config_file>
start_agent() {
  local name="$1"
  local prompt_file="$2"
  local interval="${3:-$DEFAULT_RESTART_DELAY}"
  local working_dir="${4:-$PWD}"
  local config_file="${5:-}"
  local crew_dir=".crew"

  validate_agent_name "$name" || return 1

  # BUG-QA-103: Reject symlinked working directories to prevent symlink attacks
  if [[ -L "$working_dir" ]]; then
    log_error "[$name] Working directory cannot be a symlink: $working_dir"
    return 1
  fi

  ensure_dir "$crew_dir/logs"
  ensure_dir "$crew_dir/run"

  local log_file="$crew_dir/logs/${name}.log"
  local pid_file="$crew_dir/run/${name}.pid"

  # Lock PID file to prevent race conditions
  if ! acquire_pid_lock "$pid_file"; then
    log_warn "[$name] Could not acquire lock (another operation in progress)"
    return 1
  fi

  # Check if already running
  if is_agent_running "$name"; then
    log_warn "[$name] Already running (PID: $(_read_pid "$pid_file"))"
    release_pid_lock "$pid_file"
    return 1
  fi

  log_info "[$name] Starting (restart delay: ${interval}s)..."

  # Validate prompt file
  if [[ ! -f "$prompt_file" ]]; then
    log_error "[$name] Prompt file not found: $prompt_file"
    release_pid_lock "$pid_file"
    return 1
  fi

  local fallback_state_file="$crew_dir/run/${name}.fallback"
  local exhausted_file="$crew_dir/run/${name}.exhausted"

  # Determine fallback chain depth
  local fallback_count=0
  if [[ -n "$config_file" && -f "$config_file" ]]; then
    fallback_count=$(get_fallback_count "$name" "$config_file")
  fi

  # Start agent in background
  (
    cd "$working_dir" || exit 1

    _handle_term() {
      # Kill timeout watchdog to prevent orphaned sleep processes
      if [[ -n "${timeout_pid:-}" ]] && kill -0 "$timeout_pid" 2>/dev/null; then
        kill "$timeout_pid" 2>/dev/null || true
      fi
      # Kill entire child process tree (agent CLI + its subprocesses)
      if [[ -n "${child_pid:-}" ]] && kill -0 "$child_pid" 2>/dev/null; then
        _kill_subtree "$child_pid" "TERM"
        kill -TERM "$child_pid" 2>/dev/null || true
      fi
    }
    trap _handle_term TERM INT

    local current_level=0
    local max_level="$fallback_count"

    # Check for advance marker (watchdog fallback action, T049 Phase 3)
    local advance_file="$crew_dir/run/${name}.advance"
    if [[ -f "$advance_file" ]]; then
      local advance_to
      advance_to=$(cat "$advance_file")
      rm -f "$advance_file"
      if [[ "$advance_to" =~ ^[0-9]+$ ]] && [[ "$advance_to" -le "$max_level" ]]; then
        current_level="$advance_to"
        echo "[$name] Advanced to fallback level $current_level by watchdog" >> "$log_file"
      else
        # BUG-QA-106: Log warning when advance file content is invalid
        log_warn "[$name] Invalid advance file content: '$advance_to' (expected 1-$max_level)"
      fi
    fi

    # Outer loop: iterate through fallback levels
    while [[ "$current_level" -le "$max_level" ]]; do
      # Export env for this fallback level
      export_fallback_env "$name" "$current_level" "$config_file"

      # Resolve CLI type for this fallback level
      local cli_type="claude"
      if [[ -n "$config_file" && -f "$config_file" ]]; then
        cli_type=$(get_fallback_cli_type "$name" "$current_level" "$config_file")
      fi

      # Get per-level max_restarts
      local level_max_restarts="$DEFAULT_MAX_RESTARTS"
      if [[ -n "$config_file" && -f "$config_file" ]]; then
        level_max_restarts=$(get_fallback_max_restarts "$name" "$current_level" "$config_file")
      fi

      # Get per-level timeout (0 = no timeout)
      local agent_timeout="$DEFAULT_TIMEOUT"
      if [[ -n "$config_file" && -f "$config_file" ]]; then
        agent_timeout=$(get_fallback_timeout "$name" "$current_level" "$config_file")
      fi

      local level_label
      level_label=$(get_fallback_label "$name" "$current_level" "${config_file:-}")

      # Write fallback state for status display
      echo "${current_level}|${level_label}" > "$fallback_state_file"

      if [[ "$current_level" -gt 0 ]]; then
        echo "[$name] Falling back to: $level_label (level $current_level, type: $cli_type)" >> "$log_file"
      fi

      local restart_count=0
      local delay="$interval"

      # Inner loop: retry at current level
      while true; do
        rotate_log_if_needed "$log_file"
        echo "[$name] Starting at $(timestamp) [$level_label] (type: $cli_type)" >> "$log_file"

        # Inject shared context into prompt (T065)
        local effective_prompt
        effective_prompt=$(_build_shared_prompt "$prompt_file")

        # Defer TERM/INT during child launch to prevent orphans (D010)
        local _deferred_term=false
        trap '_deferred_term=true' TERM INT

        # Execute based on type
        if [[ "$cli_type" == "command" ]]; then
          # Legacy: raw command from config (DEPRECATED — use type: plugin instead)
          log_warn "[$name] 'command:' field is deprecated; migrate to 'type:' plugin"
          local raw_command
          raw_command=$(get_fallback_command "$name" "$current_level" "$config_file")
          # Run via word-split (no eval) to prevent command injection (BUG-QA-001)
          # shellcheck disable=SC2086
          $raw_command < "$effective_prompt" >> "$log_file" 2>&1 &
        else
          # Plugin-based execution
          plugin_run "$cli_type" "$effective_prompt" "$working_dir" >> "$log_file" 2>&1 &
        fi
        child_pid=$!

        # Restore signal handler and process any deferred signal (BUG-QA-005)
        # Bash delivers signals at statement boundaries, so no race between
        # trap restore and the flag check. Reset flag first to avoid double-handle.
        trap _handle_term TERM INT
        if $_deferred_term; then
          _deferred_term=false
          _handle_term
          exit 1
        fi

        # Start timeout watchdog if configured (0 = disabled)
        # Uses child_pid as token to prevent false positives from stale markers (BUG-QA-004)
        local timeout_pid=""
        local timeout_marker="$crew_dir/run/${name}.timedout"
        rm -f "$timeout_marker"
        if [[ "$agent_timeout" -gt 0 ]]; then
          (
            umask 077
            sleep "$agent_timeout"
            if kill -0 "$child_pid" 2>/dev/null; then
              echo "$child_pid" > "$timeout_marker"
              kill -TERM "$child_pid" 2>/dev/null
            fi
          ) &
          timeout_pid=$!
        fi

        local exit_code=0
        local expected_child_pid="$child_pid"
        wait "$child_pid" || exit_code=$?
        child_pid=""

        # Clean up shared context temp file
        if [[ "$effective_prompt" != "$prompt_file" ]]; then
          rm -f "$effective_prompt"
        fi

        # Clean up timeout watchdog
        if [[ -n "$timeout_pid" ]]; then
          kill "$timeout_pid" 2>/dev/null || true
          wait "$timeout_pid" 2>/dev/null || true
        fi

        # Detect timeout: verify marker token matches our child_pid (BUG-QA-004)
        if [[ -f "$timeout_marker" ]] && [[ "$(cat "$timeout_marker" 2>/dev/null)" == "$expected_child_pid" ]]; then
          rm -f "$timeout_marker"
          exit_code=124
          echo "[$name] Timed out after ${agent_timeout}s at $(timestamp) [$level_label]" >> "$log_file"
        else
          echo "[$name] Exited with code $exit_code at $(timestamp) [$level_label]" >> "$log_file"
        fi

        # Check if we should stop (PID file removed by stop_agent)
        if [[ ! -f "$pid_file" ]]; then
          echo "[$name] PID file removed, stopping." >> "$log_file"
          rm -f "$fallback_state_file"
          exit 0
        fi

        if [[ "$exit_code" -eq 0 ]]; then
          # Success: reset backoff, stay at current level
          restart_count=0
          delay="$interval"
        else
          # Error: increment restart count
          restart_count=$((restart_count + 1))
          if [[ "$restart_count" -ge "$level_max_restarts" ]]; then
            echo "[$name] Max restarts ($level_max_restarts) reached at level: $level_label" >> "$log_file"
            break  # Break inner loop → try next fallback level
          fi
          # Exponential backoff: interval * 2^(n-1), capped at MAX_BACKOFF_DELAY
          # Handle edge case: when restart_count=0, use interval directly (avoid 1 << -1)
          if [[ "$restart_count" -le 0 ]]; then
            delay="$interval"
          else
            local exp=$((restart_count - 1))
            [[ "$exp" -gt 6 ]] && exp=6  # cap at 64x to prevent 64-bit overflow
            delay=$((interval * (1 << exp)))
            if [[ "$delay" -gt "$MAX_BACKOFF_DELAY" ]]; then
              delay="$MAX_BACKOFF_DELAY"
            fi
          fi
          echo "[$name] Error restart $restart_count/$level_max_restarts [$level_label] (backoff: ${delay}s)" >> "$log_file"
        fi

        # Wait before restart
        echo "[$name] Restarting in ${delay}s..." >> "$log_file"
        sleep "$delay"
      done

      # Move to next fallback level
      current_level=$((current_level + 1))
    done

    # All fallback levels exhausted
    echo "[$name] All fallback levels exhausted. Giving up." >> "$log_file"
    rm -f "$fallback_state_file"
    rm -f "$pid_file"
    echo "exhausted" > "$exhausted_file"
  ) < /dev/null &

  local pid=$!
  _write_pid "$pid" "$pid_file"
  release_pid_lock "$pid_file"

  log_ok "[$name] Started (PID: $pid)"
  log_info "[$name] Log: $log_file"
  if [[ "$fallback_count" -gt 0 ]]; then
    log_info "[$name] Fallback chain: $fallback_count level(s) configured"
  fi
}

# Recursively kill a process tree (depth-first, children before parent).
# Essential for crew stop: agent CLIs (claude, gemini, etc.) spawn their own
# child processes which would become orphans if only the top-level shell is killed.
_kill_subtree() {
  local ppid=$1
  local sig=${2:-TERM}

  local children
  children=$(pgrep -P "$ppid" 2>/dev/null || echo "")

  for child in $children; do
    [[ -z "$child" ]] && continue
    _kill_subtree "$child" "$sig"
    kill "-$sig" "$child" 2>/dev/null || true
  done
}

# Stop an agent gracefully (SIGTERM → wait → SIGKILL).
# Removes PID file first so the agent's inner loop exits cleanly on its next
# iteration check. Then sends SIGTERM to the full process tree, waits up to
# GRACEFUL_SHUTDOWN_TIMEOUT seconds, and escalates to SIGKILL if still alive.
stop_agent() {
  local name="$1"
  local crew_dir=".crew"
  local pid_file="$crew_dir/run/${name}.pid"

  if [[ ! -f "$pid_file" ]]; then
    log_warn "[$name] Not running (no PID file)"
    # Clean up orphaned progress files even when agent is already stopped
    rm -f "$crew_dir/run/${name}.progress"
    rm -f "$crew_dir/run/${name}.lastcheck"
    rm -f "$crew_dir/run/${name}.verdict"
    rm -f "$crew_dir/run/${name}.advance"
    return 0
  fi

  # Lock PID file to prevent race conditions
  if ! acquire_pid_lock "$pid_file"; then
    log_warn "[$name] Could not acquire lock (another operation in progress)"
    return 1
  fi

  local pid
  pid=$(_read_pid "$pid_file")

  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    log_warn "[$name] Corrupt PID file (non-numeric: $pid), removing"
    rm -f "$pid_file"
    release_pid_lock "$pid_file"
    return 1
  fi

  log_info "[$name] Stopping (PID: $pid)..."

  # Remove PID file first (signals the loop to stop)
  rm -f "$pid_file"

  # Send SIGTERM to entire process tree for graceful shutdown
  if kill -0 "$pid" 2>/dev/null; then
    _kill_subtree "$pid" "TERM"
    kill -TERM "$pid" 2>/dev/null || true

    # Wait for graceful exit
    local wait_count=0
    while kill -0 "$pid" 2>/dev/null && [[ $wait_count -lt $GRACEFUL_SHUTDOWN_TIMEOUT ]]; do
      sleep 1
      wait_count=$((wait_count + 1))
    done

    # Force kill entire tree if still alive
    if kill -0 "$pid" 2>/dev/null; then
      _kill_subtree "$pid" "9"
      kill -9 "$pid" 2>/dev/null || true
      log_warn "[$name] Force killed"
    else
      log_ok "[$name] Stopped gracefully"
    fi
  else
    log_warn "[$name] Process not found (already stopped)"
  fi

  # Clean up fallback state files
  rm -f "$crew_dir/run/${name}.fallback"
  rm -f "$crew_dir/run/${name}.exhausted"
  rm -f "$crew_dir/run/${name}.progress"
  rm -f "$crew_dir/run/${name}.lastcheck"
  rm -f "$crew_dir/run/${name}.verdict"
  rm -f "$crew_dir/run/${name}.advance"

  release_pid_lock "$pid_file"
}

# Check if agent is running (with PID reuse detection via lstart verification)
is_agent_running() {
  local name="$1"
  local crew_dir=".crew"
  local pid_file="$crew_dir/run/${name}.pid"

  _verify_pid_owner "$pid_file"
}

# Get agent status
get_agent_status() {
  local name="$1"
  local crew_dir=".crew"
  local pid_file="$crew_dir/run/${name}.pid"
  local log_file="$crew_dir/logs/${name}.log"

  if is_agent_running "$name"; then
    local pid
    pid=$(_read_pid "$pid_file")
    echo "running:$pid"
  elif [[ -f "$pid_file" ]]; then
    echo "stale"  # PID file exists but process dead
  else
    echo "stopped"
  fi
}

# Get agent PID
get_agent_pid() {
  local name="$1"
  local crew_dir=".crew"
  local pid_file="$crew_dir/run/${name}.pid"

  if is_agent_running "$name"; then
    _read_pid "$pid_file"
  else
    return 1
  fi
}

# Restart an agent
restart_agent() {
  local name="$1"
  local config_file="$2"

  stop_agent "$name"
  sleep 1

  # Get agent config and restart
  local prompt_file interval
  prompt_file=$(config_get ".agents[] | select(.name == \"$name\") | .prompt" "" "$config_file")
  interval=$(config_get ".agents[] | select(.name == \"$name\") | .interval" "$DEFAULT_RESTART_DELAY" "$config_file")

  if [[ -n "$prompt_file" ]]; then
    start_agent "$name" ".crew/$prompt_file" "$interval" "$PWD" "$config_file" || true
  else
    log_error "[$name] Cannot restart: missing config"
  fi
}

# Start all agents from config
start_all_agents() {
  local config_file="$1"

  if [[ ! -f "$config_file" ]]; then
    log_error "Config file not found: $config_file"
    return 1
  fi

  # Get list of agent names
  local agents
  agents=$(config_get ".agents[].name" "" "$config_file")

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    validate_agent_name "$name" || continue
    local prompt_file interval
    prompt_file=$(config_get ".agents[] | select(.name == \"$name\") | .prompt" "" "$config_file")
    interval=$(config_get ".agents[] | select(.name == \"$name\") | .interval" "$DEFAULT_RESTART_DELAY" "$config_file")

    if [[ -z "$prompt_file" ]]; then
      log_warn "[$name] Skipping: missing prompt"
      continue
    fi

    # Pre-validate plugin for type-based agents
    local cli_type
    cli_type=$(get_agent_cli_type "$name" "$config_file")
    if [[ "$cli_type" != "command" ]]; then
      if ! load_plugin "$cli_type" 2>/dev/null; then
        log_warn "[$name] Skipping: unknown CLI type '$cli_type'"
        continue
      fi
    fi

    start_agent "$name" ".crew/$prompt_file" "$interval" "$PWD" "$config_file" || true
  done <<< "$agents"
}

# Stop all agents
stop_all_agents() {
  local crew_dir=".crew"

  if [[ ! -d "$crew_dir/run" ]]; then
    log_info "No agents running"
    return 0
  fi

  for pid_file in "$crew_dir/run"/*.pid; do
    if [[ -f "$pid_file" ]]; then
      local name
      name=$(basename "$pid_file" .pid)
      stop_agent "$name"
    fi
  done

  # Clean up stale lock dirs
  for lock_dir in "$crew_dir/run"/*.lock; do
    [[ -d "$lock_dir" ]] && rmdir "$lock_dir" 2>/dev/null || true
  done
}

# ── Progress Watchdog (T049) ──────────────────────────────────────────────────
# Detects silent agent failures: process alive but no useful output.
# Architecture: watchdog is infrastructure (pure Bash), not a peer agent.
# Only spawns a one-shot AI call when heuristics flag suspicious state.

# Read a key=value pair from a progress file
_read_progress_key() {
  local file="$1"
  local key="$2"
  local default="${3:-}"
  [[ ! -f "$file" ]] && echo "$default" && return 0
  local val
  val=$(grep "^${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2- || true)
  [[ -z "$val" ]] && echo "$default" || echo "$val"
}

# Update a key=value pair in a progress file (pure Bash, no sed)
_write_progress_key() {
  local file="$1"
  local key="$2"
  local value="$3"
  if [[ ! -f "$file" ]]; then
    echo "${key}=${value}" > "$file"
    return 0
  fi
  local tmp="${file}.tmp"
  local found=false
  while IFS= read -r line; do
    if [[ "$line" == "${key}="* ]]; then
      echo "${key}=${value}"
      found=true
    else
      echo "$line"
    fi
  done < "$file" > "$tmp"
  if ! $found; then
    echo "${key}=${value}" >> "$tmp"
  fi
  mv "$tmp" "$file"
}

# Get all descendant PIDs of a process (recursive, depth-first)
# BUG-QA-091: Validate PID before using it
_get_descendant_pids() {
  local pid="$1"

  # Validate PID is numeric
  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    return
  fi

  local children
  children=$(pgrep -P "$pid" 2>/dev/null || true)

  # Validate pgrep output format - should be numeric PIDs, one per line
  if [[ -n "$children" && "$children" =~ [^0-9\n] ]]; then
    return
  fi

  for child in $children; do
    [[ -z "$child" ]] && continue
    echo "$child"
    _get_descendant_pids "$child"
  done
}

# Phase 1: Collect progress signals for a running agent.
# Tracks log file growth, working directory file changes, and child process tree.
# Writes key=value signals to .crew/run/<AGENT>.progress, touches .lastcheck.
_collect_progress_signals() {
  local name="$1"
  local crew_dir=".crew"
  local progress_file="$crew_dir/run/${name}.progress"
  local lastcheck_file="$crew_dir/run/${name}.lastcheck"
  local log_file="$crew_dir/logs/${name}.log"
  local pid_file="$crew_dir/run/${name}.pid"
  local now

  # BUG-QA-089: Handle timestamp overflow - use %s%3N if available, validate range
  now=$(date +%s%3N 2>/dev/null || date +%s 2>/dev/null || echo 0)
  # Validate timestamp is reasonable (positive and within 64-bit range)
  if [[ ! "$now" =~ ^[0-9]+$ ]] || [[ "$now" -lt 0 ]] || [[ "$now" -gt 9999999999999 ]]; then
    now=$(date +%s 2>/dev/null || echo 0)
  fi

  # Current log size
  local log_size=0
  if [[ -f "$log_file" ]]; then
    log_size=$(stat -f%z "$log_file" 2>/dev/null || stat -c%s "$log_file" 2>/dev/null || echo 0)
  fi

  # Previous log size from last collection
  local prev_log_size
  prev_log_size=$(_read_progress_key "$progress_file" "log_size" "0")
  local log_growth=$((log_size - prev_log_size))
  [[ "$log_growth" -lt 0 ]] && log_growth=0  # Handle log rotation

  # File changes since last check
  local file_changes=0
  if [[ -f "$lastcheck_file" ]]; then
    file_changes=$(find . -newer "$lastcheck_file" \
      -not -path "./.crew/*" -not -path "./.git/*" \
      -not -path "./.design/*" -type f 2>/dev/null | wc -l | tr -d ' ')
  fi

  # Child process names (unique, space-separated)
  local pid child_procs=""
  pid=$(_read_pid "$pid_file" 2>/dev/null || echo "")
  if [[ -n "$pid" ]]; then
    local descendants
    descendants=$(_get_descendant_pids "$pid" 2>/dev/null || true)
    if [[ -n "$descendants" ]]; then
      child_procs=$(echo "$descendants" | while read -r cpid; do
        [[ -z "$cpid" ]] && continue
        ps -o comm= -p "$cpid" 2>/dev/null || true
      done | sort -u | tr '\n' ' ')
    fi
  fi

  # Preserve idle tracking state from previous cycle
  local idle_since
  idle_since=$(_read_progress_key "$progress_file" "idle_since" "0")

  # Write complete progress file
  cat > "$progress_file" << EOF
timestamp=$now
log_size=$log_size
prev_log_size=$prev_log_size
log_growth=$log_growth
file_changes=$file_changes
child_procs=$child_procs
idle_since=$idle_since
EOF

  touch "$lastcheck_file"
}

# Phase 2: Heuristic pre-filter. Analyzes progress signals and returns one of:
#   PRODUCTIVE — agent is making real progress (file changes or active tools)
#   LEGITIMATE — agent has active child processes (test runners, compilers)
#   SUSPECT    — no meaningful progress for idle_timeout duration
_check_agent_progress() {
  local name="$1"
  local idle_timeout="$2"
  local crew_dir=".crew"
  local progress_file="$crew_dir/run/${name}.progress"
  local verdict_file="$crew_dir/run/${name}.verdict"

  local log_growth file_changes child_procs idle_since
  log_growth=$(_read_progress_key "$progress_file" "log_growth" "0")
  file_changes=$(_read_progress_key "$progress_file" "file_changes" "0")
  child_procs=$(_read_progress_key "$progress_file" "child_procs" "")
  idle_since=$(_read_progress_key "$progress_file" "idle_since" "0")

  local now
  now=$(date +%s)

  # Check for active child processes that indicate legitimate work
  local known_tools="pytest make cargo node npm npx gcc g++ javac go rustc tsc webpack vite jest mocha ruby python python3 bats"
  for tool in $known_tools; do
    if echo " $child_procs " | grep -qw "$tool" 2>/dev/null; then
      _write_progress_key "$progress_file" "idle_since" "0"
      echo "LEGITIMATE" > "$verdict_file"
      echo "LEGITIMATE"
      return 0
    fi
  done

  # Check for error loops (same line repeated 10+ times in last 50 lines)
  local log_file="$crew_dir/logs/${name}.log"
  if [[ -f "$log_file" ]]; then
    local top_repeat
    top_repeat=$(tail -50 "$log_file" 2>/dev/null | sort | uniq -c | sort -rn | head -1 | awk '{print $1}' || echo "0")
    if [[ -n "$top_repeat" && "$top_repeat" -ge 10 ]]; then
      echo "SUSPECT" > "$verdict_file"
      echo "SUSPECT"
      return 0
    fi
  fi

  # File changes indicate real progress
  if [[ "$file_changes" -gt 0 ]]; then
    _write_progress_key "$progress_file" "idle_since" "0"
    echo "PRODUCTIVE" > "$verdict_file"
    echo "PRODUCTIVE"
    return 0
  fi

  # Log growing but zero file changes: possible answer-only loop
  if [[ "$log_growth" -gt 0 && "$file_changes" -eq 0 ]]; then
    if [[ "$idle_since" -eq 0 ]]; then
      _write_progress_key "$progress_file" "idle_since" "$now"
      echo "PRODUCTIVE" > "$verdict_file"
      echo "PRODUCTIVE"
      return 0
    fi
    local idle_duration=$((now - idle_since))
    if [[ "$idle_duration" -ge $((idle_timeout * 2)) ]]; then
      echo "SUSPECT" > "$verdict_file"
      echo "SUSPECT"
      return 0
    fi
    echo "PRODUCTIVE" > "$verdict_file"
    echo "PRODUCTIVE"
    return 0
  fi

  # No log growth AND no file changes
  if [[ "$idle_since" -eq 0 ]]; then
    _write_progress_key "$progress_file" "idle_since" "$now"
    echo "PRODUCTIVE" > "$verdict_file"
    echo "PRODUCTIVE"
    return 0
  fi
  local idle_duration=$((now - idle_since))
  if [[ "$idle_duration" -ge "$idle_timeout" ]]; then
    echo "SUSPECT" > "$verdict_file"
    echo "SUSPECT"
    return 0
  fi

  echo "PRODUCTIVE" > "$verdict_file"
  echo "PRODUCTIVE"
}

# Build context file for AI judge evaluation
_build_judge_context() {
  local name="$1"
  local output_file="$2"
  local crew_dir=".crew"
  local log_file="$crew_dir/logs/${name}.log"
  local pid_file="$crew_dir/run/${name}.pid"
  local progress_file="$crew_dir/run/${name}.progress"
  local lastcheck_file="$crew_dir/run/${name}.lastcheck"

  {
    echo "=== AGENT: $name ==="
    echo "=== TIME: $(timestamp) ==="
    echo ""
    echo "--- LAST 200 LINES OF AGENT LOG ---"
    if [[ -f "$log_file" ]]; then
      tail -200 "$log_file" 2>/dev/null || echo "(empty)"
    else
      echo "(no log file)"
    fi
    echo ""
    echo "--- FILE CHANGES SINCE LAST CHECK ---"
    if [[ -f "$lastcheck_file" ]]; then
      find . -newer "$lastcheck_file" -not -path "./.crew/*" \
        -not -path "./.git/*" -not -path "./.design/*" \
        -type f 2>/dev/null | head -50 || echo "(none)"
    else
      echo "(no baseline)"
    fi
    echo ""
    echo "--- GIT DIFF STAT ---"
    git diff --stat HEAD 2>/dev/null || echo "(not a git repo)"
    echo ""
    echo "--- PROCESS TREE ---"
    local pid
    pid=$(_read_pid "$pid_file" 2>/dev/null || echo "")
    if [[ -n "$pid" ]]; then
      local descendants
      descendants=$(_get_descendant_pids "$pid" 2>/dev/null || true)
      if [[ -n "$descendants" ]]; then
        for dpid in $descendants; do
          ps -o pid=,ppid=,etime=,comm= -p "$dpid" 2>/dev/null || true
        done
      else
        echo "(no child processes)"
      fi
    else
      echo "(agent not running)"
    fi
    echo ""
    echo "--- PROGRESS SIGNALS ---"
    if [[ -f "$progress_file" ]]; then
      cat "$progress_file"
    else
      echo "(no data)"
    fi
    local idle_since
    idle_since=$(_read_progress_key "$progress_file" "idle_since" "0")
    if [[ "$idle_since" -gt 0 ]]; then
      local now idle_dur
      now=$(date +%s)
      idle_dur=$((now - idle_since))
      echo "idle_duration_seconds=$idle_dur"
    fi
    local fb_file="$crew_dir/run/${name}.fallback"
    if [[ -f "$fb_file" ]]; then
      echo "fallback_level=$(cat "$fb_file")"
    fi
  } > "$output_file"
}

# Export env vars for AI judge from watchdog.ai_judge.env config
_export_judge_env() {
  local config_file="$1"
  local env_keys
  env_keys=$(config_get ".watchdog.ai_judge.env | keys | .[]" "" "$config_file" 2>/dev/null || true)
  [[ -z "$env_keys" || "$env_keys" == "null" ]] && return 0
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    _assert_safe_yq_name "$key" || { log_warn "Skipping unsafe judge env key: $key"; continue; }
    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      log_warn "Skipping invalid judge env var name: $key"
      continue
    fi
    local value
    value=$(config_get ".watchdog.ai_judge.env.$key" "" "$config_file")
    if [[ -n "$value" && "$value" != "null" ]]; then
      export "$key=$value"
    fi
  done <<< "$env_keys"
}

# Phase 3: AI judge — one-shot CLI call to evaluate a SUSPECT agent.
# Builds context from log, file changes, and process tree, sends to AI,
# and parses response for verdict: PRODUCTIVE / STUCK / UNCERTAIN.
# Rate-limited to max 1 call per agent per MAX_AI_JUDGE_INTERVAL.
_invoke_ai_judge() {
  local name="$1"
  local judge_type="$2"
  local judge_prompt_template="$3"
  local config_file="$4"
  local crew_dir=".crew"
  local progress_file="$crew_dir/run/${name}.progress"
  local wd_log="$crew_dir/logs/watchdog.log"

  # Cost guard: max 1 AI judge call per agent per hour
  local last_judge_time now since_last
  last_judge_time=$(_read_progress_key "$progress_file" "last_judge_time" "0")
  now=$(date +%s)
  since_last=$((now - last_judge_time))
  if [[ "$since_last" -lt "$MAX_AI_JUDGE_INTERVAL" ]]; then
    echo "[watchdog] [$name] AI judge rate-limited (${since_last}s < ${MAX_AI_JUDGE_INTERVAL}s)" >> "$wd_log"
    echo "UNCERTAIN"
    return 0
  fi

  # Build context file — use umask 077 for atomic 600 permissions
  local context_file
  context_file=$(umask 077 && mktemp "/tmp/crew_watchdog.XXXXXX")
  _build_judge_context "$name" "$context_file"

  # Build prompt: template + context
  local prompt_file
  prompt_file=$(umask 077 && mktemp "/tmp/crew_watchdog_prompt.XXXXXX")
  local crew_home
  crew_home=$(get_crew_home)
  local template_path=""
  if [[ -f "$crew_dir/$judge_prompt_template" ]]; then
    template_path="$crew_dir/$judge_prompt_template"
  elif [[ -f "$crew_home/$judge_prompt_template" ]]; then
    template_path="$crew_home/$judge_prompt_template"
  fi

  {
    if [[ -n "$template_path" ]]; then
      cat "$template_path"
    else
      echo "Determine if this agent is making progress or is stuck."
      echo "Output exactly one line: VERDICT: PRODUCTIVE|STUCK|UNCERTAIN — reason"
    fi
    echo ""
    echo "---"
    echo ""
    cat "$context_file"
  } > "$prompt_file"

  # Export AI judge env vars
  _export_judge_env "$config_file"

  # Invoke AI judge via plugin
  local judge_output
  judge_output=$(umask 077 && mktemp "/tmp/crew_watchdog_output.XXXXXX")
  plugin_run "$judge_type" "$prompt_file" "$PWD" > "$judge_output" 2>&1 || true

  _write_progress_key "$progress_file" "last_judge_time" "$now"

  # Parse verdict from output
  local verdict="UNCERTAIN"
  local verdict_line
  verdict_line=$(grep -i "VERDICT:" "$judge_output" 2>/dev/null | head -1 || true)
  if echo "$verdict_line" | grep -qi "STUCK"; then
    verdict="STUCK"
  elif echo "$verdict_line" | grep -qi "PRODUCTIVE"; then
    verdict="PRODUCTIVE"
  fi

  echo "[watchdog] [$name] AI verdict: $verdict ($verdict_line)" >> "$wd_log"
  rm -f "$context_file" "$prompt_file" "$judge_output"
  echo "$verdict"
}

# Phase 4: Handle a stuck agent by taking the configured action.
# Actions: fallback (advance chain), restart, notify (run command), stop.
_handle_stuck_agent() {
  local name="$1"
  local action="$2"
  local config_file="$3"
  local crew_dir=".crew"
  local wd_log="$crew_dir/logs/watchdog.log"

  echo "[watchdog] [$name] Action: $action at $(timestamp)" >> "$wd_log"

  case "$action" in
    fallback)
      # Advance to next fallback level then restart
      local current_level=0
      local fb_file="$crew_dir/run/${name}.fallback"
      if [[ -f "$fb_file" ]]; then
        current_level=$(cut -d'|' -f1 "$fb_file")
      fi
      echo "$((current_level + 1))" > "$crew_dir/run/${name}.advance"
      restart_agent "$name" "$config_file"
      ;;
    restart)
      restart_agent "$name" "$config_file"
      ;;
    notify)
      local notify_cmd
      notify_cmd=$(config_get ".watchdog.on_stuck_command" "" "$config_file" 2>/dev/null || true)
      if [[ -n "$notify_cmd" && "$notify_cmd" != "null" ]]; then
        echo "[watchdog] [$name] Running notify command: $notify_cmd" >> "$wd_log"
        # Array-based execution prevents shell injection (no eval).
        # Complex commands (pipes, redirects) should be wrapped in a script.
        local -a cmd_parts
        read -ra cmd_parts <<< "$notify_cmd"
        "${cmd_parts[@]}" >> "$wd_log" 2>&1 || true
      else
        log_warn "[$name] STUCK but no on_stuck_command configured"
      fi
      ;;
    stop)
      stop_agent "$name"
      echo "[watchdog] [$name] Stopped (stuck)" >> "$wd_log"
      ;;
    *)
      log_warn "[$name] Unknown on_stuck action: $action"
      ;;
  esac

  # Reset progress tracking after action
  rm -f "$crew_dir/run/${name}.progress"
  rm -f "$crew_dir/run/${name}.lastcheck"
}

# Watchdog loop — periodic health check and progress monitoring.
# Runs as a background process started by crew_start().
#
# Two levels of monitoring:
#   1. Health checks (every check_interval): detect crashed/stale agents, restart
#   2. Progress checks (every watchdog.check_interval, T049): detect silent failures
#      via log growth analysis, file change tracking, and optional AI judgment
#
# Started by crew_start() and stored in .crew/run/watchdog.pid for cleanup.
watchdog_loop() {
  local config_file="$1"
  local check_interval="${2:-$DEFAULT_CHECK_INTERVAL}"

  log_info "Watchdog started (interval: ${check_interval}s)"

  # Read progress watchdog config
  local wd_enabled wd_check_interval wd_idle_timeout wd_on_stuck
  wd_enabled=$(config_get ".watchdog.enabled" "false" "$config_file" 2>/dev/null || echo "false")
  wd_check_interval=$(config_get ".watchdog.check_interval" "$DEFAULT_WD_CHECK_INTERVAL" "$config_file" 2>/dev/null || echo "$DEFAULT_WD_CHECK_INTERVAL")
  wd_idle_timeout=$(config_get ".watchdog.idle_timeout" "$DEFAULT_WD_IDLE_TIMEOUT" "$config_file" 2>/dev/null || echo "$DEFAULT_WD_IDLE_TIMEOUT")
  wd_on_stuck=$(config_get ".watchdog.on_stuck" "$DEFAULT_WD_ON_STUCK" "$config_file" 2>/dev/null || echo "$DEFAULT_WD_ON_STUCK")

  local ai_judge_enabled ai_judge_type ai_judge_prompt
  ai_judge_enabled=$(config_get ".watchdog.ai_judge.enabled" "false" "$config_file" 2>/dev/null || echo "false")
  ai_judge_type=$(config_get ".watchdog.ai_judge.type" "claude" "$config_file" 2>/dev/null || echo "claude")
  ai_judge_prompt=$(config_get ".watchdog.ai_judge.prompt" "prompts/crew/watchdog.md" "$config_file" 2>/dev/null || echo "prompts/crew/watchdog.md")

  if [[ "$wd_enabled" == "true" ]]; then
    ensure_dir ".crew/logs"
    log_info "Progress watchdog enabled (check: ${wd_check_interval}s, idle: ${wd_idle_timeout}s, action: $wd_on_stuck)"
    if [[ "$ai_judge_enabled" == "true" ]]; then
      log_info "AI judge enabled (type: $ai_judge_type)"
    fi
  fi

  local last_progress_check
  last_progress_check=$(date +%s)

  trap 'log_info "Watchdog stopping..."; return 0' INT TERM

  while true; do
    sleep "$check_interval"

    local agents
    agents=$(config_get ".agents[].name" "" "$config_file")

    # ── Health checks (existing behavior) ──
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      local status
      status=$(get_agent_status "$name")

      case "$status" in
        running:*)
          ;;
        stale)
          log_warn "[$name] Stale PID file, cleaning up..."
          rm -f ".crew/run/${name}.pid"
          restart_agent "$name" "$config_file"
          ;;
        stopped)
          if [[ -f ".crew/run/${name}.exhausted" ]]; then
            log_warn "[$name] All fallback levels exhausted, not restarting"
          else
            log_warn "[$name] Not running, starting..."
            local prompt_file interval
            prompt_file=$(config_get ".agents[] | select(.name == \"$name\") | .prompt" "" "$config_file")
            interval=$(config_get ".agents[] | select(.name == \"$name\") | .interval" "$DEFAULT_RESTART_DELAY" "$config_file")
            start_agent "$name" ".crew/$prompt_file" "$interval" "$PWD" "$config_file"
          fi
          ;;
      esac
    done <<< "$agents"

    # ── Progress checks (T049, runs at watchdog.check_interval) ──
    if [[ "$wd_enabled" == "true" ]]; then
      local now
      now=$(date +%s)
      local elapsed=$((now - last_progress_check))

      if [[ "$elapsed" -ge "$wd_check_interval" ]]; then
        last_progress_check="$now"

        while IFS= read -r name; do
          [[ -z "$name" ]] && continue
          local status
          status=$(get_agent_status "$name")

          # Only monitor running agents
          [[ "$status" != running:* ]] && continue

          # Phase 1: Collect progress signals
          _collect_progress_signals "$name"

          # Phase 2: Heuristic pre-filter
          local heuristic
          heuristic=$(_check_agent_progress "$name" "$wd_idle_timeout")

          if [[ "$heuristic" == "SUSPECT" ]]; then
            echo "[watchdog] [$name] Flagged SUSPECT at $(timestamp)" >> ".crew/logs/watchdog.log"

            if [[ "$ai_judge_enabled" == "true" ]]; then
              # Phase 3: AI judge
              local verdict
              verdict=$(_invoke_ai_judge "$name" "$ai_judge_type" "$ai_judge_prompt" "$config_file")

              case "$verdict" in
                STUCK)
                  echo "STUCK" > ".crew/run/${name}.verdict"
                  _handle_stuck_agent "$name" "$wd_on_stuck" "$config_file"
                  ;;
                PRODUCTIVE)
                  _write_progress_key ".crew/run/${name}.progress" "idle_since" "0"
                  echo "PRODUCTIVE" > ".crew/run/${name}.verdict"
                  ;;
                *)
                  echo "[watchdog] [$name] UNCERTAIN — grace period extended" >> ".crew/logs/watchdog.log"
                  ;;
              esac
            else
              # No AI judge: directly trigger on_stuck action
              _handle_stuck_agent "$name" "$wd_on_stuck" "$config_file"
            fi
          fi
        done <<< "$agents"
      fi
    fi
  done
}

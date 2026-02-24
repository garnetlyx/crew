#!/bin/bash
# crew/lib/watchdog.sh - Health monitoring and auto-restart
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

# Default values
DEFAULT_CHECK_INTERVAL=30
DEFAULT_TIMEOUT=600
DEFAULT_RESTART_DELAY=5
DEFAULT_MAX_RESTARTS=5
MAX_BACKOFF_DELAY=300
GRACEFUL_SHUTDOWN_TIMEOUT=10
MAX_LOG_SIZE=10485760  # 10MB

# Rotate log file if it exceeds MAX_LOG_SIZE
rotate_log_if_needed() {
  local log_file="$1"
  [[ ! -f "$log_file" ]] && return 0

  local size
  # macOS uses -f%z, Linux uses -c%s
  size=$(stat -f%z "$log_file" 2>/dev/null || stat -c%s "$log_file" 2>/dev/null || echo 0)

  if [[ "$size" -gt "$MAX_LOG_SIZE" ]]; then
    local rotated="${log_file}.$(date +%Y%m%d%H%M%S).bak"
    mv "$log_file" "$rotated"
    echo "[log] Rotated to $rotated (was ${size} bytes)" > "$log_file"
  fi
}

# Export per-agent env vars from config
# Usage: export_agent_env <name> <config_file>
export_agent_env() {
  local name="$1"
  local config_file="$2"
  
  # Load .crew/.env if it exists
  if [[ -f ".crew/.env" ]]; then
    set -a
    source ".crew/.env"
    set +a
  fi

  [[ -z "$config_file" || ! -f "$config_file" ]] && return 0

  local env_keys
  env_keys=$(config_get ".agents[] | select(.name == \"$name\") | .env | keys | .[]" "" "$config_file")
  [[ -z "$env_keys" || "$env_keys" == "null" ]] && return 0

  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    local value
    value=$(config_get ".agents[] | select(.name == \"$name\") | .env.$key" "" "$config_file")
    if [[ -n "$value" && "$value" != "null" ]]; then
      # Expand environment variables in the value (like ${API_KEY})
      local expanded_value
      expanded_value=$(eval echo "$value")
      export "$key=$expanded_value"
    fi
  done <<< "$env_keys"
}

# Acquire lock on PID file (non-blocking)
# Uses flock if available, otherwise proceeds without locking (best effort)
acquire_pid_lock() {
  local pid_file="$1"
  local lock_file="${pid_file}.lock"
  if command_exists flock; then
    exec 200>"$lock_file"
    flock -n 200 || return 1
  fi
}

# Release PID lock
release_pid_lock() {
  local pid_file="$1"
  local lock_file="${pid_file}.lock"
  if command_exists flock; then
    flock -u 200 2>/dev/null || true
  fi
  rm -f "$lock_file"
}

# Start an agent in background with monitoring
start_agent() {
  local name="$1"
  local command="$2"
  local prompt_file="$3"
  local interval="${4:-$DEFAULT_RESTART_DELAY}"
  local working_dir="${5:-$PWD}"
  local config_file="${6:-}"
  local crew_dir=".crew"

  validate_agent_name "$name" || return 1

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
    log_warn "[$name] Already running (PID: $(cat "$pid_file"))"
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

  # Start agent in background
  (
    # Export per-agent env vars (only affects this subshell)
    export_agent_env "$name" "$config_file"

    cd "$working_dir" || exit 1
    local restart_count=0
    local delay="$interval"
    
    _handle_term() {
      if [[ -n "${child_pid:-}" ]] && kill -0 "$child_pid" 2>/dev/null; then
        kill -TERM "$child_pid" 2>/dev/null || true
      fi
    }
    trap _handle_term TERM INT

    while true; do
      rotate_log_if_needed "$log_file"
      echo "[$name] Starting at $(timestamp)" >> "$log_file"
      # Run command via eval to correctly parse quotes in yaml
      eval "$command < \"$prompt_file\"" >> "$log_file" 2>&1 &
      child_pid=$!
      
      wait "$child_pid" || true
      wait "$child_pid" 2>/dev/null || true
      local exit_code=$?
      child_pid=""

      echo "[$name] Exited with code $exit_code at $(timestamp)" >> "$log_file"

      # Check if we should restart
      if [[ ! -f "$pid_file" ]]; then
        echo "[$name] PID file removed, stopping." >> "$log_file"
        break
      fi

      if [[ "$exit_code" -eq 0 ]]; then
        # Normal cycle: reset backoff
        restart_count=0
        delay="$interval"
      else
        # Error: increment restart count, apply exponential backoff
        restart_count=$((restart_count + 1))
        if [[ "$restart_count" -ge "$DEFAULT_MAX_RESTARTS" ]]; then
          echo "[$name] Max restarts ($DEFAULT_MAX_RESTARTS) reached. Giving up." >> "$log_file"
          break
        fi
        # Exponential backoff: interval * 2^(n-1), capped at MAX_BACKOFF_DELAY
        delay=$((interval * (1 << (restart_count - 1))))
        if [[ "$delay" -gt "$MAX_BACKOFF_DELAY" ]]; then
          delay="$MAX_BACKOFF_DELAY"
        fi
        echo "[$name] Error restart $restart_count/$DEFAULT_MAX_RESTARTS (backoff: ${delay}s)" >> "$log_file"
      fi

      # Wait before restart
      echo "[$name] Restarting in ${delay}s..." >> "$log_file"
      sleep "$delay"
    done
  ) < /dev/null &

  local pid=$!
  echo "$pid" > "$pid_file"
  release_pid_lock "$pid_file"

  log_ok "[$name] Started (PID: $pid)"
  log_info "[$name] Log: $log_file"
}

# Internal helper to recursively kill a process tree
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

# Stop an agent gracefully
stop_agent() {
  local name="$1"
  local crew_dir=".crew"
  local pid_file="$crew_dir/run/${name}.pid"

  if [[ ! -f "$pid_file" ]]; then
    log_warn "[$name] Not running (no PID file)"
    return 0
  fi

  # Lock PID file to prevent race conditions
  if ! acquire_pid_lock "$pid_file"; then
    log_warn "[$name] Could not acquire lock (another operation in progress)"
    return 1
  fi

  local pid
  pid=$(cat "$pid_file")

  log_info "[$name] Stopping (PID: $pid)..."

  # Remove PID file first (signals the loop to stop)
  rm -f "$pid_file"

  # Send SIGTERM for graceful shutdown
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    
    # Wait for graceful exit
    local wait_count=0
    while kill -0 "$pid" 2>/dev/null && [[ $wait_count -lt $GRACEFUL_SHUTDOWN_TIMEOUT ]]; do
      sleep 1
      wait_count=$((wait_count + 1))
    done

    # Force kill if still alive
    if kill -0 "$pid" 2>/dev/null; then
      _kill_subtree "$pid" "9"
      kill -9 "$pid" 2>/dev/null
      log_warn "[$name] Force killed"
    else
      log_ok "[$name] Stopped gracefully"
    fi
  else
    log_warn "[$name] Process not found (already stopped)"
  fi

  release_pid_lock "$pid_file"
}

# Check if agent is running
is_agent_running() {
  local name="$1"
  local crew_dir=".crew"
  local pid_file="$crew_dir/run/${name}.pid"
  
  if [[ ! -f "$pid_file" ]]; then
    return 1
  fi
  
  local pid
  pid=$(cat "$pid_file")
  
  kill -0 "$pid" 2>/dev/null
}

# Get agent status
get_agent_status() {
  local name="$1"
  local crew_dir=".crew"
  local pid_file="$crew_dir/run/${name}.pid"
  local log_file="$crew_dir/logs/${name}.log"
  
  if is_agent_running "$name"; then
    local pid
    pid=$(cat "$pid_file")
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
    cat "$pid_file"
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
  local command prompt_file interval
  command=$(config_get ".agents[] | select(.name == \"$name\") | .command" "" "$config_file")
  prompt_file=$(config_get ".agents[] | select(.name == \"$name\") | .prompt" "" "$config_file")
  interval=$(config_get ".agents[] | select(.name == \"$name\") | .interval" "$DEFAULT_RESTART_DELAY" "$config_file")
  
  if [[ -n "$command" && -n "$prompt_file" ]]; then
    start_agent "$name" "$command" ".crew/$prompt_file" "$interval" "$PWD" "$config_file" || true
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
    local command prompt_file interval
    command=$(config_get ".agents[] | select(.name == \"$name\") | .command" "" "$config_file")
    prompt_file=$(config_get ".agents[] | select(.name == \"$name\") | .prompt" "" "$config_file")
    interval=$(config_get ".agents[] | select(.name == \"$name\") | .interval" "$DEFAULT_RESTART_DELAY" "$config_file")
    
    if [[ -n "$command" && -n "$prompt_file" ]]; then
      start_agent "$name" "$command" ".crew/$prompt_file" "$interval" "$PWD" "$config_file" || true
    else
      log_warn "[$name] Skipping: missing command or prompt"
    fi
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

  # Clean up stale lock files
  rm -f "$crew_dir/run"/*.lock 2>/dev/null || true
}

# Watchdog loop - monitor and restart agents
watchdog_loop() {
  local config_file="$1"
  local check_interval="${2:-$DEFAULT_CHECK_INTERVAL}"
  
  log_info "Watchdog started (interval: ${check_interval}s)"

  trap 'log_info "Watchdog stopping..."; return 0' INT TERM

  while true; do
    sleep "$check_interval"
    
    # Check each agent
    local agents
    agents=$(config_get ".agents[].name" "" "$config_file")
    
    for name in $agents; do
      local status
      status=$(get_agent_status "$name")
      
      case "$status" in
        running:*)
          # All good
          ;;
        stale)
          log_warn "[$name] Stale PID file, cleaning up..."
          rm -f ".crew/run/${name}.pid"
          restart_agent "$name" "$config_file"
          ;;
        stopped)
          log_warn "[$name] Not running, starting..."
          local command prompt_file
          command=$(config_get ".agents[] | select(.name == \"$name\") | .command" "" "$config_file")
          prompt_file=$(config_get ".agents[] | select(.name == \"$name\") | .prompt" "" "$config_file")
          start_agent "$name" "$command" "$prompt_file"
          ;;
      esac
    done
  done
}

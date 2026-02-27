#!/bin/bash
# crew/lib/status.sh - Status display and monitoring
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/watchdog.sh"

# Constants
LOG_TRUNCATE_LENGTH=30
STATUS_TABLE_WIDTH=92
DEFAULT_MONITOR_REFRESH=2
DEFAULT_LOG_TAIL_LINES=50

# Show status of all agents
show_status() {
  local config_file="$1"
  local crew_dir=".crew"

  header "Crew Status"

  if [[ ! -f "$config_file" ]]; then
    log_error "No config found. Run 'crew init' first."
    return 1
  fi

  # Get project name
  local project
  project=$(config_get ".project" "$(basename "$PWD")" "$config_file")
  echo "Project: $project"
  echo ""

  # Get agent list
  local agents
  agents=$(config_get ".agents[].name" "" "$config_file")

  if [[ -z "$agents" ]]; then
    log_warn "No agents configured"
    return 0
  fi

  # Print table header (T071: Added CLI column to show actual CLI type)
  printf "%-15s %-10s %-10s %-15s %-10s %-12s %-20s\n" "AGENT" "STATUS" "PID" "LEVEL" "CLI" "VERDICT" "LAST LOG"
  separator "-" "$STATUS_TABLE_WIDTH"

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    local status pid_display last_log icon color status_text level_display cli_type_display verdict_display
    status=$(get_agent_status "$name")
    level_display="-"
    cli_type_display="-"
    verdict_display="-"

    case "$status" in
      running:*)
        pid_display="${status#running:}"
        icon=$(config_get ".agents[] | select(.name == \"$name\") | .icon" "🔵" "$config_file")
        color="$GREEN"
        status_text="running"
        # Read fallback state
        local fallback_state_file="$crew_dir/run/${name}.fallback"
        local fb_level=0
        if [[ -f "$fallback_state_file" ]]; then
          local fb_state
          fb_state=$(cat "$fallback_state_file")
          fb_level="${fb_state%%|*}"
          level_display="${fb_state#*|}"
        fi
        # T071: Get actual CLI type for current fallback level
        cli_type_display=$(get_fallback_cli_type "$name" "$fb_level" "$config_file" 2>/dev/null || echo "-")
        # Read verdict from progress watchdog (T049)
        local verdict_file="$crew_dir/run/${name}.verdict"
        if [[ -f "$verdict_file" ]]; then
          verdict_display=$(cat "$verdict_file")
        fi
        ;;
      stale)
        pid_display="-"
        icon="⚠️"
        color="$YELLOW"
        status_text="stale"
        ;;
      stopped)
        pid_display="-"
        icon="⭕"
        color="$RED"
        status_text="stopped"
        if [[ -f "$crew_dir/run/${name}.exhausted" ]]; then
          status_text="exhausted"
        fi
        ;;
    esac

    # Get last log line
    local log_file="$crew_dir/logs/${name}.log"
    if [[ -f "$log_file" ]]; then
      # BUG-QA-068: Use awk for UTF-8 safe truncation instead of cut -c which can split multi-byte chars
      last_log=$(tail -1 "$log_file" 2>/dev/null | awk -v len="$LOG_TRUNCATE_LENGTH" '{print substr($0, 1, len)}')
    else
      last_log="-"
    fi

    printf "${color}%-15s %-10s %-10s %-15s %-10s %-12s %-20s${NC}\n" "$icon $name" "$status_text" "$pid_display" "$level_display" "$cli_type_display" "$verdict_display" "$last_log"
  done <<< "$agents"

  echo ""
}

# Real-time monitor (like htop for agents)
monitor_loop() {
  local config_file="$1"
  local refresh="${2:-$DEFAULT_MONITOR_REFRESH}"

  trap 'echo ""; return 0' INT TERM

  while true; do
    clear
    show_status "$config_file"
    echo ""
    echo "Press Ctrl+C to exit. Refreshing every ${refresh}s..."
    sleep "$refresh"
  done
}

# Tail logs for an agent
tail_agent_log() {
  local name="$1"
  local lines="${2:-$DEFAULT_LOG_TAIL_LINES}"
  local crew_dir=".crew"

  validate_agent_name "$name" || return 1

  local log_file="$crew_dir/logs/${name}.log"

  if [[ ! -f "$log_file" ]]; then
    log_error "No log file for agent: $name"
    return 1
  fi

  header "Logs: $name"
  echo "File: $log_file"
  separator "-" 50

  tail -n "$lines" -f "$log_file"
}

# Show specific agent info
show_agent_info() {
  local name="$1"
  local config_file="$2"
  local crew_dir=".crew"

  header "Agent: $name"

  # Get config
  local command prompt_file interval timeout icon
  command=$(config_get ".agents[] | select(.name == \"$name\") | .command" "" "$config_file")
  prompt_file=$(config_get ".agents[] | select(.name == \"$name\") | .prompt" "" "$config_file")
  interval=$(config_get ".agents[] | select(.name == \"$name\") | .interval" "10" "$config_file")
  timeout=$(config_get ".agents[] | select(.name == \"$name\") | .timeout" "600" "$config_file")
  icon=$(config_get ".agents[] | select(.name == \"$name\") | .icon" "🔵" "$config_file")

  echo "Icon: $icon"
  echo "Command: $command"
  echo "Prompt: $prompt_file"
  echo "Interval: ${interval}s"
  echo "Timeout: ${timeout}s"

  # Fallback chain info
  local fb_count
  fb_count=$(get_fallback_count "$name" "$config_file")
  if [[ "$fb_count" -gt 0 ]]; then
    echo "Fallback chain: $fb_count level(s)"
    for ((i=1; i<=fb_count; i++)); do
      local fb_label
      fb_label=$(get_fallback_label "$name" "$i" "$config_file")
      echo "  $i. $fb_label"
    done
  fi

  # Current active fallback level
  local fallback_state_file="$crew_dir/run/${name}.fallback"
  if [[ -f "$fallback_state_file" ]]; then
    local fb_state
    fb_state=$(cat "$fallback_state_file")
    echo "Active level: ${fb_state#*|}"
  fi
  echo ""

  # Status
  local status
  status=$(get_agent_status "$name")
  case "$status" in
    running:*)
      echo -e "Status: ${GREEN}Running${NC} (PID: ${status#running:})"
      ;;
    stale)
      echo -e "Status: ${YELLOW}Stale${NC}"
      ;;
    stopped)
      echo -e "Status: ${RED}Stopped${NC}"
      ;;
  esac

  # Log info
  local log_file="$crew_dir/logs/${name}.log"
  if [[ -f "$log_file" ]]; then
    local log_size
    log_size=$(du -h "$log_file" | cut -f1)
    echo "Log file: $log_file ($log_size)"
    echo ""
    echo "Last 5 lines:"
    separator "-" 50
    tail -5 "$log_file"
  fi
}
# Generate a summary report of agent activity and file changes.
# Parses agent logs for run statistics and uses git to detect conflicting changes.
show_report() {
  local config_file="$1"
  local crew_dir=".crew"

  header "Crew Report"

  if [[ ! -f "$config_file" ]]; then
    log_error "No config found. Run 'crew init' first."
    return 1
  fi

  local project
  project=$(config_get ".project" "$(basename "$PWD")" "$config_file")
  echo "Project: $project"
  echo "Report generated: $(date '+%Y-%m-%d %H:%M:%S')"
  echo ""

  # ── Agent Activity Summary ──
  local agents
  agents=$(config_get ".agents[].name" "" "$config_file")

  if [[ -z "$agents" ]]; then
    log_warn "No agents configured"
    return 0
  fi

  echo "${BOLD}Agent Activity${NC}"
  separator "-" 60

  local all_modified_files=""

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    local log_file="$crew_dir/logs/${name}.log"

    if [[ ! -f "$log_file" ]]; then
      printf "  %-12s  No log data\n" "$name"
      continue
    fi

    # Parse log for statistics
    local starts exits errors timeouts
    starts=$(grep -c "\[${name}\] Starting at" "$log_file" 2>/dev/null || echo 0)
    exits=$(grep -c "\[${name}\] Exited with" "$log_file" 2>/dev/null || echo 0)
    errors=$(grep -c "\[${name}\] Error restart" "$log_file" 2>/dev/null || echo 0)
    timeouts=$(grep -c "\[${name}\] Timed out" "$log_file" 2>/dev/null || echo 0)

    # Current status
    local status
    status=$(get_agent_status "$name")
    local status_label="stopped"
    case "$status" in
      running:*) status_label="running" ;;
      stale) status_label="stale" ;;
      stopped)
        if [[ -f "$crew_dir/run/${name}.exhausted" ]]; then
          status_label="exhausted"
        fi
        ;;
    esac

    # Active fallback level
    local level_info=""
    local fallback_state_file="$crew_dir/run/${name}.fallback"
    if [[ -f "$fallback_state_file" ]]; then
      local fb_state
      fb_state=$(cat "$fallback_state_file")
      level_info=" [${fb_state#*|}]"
    fi

    printf "  %-12s  status=%-10s starts=%-3s exits=%-3s errors=%-3s timeouts=%-3s%s\n" \
      "$name" "$status_label" "$starts" "$exits" "$errors" "$timeouts" "$level_info"
  done <<< "$agents"

  echo ""

  # ── File Changes ──
  if command_exists git && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "${BOLD}File Changes (uncommitted)${NC}"
    separator "-" 60

    local diff_stat
    diff_stat=$(git diff --stat HEAD 2>/dev/null || true)
    local untracked
    untracked=$(git ls-files --others --exclude-standard 2>/dev/null || true)

    if [[ -n "$diff_stat" ]]; then
      echo "$diff_stat"
    else
      echo "  No uncommitted changes"
    fi

    if [[ -n "$untracked" ]]; then
      echo ""
      echo "  Untracked files:"
      echo "$untracked" | while IFS= read -r f; do
        echo "    + $f"
      done
    fi
    echo ""

    # ── Conflict Detection ──
    # Check recent commits for files modified by different commit authors/messages
    # that might indicate multiple agents touching the same files
    local recent_files
    recent_files=$(git diff --name-only HEAD 2>/dev/null || true)
    local changed_files
    changed_files=$(git diff --cached --name-only 2>/dev/null || true)
    all_modified_files=$(printf '%s\n%s\n%s' "$recent_files" "$changed_files" "$untracked" | sort -u | grep -v '^$' || true)

    if [[ -n "$all_modified_files" ]]; then
      # Check if any modified files appear in multiple agent logs
      local conflict_found=false
      local conflict_files=""

      while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        local matching_agents=""
        local match_count=0

        while IFS= read -r name; do
          [[ -z "$name" ]] && continue
          local log_file="$crew_dir/logs/${name}.log"
          [[ ! -f "$log_file" ]] && continue

          if grep -q "$file" "$log_file" 2>/dev/null; then
            matching_agents="$matching_agents $name"
            match_count=$((match_count + 1))
          fi
        done <<< "$agents"

        if [[ "$match_count" -ge 2 ]]; then
          conflict_found=true
          conflict_files="${conflict_files}  ${YELLOW}!${NC} $file — mentioned in logs of:$matching_agents\n"
        fi
      done <<< "$all_modified_files"

      if $conflict_found; then
        echo "${BOLD}${YELLOW}Potential Conflicts${NC}"
        separator "-" 60
        echo -e "$conflict_files"
        log_warn "Files above appear in multiple agent logs — review for conflicting changes"
      else
        echo "${BOLD}Conflicts${NC}"
        separator "-" 60
        echo "  No conflicts detected"
      fi
      echo ""
    fi
  fi
}

# NOTE: show_cost() is defined in lib/cost.sh (supersedes the original
# runtime-based version that was here). Do not re-add a show_cost() here.

# Internal helper for recursive process tree
_print_subtree() {
  local ppid=$1
  local indent=$2

  local children
  children=$(pgrep -P "$ppid" 2>/dev/null || echo "")

  for child in $children; do
    [[ -z "$child" ]] && continue

    # BUG-QA-060: Use comm= instead of args= to avoid exposing env vars/secrets
    local cmd_name
    cmd_name=$(ps -p "$child" -o comm= 2>/dev/null || echo "")
    [[ -z "$cmd_name" ]] && continue

    printf "%s└─ %-6s %s\n" "$indent" "$child" "$cmd_name"

    # Recurse
    _print_subtree "$child" "   $indent"
  done
}

# Show active sub-processes for all agents
show_processes() {
  local config_file="$1"
  local crew_dir=".crew"

  header "Agent Process Tree"

  if [[ ! -f "$config_file" ]]; then
    log_error "No config found. Run 'crew init' first."
    return 1
  fi

  local agents
  agents=$(config_get ".agents[].name" "" "$config_file")

  if [[ -z "$agents" ]]; then
    log_warn "No agents configured"
    return 0
  fi

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    local pid=""
    local pid_file="${crew_dir}/run/${name}.pid"

    if is_agent_running "$name"; then
      pid=$(_read_pid "$pid_file")
    fi

    if [[ -n "$pid" ]]; then
      echo -e "${BOLD}${BLUE}● $name${NC} (Watchdog PID: $pid)"
      _print_subtree "$pid" "  "
    else
      echo -e "${RED}○ $name${NC} (Not running)"
    fi
    echo ""
  done <<< "$agents"
}

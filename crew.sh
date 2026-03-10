#!/bin/bash
# crew - Multi-agent parallel orchestration
#
# Usage:
#   crew init [--template T]  Create .crew/ with config
#   crew start [AGENT..] Start all or specific agents
#   crew stop [AGENT..]  Stop all or specific agents
#   crew restart [AGENT] Restart agent(s)
#   crew status          Show agent status
#   crew ps              Show active agent processes
#   crew monitor         Real-time dashboard
#   crew logs AGENT      Tail agent logs
#   crew cost            Show token usage and cost estimates
#   crew context         Show/edit shared agent context
#   crew validate        Check config syntax

set -euo pipefail

# Get script directory (resolve symlinks for install via ~/.local/bin)
SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
  DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/plugin_loader.sh"
source "$SCRIPT_DIR/lib/watchdog.sh"
source "$SCRIPT_DIR/lib/status.sh"
source "$SCRIPT_DIR/lib/cost.sh"

VERSION=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "unknown")
CREW_DIR=".crew"
WATCHDOG_ENABLED=true
CHECK_INTERVAL=""

# Resolve config file: local .crew/ → parent dirs → ~/.crew/
# Falls back to local default for commands that don't need an existing config.
_resolve_config() {
  local config
  config=$(find_config "crew.yaml" 2>/dev/null) || config="$CREW_DIR/crew.yaml"
  echo "$config"
}

# Get the .crew/ dir that contains the resolved config (for logs, run, prompts)
_resolve_crew_dir() {
  local config="$1"
  dirname "$config"
}

usage() {
  cat << EOF
${BOLD}crew${NC} - Multi-agent parallel orchestration

${BOLD}USAGE${NC}
  crew <command> [options]

${BOLD}COMMANDS${NC}
  init [--template T]  Create .crew/ with config (optionally from template)
  start [AGENT...]     Start all or specific agents
  stop [AGENT...]      Stop all or specific agents
  restart [AGENT...]   Restart agent(s)
  status               Show agent status
  ps                   Show active agent processes
  monitor              Real-time dashboard
  logs <AGENT>         Tail agent logs
  report               Show agent activity summary and conflicts
  cost                 Show runtime and cost estimates per agent
  context [show|edit|clear]  Manage shared context between agents
  plugins              List available CLI plugins
  edit <AGENT>         Edit agent prompt in \$EDITOR
  serve --mcp          Start MCP server (JSON-RPC over stdio)
  validate             Check config syntax
  help                 Show this help

${BOLD}OPTIONS${NC}
  --check-interval N   Health check interval in seconds (default: 30)
  --no-watchdog        Start agents without watchdog

${BOLD}EXAMPLES${NC}
  # Initialize with default config
  crew init

  # Initialize with a workflow template
  crew init --template code-review

  # List available templates
  crew init --list-templates

  # Start all agents
  crew start

  # Start specific agents
  crew start QA DEV

  # Restart all agents
  crew restart

  # Restart specific agent
  crew restart JANITOR

  # Show active processes
  crew ps

  # Monitor in real-time
  crew monitor

  # Edit agent prompt
  crew edit QA

  # View logs
  crew logs QA

  # Check config before starting
  crew validate

${BOLD}TROUBLESHOOTING${NC}
  "No config found"       Run 'crew init' first
  "CLI not installed"     Install the agent CLI (see 'crew plugins')
  "Prompt file not found" Check paths in .crew/crew.yaml
  "yq is required"        Install yq: brew install yq
  Agents keep restarting  Check .crew/logs/<AGENT>.log for errors
  Ghost processes         Run 'crew stop' then 'crew ps' to verify

${BOLD}FILES${NC}
  .crew/
  ├── crew.yaml         Config file
  ├── prompts/          Agent prompts
  ├── logs/             Agent logs
  └── run/              PID files

${BOLD}VERSION${NC}
  $VERSION
EOF
}

# List available workflow templates
crew_list_templates() {
  local crew_home
  crew_home=$(get_crew_home)
  local templates_dir="$crew_home/templates/workflows"

  if [[ ! -d "$templates_dir" ]]; then
    log_error "No templates directory found"
    return 1
  fi

  header "Available Workflow Templates"
  echo ""

  for template_dir in "$templates_dir"/*/; do
    [[ ! -d "$template_dir" ]] && continue
    local name
    name=$(basename "$template_dir")
    local desc=""
    if [[ -f "$template_dir/description.txt" ]]; then
      desc=$(head -1 "$template_dir/description.txt")
    fi
    printf "  %-18s %s\n" "$name" "$desc"
  done

  echo ""
  log_info "Usage: crew init --template <name>"
}

# Initialize crew in current directory
crew_init() {
  local template=""

  # Parse init-specific flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --template)
        shift
        [[ $# -eq 0 ]] && { log_error "--template requires a name"; return 1; }
        template="$1"
        shift
        ;;
      --list-templates)
        crew_list_templates
        return 0
        ;;
      *)
        log_error "Unknown option for init: $1"
        return 1
        ;;
    esac
  done

  header "Initializing Crew"

  if [[ -d "$CREW_DIR" ]]; then
    if ! confirm ".$CREW_DIR already exists. Overwrite config?"; then
      return 0
    fi
  fi

  ensure_dir "$CREW_DIR"
  ensure_dir "$CREW_DIR/prompts"
  ensure_dir "$CREW_DIR/logs"
  ensure_dir "$CREW_DIR/run"
  ensure_dir "$CREW_DIR/shared"

  local crew_home
  crew_home=$(get_crew_home)

  if [[ -n "$template" ]]; then
    # Use workflow template
    local template_dir="$crew_home/templates/workflows/$template"
    if [[ ! -d "$template_dir" ]]; then
      log_error "Unknown template: $template"
      log_info "Run 'crew init --list-templates' to see available templates"
      return 1
    fi

    if [[ ! -f "$template_dir/crew.yaml" ]]; then
      log_error "Template missing crew.yaml: $template_dir"
      return 1
    fi

    # Copy template config, substitute project name
    # Escape sed special characters (&, /, \) in project name to prevent injection
    local project_name
    project_name=$(basename "$PWD" | sed 's/[&/\]/\\&/g')
    sed "s/^project: .*/project: $project_name/" "$template_dir/crew.yaml" > "$CONFIG_FILE"
    log_ok "Created $CONFIG_FILE from template: $template"

    # Copy only the prompts referenced in the template
    local agent_prompts
    agent_prompts=$(grep -oE 'prompts/[a-z_-]+\.md' "$CONFIG_FILE" 2>/dev/null || true)
    for prompt_ref in $agent_prompts; do
      local prompt_basename
      prompt_basename=$(basename "$prompt_ref")
      local role="${prompt_basename%.md}"
      if [[ -f "$crew_home/prompts/crew/${role}.md" ]]; then
        cp "$crew_home/prompts/crew/${role}.md" "$CREW_DIR/prompts/"
        log_ok "Copied prompts/${role}.md"
      else
        log_warn "Default prompt not found: prompts/crew/${role}.md"
      fi
    done
  else
    # Default: copy full example config
    if [[ -f "$crew_home/templates/crew.yaml.example" ]]; then
      cp "$crew_home/templates/crew.yaml.example" "$CONFIG_FILE"
      log_ok "Created $CONFIG_FILE from template"
    else
      log_error "Template not found: $crew_home/templates/crew.yaml.example"
      return 1
    fi

    # Copy all default prompts
    for role in qa dev janitor; do
      if [[ -f "$crew_home/prompts/crew/${role}.md" ]]; then
        cp "$crew_home/prompts/crew/${role}.md" "$CREW_DIR/prompts/"
        log_ok "Copied prompts/${role}.md"
      else
        log_warn "Default prompt not found: prompts/crew/${role}.md"
      fi
    done
  fi

  # Copy .env.example
  if [[ -f "$crew_home/templates/.env.example" ]]; then
    cp "$crew_home/templates/.env.example" "$CREW_DIR/.env.example"
    log_ok "Copied .env.example"
  fi

  echo ""
  log_info "Crew initialized!"
  log_info "Edit $CONFIG_FILE to configure agents"
  log_info "Run 'crew start' to begin"
}

# Start agents
crew_start() {
  local agents=("$@")

  if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "No config found. Run 'crew init' first."
    return 1
  fi

  validate_yaml_parser || return 1

  # Pre-flight: validate prompt files and CLI tools before starting
  validate_crew_preflight "$CONFIG_FILE" "$@" || return 1

  # Cleanup trap: stop all agents on exit/interrupt
  _crew_cleanup() {
    local exit_code=$?
    trap - EXIT INT TERM
    stop_watchdog 2>/dev/null || true
    stop_all_agents 2>/dev/null || true
    exit "$exit_code"
  }
  trap _crew_cleanup EXIT INT TERM

  log_warn "Agents run with full system access and can modify/delete files."
  log_warn "Review .crew/crew.yaml and prompts before proceeding."

  header "Starting Agents"

  local runtime_dir=".crew"
  ensure_dir "$runtime_dir/run"
  ensure_dir "$runtime_dir/logs"

  # Clean exhausted markers so fallback chain resets on explicit start
  rm -f "$runtime_dir/run"/*.exhausted 2>/dev/null || true

  # Stop existing watchdog to avoid concurrent monitoring conflicts (e.g. one tracking DEV, one tracking ALL)
  stop_watchdog 2>/dev/null || true

  if [[ ${#agents[@]} -eq 0 ]]; then
    # Start all
    start_all_agents "$CONFIG_FILE"
  else
    # Start specific agents
    for name in "${agents[@]}"; do
      validate_agent_name "$name" || continue
      local prompt_file interval cli_type
      prompt_file=$(config_get ".agents[] | select(.name == \"$name\") | .prompt" "" "$CONFIG_FILE")
      interval=$(config_get ".agents[] | select(.name == \"$name\") | .interval" "$DEFAULT_RESTART_DELAY" "$CONFIG_FILE")

      if [[ -z "$prompt_file" ]]; then
        log_error "[$name] Not found in config"
        continue
      fi

      # Pre-validate plugin for type-based agents
      cli_type=$(get_agent_cli_type "$name" "$CONFIG_FILE")
      if [[ "$cli_type" != "command" ]]; then
        if ! load_plugin "$cli_type" 2>/dev/null; then
          log_error "[$name] Unknown CLI type: $cli_type"
          continue
        fi
      fi

      start_agent "$name" "$CREW_DIR/$prompt_file" "$interval" "$PWD" "$CONFIG_FILE" || true
    done
  fi

  # Start watchdog loop in background if enabled
  if [[ "$WATCHDOG_ENABLED" == "true" ]]; then
    # Priority: CLI flag > config file > hardcoded default
    local wd_interval="$CHECK_INTERVAL"
    if [[ -z "$wd_interval" ]]; then
      wd_interval=$(config_get ".check_interval" "$DEFAULT_CHECK_INTERVAL" "$CONFIG_FILE")
    fi
    (
      watchdog_loop "$CONFIG_FILE" "$wd_interval" "${agents[@]:-}"
    ) < /dev/null &
    local wd_pid=$!
    _write_pid "$wd_pid" ".crew/run/watchdog.pid"
    log_info "Watchdog started (PID: $wd_pid, interval: ${wd_interval}s)"
  fi

  # Success: clear trap so we don't kill agents on exit
  trap - EXIT INT TERM
}

# Stop the watchdog process if running.
# Creates a sentinel file so the watchdog exits its loop even if SIGTERM
# can't interrupt its sleep (bash 3.2 on macOS).
stop_watchdog() {
  local runtime_dir=".crew"
  local wd_pid_file="$runtime_dir/run/watchdog.pid"
  local stop_sentinel="$runtime_dir/run/watchdog.stop"

  # Create sentinel first — watchdog checks this before restarting agents
  touch "$stop_sentinel"

  if [[ -f "$wd_pid_file" ]]; then
    local wd_pid
    wd_pid=$(_read_pid "$wd_pid_file")
    if kill -0 "$wd_pid" 2>/dev/null; then
      kill -TERM "$wd_pid" 2>/dev/null || true

      # Wait for watchdog to actually exit
      local wait_count=0
      while kill -0 "$wd_pid" 2>/dev/null && [[ $wait_count -lt $GRACEFUL_SHUTDOWN_TIMEOUT ]]; do
        sleep 1
        wait_count=$((wait_count + 1))
      done

      if kill -0 "$wd_pid" 2>/dev/null; then
        kill -9 "$wd_pid" 2>/dev/null || true
        log_warn "Watchdog force killed (PID: $wd_pid)"
      else
        log_info "Watchdog stopped (PID: $wd_pid)"
      fi
    fi
    rm -f "$wd_pid_file"
  fi

  rm -f "$stop_sentinel"
}

# Stop agents
crew_stop() {
  local agents=("$@")

  header "Stopping Agents"

  if [[ ${#agents[@]} -eq 0 ]]; then
    stop_watchdog
    stop_all_agents
  else
    for name in "${agents[@]}"; do
      validate_agent_name "$name" || continue
      stop_agent "$name"
    done
  fi
}

# Restart agents
crew_restart() {
  local agents=("$@")

  header "Restarting Agents"

  if [[ ${#agents[@]} -eq 0 ]]; then
    stop_all_agents
    sleep 2
    start_all_agents "$CONFIG_FILE"
  else
    for name in "${agents[@]}"; do
      validate_agent_name "$name" || continue
      restart_agent "$name" "$CONFIG_FILE"
    done
  fi
}

# Show status
crew_status() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "No config found. Run 'crew init' first."
    return 1
  fi

  show_status "$CONFIG_FILE"
}

# Show agent processes
crew_ps() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "No config found. Run 'crew init' first."
    return 1
  fi

  show_processes "$CONFIG_FILE"
}

# Monitor mode
crew_monitor() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "No config found. Run 'crew init' first."
    return 1
  fi

  monitor_loop "$CONFIG_FILE"
}

# Tail logs
crew_logs() {
  local name="$1"

  if [[ -z "$name" ]]; then
    log_error "Usage: crew logs <AGENT>"
    return 1
  fi

  validate_agent_name "$name" || return 1
  tail_agent_log "$name"
}

# List available plugins
crew_plugins() {
  list_plugins "crew"
}

# Edit agent prompt
crew_edit() {
  local name="${1:-}"

  if [[ -z "$name" ]]; then
    log_error "Usage: crew edit <AGENT>"
    return 1
  fi

  validate_agent_name "$name" || return 1

  if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "No config found. Run 'crew init' first."
    return 1
  fi

  local prompt_file
  prompt_file=$(config_get ".agents[] | select(.name == \"$name\") | .prompt" "" "$CONFIG_FILE")

  if [[ -z "$prompt_file" || "$prompt_file" == "null" ]]; then
    log_error "[$name] Not found in config"
    return 1
  fi

  local full_path="$CREW_DIR/$prompt_file"
  if [[ ! -f "$full_path" ]]; then
    log_error "[$name] Prompt file not found: $full_path"
    return 1
  fi

  local editor="${EDITOR:-vi}"
  "$editor" "$full_path"
}

# Show cost/runtime estimates
crew_cost() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "No config found. Run 'crew init' first."
    return 1
  fi

  show_cost "$CONFIG_FILE"
}

# Show aggregated report
crew_report() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "No config found. Run 'crew init' first."
    return 1
  fi

  show_report "$CONFIG_FILE"
}

# Show or edit shared context
crew_context() {
  local action="${1:-show}"
  local runtime_dir=".crew"

  ensure_dir "$runtime_dir/shared"
  local context_file="$runtime_dir/shared/context.md"

  case "$action" in
    show)
      header "Shared Context"
      if [[ -f "$context_file" ]] && [[ -s "$context_file" ]]; then
        cat "$context_file"
      else
        log_info "No shared context. Use 'crew context edit' to add one."
      fi
      ;;
    edit)
      if [[ ! -f "$context_file" ]]; then
        cat > "$context_file" << 'TMPL'
# Shared Context

> This file is automatically injected into all agent prompts.
> Agents can read this context at the start of each run.
> Use it to share state, decisions, or instructions between agents.

TMPL
      fi
      local editor="${EDITOR:-vi}"
      "$editor" "$context_file"
      ;;
    clear)
      if [[ -f "$context_file" ]]; then
        rm -f "$context_file"
        log_ok "Shared context cleared"
      else
        log_info "No shared context to clear"
      fi
      ;;
    *)
      log_error "Usage: crew context [show|edit|clear]"
      return 1
      ;;
  esac
}

# Start MCP server
crew_serve() {
  local mode="${1:-}"

  if [[ "$mode" != "--mcp" ]]; then
    log_error "Usage: crew serve --mcp"
    return 1
  fi

  exec "$SCRIPT_DIR/crew-mcp.sh"
}

# Validate config
crew_validate() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "No config found."
    return 1
  fi

  validate_config "$CONFIG_FILE"
}

# Main
main() {
  # BUG-QA-103: Resolve symlinks in project directory to prevent symlink-based attacks.
  # Uses cd -P to get the physical path (no symlinks) instead of relying on $PWD.
  if [[ -L "$PWD" ]] || [[ "$(cd -P . && pwd)" != "$PWD" ]]; then
    cd -P .
    log_debug "Resolved symlinked working directory to: $PWD"
  fi

  # Parse global options
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check-interval)
        shift
        [[ $# -eq 0 ]] && { log_error "--check-interval requires a value"; exit 1; }
        CHECK_INTERVAL="$1"
        validate_interval "$CHECK_INTERVAL" || exit 1
        shift
        ;;
      --no-watchdog)
        WATCHDOG_ENABLED=false
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      --version|-v)
        echo "crew $VERSION"
        exit 0
        ;;
      *)
        break
        ;;
    esac
  done

  local cmd="${1:-help}"
  shift 2>/dev/null || true

  # Resolve config for all commands except init and help
  local CONFIG_FILE
  local CREW_DIR

  if [[ "$cmd" != "init" && "$cmd" != "help" ]]; then
    CONFIG_FILE=$(_resolve_config)
    CREW_DIR=$(_resolve_crew_dir "$CONFIG_FILE")
  else
    CREW_DIR=".crew"
    CONFIG_FILE="$CREW_DIR/crew.yaml"
  fi

  case "$cmd" in
    init)
      crew_init "$@"
      ;;
    start)
      crew_start "$@"
      ;;
    stop)
      crew_stop "$@"
      ;;
    restart)
      crew_restart "$@"
      ;;
    status)
      crew_status
      ;;
    ps)
      crew_ps
      ;;
    monitor)
      crew_monitor
      ;;
    logs)
      crew_logs "$@"
      ;;
    edit)
      crew_edit "$@"
      ;;
    plugins)
      crew_plugins
      ;;
    report)
      crew_report
      ;;
    context)
      crew_context "$@"
      ;;
    cost)
      crew_cost
      ;;
    serve)
      crew_serve "$@"
      ;;
    validate)
      crew_validate
      ;;
    help|--help|-h)
      usage
      ;;
    version|--version|-v)
      echo "crew $VERSION"
      ;;
    *)
      log_error "Unknown command: $cmd"
      echo ""
      usage
      exit 1
      ;;
  esac
}

# Only run main when executed directly, not when sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

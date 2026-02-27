#!/bin/bash
# crew - Multi-agent parallel orchestration
#
# Usage:
#   crew init            Create .crew/ with template config
#   crew start [AGENT..] Start all or specific agents
#   crew stop [AGENT..]  Stop all or specific agents
#   crew restart [AGENT] Restart agent(s)
#   crew status          Show agent status
#   crew ps              Show active agent processes
#   crew monitor         Real-time dashboard
#   crew logs AGENT      Tail agent logs
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

VERSION="0.2.0"
CREW_DIR=".crew"
CONFIG_FILE="$CREW_DIR/crew.yaml"

usage() {
  cat << EOF
${BOLD}crew${NC} - Multi-agent parallel orchestration

${BOLD}USAGE${NC}
  crew <command> [options]

${BOLD}COMMANDS${NC}
  init                 Create .crew/ with template config
  start [AGENT...]     Start all or specific agents
  stop [AGENT...]      Stop all or specific agents
  restart [AGENT...]   Restart agent(s)
  status               Show agent status
  ps                   Show active agent processes
  monitor              Real-time dashboard
  logs <AGENT>         Tail agent logs
  plugins              List available CLI plugins
  validate             Check config syntax
  help                 Show this help

${BOLD}OPTIONS${NC}
  --check-interval N   Health check interval in seconds (default: 30)
  --no-watchdog        Start agents without watchdog

${BOLD}EXAMPLES${NC}
  # Initialize in a project
  crew init

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

  # View logs
  crew logs QA

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

# Initialize crew in current directory
crew_init() {
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
  
  # Copy default config from templates
  local crew_home
  crew_home=$(get_crew_home)
  
  if [[ -f "$crew_home/templates/crew.yaml.example" ]]; then
    cp "$crew_home/templates/crew.yaml.example" "$CONFIG_FILE"
    log_ok "Created $CONFIG_FILE from template"
  else
    log_error "Template not found: $crew_home/templates/crew.yaml.example"
    return 1
  fi

  # Copy default prompts from crew home
  local crew_home
  crew_home=$(get_crew_home)

  for role in qa dev janitor; do
    if [[ -f "$crew_home/prompts/crew/${role}.md" ]]; then
      cp "$crew_home/prompts/crew/${role}.md" "$CREW_DIR/prompts/"
      log_ok "Copied prompts/${role}.md"
    else
      log_warn "Default prompt not found: prompts/crew/${role}.md"
    fi
  done

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
  
  # Cleanup trap: stop all agents on exit/interrupt
  _crew_cleanup() {
    local exit_code=$?
    trap - EXIT INT TERM
    stop_all_agents 2>/dev/null || true
    exit "$exit_code"
  }
  trap _crew_cleanup EXIT INT TERM

  log_warn "Agents run with full system access and can modify/delete files."
  log_warn "Review .crew/crew.yaml and prompts before proceeding."

  header "Starting Agents"

  # Clean exhausted markers so fallback chain resets on explicit start
  rm -f "$CREW_DIR/run"/*.exhausted 2>/dev/null || true

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
  
  # Success: clear trap so we don't kill agents on exit
  trap - EXIT INT TERM
}

# Stop agents
crew_stop() {
  local agents=("$@")
  
  header "Stopping Agents"
  
  if [[ ${#agents[@]} -eq 0 ]]; then
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
  list_plugins
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
  local cmd="${1:-help}"
  shift 2>/dev/null || true
  
  case "$cmd" in
    init)
      crew_init
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
    plugins)
      crew_plugins
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

main "$@"

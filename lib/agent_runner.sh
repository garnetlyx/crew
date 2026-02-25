#!/bin/bash
# crew/lib/agent_runner.sh - Unified agent interface (design mode)
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/plugin_loader.sh"

# Agent runner - unified interface for CLI agents via plugin system
# Usage: agent_runner <agent_type> <prompt_file> [--inject FILE...] [--cwd DIR]
agent_runner() {
  local agent_type="$1"
  local prompt_file="$2"
  shift 2

  local inject_files=()
  local working_dir="$PWD"

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --inject)
        shift
        inject_files+=("$1")
        ;;
      --cwd)
        shift
        working_dir="$1"
        ;;
      *)
        log_warn "Unknown argument: $1"
        ;;
    esac
    shift
  done

  # Validate prompt file
  if [[ ! -f "$prompt_file" ]]; then
    log_error "Prompt file not found: $prompt_file"
    return 1
  fi

  # Build the full prompt with injected context
  local full_prompt
  full_prompt=$(build_prompt "$prompt_file" "${inject_files[@]+"${inject_files[@]}"}")

  # Run via plugin system
  log_debug "Running agent: $agent_type"
  log_debug "Prompt file: $prompt_file"
  log_debug "Inject files: ${inject_files[*]:-}"

  plugin_run_prompt "$agent_type" "$full_prompt" "$working_dir" "design"
}

# Build prompt with injected files
build_prompt() {
  local prompt_file="$1"
  shift
  local inject_files=("$@")

  local prompt=""

  # Add injected context first
  for file in "${inject_files[@]}"; do
    if [[ -f "$file" ]]; then
      local filename
      filename=$(basename "$file")
      prompt+="<context file=\"$filename\">"$'\n'
      prompt+=$(cat "$file")
      prompt+=$'\n'"</context>"$'\n\n'
    fi
  done

  # Add main prompt
  prompt+=$(cat "$prompt_file")

  echo "$prompt"
}

# Check if agent is available (delegates to plugin system)
check_agent() {
  local agent_type="$1"
  plugin_check "$agent_type"
}

# List available agents (delegates to plugin system)
list_agents() {
  list_plugins
}

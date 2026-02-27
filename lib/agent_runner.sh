#!/bin/bash
# crew/lib/agent_runner.sh - Unified agent interface for design mode.
#
# This module bridges design-review orchestration to the plugin system.
# Design mode differs from crew mode: it runs agents synchronously (one at a time,
# writer then reviewer) rather than as persistent background processes.
#
# Key abstraction: agent_runner() accepts an agent type string (e.g., "claude",
# "gemini") and delegates to plugin_run(). This decouples orchestrator.sh from
# any specific CLI tool — adding a new agent requires only a plugin, not changes here.
#
# Prompt construction: build_prompt() assembles a temp file containing injected
# context files (idea.txt, plan.md, review.md) wrapped in <context> XML tags,
# followed by the main prompt. This avoids ARG_MAX limits from passing large
# prompts as CLI arguments (D003).
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/plugin_loader.sh"

# Run an agent synchronously with optional context injection.
# Builds a combined prompt (injected files + main prompt) as a temp file,
# passes it to the plugin system, and cleans up on completion.
# The "design" mode flag tells plugin_run this is a one-shot design invocation.
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
        if [[ $# -eq 0 ]]; then
          log_error "--inject requires a file argument"
          return 1
        fi
        inject_files+=("$1")
        ;;
      --cwd)
        shift
        if [[ $# -eq 0 ]]; then
          log_error "--cwd requires a directory argument"
          return 1
        fi
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

  # BUG-QA-063: Reject symlinked prompt files to prevent arbitrary file read
  if [[ -L "$prompt_file" ]]; then
    log_error "Prompt file is a symlink (not allowed): $prompt_file"
    return 1
  fi

  # Build the full prompt as a temp file to avoid ARG_MAX limits
  # BUG-QA-057: Use umask to create temp file with 600 permissions atomically
  local tmp_prompt old_umask
  old_umask=$(umask)
  umask 077
  tmp_prompt=$(mktemp)
  umask "$old_umask"

  build_prompt "$prompt_file" "${inject_files[@]+"${inject_files[@]}"}" > "$tmp_prompt"

  # Run via plugin system (file-based to handle large prompts)
  log_debug "Running agent: $agent_type"
  log_debug "Prompt file: $prompt_file"
  log_debug "Inject files: ${inject_files[*]:-}"

  local rc=0
  plugin_run "$agent_type" "$tmp_prompt" "$working_dir" "design" || rc=$?
  rm -f "$tmp_prompt"
  return "$rc"
}

# Build a composite prompt: context files first, then the main prompt.
# Context files are wrapped in <context file="name"> XML tags so the AI agent
# can distinguish between injected state (idea, plan, review) and instructions.
# Output goes to stdout; caller redirects to a temp file.
build_prompt() {
  local prompt_file="$1"
  shift
  local inject_files=("$@")

  local prompt=""

  # Add injected context first
  for file in "${inject_files[@]}"; do
    # BUG-QA-063: Skip symlinked inject files
    if [[ -L "$file" ]]; then
      log_warn "Skipping symlinked inject file: $file"
      continue
    fi
    if [[ -f "$file" ]]; then
      local filename
      filename=$(basename "$file")
      # Escape XML special characters in filename to prevent injection (BUG-QA-003)
      filename="${filename//&/&amp;}"
      filename="${filename//</&lt;}"
      filename="${filename//>/&gt;}"
      filename="${filename//\"/&quot;}"
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

#!/bin/bash
# CLI plugin: aider

cli_aider_check() {
  command_exists aider
}

cli_aider_run() {
  local prompt_file="$1"
  local working_dir="$2"
  if ! cd "$working_dir" 2>/dev/null; then
    echo "aider: working directory does not exist: $working_dir" >&2
    return 1
  fi
  local message
  message=$(cat "$prompt_file")
  # Use array-based command to prevent any shell interpretation of message content
  local cmd=(aider --message "$message" --yes-always)
  "${cmd[@]}"
}

cli_aider_run_prompt() {
  local prompt="$1"
  local working_dir="$2"
  if ! cd "$working_dir" 2>/dev/null; then
    echo "aider: working directory does not exist: $working_dir" >&2
    return 1
  fi
  # Use array-based command to prevent any shell interpretation of prompt content
  local cmd=(aider --message "$prompt" --yes-always)
  "${cmd[@]}"
}

cli_aider_install_hint() {
  echo "Install aider: pip install aider-chat"
}

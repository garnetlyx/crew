#!/bin/bash
# CLI plugin: aider

cli_aider_check() {
  command_exists aider
}

cli_aider_run() {
  local prompt_file="$1"
  local working_dir="$2"
  local message
  message=$(cat "$prompt_file")
  (cd "$working_dir" && aider --message "$message" --yes-always)
}

cli_aider_run_prompt() {
  local prompt="$1"
  local working_dir="$2"
  (cd "$working_dir" && aider --message "$prompt" --yes-always)
}

cli_aider_install_hint() {
  echo "Install aider: pip install aider-chat"
}

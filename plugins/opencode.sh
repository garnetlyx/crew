#!/bin/bash
# CLI plugin: opencode

cli_opencode_check() {
  command_exists opencode
}

cli_opencode_run() {
  local prompt_file="$1"
  local working_dir="$2"
  local message
  message=$(cat "$prompt_file")
  (cd "$working_dir" && opencode run -- "$message")
}

cli_opencode_run_prompt() {
  local prompt="$1"
  local working_dir="$2"
  (cd "$working_dir" && opencode run -- "$prompt")
}

cli_opencode_install_hint() {
  echo "Install OpenCode: curl -fsSL https://opencode.ai/install | bash"
}

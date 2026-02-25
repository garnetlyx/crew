#!/bin/bash
# CLI plugin: gemini (Google Gemini CLI)
# Requires: gemini CLI (npm install -g @anthropic-ai/gemini-cli)
# Note: Uses -y (yolo) mode for auto-approval of all tool calls.
#       --sandbox restricts tool access and must NOT be used for agents
#       that need filesystem access (write_file, run_shell_command are
#       unavailable in sandbox mode).

cli_gemini_check() {
  command_exists gemini
}

cli_gemini_run() {
  local prompt_file="$1"
  local working_dir="$2"
  local message
  message=$(cat "$prompt_file")
  (cd "$working_dir" && gemini -y -p "$message")
}

cli_gemini_run_prompt() {
  local prompt="$1"
  local working_dir="$2"
  (cd "$working_dir" && gemini -y -p "$prompt")
}

cli_gemini_install_hint() {
  echo "Install Gemini CLI: npm install -g @anthropic-ai/gemini-cli"
}

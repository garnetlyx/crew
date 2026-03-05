#!/bin/bash
# CLI plugin: gemini (Google Gemini CLI)
# Requires: gemini CLI (npm install -g gemini-cli)
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
  if ! cd "$working_dir" 2>/dev/null; then
    echo "gemini: working directory does not exist: $working_dir" >&2
    return 1
  fi
  # Use a space prefix before the prompt to prevent yargs from parsing
  # leading hyphens (---) as CLI flags. The space prevents the issue safely.
  local prompt
  prompt=$(cat "$prompt_file")
  gemini -y -p " $prompt"
}

cli_gemini_run_prompt() {
  local prompt="$1"
  local working_dir="$2"
  if ! cd "$working_dir" 2>/dev/null; then
    echo "gemini: working directory does not exist: $working_dir" >&2
    return 1
  fi
  # Use a space prefix to prevent yargs parsing errors for dashes.
  gemini -y -p " $prompt"
}

cli_gemini_install_hint() {
  echo "Install Gemini CLI: npm install -g gemini-cli"
}

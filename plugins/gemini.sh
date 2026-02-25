#!/bin/bash
# CLI plugin: gemini (Google Gemini CLI)

cli_gemini_check() {
  command_exists gemini
}

cli_gemini_run() {
  local prompt_file="$1"
  local working_dir="$2"
  local message
  message=$(cat "$prompt_file")
  (cd "$working_dir" && gemini --sandbox -p "$message")
}

cli_gemini_run_prompt() {
  local prompt="$1"
  local working_dir="$2"
  (cd "$working_dir" && gemini --sandbox -p "$prompt")
}

cli_gemini_install_hint() {
  echo "Install Gemini CLI: npm install -g @anthropic-ai/gemini-cli"
}

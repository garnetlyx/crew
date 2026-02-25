#!/bin/bash
# CLI plugin: codex (OpenAI Codex CLI)

cli_codex_check() {
  command_exists codex
}

cli_codex_run() {
  local prompt_file="$1"
  local working_dir="$2"
  (cd "$working_dir" && codex exec --dangerously-bypass-approvals-and-sandbox - < "$prompt_file")
}

cli_codex_run_prompt() {
  local prompt="$1"
  local working_dir="$2"
  (cd "$working_dir" && echo "$prompt" | codex exec --dangerously-bypass-approvals-and-sandbox -)
}

cli_codex_install_hint() {
  echo "Install Codex CLI: npm install -g @openai/codex"
}

#!/bin/bash
# CLI plugin: claude (Anthropic Claude Code)

cli_claude_check() {
  command_exists claude
}

cli_claude_run() {
  local prompt_file="$1"
  local working_dir="$2"
  if ! cd "$working_dir" 2>/dev/null; then
    echo "claude: working directory does not exist: $working_dir" >&2
    return 1
  fi
  claude --dangerously-skip-permissions -p < "$prompt_file"
}

cli_claude_run_prompt() {
  local prompt="$1"
  local working_dir="$2"
  if ! cd "$working_dir" 2>/dev/null; then
    echo "claude: working directory does not exist: $working_dir" >&2
    return 1
  fi
  printf '%s' "$prompt" | claude --dangerously-skip-permissions -p -
}

cli_claude_pre_run() {
  rm -rf .claude/conversations 2>/dev/null || true
}

cli_claude_install_hint() {
  echo "Install Claude CLI: npm install -g @anthropic-ai/claude-code"
}

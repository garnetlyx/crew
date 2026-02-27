#!/bin/bash
# CLI plugin: codex (OpenAI Codex CLI)
#
# Supports configuring custom model providers via environment variables:
#
#   CODEX_MODEL          - Model name (e.g. "qwen3.5-plus")
#   CODEX_PROVIDER       - Provider identifier (e.g. "dashscope")
#   CODEX_PROVIDER_NAME  - Human-readable name (defaults to CODEX_PROVIDER)
#   CODEX_BASE_URL       - Provider API base URL
#   CODEX_API_KEY_ENV    - Env var holding the API key (default: "OPENAI_API_KEY")
#   CODEX_WIRE_API       - Wire protocol: "chat" or "responses" (default: "responses")
#
# These are translated into `codex -c` flags so the plugin works with
# any OpenAI-compatible provider without modifying global config.toml.

cli_codex_check() {
  command_exists codex
}

# Build an array of -c flags from CODEX_* env vars
_codex_build_config_flags() {
  local flags=()
  local provider="${CODEX_PROVIDER:-}"

  if [[ -n "$provider" ]]; then
    flags+=(-c "model_provider=\"$provider\"")

    local provider_name="${CODEX_PROVIDER_NAME:-$provider}"
    flags+=(-c "model_providers.${provider}.name=\"$provider_name\"")

    if [[ -n "${CODEX_BASE_URL:-}" ]]; then
      flags+=(-c "model_providers.${provider}.base_url=\"$CODEX_BASE_URL\"")
    fi

    local api_key_env="${CODEX_API_KEY_ENV:-OPENAI_API_KEY}"
    flags+=(-c "model_providers.${provider}.env_key=\"$api_key_env\"")

    local wire_api="${CODEX_WIRE_API:-responses}"
    flags+=(-c "model_providers.${provider}.wire_api=\"$wire_api\"")
  fi

  if [[ -n "${CODEX_MODEL:-}" ]]; then
    flags+=(-c "model=\"$CODEX_MODEL\"")
  fi

  printf '%s\n' "${flags[@]}"
}

cli_codex_run() {
  local prompt_file="$1"
  local working_dir="$2"

  # Read config flags into an array
  local config_flags=()
  while IFS= read -r flag; do
    [[ -n "$flag" ]] && config_flags+=("$flag")
  done < <(_codex_build_config_flags)

  (cd "$working_dir" && codex "${config_flags[@]}" --dangerously-bypass-approvals-and-sandbox exec - < "$prompt_file")
}

cli_codex_run_prompt() {
  local prompt="$1"
  local working_dir="$2"

  local config_flags=()
  while IFS= read -r flag; do
    [[ -n "$flag" ]] && config_flags+=("$flag")
  done < <(_codex_build_config_flags)

  (cd "$working_dir" && echo "$prompt" | codex "${config_flags[@]}" --dangerously-bypass-approvals-and-sandbox exec -)
}

cli_codex_install_hint() {
  echo "Install Codex CLI: npm install -g @openai/codex"
}

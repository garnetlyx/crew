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

# Escape a value for safe embedding in a TOML double-quoted string.
# Handles backslashes, double quotes, and control characters that could
# break out of the string or inject new TOML keys/sections.
_codex_escape_toml() {
  local val="$1"
  val="${val//\\/\\\\}"
  val="${val//\"/\\\"}"
  val="${val//$'\n'/\\n}"
  val="${val//$'\r'/\\r}"
  val="${val//$'\t'/\\t}"
  printf '%s' "$val"
}

# Build an array of -c flags from CODEX_* env vars
# Each -c and its value are separate elements for proper shell expansion.
# Values use TOML-style quoting (codex -c expects key="value" for strings).
_codex_build_config_flags() {
  local flags=()
  local provider="${CODEX_PROVIDER:-}"

  # Validate provider name: only allow safe identifier characters
  if [[ -n "$provider" ]]; then
    if ! echo "$provider" | grep -qE '^[A-Za-z0-9_-]+$'; then
      echo "codex: invalid CODEX_PROVIDER (must match [A-Za-z0-9_-]+)" >&2
      return 1
    fi

    flags+=(-c "model_provider=\"$(_codex_escape_toml "$provider")\"")

    local provider_name="${CODEX_PROVIDER_NAME:-$provider}"
    flags+=(-c "model_providers.${provider}.name=\"$(_codex_escape_toml "$provider_name")\"")

    if [[ -n "${CODEX_BASE_URL:-}" ]]; then
      flags+=(-c "model_providers.${provider}.base_url=\"$(_codex_escape_toml "$CODEX_BASE_URL")\"")
    fi

    local api_key_env="${CODEX_API_KEY_ENV:-OPENAI_API_KEY}"
    if ! echo "$api_key_env" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*$'; then
      echo "codex: invalid CODEX_API_KEY_ENV: $api_key_env" >&2
      return 1
    fi
    flags+=(-c "model_providers.${provider}.env_key=\"$(_codex_escape_toml "$api_key_env")\"")

    local wire_api="${CODEX_WIRE_API:-responses}"
    if ! echo "$wire_api" | grep -qE '^(chat|responses)$'; then
      echo "codex: invalid CODEX_WIRE_API (must be 'chat' or 'responses'): $wire_api" >&2
      return 1
    fi
    flags+=(-c "model_providers.${provider}.wire_api=\"$(_codex_escape_toml "$wire_api")\"")
  fi

  if [[ -n "${CODEX_MODEL:-}" ]]; then
    if ! echo "$CODEX_MODEL" | grep -qE '^[A-Za-z0-9._:/-]+$'; then
      echo "codex: invalid CODEX_MODEL (must match [A-Za-z0-9._:/-]+)" >&2
      return 1
    fi
    flags+=(-c "model=\"$(_codex_escape_toml "$CODEX_MODEL")\"")
  fi

  # Output one element per line for safe read-back into caller's array
  printf '%s\n' ${flags[@]+"${flags[@]}"}
}

# Execute codex with config flags, temp file capture, and rate-limit detection.
# Reads prompt from stdin. Caller is responsible for piping input.
# Usage: _codex_exec <working_dir>
_codex_exec() {
  local working_dir="$1"

  if ! cd "$working_dir" 2>/dev/null; then
    echo "codex: working directory does not exist: $working_dir" >&2
    return 1
  fi

  local config_flags=()
  while IFS= read -r flag; do
    [[ -n "$flag" ]] && config_flags+=("$flag")
  done < <(_codex_build_config_flags)

  local out_file old_umask
  old_umask=$(umask)
  umask 077
  out_file=$(mktemp)
  umask "$old_umask"

  trap 'rm -f "$out_file"' EXIT INT TERM

  local exit_code=0
  codex ${config_flags[@]+"${config_flags[@]}"} --dangerously-bypass-approvals-and-sandbox exec - > "$out_file" 2>&1 || exit_code=$?

  cat "$out_file"
  if [[ "$exit_code" -eq 0 ]] && grep -qE -i "usage_limit_reached|usage limit|429 too many requests" "$out_file"; then
    exit_code=1
  fi
  rm -f "$out_file"
  trap - EXIT INT TERM
  return "$exit_code"
}

cli_codex_run() {
  local prompt_file="$1"
  local working_dir="$2"
  _codex_exec "$working_dir" < "$prompt_file"
}

cli_codex_run_prompt() {
  local prompt="$1"
  local working_dir="$2"
  printf '%s' "$prompt" | _codex_exec "$working_dir"
}

cli_codex_install_hint() {
  echo "Install Codex CLI: npm install -g @openai/codex"
}

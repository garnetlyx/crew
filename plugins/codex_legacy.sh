#!/bin/bash
# CLI plugin: codex_legacy (OpenAI Codex CLI v0.80.0)
#
# Uses the `codex-legacy` binary (Codex v0.80.0) which supports
# wire_api = "chat" for third-party OpenAI-compatible providers.
#
# Codex v0.105.0+ dropped chat wire_api support, so this plugin
# exists to provide backward compatibility with non-OpenAI models.
#
# Supports the same CODEX_* environment variables as the codex plugin:
#
#   CODEX_MODEL          - Model name (e.g. "qwen3.5-plus")
#   CODEX_PROVIDER       - Provider identifier (e.g. "dashscope")
#   CODEX_PROVIDER_NAME  - Human-readable name (defaults to CODEX_PROVIDER)
#   CODEX_BASE_URL       - Provider API base URL
#   CODEX_API_KEY_ENV    - Env var holding the API key (default: "OPENAI_API_KEY")
#   CODEX_WIRE_API       - Wire protocol: "chat" or "responses" (default: "chat")
#
# Install:
#   npm install -g @openai/codex@0.80.0 --prefix ~/.codex-legacy
#   ln -sf ~/.codex-legacy/bin/codex ~/.local/bin/codex-legacy

cli_codex_legacy_check() {
  command_exists codex-legacy
}

# Escape a value for safe embedding in a TOML double-quoted string.
_codex_legacy_escape_toml() {
  local val="$1"
  val="${val//\\/\\\\}"
  val="${val//\"/\\\"}"
  val="${val//$'\n'/\\n}"
  val="${val//$'\r'/\\r}"
  val="${val//$'\t'/\\t}"
  printf '%s' "$val"
}

# Build an array of -c flags from CODEX_* env vars.
# Default wire_api is "chat" (unlike the latest codex plugin which defaults to "responses")
# because this plugin exists specifically for third-party providers.
_codex_legacy_build_config_flags() {
  local flags=()
  local provider="${CODEX_PROVIDER:-}"

  # Validate provider name: only allow safe identifier characters
  if [[ -n "$provider" ]]; then
    if ! echo "$provider" | grep -qE '^[A-Za-z0-9_-]+$'; then
      echo "codex-legacy: invalid CODEX_PROVIDER (must match [A-Za-z0-9_-]+)" >&2
      return 1
    fi

    flags+=(-c "model_provider=\"$(_codex_legacy_escape_toml "$provider")\"")

    local provider_name="${CODEX_PROVIDER_NAME:-$provider}"
    flags+=(-c "model_providers.${provider}.name=\"$(_codex_legacy_escape_toml "$provider_name")\"")

    if [[ -n "${CODEX_BASE_URL:-}" ]]; then
      flags+=(-c "model_providers.${provider}.base_url=\"$(_codex_legacy_escape_toml "$CODEX_BASE_URL")\"")
    fi

    local api_key_env="${CODEX_API_KEY_ENV:-OPENAI_API_KEY}"
    if ! echo "$api_key_env" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*$'; then
      echo "codex-legacy: invalid CODEX_API_KEY_ENV: $api_key_env" >&2
      return 1
    fi
    flags+=(-c "model_providers.${provider}.env_key=\"$(_codex_legacy_escape_toml "$api_key_env")\"")

    local wire_api="${CODEX_WIRE_API:-chat}"
    if ! echo "$wire_api" | grep -qE '^(chat|responses)$'; then
      echo "codex-legacy: invalid CODEX_WIRE_API (must be 'chat' or 'responses'): $wire_api" >&2
      return 1
    fi
    flags+=(-c "model_providers.${provider}.wire_api=\"$(_codex_legacy_escape_toml "$wire_api")\"")
  fi

  if [[ -n "${CODEX_MODEL:-}" ]]; then
    if ! echo "$CODEX_MODEL" | grep -qE '^[A-Za-z0-9._:/-]+$'; then
      echo "codex-legacy: invalid CODEX_MODEL (must match [A-Za-z0-9._:/-]+)" >&2
      return 1
    fi
    flags+=(-c "model=\"$(_codex_legacy_escape_toml "$CODEX_MODEL")\"")
  fi

  printf '%s\n' ${flags[@]+"${flags[@]}"}
}

# Execute codex-legacy with config flags, temp file capture, and rate-limit detection.
_codex_legacy_exec() {
  local working_dir="$1"

  if ! cd "$working_dir" 2>/dev/null; then
    echo "codex-legacy: working directory does not exist: $working_dir" >&2
    return 1
  fi

  local config_flags=()
  while IFS= read -r flag; do
    [[ -n "$flag" ]] && config_flags+=("$flag")
  done < <(_codex_legacy_build_config_flags)

  local out_file old_umask
  old_umask=$(umask)
  umask 077
  out_file=$(mktemp)
  umask "$old_umask"

  trap 'rm -f "$out_file"' EXIT INT TERM

  local exit_code=0
  codex-legacy ${config_flags[@]+"${config_flags[@]}"} --dangerously-bypass-approvals-and-sandbox exec - > "$out_file" 2>&1 || exit_code=$?

  cat "$out_file"
  if [[ "$exit_code" -eq 0 ]] && grep -qE -i "usage_limit_reached|usage limit|429 too many requests" "$out_file"; then
    exit_code=1
  fi
  rm -f "$out_file"
  trap - EXIT INT TERM
  return "$exit_code"
}

cli_codex_legacy_run() {
  local prompt_file="$1"
  local working_dir="$2"
  _codex_legacy_exec "$working_dir" < "$prompt_file"
}

cli_codex_legacy_run_prompt() {
  local prompt="$1"
  local working_dir="$2"
  printf '%s' "$prompt" | _codex_legacy_exec "$working_dir"
}

cli_codex_legacy_install_hint() {
  echo "Install Codex Legacy (v0.80.0):"
  echo "  npm install -g @openai/codex@0.80.0 --prefix ~/.codex-legacy"
  echo "  ln -sf ~/.codex-legacy/bin/codex ~/.local/bin/codex-legacy"
}

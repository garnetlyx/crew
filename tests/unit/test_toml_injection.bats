#!/usr/bin/env bats
# tests/unit/test_toml_injection.bats
# TOML Injection vulnerability in codex plugin

setup() {
  load ../test_helper
  source "$PROJECT_ROOT/lib/utils.sh"
  source "$PROJECT_ROOT/plugins/codex.sh"
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG-QA-023: TOML injection in codex plugin config flags [HIGH]
# Location: plugins/codex.sh:28-46 (_codex_build_config_flags)
# Impact: HIGH - Config injection could redirect API calls
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG-QA-023: CODEX_MODEL with quote should not inject TOML" {
  # This test documents the TOML injection vulnerability
  # If CODEX_MODEL contains quotes, it can inject arbitrary TOML

  export CODEX_MODEL='"]; malicious_key = "value"'

  run _codex_build_config_flags

  # The output should NOT contain the injected key
  [[ ! "$output" == *"malicious_key"* ]]
}

@test "BUG-QA-023b: CODEX_PROVIDER with newline should not inject TOML" {
  export CODEX_PROVIDER=$'claude"\nmalicious = "injected'

  run _codex_build_config_flags

  # Should not contain the injected key
  [[ ! "$output" == *"malicious = "* ]]
}

@test "BUG-QA-023c: CODEX_BASE_URL with quote should be escaped" {
  export CODEX_PROVIDER="custom"
  export CODEX_BASE_URL='https://evil.com"\nkey = "value'

  run _codex_build_config_flags

  # Newline in output would indicate injection
  [[ ! "$output" == $'*\n*key = *' ]]
}

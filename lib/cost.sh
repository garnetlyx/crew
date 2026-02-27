#!/bin/bash
# crew/lib/cost.sh - Token and cost tracking
#
# Parses agent log files for cost/token usage patterns reported by CLI tools.
# Each CLI tool (claude, codex, gemini, etc.) has a dedicated parser that
# extracts cost data from its specific output format.
#
# Usage: source this file and call show_cost() with a config file path.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

# Max safe value for Bash 64-bit signed integer arithmetic
readonly MAX_TOKEN_COUNT=9223372036854775807

# Max line length to process (defense against regex DoS via crafted log input)
readonly MAX_COST_LINE_LENGTH=1024

# ── Shared Helpers ──────────────────────────────────────────

# Sum dollar amounts from log lines matching a grep pattern.
# Outputs "cost api_calls" (space-separated) to stdout.
# Usage: _sum_cost_lines <log_file> <grep_pattern>
_sum_cost_lines() {
  local log_file="$1"
  local pattern="$2"
  local total_cost=0
  local api_calls=0

  while IFS= read -r line; do
    [[ ${#line} -gt $MAX_COST_LINE_LENGTH ]] && continue
    local cost_val
    cost_val=$(printf '%s' "$line" | grep -oE '\$[0-9,]*\.?[0-9]+' | head -1 | tr -d '$,')
    if [[ -n "${cost_val:-}" ]]; then
      total_cost=$(echo "$total_cost + $cost_val" | bc 2>/dev/null || echo "$total_cost")
      api_calls=$((api_calls + 1))
    fi
  done < <(grep -iE "$pattern" "$log_file" 2>/dev/null || true)

  [[ "$total_cost" == .* ]] && total_cost="0$total_cost"
  echo "$total_cost $api_calls"
}

# Sum token counts from log lines matching a grep pattern, with overflow protection.
# Outputs the total token count to stdout.
# Usage: _sum_token_lines <log_file> <grep_pattern>
_sum_token_lines() {
  local log_file="$1"
  local pattern="$2"
  local tokens=0

  while IFS= read -r line; do
    [[ ${#line} -gt $MAX_COST_LINE_LENGTH ]] && continue
    local val
    val=$(printf '%s' "$line" | sed -E 's/.*[Tt]okens[^0-9]*//' | grep -oE '[0-9,]+' | head -1 | tr -d ',')
    if [[ -n "${val:-}" ]] && [[ "$val" =~ ^[0-9]+$ ]]; then
      local new_total=$((tokens + val))
      if [[ "$new_total" -lt "$tokens" ]]; then
        tokens=$MAX_TOKEN_COUNT
      else
        tokens=$new_total
      fi
    fi
  done < <(grep -iE "$pattern" "$log_file" 2>/dev/null || true)

  echo "$tokens"
}

# ── Log Parsers ─────────────────────────────────────────────
# Each parser reads an agent log file and outputs key=value pairs:
#   total_cost=<float>       Sum of all reported costs in USD
#   input_tokens=<int>       Sum of input/prompt tokens
#   output_tokens=<int>      Sum of output/completion tokens
#   api_calls=<int>          Number of completed API sessions

_parse_claude_cost() {
  local log_file="$1"

  local cost_result
  cost_result=$(_sum_cost_lines "$log_file" "total cost")
  local total_cost="${cost_result%% *}"
  local api_calls="${cost_result##* }"

  local input_tokens
  input_tokens=$(_sum_token_lines "$log_file" "input.?tokens")
  local output_tokens
  output_tokens=$(_sum_token_lines "$log_file" "output.?tokens")

  echo "total_cost=$total_cost"
  echo "input_tokens=$input_tokens"
  echo "output_tokens=$output_tokens"
  echo "api_calls=$api_calls"
}

_parse_generic_cost() {
  local log_file="$1"

  local cost_result
  cost_result=$(_sum_cost_lines "$log_file" "cost|total.*(spent|usage|price)")
  local total_cost="${cost_result%% *}"
  local api_calls="${cost_result##* }"

  local input_tokens
  input_tokens=$(_sum_token_lines "$log_file" "input.?tokens|prompt.?tokens")
  local output_tokens
  output_tokens=$(_sum_token_lines "$log_file" "output.?tokens|completion.?tokens")

  # Count API sessions from agent lifecycle markers
  if [[ "$api_calls" -eq 0 ]]; then
    local starts
    starts=$(grep -cE "^\[.*\] Starting at" "$log_file" 2>/dev/null || echo 0)
    if [[ "$starts" -gt 0 ]]; then
      api_calls="$starts"
    fi
  fi

  echo "total_cost=$total_cost"
  echo "input_tokens=$input_tokens"
  echo "output_tokens=$output_tokens"
  echo "api_calls=$api_calls"
}

# ── Public API ──────────────────────────────────────────────

# Get cost data for a single agent.
# Outputs key=value pairs to stdout.
get_agent_cost() {
  local name="$1"
  local config_file="$2"
  local crew_dir
  crew_dir="$(dirname "$config_file")"
  local log_file="$crew_dir/logs/${name}.log"

  if [[ ! -f "$log_file" ]]; then
    echo "total_cost=0"
    echo "input_tokens=0"
    echo "output_tokens=0"
    echo "api_calls=0"
    return 0
  fi

  local cli_type
  cli_type=$(get_agent_cli_type "$name" "$config_file" 2>/dev/null || echo "claude")

  case "$cli_type" in
    claude) _parse_claude_cost "$log_file" ;;
    *)      _parse_generic_cost "$log_file" ;;
  esac
}

# Display cost summary table for all configured agents.
show_cost() {
  local config_file="$1"
  local crew_dir
  crew_dir="$(dirname "$config_file")"

  header "Cost Summary"

  if [[ ! -f "$config_file" ]]; then
    log_error "No config found. Run 'crew init' first."
    return 1
  fi

  # Check bc dependency for floating-point arithmetic
  if ! command_exists bc; then
    log_warn "bc is not installed. Cost calculations may be inaccurate (floating-point arithmetic unavailable)."
  fi

  local project
  project=$(config_get ".project" "$(basename "$PWD")" "$config_file")
  echo "Project: $project"
  echo "Source:  $crew_dir/logs/"
  echo ""

  local agents
  agents=$(config_get ".agents[].name" "" "$config_file")

  if [[ -z "$agents" ]]; then
    log_warn "No agents configured"
    return 0
  fi

  # Table header
  printf "%-12s %-8s %-14s %-14s %-8s %-10s\n" \
    "AGENT" "TYPE" "INPUT TOKENS" "OUTPUT TOKENS" "RUNS" "COST"
  separator "-" 70

  local grand_cost=0
  local grand_input=0
  local grand_output=0
  local grand_calls=0

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue

    local cli_type
    cli_type=$(get_agent_cli_type "$name" "$config_file" 2>/dev/null || echo "?")

    # Parse cost data
    local total_cost=0 input_tokens=0 output_tokens=0 api_calls=0
    while IFS='=' read -r key val; do
      case "$key" in
        total_cost)     total_cost="$val" ;;
        input_tokens)   input_tokens="$val" ;;
        output_tokens)  output_tokens="$val" ;;
        api_calls)      api_calls="$val" ;;
      esac
    done < <(get_agent_cost "$name" "$config_file")

    # Format displays
    local cost_display="-"
    if [[ "$total_cost" != "0" ]]; then
      cost_display="\$$total_cost"
    fi

    local input_display="-"
    if [[ "$input_tokens" -gt 0 ]] 2>/dev/null; then
      input_display=$(printf "%'d" "$input_tokens" 2>/dev/null || echo "$input_tokens")
    fi

    local output_display="-"
    if [[ "$output_tokens" -gt 0 ]] 2>/dev/null; then
      output_display=$(printf "%'d" "$output_tokens" 2>/dev/null || echo "$output_tokens")
    fi

    local calls_display="-"
    if [[ "$api_calls" -gt 0 ]] 2>/dev/null; then
      calls_display="$api_calls"
    fi

    printf "%-12s %-8s %-14s %-14s %-8s %-10s\n" \
      "$name" "$cli_type" "$input_display" "$output_display" "$calls_display" "$cost_display"

    # Accumulate totals
    grand_cost=$(echo "$grand_cost + $total_cost" | bc 2>/dev/null || echo "$grand_cost")
    grand_input=$((grand_input + input_tokens))
    grand_output=$((grand_output + output_tokens))
    grand_calls=$((grand_calls + api_calls))
  done <<< "$agents"

  # Totals row
  separator "-" 70

  local grand_cost_display="-"
  if [[ "$grand_cost" != "0" ]]; then
    grand_cost_display="\$$grand_cost"
  fi

  local grand_input_display
  grand_input_display=$(printf "%'d" "$grand_input" 2>/dev/null || echo "$grand_input")
  local grand_output_display
  grand_output_display=$(printf "%'d" "$grand_output" 2>/dev/null || echo "$grand_output")

  printf "${BOLD}%-12s %-8s %-14s %-14s %-8s %-10s${NC}\n" \
    "TOTAL" "" "$grand_input_display" "$grand_output_display" "$grand_calls" "$grand_cost_display"

  echo ""

  # Fallback level breakdown
  local has_fallback=false
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if [[ -f "$crew_dir/run/${name}.fallback" ]]; then
      has_fallback=true
      break
    fi
  done <<< "$agents"

  if $has_fallback; then
    echo "${BOLD}Active Fallback Levels${NC}"
    separator "-" 40
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      local fallback_file="$crew_dir/run/${name}.fallback"
      if [[ -f "$fallback_file" ]]; then
        local fb_state
        fb_state=$(cat "$fallback_file")
        local level="${fb_state#*|}"
        printf "  %-12s  %s\n" "$name" "$level"
      fi
    done <<< "$agents"
    echo ""
  fi

  # Footer notes
  log_info "Cost data parsed from CLI tool output in agent logs"
  if [[ "$grand_cost" == "0" ]] && [[ "$grand_calls" -eq 0 ]]; then
    log_info "No cost data found. Agents may not have run yet, or the CLI does not report costs."
  fi
}

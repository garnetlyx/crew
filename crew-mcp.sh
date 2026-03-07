#!/bin/bash
# crew-mcp.sh - MCP (Model Context Protocol) server for crew
#
# Exposes crew and design commands as MCP tools over JSON-RPC 2.0 stdio.
# Compatible with Claude Desktop, Cursor, and other MCP-capable clients.
#
# Usage:
#   crew serve --mcp                    # Via crew CLI
#   crew-mcp                            # Direct invocation
#   echo '{"jsonrpc":"2.0",...}' | crew-mcp  # Pipe mode
#
# Protocol: JSON-RPC 2.0, newline-delimited, over stdin/stdout.
# stderr is used for logging (not part of protocol).

set -euo pipefail

# Resolve script directory (same pattern as crew.sh)
SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
  DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"

# Source libraries (stderr only for logging)
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/plugin_loader.sh"
source "$SCRIPT_DIR/lib/watchdog.sh"
source "$SCRIPT_DIR/lib/status.sh"
source "$SCRIPT_DIR/lib/orchestrator.sh"

MCP_VERSION=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "unknown")
PROTOCOL_VERSION="2024-11-05"

# ── JSON helpers (python3, no dependencies) ────────────────────────────────

# Parse a JSON field from stdin
_json_get() {
  local json="$1"
  local path="$2"
  python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
except (json.JSONDecodeError, ValueError):
    print('')
    sys.exit(0)
keys = sys.argv[2].split('.')
val = data
for k in keys:
    if isinstance(val, dict) and k in val:
        val = val[k]
    else:
        val = None
        break
if val is None:
    print('')
elif isinstance(val, (dict, list)):
    print(json.dumps(val))
else:
    print(val)
" "$json" "$path"
}

# Build a JSON-RPC response
_json_response() {
  local id="$1"
  local result="$2"
  python3 -c "
import json, sys
resp = {'jsonrpc': '2.0', 'id': int(sys.argv[1]) if sys.argv[1].lstrip('-').isdigit() else sys.argv[1], 'result': json.loads(sys.argv[2])}
print(json.dumps(resp))
" "$id" "$result"
}

# Build a JSON-RPC error response
_json_error() {
  local id="$1"
  local code="$2"
  local message="$3"
  python3 -c "
import json, sys
_id = sys.argv[1]
if _id.lstrip('-').isdigit():
    _id = int(_id)
resp = {'jsonrpc': '2.0', 'id': _id, 'error': {'code': int(sys.argv[2]), 'message': sys.argv[3]}}
print(json.dumps(resp))
" "$id" "$code" "$message"
}

# ── Tool definitions ───────────────────────────────────────────────────────

TOOLS_JSON=$(python3 -c '
import json
tools = [
    {
        "name": "crew_status",
        "description": "Show the status of all configured agents (running, stopped, stale)",
        "inputSchema": {"type": "object", "properties": {}}
    },
    {
        "name": "crew_start",
        "description": "Start all agents or specific agents by name",
        "inputSchema": {
            "type": "object",
            "properties": {
                "agents": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Agent names to start (empty = all)"
                }
            }
        }
    },
    {
        "name": "crew_stop",
        "description": "Stop all agents or specific agents by name",
        "inputSchema": {
            "type": "object",
            "properties": {
                "agents": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Agent names to stop (empty = all)"
                }
            }
        }
    },
    {
        "name": "crew_report",
        "description": "Show agent activity report with run counts, errors, and file conflicts",
        "inputSchema": {"type": "object", "properties": {}}
    },
    {
        "name": "crew_cost",
        "description": "Show runtime and cost estimates per agent and fallback level",
        "inputSchema": {"type": "object", "properties": {}}
    },
    {
        "name": "design_init",
        "description": "Initialize a design-review session with an idea",
        "inputSchema": {
            "type": "object",
            "properties": {
                "idea": {
                    "type": "string",
                    "description": "The idea to refine"
                }
            },
            "required": ["idea"]
        }
    },
    {
        "name": "design_status",
        "description": "Show the current design-review session status",
        "inputSchema": {"type": "object", "properties": {}}
    }
]
print(json.dumps(tools))
')

# ── Method handlers ────────────────────────────────────────────────────────

handle_initialize() {
  local id="$1"
  local result
  result=$(python3 -c "
import json
print(json.dumps({
    'protocolVersion': '$PROTOCOL_VERSION',
    'capabilities': {'tools': {}},
    'serverInfo': {'name': 'crew-mcp', 'version': '$MCP_VERSION'}
}))
")
  _json_response "$id" "$result"
}

handle_tools_list() {
  local id="$1"
  local result
  result=$(python3 -c "
import json, sys
print(json.dumps({'tools': json.loads(sys.argv[1])}))
" "$TOOLS_JSON")
  _json_response "$id" "$result"
}

# Parse and validate a JSON agent list from MCP input.
# Outputs one validated agent name per line on success.
# On failure, outputs "ERROR:<name>" and returns 1.
_parse_mcp_agent_list() {
  local json_list="$1"
  while IFS= read -r _agent; do
    [[ -n "$_agent" ]] || continue
    if ! validate_agent_name "$_agent" 2>/dev/null; then
      echo "ERROR:$_agent"
      return 1
    fi
    echo "$_agent"
  done < <(python3 -c "import json,sys; [print(a) for a in json.loads(sys.argv[1])]" "$json_list")
}

handle_tools_call() {
  local id="$1"
  local params="$2"

  local tool_name
  tool_name=$(_json_get "$params" "name")
  local arguments
  arguments=$(_json_get "$params" "arguments")

  local config_file
  config_file=$(find_config 2>/dev/null) || { _json_error "$id" -32603 "No crew config found"; return; }

  local output=""
  local is_error=false

  case "$tool_name" in
    crew_status)
      output=$(show_status "$config_file" 2>&1) || is_error=true
      ;;
    crew_start)
      local agent_list
      agent_list=$(_json_get "$arguments" "agents")
      if [[ -n "$agent_list" && "$agent_list" != "null" && "$agent_list" != "[]" ]]; then
        local parsed
        if ! parsed=$(_parse_mcp_agent_list "$agent_list"); then
          local bad_line
          bad_line=$(echo "$parsed" | grep "^ERROR:" | head -1)
          _json_error "$id" -32602 "Invalid agent name: ${bad_line#ERROR:}"
          return
        fi
        local agents_arr=()
        while IFS= read -r _agent; do
          agents_arr+=("$_agent")
        done <<< "$parsed"
        output=$(start_all_agents "$config_file" "${agents_arr[@]}" 2>&1) || is_error=true
      else
        output=$(start_all_agents "$config_file" 2>&1) || is_error=true
      fi
      ;;
    crew_stop)
      local agent_list
      agent_list=$(_json_get "$arguments" "agents")
      if [[ -n "$agent_list" && "$agent_list" != "null" && "$agent_list" != "[]" ]]; then
        local parsed
        if ! parsed=$(_parse_mcp_agent_list "$agent_list"); then
          local bad_line
          bad_line=$(echo "$parsed" | grep "^ERROR:" | head -1)
          _json_error "$id" -32602 "Invalid agent name: ${bad_line#ERROR:}"
          return
        fi
        while IFS= read -r agent_name; do
          output+=$(stop_agent "$agent_name" 2>&1)$'\n' || is_error=true
        done <<< "$parsed"
      else
        output=$(stop_all_agents 2>&1) || is_error=true
      fi
      ;;
    crew_report)
      output=$(show_report "$config_file" 2>&1) || is_error=true
      ;;
    crew_cost)
      output=$(show_cost "$config_file" 2>&1) || is_error=true
      ;;
    design_init)
      local idea
      idea=$(_json_get "$arguments" "idea")
      if [[ -z "$idea" || "$idea" == "null" ]]; then
        _json_error "$id" -32602 "Missing required parameter: idea"
        return
      fi
      # BUG-QA-024: Reject oversized idea strings to prevent disk exhaustion
      local max_idea_len=102400  # 100KB
      if [[ ${#idea} -gt $max_idea_len ]]; then
        _json_error "$id" -32602 "Parameter 'idea' exceeds maximum length ($max_idea_len bytes)"
        return
      fi
      output=$(design_init "$idea" 2>&1) || is_error=true
      ;;
    design_status)
      output=$(design_status 2>&1) || is_error=true
      ;;
    *)
      _json_error "$id" -32601 "Unknown tool: $tool_name"
      return
      ;;
  esac

  # Strip ANSI escape codes for clean text output
  output=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')

  local result
  result=$(python3 -c "
import json, sys
print(json.dumps({'content': [{'type': 'text', 'text': sys.argv[1]}], 'isError': sys.argv[2] == 'true'}))
" "$output" "$is_error")
  _json_response "$id" "$result"
}

# ── Main loop ──────────────────────────────────────────────────────────────

main() {
  echo "crew-mcp: listening on stdio" >&2

  # BUG-QA-088: Use read with timeout to prevent indefinite blocking
  local timeout_seconds=300  # 5 minutes - reasonable for MCP requests
  while IFS= read -r -t "$timeout_seconds" line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue

    local method id params
    method=$(_json_get "$line" "method") || method=""
    id=$(_json_get "$line" "id") || id=""
    params=$(_json_get "$line" "params") || params=""

    # Skip malformed requests with no method
    if [[ -z "$method" ]]; then
      if [[ -n "$id" ]]; then
        _json_error "$id" -32600 "Invalid request: missing method"
      fi
      continue
    fi

    echo "crew-mcp: method=$method id=$id" >&2

    case "$method" in
      initialize)
        handle_initialize "$id"
        ;;
      notifications/initialized)
        # Notification — no response needed
        ;;
      tools/list)
        handle_tools_list "$id"
        ;;
      tools/call)
        handle_tools_call "$id" "$params"
        ;;
      *)
        if [[ -n "$id" ]]; then
          _json_error "$id" -32601 "Method not found: $method"
        fi
        ;;
    esac
  done

  echo "crew-mcp: stdin closed, exiting" >&2
}

main

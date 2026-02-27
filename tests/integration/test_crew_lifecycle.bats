#!/usr/bin/env bats
# Integration tests for crew mode lifecycle

setup() {
  load ../test_helper
  source "$PROJECT_ROOT/lib/utils.sh"
  source "$PROJECT_ROOT/lib/config.sh"
  source "$PROJECT_ROOT/lib/plugin_loader.sh"
  source "$PROJECT_ROOT/lib/watchdog.sh" 2>/dev/null || true

  # Create isolated test directory
  TEST_DIR="$BATS_TEST_TMPDIR/crew_integration_$$"
  mkdir -p "$TEST_DIR"
  cd "$TEST_DIR"
}

teardown() {
  # Kill any lingering test processes
  if [[ -d "$TEST_DIR/.crew/run" ]]; then
    for pid_file in "$TEST_DIR/.crew/run"/*.pid; do
      [[ -f "$pid_file" ]] || continue
      local pid
      pid=$(cat "$pid_file" 2>/dev/null | awk '{print $1}')
      [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null || true
    done
  fi
  rm -rf "$TEST_DIR"
}

# ─────────────────────────────────────────────────────────────────────────────
# crew init (via crew.sh)
# ─────────────────────────────────────────────────────────────────────────────

@test "crew init: creates .crew directory structure" {
  run "$PROJECT_ROOT/crew.sh" init
  [ "$status" -eq 0 ]
  [ -d ".crew" ]
  [ -f ".crew/crew.yaml" ]
  [ -d ".crew/prompts" ]
  [ -d ".crew/logs" ]
  [ -d ".crew/run" ]
}

@test "crew init: created config is valid YAML" {
  "$PROJECT_ROOT/crew.sh" init
  run yq eval "." ".crew/crew.yaml"
  [ "$status" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# start_agent + stop_agent lifecycle with command: echo
# ─────────────────────────────────────────────────────────────────────────────

@test "start_agent: launches agent with command and creates PID file" {
  mkdir -p .crew/run .crew/logs .crew/prompts
  echo "test" > .crew/prompts/test.md

  cat > .crew/crew.yaml << 'EOF'
agents:
  - name: ECHO
    prompt: prompts/test.md
    command: "sleep 30"
    interval: 1
EOF

  start_agent "ECHO" ".crew/prompts/test.md" 1 "$TEST_DIR" ".crew/crew.yaml"

  # PID file should exist
  [ -f ".crew/run/ECHO.pid" ]

  # Process should be running
  local pid
  pid=$(cat ".crew/run/ECHO.pid" | awk '{print $1}')
  kill -0 "$pid" 2>/dev/null
}

@test "stop_agent: terminates agent and cleans up PID file" {
  mkdir -p .crew/run .crew/logs .crew/prompts
  echo "test" > .crew/prompts/test.md

  cat > .crew/crew.yaml << 'EOF'
agents:
  - name: STOPPER
    prompt: prompts/test.md
    command: "sleep 30"
    interval: 1
EOF

  start_agent "STOPPER" ".crew/prompts/test.md" 1 "$TEST_DIR" ".crew/crew.yaml"
  [ -f ".crew/run/STOPPER.pid" ]

  local pid
  pid=$(cat ".crew/run/STOPPER.pid" | awk '{print $1}')

  stop_agent "STOPPER"

  # PID file should be removed
  [ ! -f ".crew/run/STOPPER.pid" ]

  # Process should be dead (give it a moment)
  sleep 1
  ! kill -0 "$pid" 2>/dev/null
}

@test "is_agent_running: true during lifecycle, false after stop" {
  mkdir -p .crew/run .crew/logs .crew/prompts
  echo "test" > .crew/prompts/test.md

  cat > .crew/crew.yaml << 'EOF'
agents:
  - name: LIFECYCLE
    prompt: prompts/test.md
    command: "sleep 30"
    interval: 1
EOF

  start_agent "LIFECYCLE" ".crew/prompts/test.md" 1 "$TEST_DIR" ".crew/crew.yaml"

  # Should be running
  is_agent_running "LIFECYCLE"

  stop_agent "LIFECYCLE"
  sleep 1

  # Should not be running
  ! is_agent_running "LIFECYCLE"
}

# ─────────────────────────────────────────────────────────────────────────────
# Agent exits and restarts
# ─────────────────────────────────────────────────────────────────────────────

@test "agent restarts after successful exit (exit 0)" {
  mkdir -p .crew/run .crew/logs .crew/prompts
  echo "test" > .crew/prompts/test.md

  cat > .crew/crew.yaml << 'EOF'
agents:
  - name: RESTARTER
    prompt: prompts/test.md
    command: "echo done"
    interval: 1
EOF

  start_agent "RESTARTER" ".crew/prompts/test.md" 1 "$TEST_DIR" ".crew/crew.yaml"

  # Wait for at least one restart cycle
  sleep 3

  # Agent subshell should still be alive (restarting)
  is_agent_running "RESTARTER"

  # Log should show multiple starts
  local start_count
  start_count=$(grep -c "Starting at" ".crew/logs/RESTARTER.log" 2>/dev/null || echo 0)
  [ "$start_count" -gt 1 ]

  stop_agent "RESTARTER"
}

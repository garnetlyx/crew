#!/usr/bin/env bats
# Test scenario: Global crew.yaml with local .crew/run directory.
# This simulates the user's setup that was failing.

setup() {
  load ../test_helper
  
  # 1. Create a global "home" for crew
  GLOBAL_HOME="$BATS_TEST_TMPDIR/global_home"
  mkdir -p "$GLOBAL_HOME/.crew"
  
  # 2. Create the global config
  cat > "$GLOBAL_HOME/.crew/crew.yaml" << EOF
project: global-test
agents:
  - name: TESTER
    prompt: prompts/test.md
    command: "sleep 10"
    interval: 1
EOF
  mkdir -p "$GLOBAL_HOME/.crew/prompts"
  echo "test prompt" > "$GLOBAL_HOME/.crew/prompts/test.md"

  # 3. Create a local project directory
  PROJECT_DIR="$BATS_TEST_TMPDIR/local_project"
  mkdir -p "$PROJECT_DIR/.crew/run"
  mkdir -p "$PROJECT_DIR/.crew/logs"
  
  # 4. Mock HOME to point to our fake global home so _resolve_config finds it
  ORIG_HOME="$HOME"
  export HOME="$GLOBAL_HOME"
}

teardown() {
  # Kill any lingering test processes
  if [[ -d "$PROJECT_DIR/.crew/run" ]]; then
    for pid_file in "$PROJECT_DIR/.crew/run"/*.pid; do
      [[ -f "$pid_file" ]] || continue
      local pid
      pid=$(cat "$pid_file" 2>/dev/null | awk '{print $1}')
      [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null || true
    done
  fi
  export HOME="$ORIG_HOME"
  rm -rf "$GLOBAL_HOME" "$PROJECT_DIR"
}

@test "Global config with local runtime: crew status and stop work correctly" {
  cd "$PROJECT_DIR"
  
  # Sanity check: confirm which config is being used
  run "$PROJECT_ROOT/crew.sh" validate
  [ "$status" -eq 0 ]
  [[ "$output" == *"Validating config: $GLOBAL_HOME/.crew/crew.yaml"* ]]

  # Start the agent. It should use local .crew/run for its PID file.
  # CREW_DIR should be resolved to .crew because it exists locally.
  run "$PROJECT_ROOT/crew.sh" start TESTER
  [ "$status" -eq 0 ]

  # Verify PID file is in LOCAL project directory, not global one
  [ -f "$PROJECT_DIR/.crew/run/TESTER.pid" ]
  [ ! -f "$GLOBAL_HOME/.crew/run/TESTER.pid" ]

  # Verify status shows it's running (this was working before, but good to check)
  run "$PROJECT_ROOT/crew.sh" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"TESTER"* ]]
  [[ "$output" == *"running"* ]]

  # Verify crew stop works (THIS WAS THE FAILING PART)
  run "$PROJECT_ROOT/crew.sh" stop TESTER
  [ "$status" -eq 0 ]
  [[ "$output" != *"Not running"* ]]

  # Verify PID file is gone from local directory
  [ ! -f "$PROJECT_DIR/.crew/run/TESTER.pid" ]
}

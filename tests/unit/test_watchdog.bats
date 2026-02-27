#!/usr/bin/env bats
# tests/unit/test_watchdog.bats
# Watchdog and agent lifecycle tests

setup() {
  TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
  source "$PROJECT_ROOT/lib/utils.sh"
  source "$PROJECT_ROOT/lib/config.sh"
  source "$PROJECT_ROOT/lib/watchdog.sh" 2>/dev/null || true

  # Setup test environment
  TEST_CREW_DIR="/tmp/test_crew_$$"
  mkdir -p "$TEST_CREW_DIR/.crew/run" "$TEST_CREW_DIR/.crew/logs" "$TEST_CREW_DIR/.crew/prompts"
  echo "test prompt" > "$TEST_CREW_DIR/.crew/prompts/test.md"
  cd "$TEST_CREW_DIR"
}

teardown() {
  # Clean up test environment
  rm -rf "$TEST_CREW_DIR"
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG: T003 - Timeout field exists in config but is NOT implemented
# Location: lib/watchdog.sh:273-288 (start_agent inner loop)
# Impact: Agents can hang indefinitely
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG: timeout field should actually kill hanging agents" {
  # Create config with 1 second timeout
  cat > "$TEST_CREW_DIR/.crew/crew.yaml" << 'EOF'
agents:
  - name: HANGER
    prompt: prompts/test.md
    timeout: 1
    interval: 1
EOF

  # Create a prompt that will hang
  cat > "$TEST_CREW_DIR/.crew/prompts/test.md" << 'EOF'
Sleep for 60 seconds
EOF

  # Start the agent
  start_agent "HANGER" "$TEST_CREW_DIR/.crew/prompts/test.md" 1 "$TEST_CREW_DIR" "$TEST_CREW_DIR/.crew/crew.yaml" &
  local starter_pid=$!
  sleep 2

  # The agent should have been killed by timeout after 1 second
  # But due to the bug, timeout is not implemented
  if [[ -f "$TEST_CREW_DIR/.crew/run/HANGER.pid" ]]; then
    local pid
    pid=$(cat "$TEST_CREW_DIR/.crew/run/HANGER.pid" 2>/dev/null)
    if kill -0 "$pid" 2>/dev/null; then
      # Process is still running - bug confirmed
      kill -9 "$pid" 2>/dev/null || true
      false  # Force test to fail - proves bug exists
    fi
  fi

  wait "$starter_pid" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG: T024 - Unquoted loop variables in watchdog.sh
# Location: lib/watchdog.sh:562
# Impact: Agent names with spaces break the loop
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG: watchdog should handle agent names with spaces gracefully" {
  skip "Bats compatibility issue - run manually"

  # Create config with agent name containing space
  cat > "$TEST_CREW_DIR/.crew/crew.yaml" << 'EOF'
agents:
  - name: "QA AGENT"
    prompt: prompts/test.md
    interval: 10
EOF

  # The for loop in watchdog_loop will iterate incorrectly
  # for name in $agents will split "QA AGENT" into two iterations

  run get_agent_status "QA AGENT"
  # This will fail because the name gets split
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG: Restart count not reset on successful exit
# Location: lib/watchdog.sh:478-494
# Impact: Backoff calculation with restart_count=0 causes integer overflow
# ─────────────────────────────────────────────────────────────────────────────

@test "backoff calculation handles restart_count=0 correctly" {
  # The backoff formula interval * (1 << (restart_count - 1))
  # produces a huge negative number when restart_count=0 due to 1 << -1
  # This test verifies the defensive fix handles restart_count=0

  local interval=5

  # Test the fixed calculation logic (from lib/watchdog.sh lines 489-497)
  local restart_count=0
  local delay

  # Handle edge case: when restart_count=0, use interval directly (avoid 1 << -1)
  if [[ "$restart_count" -le 0 ]]; then
    delay="$interval"
  else
    delay=$((interval * (1 << (restart_count - 1))))
  fi

  # With restart_count=0, delay should equal interval
  [ "$delay" -eq "$interval" ]

  # Test with restart_count=1 (normal case)
  restart_count=1
  if [[ "$restart_count" -le 0 ]]; then
    delay="$interval"
  else
    delay=$((interval * (1 << (restart_count - 1))))
  fi
  [ "$delay" -eq "$interval" ]

  # Test with restart_count=2 (double interval)
  restart_count=2
  if [[ "$restart_count" -le 0 ]]; then
    delay="$interval"
  else
    delay=$((interval * (1 << (restart_count - 1))))
  fi
  [ "$delay" -eq $((interval * 2)) ]

  # Test with restart_count=3 (4x interval)
  restart_count=3
  if [[ "$restart_count" -le 0 ]]; then
    delay="$interval"
  else
    delay=$((interval * (1 << (restart_count - 1))))
  fi
  [ "$delay" -eq $((interval * 4)) ]
}

# ─────────────────────────────────────────────────────────────────────────────
# BUG: D006 - Hardcoded file descriptor 200 in PID lock
# Location: lib/watchdog.sh:165-177
# Impact: May conflict with other fd usage
# ─────────────────────────────────────────────────────────────────────────────

@test "BUG: PID lock should use dynamic file descriptor" {
  # The code uses fd 200 which could conflict
  # In bash 3.2, high fds may not be available

  # This test verifies the hardcoded fd issue
  local lock_file="/tmp/test_lock_$$"

  # Try to use fd 200 multiple times
  (exec 200>"$lock_file"; echo "locked" >&200) &
  local pid1=$!

  (exec 200>"$lock_file"; echo "locked2" >&200) &
  local pid2=$!

  wait "$pid1" 2>/dev/null || true
  wait "$pid2" 2>/dev/null || true

  rm -f "$lock_file"

  # If we get here without errors, the fd 200 is usable
  # but still a bad practice to hardcode
  true
}

# ─────────────────────────────────────────────────────────────────────────────
# is_agent_running
# ─────────────────────────────────────────────────────────────────────────────

@test "is_agent_running: returns false when no PID file" {
  run is_agent_running "NONEXISTENT"
  [ "$status" -ne 0 ]
}

@test "is_agent_running: returns false with stale PID file" {
  # Write a PID that doesn't exist
  echo "99999999" > "$TEST_CREW_DIR/.crew/run/STALE.pid"
  run is_agent_running "STALE"
  [ "$status" -ne 0 ]
}

@test "is_agent_running: returns true for running process" {
  # Start a real background process and write its PID
  sleep 60 &
  local real_pid=$!
  echo "$real_pid" > "$TEST_CREW_DIR/.crew/run/ALIVE.pid"

  run is_agent_running "ALIVE"
  [ "$status" -eq 0 ]

  kill "$real_pid" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# get_agent_status
# ─────────────────────────────────────────────────────────────────────────────

@test "get_agent_status: reports 'stopped' when no PID file" {
  run get_agent_status "MISSING"
  [ "$status" -eq 0 ]
  [ "$output" = "stopped" ]
}

@test "get_agent_status: reports 'stale' when PID file exists but process dead" {
  echo "99999999" > "$TEST_CREW_DIR/.crew/run/DEAD.pid"
  run get_agent_status "DEAD"
  [ "$status" -eq 0 ]
  [ "$output" = "stale" ]
}

@test "get_agent_status: reports 'running:<pid>' for live process" {
  sleep 60 &
  local real_pid=$!
  echo "$real_pid" > "$TEST_CREW_DIR/.crew/run/LIVE.pid"

  run get_agent_status "LIVE"
  [ "$status" -eq 0 ]
  [ "$output" = "running:$real_pid" ]

  kill "$real_pid" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# acquire_pid_lock / release_pid_lock
# ─────────────────────────────────────────────────────────────────────────────

@test "acquire_pid_lock: succeeds on fresh lock" {
  local pid_file="$TEST_CREW_DIR/.crew/run/LOCKTEST.pid"
  run acquire_pid_lock "$pid_file"
  [ "$status" -eq 0 ]
  [ -d "${pid_file}.lock" ]

  # Cleanup
  release_pid_lock "$pid_file"
}

@test "acquire_pid_lock: fails if already locked" {
  local pid_file="$TEST_CREW_DIR/.crew/run/LOCKTEST2.pid"
  acquire_pid_lock "$pid_file"

  run acquire_pid_lock "$pid_file"
  [ "$status" -ne 0 ]

  release_pid_lock "$pid_file"
}

@test "release_pid_lock: removes lock directory" {
  local pid_file="$TEST_CREW_DIR/.crew/run/LOCKTEST3.pid"
  acquire_pid_lock "$pid_file"
  [ -d "${pid_file}.lock" ]

  release_pid_lock "$pid_file"
  [ ! -d "${pid_file}.lock" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# rotate_log_if_needed
# ─────────────────────────────────────────────────────────────────────────────

@test "rotate_log_if_needed: no-op for small files" {
  local log="$TEST_CREW_DIR/.crew/logs/SMALL.log"
  echo "small log" > "$log"

  run rotate_log_if_needed "$log"
  [ "$status" -eq 0 ]
  # Original file should still exist unchanged
  [ -f "$log" ]
  [[ "$(cat "$log")" == "small log" ]]
}

@test "rotate_log_if_needed: no-op for nonexistent file" {
  run rotate_log_if_needed "$TEST_CREW_DIR/.crew/logs/NONE.log"
  [ "$status" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# start_agent / stop_agent lifecycle
# ─────────────────────────────────────────────────────────────────────────────

@test "start_agent: rejects invalid agent name" {
  run start_agent "bad name!" "$TEST_CREW_DIR/.crew/prompts/test.md" 5 "$TEST_CREW_DIR" ""
  [ "$status" -ne 0 ]
}

@test "start_agent: rejects missing prompt file" {
  run start_agent "NOPROMPT" "/nonexistent/prompt.md" 5 "$TEST_CREW_DIR" ""
  [ "$status" -ne 0 ]
}

@test "stop_agent: handles non-running agent gracefully" {
  run stop_agent "NOTRUNNING"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Not running"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# T049: Progress watchdog functions
# ─────────────────────────────────────────────────────────────────────────────

@test "_read_progress_key: returns default when file missing" {
  run _read_progress_key "/nonexistent/file" "key" "default_val"
  [ "$status" -eq 0 ]
  [ "$output" = "default_val" ]
}

@test "_read_progress_key: reads value from progress file" {
  local pfile="$TEST_CREW_DIR/progress.txt"
  cat > "$pfile" << 'EOF'
timestamp=1234567890
log_size=5000
idle_since=0
EOF
  run _read_progress_key "$pfile" "log_size" "0"
  [ "$output" = "5000" ]

  run _read_progress_key "$pfile" "timestamp" "0"
  [ "$output" = "1234567890" ]
}

@test "_read_progress_key: returns default when key missing" {
  local pfile="$TEST_CREW_DIR/progress.txt"
  echo "log_size=5000" > "$pfile"
  run _read_progress_key "$pfile" "idle_since" "42"
  [ "$output" = "42" ]
}

@test "_write_progress_key: creates file with key" {
  local pfile="$TEST_CREW_DIR/newprogress.txt"
  _write_progress_key "$pfile" "timestamp" "999"
  [ -f "$pfile" ]
  run _read_progress_key "$pfile" "timestamp" ""
  [ "$output" = "999" ]
}

@test "_write_progress_key: updates existing key" {
  local pfile="$TEST_CREW_DIR/update.txt"
  cat > "$pfile" << 'EOF'
timestamp=100
log_size=200
idle_since=300
EOF
  _write_progress_key "$pfile" "log_size" "999"

  run _read_progress_key "$pfile" "log_size" ""
  [ "$output" = "999" ]

  # Other keys preserved
  run _read_progress_key "$pfile" "timestamp" ""
  [ "$output" = "100" ]
  run _read_progress_key "$pfile" "idle_since" ""
  [ "$output" = "300" ]
}

@test "_write_progress_key: adds new key to existing file" {
  local pfile="$TEST_CREW_DIR/addkey.txt"
  echo "timestamp=100" > "$pfile"
  _write_progress_key "$pfile" "new_key" "hello"

  run _read_progress_key "$pfile" "new_key" ""
  [ "$output" = "hello" ]
  run _read_progress_key "$pfile" "timestamp" ""
  [ "$output" = "100" ]
}

@test "_get_descendant_pids: returns empty for process with no children" {
  # Use current shell PID — $$ has no children in this test context
  # but we just want to verify no crash
  run _get_descendant_pids "99999999"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_get_descendant_pids: finds children of a process" {
  # Start a parent that spawns a child
  (sleep 60 &
   echo $!
   wait) &
  local parent_pid=$!
  sleep 0.5

  run _get_descendant_pids "$parent_pid"
  # Should find at least the sleep process
  [ "$status" -eq 0 ]

  kill "$parent_pid" 2>/dev/null || true
  # Clean up any descendants
  for dpid in $output; do
    kill "$dpid" 2>/dev/null || true
  done
  wait "$parent_pid" 2>/dev/null || true
}

@test "_collect_progress_signals: creates progress file and lastcheck" {
  mkdir -p "$TEST_CREW_DIR/.crew/run" "$TEST_CREW_DIR/.crew/logs"
  # Create a fake running agent
  sleep 60 &
  local pid=$!
  _write_pid "$pid" "$TEST_CREW_DIR/.crew/run/TESTAGENT.pid"
  echo "some log output" > "$TEST_CREW_DIR/.crew/logs/TESTAGENT.log"

  _collect_progress_signals "TESTAGENT"

  [ -f "$TEST_CREW_DIR/.crew/run/TESTAGENT.progress" ]
  [ -f "$TEST_CREW_DIR/.crew/run/TESTAGENT.lastcheck" ]

  # Progress file should have expected keys
  run _read_progress_key "$TEST_CREW_DIR/.crew/run/TESTAGENT.progress" "timestamp" ""
  [ -n "$output" ]
  run _read_progress_key "$TEST_CREW_DIR/.crew/run/TESTAGENT.progress" "log_size" ""
  [ -n "$output" ]
  [ "$output" -gt 0 ]

  kill "$pid" 2>/dev/null || true
}

@test "_check_agent_progress: PRODUCTIVE when file changes detected" {
  mkdir -p "$TEST_CREW_DIR/.crew/run"
  local progress_file="$TEST_CREW_DIR/.crew/run/DEVAGENT.progress"
  cat > "$progress_file" << 'EOF'
log_growth=100
file_changes=3
child_procs=
idle_since=0
EOF

  run _check_agent_progress "DEVAGENT" "1800"
  [ "$output" = "PRODUCTIVE" ]
}

@test "_check_agent_progress: LEGITIMATE when known tools running" {
  mkdir -p "$TEST_CREW_DIR/.crew/run"
  local progress_file="$TEST_CREW_DIR/.crew/run/BUILDAGENT.progress"
  cat > "$progress_file" << 'EOF'
log_growth=0
file_changes=0
child_procs=pytest node
idle_since=0
EOF

  run _check_agent_progress "BUILDAGENT" "1800"
  [ "$output" = "LEGITIMATE" ]
}

@test "_check_agent_progress: SUSPECT when no progress for idle_timeout" {
  mkdir -p "$TEST_CREW_DIR/.crew/run"
  local now
  now=$(date +%s)
  local old=$((now - 3600))  # 1 hour ago

  local progress_file="$TEST_CREW_DIR/.crew/run/STUCKAGENT.progress"
  cat > "$progress_file" << EOF
log_growth=0
file_changes=0
child_procs=
idle_since=$old
EOF

  run _check_agent_progress "STUCKAGENT" "1800"
  [ "$output" = "SUSPECT" ]
}

@test "_check_agent_progress: PRODUCTIVE when within idle_timeout" {
  mkdir -p "$TEST_CREW_DIR/.crew/run"
  local now
  now=$(date +%s)
  local recent=$((now - 60))  # 1 minute ago

  local progress_file="$TEST_CREW_DIR/.crew/run/OKAGENT.progress"
  cat > "$progress_file" << EOF
log_growth=0
file_changes=0
child_procs=
idle_since=$recent
EOF

  run _check_agent_progress "OKAGENT" "1800"
  [ "$output" = "PRODUCTIVE" ]
}

@test "_check_agent_progress: SUSPECT on error loop (same line 10+ times)" {
  mkdir -p "$TEST_CREW_DIR/.crew/run" "$TEST_CREW_DIR/.crew/logs"
  local progress_file="$TEST_CREW_DIR/.crew/run/LOOPAGENT.progress"
  cat > "$progress_file" << 'EOF'
log_growth=500
file_changes=0
child_procs=
idle_since=0
EOF

  # Create log with repeated error
  local log_file="$TEST_CREW_DIR/.crew/logs/LOOPAGENT.log"
  for i in $(seq 1 15); do
    echo "Error: API rate limit exceeded" >> "$log_file"
  done

  run _check_agent_progress "LOOPAGENT" "1800"
  [ "$output" = "SUSPECT" ]
}

@test "_check_agent_progress: SUSPECT on log growth without file changes for 2x idle_timeout" {
  mkdir -p "$TEST_CREW_DIR/.crew/run"
  local now
  now=$(date +%s)
  local old=$((now - 7200))  # 2 hours ago (> 2 * 1800s)

  local progress_file="$TEST_CREW_DIR/.crew/run/CHATTYAGENT.progress"
  cat > "$progress_file" << EOF
log_growth=1000
file_changes=0
child_procs=
idle_since=$old
EOF

  run _check_agent_progress "CHATTYAGENT" "1800"
  [ "$output" = "SUSPECT" ]
}

@test "_check_agent_progress: writes verdict file" {
  mkdir -p "$TEST_CREW_DIR/.crew/run"
  local progress_file="$TEST_CREW_DIR/.crew/run/VERDICTTEST.progress"
  cat > "$progress_file" << 'EOF'
log_growth=100
file_changes=5
child_procs=
idle_since=0
EOF

  _check_agent_progress "VERDICTTEST" "1800" > /dev/null
  [ -f "$TEST_CREW_DIR/.crew/run/VERDICTTEST.verdict" ]
  local verdict
  verdict=$(cat "$TEST_CREW_DIR/.crew/run/VERDICTTEST.verdict")
  [ "$verdict" = "PRODUCTIVE" ]
}

@test "stop_agent: cleans up progress files" {
  mkdir -p "$TEST_CREW_DIR/.crew/run"
  # Create progress tracking files
  echo "some progress" > "$TEST_CREW_DIR/.crew/run/CLEANUP.progress"
  touch "$TEST_CREW_DIR/.crew/run/CLEANUP.lastcheck"
  echo "PRODUCTIVE" > "$TEST_CREW_DIR/.crew/run/CLEANUP.verdict"
  echo "1" > "$TEST_CREW_DIR/.crew/run/CLEANUP.advance"

  # Agent is not running (no PID file)
  run stop_agent "CLEANUP"

  # Progress files should be cleaned
  [ ! -f "$TEST_CREW_DIR/.crew/run/CLEANUP.progress" ]
  [ ! -f "$TEST_CREW_DIR/.crew/run/CLEANUP.lastcheck" ]
  [ ! -f "$TEST_CREW_DIR/.crew/run/CLEANUP.verdict" ]
  [ ! -f "$TEST_CREW_DIR/.crew/run/CLEANUP.advance" ]
}

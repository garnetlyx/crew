# crew - Development Tasks

**Last Updated**: 2026-02-27

## Task Sizing

| Size | Effort |
|------|--------|
| S | < 1 hour |
| M | 1-4 hours |
| L | 4+ hours |

---

## P0: Critical Security & Reliability

### T000: Add .gitignore [S] - COMPLETED 2026-01-28
- [x] Create .gitignore with .crew/logs/, .crew/run/, .design/history/
- [x] Add docs/EVAL.md to gitignore (local only)
- [x] Include editor and OS-specific ignores

### T001: Add input validation [M] - COMPLETED 2026-02-06
- [x] Create validate_agent_name() in lib/utils.sh
- [x] Create validate_file_path() to prevent path traversal
- [x] Create validate_interval() for numeric config values
- [x] Add validation to crew.sh (agent name inputs)
- [x] Add validation to design.sh (idea input)

### T002: Fix infinite restart loop [M] - COMPLETED 2026-02-06
- [x] Add restart_count and max_restarts to lib/watchdog.sh
- [x] Implement exponential backoff (capped at 300s)
- [x] Log when max restarts reached
- [x] Exit agent loop after max_restarts (5) hit

### T003: Add agent execution timeout [M] - PARTIALLY COMPLETE
- [ ] Use `timeout` command wrapping plugin_run in lib/watchdog.sh:273-288
- [x] Make timeout configurable per agent (field exists in crew.yaml)
- [ ] Log when timeout occurs (exit code 124)
- [ ] Handle timeout exit code (124) in restart backoff logic

### T004: Improve PID management [M] - COMPLETED 2026-02-06
- [x] Add flock-based file locking to lib/watchdog.sh
- [x] Graceful fallback for systems without flock
- [x] Handle PID reuse edge case

### T005: Add log rotation [S] - COMPLETED 2026-02-06
- [x] Implement size-based rotation (10MB max)
- [x] Rotate to .log.old on size threshold
- [x] Add rotate_log_if_needed() to lib/watchdog.sh

### T006: Extract magic numbers [S] - COMPLETED 2026-02-06
- [x] Move hardcoded values to named constants at file top
- [x] lib/watchdog.sh: DEFAULT_RESTART_DELAY, GRACEFUL_SHUTDOWN_TIMEOUT
- [x] lib/orchestrator.sh: conflict threshold
- [x] crew.sh: CREW_DIR constant

### T007: Fix eval in env var expansion [S] - FROM REVIEW 2026-02-26
- [ ] Replace `eval echo "$value"` in lib/watchdog.sh:60 and lib/watchdog.sh:153
- [ ] Use `envsubst` or safe Bash parameter expansion instead
- [ ] Test with values containing spaces, $() subshell syntax, and backticks
- [ ] Update SECURITY.md to accurately describe current eval usage

### T008: Wire parse_options in design.sh [S] - FROM REVIEW 2026-02-26
- [ ] Call `parse_options` from `main()` in design.sh before the case dispatch
- [ ] Pass MAX_ITER_OVERRIDE to cross_review_loop or read it inside the function
- [ ] Verify `--agent TYPE` and `--max-iter N` flags work end-to-end
- [ ] Add to design --help examples to document both flags

### T009: Decide on watchdog_loop [S] - FROM REVIEW 2026-02-26
- [ ] Either: call `watchdog_loop` as background process from crew_start()
- [ ] Or: remove --check-interval and --no-watchdog from crew.sh usage text
- [ ] And: delete the unused watchdog_loop() function if not implementing
- [ ] If keeping: wire --check-interval and --no-watchdog parsing in crew.sh:main()

---

## P1: Testing (Critical for Quality)

### T010: Set up test framework [M]
- [ ] Install bats-core for Bash testing
- [ ] Create tests/ directory structure (unit/, integration/, fixtures/)
- [ ] Add GitHub Actions CI configuration (.github/workflows/ci.yml)
- [ ] Document how to run tests in README

### T011: Unit tests for lib/utils.sh [S]
- [ ] Test log_* functions
- [ ] Test file_hash (md5/md5sum/fallback)
- [ ] Test ensure_dir
- [ ] Test command_exists
- [ ] Test validate_agent_name (boundary: 32 chars, special chars, empty)

### T012: Unit tests for lib/config.sh [M]
- [ ] Test config_get with yq against a real YAML fixture
- [ ] Test config_get with Python fallback (simple key paths only)
- [ ] Test validate_config with valid/invalid YAML
- [ ] Test get_agent_type precedence (env > config > default)

### T013: Unit tests for lib/orchestrator.sh [M]
- [ ] Test parse_review_decision: "PASS: true", "PASS: false", "**PASS**: true", "NOT PASS: true"
- [ ] Test resolve_prompt_path (local vs crew home priority)
- [ ] Test stale detection (same hash twice triggers EXIT_STALE)

### T014: Unit tests for lib/watchdog.sh [M]
- [ ] Test is_agent_running with mock PID files
- [ ] Test get_agent_status states (running, stale, stopped)
- [ ] Test start_agent / stop_agent lifecycle with mock echo command

### T015: Integration tests [L]
- [ ] End-to-end design init + design review (mock agent)
- [ ] End-to-end crew init + crew start + crew stop
- [ ] Test termination conditions (stale, pass)

---

## P2: Error Handling & Robustness

### T020: Add trap handlers [S] - COMPLETED 2026-02-06
- [x] Add _crew_cleanup() function to crew.sh and design.sh
- [x] Trap EXIT INT TERM signals
- [x] Ensure stop_all_agents called on exit

### T021: Improve config parsing errors [S]
- [ ] Make config_get failures more visible
- [ ] Add warning when using defaults due to missing config key
- [ ] Validate YAML parser availability at startup (yq required for complex queries)

### T022: Add strict mode to libraries [S] - COMPLETED 2026-02-06
- [x] Add set -euo pipefail to all lib/*.sh files
- [x] Use ${DEBUG:-} and ${CREW_AGENT:-} patterns for unbound vars

### T023: Re-implement conflict detection [M]
- [ ] Track repeated issue headings across last N review files
- [ ] Trigger EXIT_STALE or new EXIT_CONFLICT (exit 3) when threshold exceeded
- [ ] Update ARCHITECTURE.md to match implementation
- [ ] Make conflict_threshold configurable in design.yaml

### T024: Fix unquoted loop variables [S] - FROM REVIEW 2026-02-26
- [ ] Replace `for name in $agents` at lib/status.sh:46
- [ ] Replace `for name in $agents` at lib/status.sh:247
- [ ] Replace `for name in $agents` at lib/watchdog.sh:562
- [ ] Use `while IFS= read -r name; do ... done <<< "$agents"` consistently

### T025: Fix Python YAML fallback [M] - FROM REVIEW 2026-02-26
- [ ] Option A: Implement proper yq-expression handling covering select(), [], and | in Python
- [ ] Option B: Make yq a hard requirement — add startup check in lib/config.sh
- [ ] If choosing Option B: update install.sh and README to make yq mandatory
- [ ] Remove misleading "python3 with pyyaml" fallback message if going with Option B

---

## P3: Documentation

### T030: Add inline comments to lib modules [M]
- [ ] orchestrator.sh - document termination logic and exit codes
- [ ] watchdog.sh - document PID management and fallback chain
- [ ] agent_runner.sh - document CLI abstraction

### T031: Create SECURITY.md [S] - COMPLETED 2026-02-06
- [x] Document trust boundaries
- [x] Explain prompt injection risks
- [x] Recommend input validation best practices

### T031b: Update SECURITY.md for eval [S] - FROM REVIEW 2026-02-26
- [ ] Correct "crew does not use eval" (line 29) — no longer accurate
- [ ] Document watchdog.sh eval for env expansion and legacy command path
- [ ] Reinforce recommendation to use type: plugin instead of command:

### T032: Add --help examples [S]
- [ ] Improve design --help with --agent and --max-iter examples (once T008 is done)
- [ ] Improve crew --help with troubleshooting section
- [ ] Add common error messages and fixes

### T033: Fix YOUR_USERNAME placeholders [S] - FROM REVIEW 2026-02-26
- [ ] Replace placeholder at README.md:22
- [ ] Replace placeholder at CONTRIBUTING.md:17
- [ ] Replace placeholder at docs/PRD.md:158
- [ ] (Third time flagged; must fix before any public launch)

### T034: Fix ARCHITECTURE.md exit code 3 reference [S] - FROM REVIEW 2026-02-26
- [ ] Remove or update CONFLICT (exit 3) from termination conditions diagram
- [ ] Reflect current behavior: only PASS, STALE, and MAX_ITER are implemented
- [ ] Update once T023 (conflict detection) is re-implemented

### T035: Fix gemini install hint [S] - FROM REVIEW 2026-02-26
- [ ] Update plugins/gemini.sh:3 comment to correct package name
- [ ] Update plugins/gemini.sh:28 install hint message
- [ ] Verify correct npm package name against official Gemini CLI documentation

---

## P4: Features

### T040: Agent-to-agent coordination [L]
- [ ] Design shared context mechanism
- [ ] Implement `.crew/shared/` for inter-agent state
- [ ] Add file locking to prevent conflicts
- [ ] Document coordination patterns

### T041: Result aggregation [M]
- [ ] Collect agent outputs after run
- [ ] Generate summary report
- [ ] Detect conflicting changes

### T042: Dry-run mode [S]
- [ ] Add `--dry-run` flag to `design review`
- [ ] Print what would happen without executing
- [ ] Useful for testing prompt changes

### T043: Workflow templates with `crew init --template` [M]
- [ ] Add `--template <name>` flag to `crew init`
- [ ] Create `templates/workflows/` directory with 5+ preset configs
- [ ] Presets: code-review (QA+DEV), refactor (DEV+JANITOR), security-audit (QA+DEV), docs (DEV+JANITOR), full (QA+DEV+JANITOR)
- [ ] Each template: crew.yaml + matching prompt files + .env.example
- [ ] Add `crew init --list-templates` to show available presets
- [ ] New users should go from install to running agents in under 60 seconds

### T044: Configuration validation [S]
- [ ] Validate prompt files exist at crew start
- [ ] Validate agent commands are executable
- [ ] Show helpful errors for misconfigurations

### T045: Add `crew edit` command [S]
- [ ] Add `edit` case to crew.sh main dispatch
- [ ] Open `$CREW_DIR/prompts/<agent>.md` in `$EDITOR`
- [ ] Fall back to `vi` if `$EDITOR` not set
- [ ] Add usage to help text

### T046: Add JSON config fallback [S]
- [ ] Update lib/config.sh to support `.crew/crew.json`
- [ ] Use Python's built-in `json` module (no pip needed)
- [ ] Try yq first, then JSON fallback
- [ ] Document in README

### T047: Fix codex flags array serialization [S] - FROM REVIEW 2026-02-26
- [ ] Test current -c flag passing with a live codex binary
- [ ] If flags are not applied: split into two array elements per flag: `flags+=(-c); flags+=("key=value")`
- [ ] Avoid line-by-line serialization; pass array directly to codex invocation

### T048: Fix agent execution timeout (complete T003) [M]
- [ ] Read timeout field in start_agent from config
- [ ] Wrap plugin_run call with `timeout "$agent_timeout"` in lib/watchdog.sh
- [ ] Handle exit code 124 specifically in the restart logic
- [ ] Log timeout event with agent name and duration

### T049: Hybrid progress watchdog (system-level + AI judge) [L]
- **Architecture**: watchdog is infrastructure, not a peer agent. Pure Bash loop does
  lightweight periodic checks; only spawns a one-shot AI call when heuristics flag
  suspicious state. Avoids "who watches the watchman" infinite regress.
- **Problem**: agents silently fail — process alive but no useful output:
  - Agent answers questions but makes no file changes (摸鱼)
  - Agent hangs with no log output (MCP tools missing, permission denied, API error loops)
  - Agent stuck in infinite retry/backoff (e.g., opencode exponential backoff on API failure)
  - Required tools not installed, agent spins without progress
- **Config schema** (crew.yaml):
  ```yaml
  watchdog:
    enabled: true
    check_interval: 900         # 15min lightweight Bash checks
    idle_timeout: 1800          # 30min no progress → trigger AI judge
    ai_judge:
      enabled: true             # opt-in, default false
      type: claude              # which CLI plugin for judgment
      env:
        ANTHROPIC_MODEL: haiku  # cheapest model for cost control
      prompt: prompts/crew/watchdog.md
    on_stuck: fallback          # fallback | restart | notify | stop
  ```
- **Depends on**: T009 (wire watchdog_loop) must be resolved first
- [ ] **Phase 1: Progress signal collection** [M] — in `watchdog_loop`, pure Bash
  - [ ] Track working directory file changes since last check (`find . -newer .crew/run/<AGENT>.lastcheck`)
  - [ ] Track log file growth (byte count delta via `stat`)
  - [ ] Track process tree via `ps -o pid,ppid,etime,comm` (detect child processes: pytest, make, cargo, node)
  - [ ] Write signals to `.crew/run/<AGENT>.progress` (key=value format, no JSON dependency)
  - [ ] Touch `.crew/run/<AGENT>.lastcheck` after each collection cycle
- [ ] **Phase 2: Heuristic pre-filter** [S] — in `watchdog_loop`, pure Bash
  - [ ] No log growth AND no file changes for `idle_timeout` → flag SUSPECT
  - [ ] Has active child processes (test runners, compilers, build tools) → skip, mark LEGITIMATE
  - [ ] Log growing but zero file changes for 2x `idle_timeout` → flag SUSPECT (answer-only loop)
  - [ ] Log contains repeated error patterns (same line 10+ times) → flag SUSPECT (error loop)
  - [ ] If `ai_judge.enabled: false`, SUSPECT → directly trigger `on_stuck` action (no AI call)
- [ ] **Phase 3: AI judge** [M] — one-shot CLI call, not a persistent agent
  - [ ] Only invoked when Phase 2 flags SUSPECT and `ai_judge.enabled: true`
  - [ ] Build context file (`/tmp/crew_watchdog_<AGENT>.txt`):
    - Last 200 lines of agent log (`tail -200`)
    - File change summary (`git diff --stat` or `find` output)
    - Process tree snapshot (`ps` output)
    - Time since last productive output
    - Current fallback level and restart count
  - [ ] Invoke via `plugin_run_prompt` with configured type/env (e.g., haiku)
  - [ ] Parse AI response for verdict keyword: PRODUCTIVE / STUCK / UNCERTAIN
  - [ ] On STUCK: trigger `on_stuck` action (fallback/restart/notify/stop)
  - [ ] On UNCERTAIN: extend grace period by `idle_timeout`, re-check next cycle
  - [ ] On PRODUCTIVE: reset idle timer, clear SUSPECT flag
  - [ ] Cost guard: max 1 AI judge call per agent per hour (prevent runaway spend)
- [ ] **Phase 4: Actions & integration** [S]
  - [ ] `on_stuck: fallback` — advance to next fallback level (same as max_restarts exhaustion)
  - [ ] `on_stuck: restart` — restart agent at current level
  - [ ] `on_stuck: notify` — run user-defined command (e.g., `./scripts/notify.sh`)
  - [ ] `on_stuck: stop` — stop agent, log reason
  - [ ] Log all verdicts + reasons to `.crew/logs/watchdog.log`
  - [ ] Add verdict column to `crew status` output (PRODUCTIVE/STUCK/—)
  - [ ] Create default `prompts/crew/watchdog.md` with judgment instructions
- [ ] **Phase 5: Watchdog prompt engineering** [S]
  - [ ] Prompt must instruct AI to output exactly one line: `VERDICT: <PRODUCTIVE|STUCK|UNCERTAIN> — <reason>`
  - [ ] Include examples of each scenario (legitimate test run vs hung vs answer-only)
  - [ ] Instruct AI to check for: file modifications, meaningful log progress, error loops, tool availability signals

---

## P5: Infrastructure

### T050: Add CI/CD pipeline [S]
- [ ] Create .github/workflows/ci.yml
- [ ] Add shellcheck lint job (ubuntu-latest has shellcheck pre-installed)
- [ ] Add smoke test job once T010 is complete
- [ ] Run on push and pull_request

### T051: Add uninstall script [S]
- [ ] Create uninstall.sh that removes ~/.local/bin/crew and ~/.local/bin/design symlinks
- [ ] Print confirmation message
- [ ] Add to README under Installation

### T052: Fix install.sh strict mode [S] - FROM REVIEW 2026-02-26
- [ ] Add `set -euo pipefail` to install.sh (currently only `set -e`)

---

## P6: Launch Readiness (Market Attractiveness)

### T060: Record asciinema/GIF demo [S]
- [ ] Record `design init "idea" && design review` full loop (~30s)
- [ ] Record `crew start` with 3 agents running in parallel
- [ ] Convert to GIF or host on asciinema.org
- [ ] Embed at top of README.md (above description)
- [ ] First impression is everything — show, don't tell

### T061: Add one-line positioning hook to README [S]
- [ ] Add hero tagline to README first line after title
- [ ] Hook: "When Claude rate-limits, automatically switch to Gemini. When that fails, run your own script."
- [ ] This is the single most compelling differentiator per market analysis

### T062: Homebrew formula [M]
- [ ] Create `Formula/crew.rb` or submit to homebrew-core
- [ ] Alternative: create `homebrew-crew` tap repository
- [ ] Support `brew install crew-ai` (or `brew tap ... && brew install crew`)
- [ ] Add Homebrew install option to README
- [ ] One-line install is the #1 friction reducer for macOS users

### T063: MCP server mode [L]
- [ ] Implement `crew serve --mcp` to expose crew as MCP server
- [ ] Expose tools: crew_start, crew_stop, crew_status, design_init, design_review
- [ ] JSON-RPC over stdio (standard MCP protocol)
- [ ] This opens crew to Claude Desktop, Cursor, and other MCP-capable IDEs
- [ ] No Bash-native tool currently offers this — first mover advantage

### T064: Token/cost tracking [M]
- [ ] Parse agent logs for token usage patterns (model-specific)
- [ ] Add `crew cost` command to display estimated spend per agent
- [ ] Show cost breakdown by fallback level (which level consumed most)
- [ ] Users care about money — this drives trust and retention

### T065: Shared context for agent coordination [M]
- [ ] Implement `.crew/shared/context.md` as inter-agent state file
- [ ] Agents can read shared context at start of each run
- [ ] Add file locking to prevent write conflicts
- [ ] Prerequisite for meaningful multi-agent collaboration
- [ ] (Overlaps with T040 — T040 is the full design, this is the MVP)

---

## Technical Debt

### D001: Remove hardcoded defaults [S]
- Location: `lib/watchdog.sh:8-10`
- Issue: `DEFAULT_CHECK_INTERVAL=30` should come from config
- Fix: Read from config with fallback

### D002: CD in agent_runner.sh [S] - COMPLETED 2026-02-06
- [x] Wrapped cd in subshells to avoid changing global state

### D003: build_prompt arg size limit [M]
- Location: `lib/agent_runner.sh:55-78`
- Issue: Large prompt content passed as CLI argument may exceed ARG_MAX
- Fix: Write combined prompt to temp file and use plugin_run (file-based) interface

### D004: Prompt file validation [S] - COMPLETED 2026-02-06
- [x] Added early validation with helpful error message

### D005: Inline env vars in command [M] - COMPLETED 2026-02-06
- [x] Implemented T028 (`env` field) and export_agent_env()

### D006: fd 200 hardcoded in PID lock [S]
- Location: `lib/watchdog.sh:165`
- Issue: Hardcoded fd 200 is fragile; may conflict with other file descriptor usage
- Fix: Use fd 9 or document the constraint explicitly

---

## Completed

- [x] Initial project structure - 2026-01-28
- [x] Design mode implementation - 2026-01-28
- [x] Crew mode implementation - 2026-01-28
- [x] AGENTS.md documentation - 2026-01-28
- [x] PRD.md documentation - 2026-01-28
- [x] ARCHITECTURE.md documentation - 2026-01-28
- [x] TASKS.md development backlog - 2026-01-28
- [x] SESSION_LOG.md checkpoint log - 2026-01-28
- [x] Code review (docs/EVAL.md) - 2026-01-28
- [x] Create .gitignore - 2026-01-28
- [x] Verify deployment in ai-judge - 2026-01-28
- [x] Fix critical bug: Multi-line config parsing - 2026-01-28
- [x] Fix critical bug: Prompt path resolution - 2026-01-28
- [x] T001: Input validation (agent names, file paths, intervals) - 2026-02-06
- [x] T002: Max restarts (5) with exponential backoff - 2026-02-06
- [x] T004: flock-based PID file locking - 2026-02-06
- [x] T005: Log rotation (10MB threshold) - 2026-02-06
- [x] T006: Extract magic numbers to named constants - 2026-02-06
- [x] T020: Trap handlers for graceful cleanup - 2026-02-06
- [x] T022: Strict mode in all library files - 2026-02-06
- [x] T028: Per-agent env config field - 2026-02-06
- [x] T031: SECURITY.md documentation - 2026-02-06
- [x] D002: CD wrapped in subshells - 2026-02-06
- [x] D004: Prompt file validation - 2026-02-06
- [x] Plugin system v0.2.0 (claude, codex, opencode, gemini, aider) - 2026-02-24
- [x] Fallback chain mechanism with per-level env overlay and max_restarts - 2026-02-24
- [x] Codex plugin: OpenAI-compatible provider config via env vars - 2026-02-24
- [x] Design-review mode: rename from cross-review, file input support - 2026-02-26
- [x] design_init: support file argument in addition to inline text - 2026-02-26
- [x] Template examples: restructured crew.yaml.example with 3 use cases - 2026-02-26

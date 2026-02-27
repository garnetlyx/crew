# crew - Architecture Document

**Version**: 0.2.1
**Last Updated**: 2026-02-26

---

## 1. System Overview

crew is a Bash-based multi-agent orchestration system with two operational modes:

```
                          ┌─────────────────────────────────────┐
                          │              crew                    │
                          │    Multi-Agent Orchestration Tool    │
                          └─────────────────────────────────────┘
                                          │
                    ┌─────────────────────┴─────────────────────┐
                    │                                           │
           ┌────────▼────────┐                        ┌─────────▼────────┐
           │   Design Mode    │                        │    Crew Mode     │
           │  (design.sh)     │                        │   (crew.sh)      │
           │                  │                        │                  │
           │  Design-Review    │                        │  Parallel Agents │
           │  Writer ⇄ Review │                        │  + Watchdog      │
           └──────────────────┘                        └──────────────────┘
```

---

## 2. Component Architecture

### 2.1 Entry Points

```
┌──────────────────────────────────────────────────────────────────┐
│                         Entry Points                              │
├────────────────────────────┬─────────────────────────────────────┤
│         design.sh          │             crew.sh                  │
│                            │                                      │
│  Commands:                 │  Commands:                           │
│  - init <idea>             │  - init                              │
│  - review                  │  - start [AGENT...]                  │
│  - status                  │  - stop [AGENT...]                   │
│  - reset                   │  - restart [AGENT...]                │
│                            │  - status                            │
│                            │  - monitor                           │
│                            │  - logs <AGENT>                      │
│                            │  - validate                          │
└────────────────────────────┴─────────────────────────────────────┘
```

### 2.2 Library Modules

```
lib/
├── utils.sh          ─────────────────────────────────────────────┐
│   Core utilities: logging, colors, file hashing, prompts         │
│   Used by: ALL modules                                           │
├──────────────────────────────────────────────────────────────────┤
├── config.sh         ─────────────────────────────────────────────┐
│   YAML parsing: yq primary, Python fallback                      │
│   Functions: parse_yaml, config_get, validate_config             │
│   Used by: orchestrator.sh, watchdog.sh, status.sh               │
├──────────────────────────────────────────────────────────────────┤
├── orchestrator.sh   ─────────────────────────────────────────────┐
│   Design-review engine: loop control, termination detection       │
│   Functions: cross_review_loop, parse_review_decision,           │
│              detect_conflict, design_init, design_status         │
│   Used by: design.sh                                             │
├──────────────────────────────────────────────────────────────────┤
├── watchdog.sh       ─────────────────────────────────────────────┐
│   Agent lifecycle: start, stop, health checks, auto-restart      │
│   Functions: start_agent, stop_agent, is_agent_running,          │
│              restart_agent, watchdog_loop                        │
│   Used by: crew.sh, status.sh                                    │
├──────────────────────────────────────────────────────────────────┤
├── plugin_loader.sh ─────────────────────────────────────────────┐
│   CLI plugin discovery, loading, validation, dispatch            │
│   Functions: load_plugin, plugin_run, plugin_run_prompt,         │
│              plugin_check, list_plugins                          │
│   Used by: agent_runner.sh, watchdog.sh, crew.sh                 │
├──────────────────────────────────────────────────────────────────┤
├── agent_runner.sh   ─────────────────────────────────────────────┐
│   CLI abstraction: design mode interface (delegates to plugins)  │
│   Functions: agent_runner, build_prompt, check_agent, list_agents│
│   Used by: orchestrator.sh                                       │
├──────────────────────────────────────────────────────────────────┤
└── status.sh         ─────────────────────────────────────────────┐
    Display: status tables, real-time monitor, log tailing          │
    Functions: show_status, monitor_loop, tail_agent_log            │
    Used by: crew.sh                                                │
└──────────────────────────────────────────────────────────────────┘
```

### 2.3 Dependency Graph

```
                    ┌─────────────┐
                    │  utils.sh   │ ← Foundation (no dependencies)
                    └──────┬──────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
        ┌─────▼─────┐ ┌────▼────┐ ┌─────▼─────┐
        │ config.sh │ │ (other) │ │ (other)   │
        └─────┬─────┘ └─────────┘ └───────────┘
              │
    ┌─────────┼─────────────────┐
    │         │                 │
┌───▼────┐ ┌──▼──────────┐ ┌────▼──────┐
│watchdog│ │agent_runner │ │  status   │
└───┬────┘ └──────┬──────┘ └─────┬─────┘
    │             │              │
    │      ┌──────▼──────┐       │
    │      │orchestrator │       │
    │      └─────────────┘       │
    │                            │
┌───▼────────────────────────────▼───┐
│              Entry Points           │
│     design.sh         crew.sh      │
└────────────────────────────────────┘
```

---

## 3. Data Flow

### 3.1 Design Mode: Design-Review Loop

```
                              design init "idea"
                                     │
                                     ▼
                          ┌─────────────────────┐
                          │  Create .design/    │
                          │  - idea.txt         │
                          │  - design.yaml      │
                          └──────────┬──────────┘
                                     │
                              design review
                                     │
                                     ▼
┌────────────────────────────────────────────────────────────────────┐
│                        Design-Review Loop                            │
│                                                                     │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────┐           │
│  │   Inject    │     │ Plan Writer │     │   Output    │           │
│  │ - idea.txt  │────▶│   Agent     │────▶│  plan.md    │           │
│  │ - plan.md   │     │ (via CLI)   │     │             │           │
│  │ - review.md │     └─────────────┘     └──────┬──────┘           │
│  └─────────────┘                                │                   │
│                                                 ▼                   │
│                                    ┌────────────────────┐           │
│                                    │  Stale Detection   │           │
│                                    │  (hash comparison) │           │
│                                    └─────────┬──────────┘           │
│                                              │                      │
│                     ┌────────────────────────┴─────┐                │
│                     │ stale_count >= threshold?    │                │
│                     └────────────┬─────────────────┘                │
│                                  │ No                               │
│                                  ▼                                  │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────┐           │
│  │   Inject    │     │  Reviewer   │     │   Output    │           │
│  │ - plan.md   │────▶│   Agent     │────▶│  review.md  │           │
│  │             │     │ (via CLI)   │     │             │           │
│  └─────────────┘     └─────────────┘     └──────┬──────┘           │
│                                                 │                   │
│                                                 ▼                   │
│                              ┌─────────────────────────┐            │
│                              │  Parse Decision         │            │
│                              │  (grep "PASS: true")    │            │
│                              └────────────┬────────────┘            │
│                                           │                         │
│                    ┌──────────────────────┼──────────────────────┐  │
│                    │                      │                      │  │
│              ┌─────▼─────┐          ┌─────▼─────┐          ┌─────▼──│
│              │   PASS    │          │   FAIL    │          │CONFLICT│
│              │  Exit 0   │          │  Continue │          │ Exit 3 │
│              └───────────┘          │   Loop    │          └────────│
│                                     └─────┬─────┘                   │
│                                           │                         │
│                                           └──────────▶ (next iter)  │
└────────────────────────────────────────────────────────────────────┘
```

### 3.2 Crew Mode: Parallel Agent Execution

```
                               crew init
                                   │
                                   ▼
                        ┌──────────────────────┐
                        │   Create .crew/      │
                        │   - crew.yaml        │
                        │   - prompts/         │
                        │   - logs/            │
                        │   - run/             │
                        └──────────┬───────────┘
                                   │
                            crew start [AGENTS]
                                   │
                                   ▼
┌──────────────────────────────────────────────────────────────────┐
│                         Crew Execution                            │
│                                                                   │
│   ┌─────────────────────────────────────────────────────────┐    │
│   │                    Watchdog Loop                         │    │
│   │              (every check_interval seconds)              │    │
│   │                                                          │    │
│   │  for each agent:                                         │    │
│   │    status = get_agent_status()                           │    │
│   │    if status == "stale":  → cleanup + restart            │    │
│   │    if status == "stopped": → start                       │    │
│   │    if status == "running": → OK                          │    │
│   └─────────────────────────────────────────────────────────┘    │
│                                                                   │
│         ┌──────────┐    ┌──────────┐    ┌──────────┐             │
│         │    QA    │    │   DEV    │    │ JANITOR  │             │
│         │  Agent   │    │  Agent   │    │  Agent   │             │
│         └────┬─────┘    └────┬─────┘    └────┬─────┘             │
│              │               │               │                    │
│         ┌────▼─────┐    ┌────▼─────┐    ┌────▼─────┐             │
│         │ .pid file│    │ .pid file│    │ .pid file│             │
│         │ .log file│    │ .log file│    │ .log file│             │
│         └──────────┘    └──────────┘    └──────────┘             │
│                                                                   │
└──────────────────────────────────────────────────────────────────┘
```

---

## 4. File System Layout

### 4.1 Installation Directory

```
~/dev/crew/                    # CREW_HOME
├── crew.sh                    # Crew mode entry
├── design.sh                  # Design mode entry
├── install.sh                 # Installation script
├── CONTRIBUTING.md            # Contribution guidelines
├── LICENSE                    # MIT license
├── SECURITY.md                # Security policy
├── lib/
│   ├── utils.sh
│   ├── config.sh
│   ├── orchestrator.sh
│   ├── watchdog.sh
│   ├── agent_runner.sh
│   └── status.sh
├── plugins/
│   ├── claude.sh              # Claude CLI plugin
│   ├── codex.sh               # OpenAI Codex plugin
│   ├── opencode.sh            # OpenCode plugin
│   ├── gemini.sh              # Gemini plugin
│   └── aider.sh               # Aider plugin
├── prompts/
│   ├── crew/
│   │   ├── qa.md              # QA agent prompt
│   │   ├── dev.md             # DEV agent prompt
│   │   └── janitor.md         # JANITOR agent prompt
│   └── design-review/
│       ├── plan_writer.md     # Default Writer prompt
│       └── reviewer.md        # Default Reviewer prompt
└── docs/
    ├── PRD.md
    ├── ARCHITECTURE.md
    ├── TASKS.md
    ├── SESSION_LOG.md
    └── EVAL.md
```

### 4.2 Project Working Directory (.design/)

```
<project>/
└── .design/
    ├── design.yaml            # Session configuration
    ├── idea.txt               # User's initial idea
    ├── plan.md                # Current plan (Writer output)
    ├── review.md              # Current review (Reviewer output)
    ├── history/
    │   ├── plan_v1.md
    │   ├── review_v1.md
    │   ├── plan_v2.md
    │   └── review_v2.md
    └── prompts/               # Optional custom prompts
        ├── plan_writer.md
        └── reviewer.md
```

### 4.3 Project Working Directory (.crew/)

```
<project>/
└── .crew/
    ├── crew.yaml              # Agent configuration
    ├── cli.d/                     # Custom CLI plugins (optional)
    ├── prompts/
    │   ├── qa.txt
    │   ├── dev.txt
    │   └── janitor.txt
    ├── logs/
    │   ├── QA.log
    │   ├── DEV.log
    │   └── JANITOR.log
    └── run/
        ├── QA.pid
        ├── DEV.pid
        └── JANITOR.pid
```

---

## 5. Key Algorithms

### 5.1 Termination Detection

```
┌─────────────────────────────────────────────────────────────────┐
│                    Termination Conditions                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. PASS (exit 0)                                               │
│     ─────────────                                                │
│     review.md contains "PASS: true" (case-insensitive)          │
│                                                                  │
│  2. STALE (exit 2)                                              │
│     ────────────                                                 │
│     plan.md hash unchanged for stale_threshold iterations       │
│     Default: 2 consecutive identical hashes                      │
│                                                                  │
│  3. CONFLICT (exit 3)                                           │
│     ─────────────                                                │
│     Same issue titles appear conflict_threshold times           │
│     Detection: grep "### [CATEGORY]:" from last N reviews       │
│     Default: 3 repeated issues                                   │
│                                                                  │
│  4. MAX_ITER (exit 1)                                           │
│     ─────────────                                                │
│     Loop count >= max_iterations config value                    │
│     Default: 5 iterations                                        │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 5.2 Agent Health Check

```bash
get_agent_status():
    if PID file does not exist:
        return "stopped"

    # flock-based locking (with graceful fallback if flock unavailable)
    acquire_lock(pid_file)

    pid = read PID file

    if kill -0 $pid succeeds:
        return "running:$pid"
    else:
        return "stale"  # PID file exists but process dead

    release_lock(pid_file)
```

### 5.3 Graceful Shutdown

```
stop_agent(name):
    1. Remove PID file (signals loop to stop on next iteration)
    2. Send SIGTERM to process
    3. Wait up to 10 seconds for exit
    4. If still alive, send SIGKILL
```

---

## 6. Extension Points

### 6.1 Adding a New CLI Plugin

Create a plugin file in `plugins/` (built-in) or `.crew/cli.d/` (project-local):

```bash
#!/bin/bash
# plugins/myagent.sh

cli_myagent_check() {
  command_exists myagent
}

cli_myagent_run() {
  local prompt_file="$1"
  local working_dir="$2"
  (cd "$working_dir" && myagent --auto < "$prompt_file")
}

cli_myagent_run_prompt() {
  local prompt="$1"
  local working_dir="$2"
  (cd "$working_dir" && echo "$prompt" | myagent --auto)
}

cli_myagent_install_hint() {
  echo "Install myagent: npm install -g myagent"
}
```

Plugin discovery order (first match wins):
1. `.crew/cli.d/` or `.design/cli.d/` (project-local)
2. `~/.crew/cli.d/` (user-global)
3. `$CREW_HOME/plugins/` (built-in)

Use `type: myagent` in crew.yaml or `--agent myagent` in design mode.

### 6.2 Custom Prompts

Place custom prompts in `.design/prompts/` or `.crew/prompts/`. They will be used instead of the defaults in `~/dev/crew/prompts/`.

### 6.3 Configuration Override

Environment variables take precedence:
- `CREW_AGENT` overrides `.agent` in config
- `DEBUG=1` enables verbose logging

---

## 7. Security Considerations

- **Legacy command mode**: Raw `command` field uses `eval` for backward compatibility; prefer `type` field which uses plugin functions directly
- **Input validation**: `validate_agent_name()`, `validate_file_path()`, `validate_interval()` in lib/utils.sh
- **PID file locking**: flock-based locking with graceful fallback for systems without flock
- **Strict mode**: All lib/*.sh files use `set -euo pipefail`
- **Per-agent env vars**: `env` config field exported in subshell via `export_agent_env()`
- **Prompt injection**: User prompts are passed to AI CLIs; validate if exposing to untrusted input
- **File permissions**: PID/log files created with user's default umask
- **Process isolation**: Agents run as subprocesses with inherited permissions
- **No secrets**: Configuration files should not contain secrets; use environment variables

---

## 8. Fallback Chain Architecture

### 8.1 Multi-Level Fallback

Each agent supports an explicit fallback chain configured in `crew.yaml`. When `max_restarts` is exhausted at one level, the next level takes over:

```
Level 0 (primary)  →  exhausted  →  Level 1 (fallback[0])
Level 1            →  exhausted  →  Level 2 (fallback[1])
...                →  exhausted  →  Agent stops (.crew/run/<name>.exhausted)
```

### 8.2 Fallback Resolution (lib/config.sh)

Per-level resolution hierarchy:
- **CLI type**: `fallback[N].type` → agent `type` → `"claude"` (default)
- **Command**: `fallback[N].command` → agent `command` (for legacy `type: "command"`)
- **Max restarts**: `fallback[N].max_restarts` → `DEFAULT_MAX_RESTARTS` (5)
- **Environment**: agent-level `env` merged with `fallback[N].env` overlay

### 8.3 Supported Fallback Patterns

| Pattern | Example | Use Case |
|---------|---------|----------|
| Model degradation | opus → sonnet → 3rd party | Cost optimization, rate limit resilience |
| Cross-CLI fallback | claude → codex → gemini → local | Maximum vendor resilience |
| Script fallback | claude → `./scripts/notify.sh` | Alerting when all AI tools fail |

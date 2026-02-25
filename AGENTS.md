# crew

Multi-agent orchestration tool for AI-assisted development.

## Quick Reference

```bash
# Design Mode - Cross-review loop
design init "Your idea description"
design review
design status

# Crew Mode - Parallel agents
crew init
crew start [AGENT...]
crew stop [AGENT...]
crew status
crew monitor
crew logs <AGENT>
```

## Project Structure

```
crew/
├── crew.sh              # Parallel agent orchestration entry
├── design.sh            # Cross-review loop entry
├── install.sh           # Installation script
├── lib/
│   ├── utils.sh         # Logging, colors, helpers
│   ├── config.sh        # YAML parsing (yq/python fallback)
│   ├── orchestrator.sh  # Cross-review loop engine
│   ├── watchdog.sh      # Agent health monitoring
│   ├── agent_runner.sh  # Unified CLI abstraction
│   └── status.sh        # Status display, monitoring
├── prompts/
│   ├── crew/
│   │   ├── qa.md            # QA agent prompt
│   │   ├── dev.md           # DEV agent prompt
│   │   └── janitor.md       # JANITOR agent prompt
│   └── cross-review/
│       ├── plan_writer.md
│       └── reviewer.md
└── docs/
    ├── PRD.md
    ├── ARCHITECTURE.md
    ├── TASKS.md
    ├── SESSION_LOG.md
    └── EVAL.md
```

## Architecture Overview

### Design Mode (Cross-Review Loop)

```
┌──────────────┐    trigger     ┌──────────────┐
│ Plan Writer  │ ──────────────→│   Reviewer   │
│    Agent     │                │    Agent     │
└──────────────┘                └──────────────┘
       ↑                               │
       │ trigger (if !pass)            │ pass?
       └───────────────────────────────┘
```

Termination conditions:
- `pass`: Reviewer approves
- `stale`: No changes for 2 iterations
- `max_iter`: Maximum iterations reached

### Crew Mode (Parallel Agents)

```
┌─────────────────────────────────────────────┐
│               Watchdog Loop                  │
│  (health check interval: 30s default)        │
└─────────────────────────────────────────────┘
         │           │           │
    ┌────▼───┐  ┌────▼───┐  ┌────▼───┐
    │  QA    │  │  DEV   │  │JANITOR │
    │ Agent  │  │ Agent  │  │ Agent  │
    └────────┘  └────────┘  └────────┘
```

## Key Modules

| Module | Purpose |
|--------|---------|
| `orchestrator.sh` | Cross-review loop logic, termination detection |
| `watchdog.sh` | Start/stop agents, PID management, health checks |
| `agent_runner.sh` | CLI abstraction for claude/opencode/gemini |
| `config.sh` | YAML parsing with yq or Python fallback |
| `utils.sh` | Logging (log_info, log_ok, log_warn, log_error), helpers |
| `status.sh` | Status table display, real-time monitor |

## Coding Conventions

- **Shell**: Bash 4+, strict mode (`set -euo pipefail`)
- **Functions**: `snake_case` (e.g., `start_agent`, `cross_review_loop`)
- **Variables**: `UPPER_CASE` for constants, `lower_case` for locals
- **Logging**: Use `log_info`, `log_ok`, `log_warn`, `log_error`
- **Source**: Always use `source "$(dirname "${BASH_SOURCE[0]}")/..."` pattern

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CREW_AGENT` | `claude` | Override agent type (claude, opencode, gemini) |
| `ANTHROPIC_BASE_URL` | (none) | Override API endpoint for Claude CLI |
| `ANTHROPIC_MODEL` | (none) | Override model for Claude CLI |
| `DEBUG` | unset | Set to `1` for verbose debug output |

## Exit Codes

### design.sh
| Code | Meaning |
|------|---------|
| 0 | Review passed |
| 1 | Max iterations reached |
| 2 | Plan stale (no changes) |

### crew.sh
| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Error (missing config, invalid args) |

## Working Directories

### .design/ (Design Mode)
```
.design/
├── design.yaml     # Session config
├── idea.txt        # Initial idea
├── plan.md         # Current plan
├── review.md       # Current review
├── history/        # All iterations (plan_v1.md, review_v1.md, ...)
└── prompts/        # Custom prompts (optional)
```

### .crew/ (Crew Mode)
```
.crew/
├── crew.yaml       # Agent config
├── prompts/        # Agent prompts
├── logs/           # Agent logs (QA.log, DEV.log, ...)
└── run/            # PID files (QA.pid, DEV.pid, ...)
```

## Common Tasks

### Add a new agent type
1. Edit `lib/agent_runner.sh`
2. Add `run_<agent_name>()` function
3. Update `agent_runner()` case statement
4. Add to `check_agent()` and `list_agents()`

### Customize termination conditions
Edit `.design/design.yaml`:
```yaml
termination:
  stale_threshold: 2    # Iterations without change
```

### Debug mode
```bash
DEBUG=1 design review
DEBUG=1 crew start
```

# crew

> Adversarial Multi-Agent Orchestration Tool for AI-assisted development

> **WARNING**: This tool launches AI agents that run with **full access to your codebase and system**.
> Agents can read, create, modify, and delete files autonomously. By default, agents run with
> `--dangerously-skip-permissions`, which bypasses all safety prompts. **Review your agent prompts
> and configuration before running `crew start`.** See [SECURITY.md](SECURITY.md) for details.

## Overview

`crew` provides two distinct modes for AI agent orchestration:

| Command | Mode | Use Case |
|---------|------|----------|
| `design` | Cross-Review | Refine ideas into polished design docs |
| `crew` | Parallel Agents | Run multiple AI agents for debugging/optimization |

## Installation

```bash
git clone https://github.com/YOUR_USERNAME/crew ~/dev/crew
cd ~/dev/crew
./install.sh
```

This creates symlinks in `~/.local/bin`. If not already in PATH, add to your shell config:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Requires:
- Bash 4+
- `yq` for YAML parsing: `brew install yq`
- An AI CLI: `claude`, `codex`, `opencode`, `gemini`, or `aider`

Supported platforms:
- **macOS** (primary, actively developed)
- **Linux** (tested)
- **Windows WSL** (untested, should work)

## First-time Setup Security Checklist

Before running `crew start`, verify the following:

- [ ] **Git clean state** — commit or stash all work; agents will modify files
- [ ] **Review prompts** — read every file in `.crew/prompts/` before agents use them
- [ ] **Review `crew.yaml`** — confirm each agent's `command` and `env` fields look correct
- [ ] **No secrets in config** — API keys go in shell env (`export ANTHROPIC_API_KEY=...`), never in `crew.yaml`
- [ ] **`.gitignore` covers runtime files** — `.crew/logs/`, `.crew/run/` should be ignored
- [ ] **Understand `--dangerously-skip-permissions`** — agents bypass all safety prompts and can read/write/delete any file

> **Tip**: Run `crew validate` to check config syntax before starting agents.

## `design` - Cross-Review Mode

Turn ideas into refined design documents through automated Writer ⇄ Reviewer loops.

```bash
# Initialize with your idea
design init "A CLI tool for managing container deployments"

# Start cross-review loop
design review

# Check status
design status
```

### How it works

```
┌──────────────┐    trigger     ┌──────────────┐
│ Plan Writer  │ ──────────────→│   Reviewer   │
│    Agent     │                │    Agent     │
└──────────────┘                └──────────────┘
       ↑                               │
       │ trigger (if !pass)            │ pass?
       └───────────────────────────────┘
```

### Termination Conditions

- **pass**: Reviewer approves the plan
- **stale**: Plan unchanged for 2 iterations
- **conflict**: Same issues repeat 3+ times

### Files

```
.design/
├── design.yaml     # Config
├── idea.txt        # Your initial idea
├── plan.md         # Current plan
├── review.md       # Current review
└── history/        # All iterations
```

## `crew` - Parallel Agents Mode

Run multiple AI agents in parallel for continuous codebase improvement.

```bash
# Initialize in your project
crew init

# Start all agents
crew start

# Start specific agents
crew start QA DEV JANITOR

# Monitor real-time
crew monitor

# View logs
crew logs QA

> **Tip**: For long-running tasks (like full test suites), log output may appear "stuck" due to buffering. The log will update in a large chunk once the command completes.

# Stop all
crew stop
```

### Configuration

Edit `.crew/crew.yaml`:

```yaml
project: my-project
check_interval: 30

agents:
  - name: QA
    icon: 🔴
    type: claude
    prompt: prompts/qa.txt
    interval: 10
    timeout: 600

  - name: DEV
    icon: 🔵
    type: claude
    prompt: prompts/dev.txt

  - name: JANITOR
    icon: 🟢
    type: claude
    prompt: prompts/janitor.txt
    interval: 10
    timeout: 600

> **Note**: Changes to `crew.yaml` (including `interval` and `env` variables) require a restart of the affected agents to take effect. Run `crew restart [AGENT]` to apply changes.
```

### Files

```
.crew/
├── crew.yaml       # Config
├── prompts/        # Agent prompts
├── logs/           # Agent logs
└── run/            # PID files
```

## CLI Plugins

crew uses a plugin system for CLI abstraction. Each supported CLI has a plugin that handles prompt delivery and execution.

### Built-in Plugins

| Plugin | CLI | Install |
|--------|-----|---------|
| `claude` | Claude Code | `npm install -g @anthropic-ai/claude-code` |
| `codex` | OpenAI Codex | `npm install -g @openai/codex` |
| `opencode` | OpenCode | `go install github.com/opencode-ai/opencode@latest` |
| `gemini` | Google Gemini | `pip install google-gemini-cli` |
| `aider` | Aider | `pip install aider-chat` |

List installed plugins:

```bash
crew plugins
```

### Custom Plugins

Create a `.sh` file in `.crew/cli.d/` (project-local) or `~/.crew/cli.d/` (global):

```bash
#!/bin/bash
# .crew/cli.d/myagent.sh

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
```

Then use `type: myagent` in `crew.yaml`.

## 3rd Party / Self-Hosted Models

Use the `env` field in `.crew/crew.yaml` to configure per-agent environment variables for different providers:

```yaml
agents:
  - name: DEV
    type: claude
    prompt: prompts/dev.md
    env:
      ANTHROPIC_BASE_URL: https://openrouter.ai/api/v1
      ANTHROPIC_MODEL: anthropic/claude-sonnet-4-20250514
```

### Common Providers

| Provider | `ANTHROPIC_BASE_URL` |
|----------|---------------------|
| Anthropic (default) | `https://api.anthropic.com` |
| OpenRouter | `https://openrouter.ai/api/v1` |
| Self-hosted | `http://localhost:8080/v1` |

### API Key Handling

> **WARNING**: Never put API keys in `crew.yaml` if it's committed to git.

Set `ANTHROPIC_API_KEY` in your shell environment instead:

```bash
export ANTHROPIC_API_KEY="sk-..."
```

## Model Fallback

When an agent fails repeatedly (reaching `max_restarts`), it can automatically fall back to alternative models or providers. Configure a `fallback` chain per-agent in `.crew/crew.yaml`.

### Fallback Order

```
Primary (env)  →  fallback[0]  →  fallback[1]  →  ... → exhausted (stop)
   opus             sonnet          openrouter
```

### Configuration

```yaml
agents:
  - name: DEV
    type: claude
    prompt: prompts/dev.md
    max_restarts: 5
    env:
      ANTHROPIC_MODEL: claude-opus-4-20250514

    fallback:
      - label: sonnet
        max_restarts: 3
        env:
          ANTHROPIC_MODEL: claude-sonnet-4-20250514

      - label: codex-fallback
        type: codex
        max_restarts: 3
```

### Behavior

- Each level retries up to its `max_restarts` (default: 5) with exponential backoff
- On success at any level, the agent **stays at that level** (does not revert)
- After all levels are exhausted, the agent stops and will not be auto-restarted
- Use `crew restart AGENT` to reset the fallback chain and start from primary
- `crew status` shows the current active fallback level

## Environment Variables

| Variable | Description |
|----------|-------------|
| `CREW_AGENT` | Override default agent type (any installed plugin) |
| `ANTHROPIC_BASE_URL` | Override API endpoint for Claude CLI |
| `ANTHROPIC_MODEL` | Override model for Claude CLI |
| `ANTHROPIC_API_KEY` | API key for Claude CLI (set in shell, not config) |
| `OPENAI_API_KEY` | API key for Codex CLI (set in shell, not config) |
| `GEMINI_API_KEY` | API key for Gemini CLI (set in shell, not config) |
| `DEBUG` | Set to `1` for verbose output |

## Examples

### Design a new feature

```bash
cd ~/dev/my-app
design init "Add real-time collaboration with WebSockets"
design review --max-iter 3
# Result: .design/plan.md with refined design
```

### Run parallel debugging agents

```bash
cd ~/dev/my-app
crew init
# Edit .crew/crew.yaml and prompts
crew start QA DEV JANITOR
crew monitor
# Agents run continuously, finding and fixing issues
crew stop
```

## Upgrading

If you already have `crew` set up on another project:

### 1. Update crew itself

```bash
cd ~/dev/crew    # or wherever you cloned crew
git pull
./install.sh     # re-creates symlinks, safe to re-run
```

### 2. Clean up old runtime files

In each project that uses crew:

```bash
crew stop                        # stop any running agents
rm -rf .crew/run/                # remove old PID files
rm -rf .crew/logs/               # remove old logs (optional)
```

### 3. Update `.crew/crew.yaml`

**Breaking change**: Commands with pipes or shell operators (e.g. `cmd1 | cmd2`)
no longer work in the `command` field. Use a wrapper script instead.

Before:
```yaml
command: ANTHROPIC_MODEL=my-model claude --dangerously-skip-permissions
```

After:
```yaml
command: claude --dangerously-skip-permissions
env:
  ANTHROPIC_MODEL: my-model
```

### Migration to `type` field (v0.2.0)

The `command` field is now optional. Use the `type` field instead:

Before:
```yaml
command: claude --dangerously-skip-permissions
```

After:
```yaml
type: claude
```

The `command` field still works for backward compatibility and custom CLIs.

### 4. Verify

```bash
crew validate    # check config syntax
crew start       # test agents start correctly
crew status      # confirm all running
crew stop        # clean shutdown
```

## License

MIT

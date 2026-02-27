# Contributing to crew

Thank you for your interest in contributing to crew! This guide will help you get started.

## Prerequisites

- **Bash 4+** (macOS ships with Bash 3; install via `brew install bash`)
- **yq** for YAML parsing: `brew install yq`
- An AI CLI tool: `claude`, `opencode`, or `gemini`
- **shellcheck** for linting: `brew install shellcheck`

## Getting Started

1. Fork and clone the repository:

```bash
git clone https://github.com/YOUR_USERNAME/crew.git
cd crew
```

2. Install locally:

```bash
./install.sh
```

3. Run a quick smoke test:

```bash
crew init
crew status
crew stop
```

## Development Workflow

### Branch Naming

```
feature/  - New features
fix/      - Bug fixes
refactor/ - Code refactoring
docs/     - Documentation only
```

### Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: add new agent type support
fix: resolve PID race condition on stop
refactor: extract validation to utils
docs: update configuration examples
```

Rules:
- Imperative mood ("add" not "added")
- No capitalization of first letter
- No period at end
- Under 72 characters

### Code Style

- **Shell**: Bash 4+, strict mode (`set -euo pipefail`)
- **Functions**: `snake_case`
- **Constants**: `UPPER_CASE`
- **Local variables**: `lower_case`
- **Logging**: Use `log_info`, `log_ok`, `log_warn`, `log_error` from `lib/utils.sh`
- **Source paths**: Use `source "$(dirname "${BASH_SOURCE[0]}")/..."` pattern

### Command Safety Rules

- **No `eval`**: Never use `eval` to execute commands from config or user input. Use array-based execution instead.
- **Validate inputs**: All user-supplied values (agent names, file paths, intervals) must pass through validation functions in `lib/utils.sh`.
- **No inline secrets**: Never hardcode API keys or credentials. Use environment variables.
- **Subshell isolation**: Commands that change directory must run in subshells `(cd dir && cmd)` to avoid leaking state.

### Linting

Run shellcheck on all shell files before submitting:

```bash
shellcheck crew.sh design.sh lib/*.sh
```

## Pull Request Checklist

Before submitting a PR, ensure:

- [ ] Code follows the style guide above
- [ ] `shellcheck` passes with no warnings
- [ ] New functions include input validation where appropriate
- [ ] No `eval` or unsafe command execution introduced
- [ ] Commit messages follow conventional format
- [ ] `crew init && crew status && crew stop` works without errors
- [ ] Documentation updated if adding new features or config options
- [ ] Magic numbers extracted to named constants

## Architecture Overview

See [CLAUDE.md](CLAUDE.md) for the full project structure and module descriptions.

Key modules:
- `lib/utils.sh` - Logging, validation, helpers
- `lib/config.sh` - YAML parsing (yq/python fallback)
- `lib/watchdog.sh` - Agent lifecycle, PID management, health monitoring
- `lib/orchestrator.sh` - Design-review loop engine
- `lib/agent_runner.sh` - CLI abstraction for different AI agents
- `lib/status.sh` - Status display and monitoring

## Reporting Issues

- Use GitHub Issues for bugs and feature requests
- Include your OS version, Bash version (`bash --version`), and relevant config
- For security vulnerabilities, see [SECURITY.md](SECURITY.md)

# crew - Product Requirements Document

**Version**: 0.2.1
**Status**: Implemented
**Last Updated**: 2026-02-26

---

## 1. Overview

### 1.1 Vision

crew is a multi-agent orchestration tool that enables developers to leverage multiple AI assistants working in concert. It provides two complementary modes: iterative design refinement through design-review loops, and parallel agent execution for continuous codebase improvement.

### 1.2 Problem Statement

Modern AI coding assistants are powerful but work in isolation. Developers face challenges:
- **Single perspective**: One AI can miss issues another would catch
- **Manual iteration**: Refining designs requires repeated manual prompting
- **No collaboration**: AI agents cannot currently review each other's work
- **Supervision overhead**: Running multiple agents requires constant monitoring

crew solves these by automating agent coordination and enabling AI-to-AI feedback loops.

### 1.3 Goals & Success Metrics

| Goal | Metric | Target |
|------|--------|--------|
| Reduce design iteration time | Manual interventions per design | < 3 |
| Improve design quality | Issues found by Reviewer | > 80% addressed |
| Enable parallel workflows | Agents running concurrently | 3+ |
| Minimize supervision | Health check failures detected | 100% |

---

## 2. Users & Personas

### 2.1 Target Users

- **Software developers** using AI coding assistants
- **Tech leads** wanting consistent design documentation
- **Teams** needing parallel AI-assisted debugging/optimization

### 2.2 User Persona: Alex (Full-Stack Developer)

- **Background**: Mid-level developer using Claude/GPT for coding tasks
- **Goals**: Ship features faster with better designs, automate repetitive prompting
- **Pain Points**: Spends time re-prompting AI for design refinement, misses edge cases

### 2.3 User Persona: Jordan (Tech Lead)

- **Background**: Senior engineer responsible for architecture decisions
- **Goals**: Ensure consistent, thorough design docs across team
- **Pain Points**: Design docs vary in quality, no automated review process

---

## 3. Use Cases

### UC-01: Design Document Refinement

**Actor**: Developer (Alex)
**Trigger**: New feature needs a design document
**Flow**:
1. Developer initializes design session with an idea
2. Plan Writer agent generates initial design doc
3. Reviewer agent identifies gaps and issues
4. Plan Writer addresses feedback and revises
5. Loop continues until Reviewer passes or termination condition hit
**Success**: Polished design document in `.design/plan.md`

### UC-02: Parallel Agent Debugging

**Actor**: Developer (Alex)
**Trigger**: Codebase needs continuous improvement
**Flow**:
1. Developer initializes crew with agent configuration
2. Starts QA, DEV, and JANITOR agents in parallel
3. Watchdog monitors agent health
4. Agents work independently on assigned tasks
5. Developer monitors via dashboard
**Success**: Continuous codebase improvements without constant supervision

### UC-03: Health Monitoring & Recovery

**Actor**: System (Watchdog)
**Trigger**: Agent process crashes or becomes unresponsive
**Flow**:
1. Watchdog detects stale PID or missing process
2. Logs warning
3. Automatically restarts affected agent
4. Continues monitoring
**Success**: Agent automatically recovered without user intervention

---

## 4. Feature Scope

### 4.1 Implemented (v0.1.0)

- [x] **Design Mode**: Design-review loop (`design init`, `design review`, `design status`)
- [x] **Crew Mode**: Parallel agent orchestration (`crew init`, `crew start`, `crew stop`)
- [x] **Multi-agent support**: claude, codex, opencode, gemini, aider CLI integration
- [x] **CLI plugin system**: Extensible type-based CLI registration with plugin discovery
- [x] **Health monitoring**: Watchdog loop with configurable intervals
- [x] **Status display**: Real-time dashboard (`crew monitor`)
- [x] **Log management**: Per-agent logging (`crew logs`)
- [x] **Termination detection**: Stale/conflict/pass conditions
- [x] **YAML configuration**: Project-level config files
- [x] **History tracking**: Iteration history in `.design/history/`
- [x] **Input validation**: Agent names, file paths, intervals (`validate_agent_name`, `validate_file_path`, `validate_interval`)
- [x] **Safe command execution**: No eval, array-based command execution
- [x] **Per-agent environment variables**: `env` config field with `export_agent_env()`
- [x] **PID file locking**: flock-based with graceful fallback
- [x] **Log rotation**: Size-based rotation at 10MB threshold
- [x] **Strict mode**: `set -euo pipefail` in all library files
- [x] **Trap handlers**: Graceful cleanup on EXIT/INT/TERM signals
- [x] **Exponential backoff**: Max restarts (5) with backoff capped at 300s
- [x] **Multi-level fallback chains**: Model degradation, cross-CLI fallback, script fallback
- [x] **Codex 3rd party models**: `CODEX_*` env vars for custom providers (DashScope, local LLMs)
- [x] **Design init from file**: `design init <filename>` reads idea from file
- [x] **Configurable history saving**: Toggle history via `history.enabled` in design.yaml

### 4.2 Planned

- [ ] Agent-to-agent communication (shared context)
- [ ] Result aggregation and conflict resolution
- [ ] Dry-run mode for validation
- [ ] Web-based dashboard

### 4.3 Out of Scope

- **GUI application**: CLI-only by design
- **Cloud deployment**: Local execution focus
- **Agent creation**: Uses existing AI CLIs

---

## 5. Technical Requirements

### 5.1 Dependencies

| Dependency | Purpose | Required |
|------------|---------|----------|
| Bash 4+ | Shell runtime | Yes |
| yq or Python 3 | YAML parsing | Yes (one of) |
| claude/codex/opencode/gemini/aider | AI CLI | Yes (one of) |

### 5.2 Platform Support

- macOS (primary)
- Linux (tested)
- WSL (untested but should work)

### 5.3 Installation

```bash
git clone https://github.com/garnetlyx/crew ~/dev/crew
cd ~/dev/crew
./install.sh
```

---

## 6. Risks & Mitigations

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Infinite loop (Writer/Reviewer) | High | Medium | Stale/conflict detection, max iteration limit |
| Agent CLI changes | Medium | Medium | Abstraction layer in agent_runner.sh |
| YAML parsing failures | Medium | Low | Fallback to Python when yq unavailable |
| Resource exhaustion | Medium | Low | Configurable timeouts, watchdog monitoring |
| Concurrent file conflicts | Medium | Low | Agents work in separate domains by design |

---

## 7. Open Questions

- [ ] Should agents share a common context file for coordination?
- [ ] What metrics should be collected for agent performance?
- [ ] How to handle agent output aggregation when tasks overlap?

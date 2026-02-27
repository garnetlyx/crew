# Security Policy

## Disclaimer

This software is provided as-is under the MIT License. AI agents launched by `crew` operate with
full access to your filesystem and can create, modify, or delete files without confirmation. The
authors are not responsible for any damage, data loss, or unintended changes caused by agent
actions. Use in trusted environments only and always review agent prompts and configuration before
running.

## Trust Boundaries

`crew` orchestrates AI CLI agents that execute with full access to your codebase and system. Understanding the trust boundaries is critical:

### What crew trusts

- **crew.yaml config**: Defines agent commands and environment variables. Anyone who can edit this file controls what processes crew launches. Treat it like a shell script.
- **Prompt files**: Fed directly to AI agents. Prompt injection in these files can cause agents to execute arbitrary actions via their CLI tools.
- **AI agent output**: Agents may create, modify, or delete files. Their actions are only bounded by the permissions of the CLI tool they run through.

### What crew does NOT trust

- **User-supplied agent names**: Validated to `[A-Za-z0-9_-]` (max 32 chars) to prevent injection into file paths and yq queries.
- **File paths**: Validated to reject `..` traversal, absolute paths, and null bytes.
- **Intervals**: Validated as positive integers with upper bounds.

## Command Execution

As of v0.1.0, `crew` does **not** use `eval` to execute agent commands. Commands from `crew.yaml` are parsed into arrays and executed directly, which prevents shell injection through config values.

If you need complex commands (pipes, redirects, shell operators), use a wrapper script instead of inline shell in the config.

## API Key Handling

**Never put API keys in `crew.yaml`** if the file is committed to version control.

Set API keys in your shell environment instead:

```bash
export ANTHROPIC_API_KEY="sk-..."
```

The `env` field in `crew.yaml` is intended for non-secret configuration like `ANTHROPIC_BASE_URL` and `ANTHROPIC_MODEL`. If you must use `env` for keys in a local-only config, ensure `.crew/` is in your `.gitignore`.

## Prompt Injection Risks

AI agents are susceptible to prompt injection. Be aware that:

1. Any file an agent reads could contain adversarial instructions
2. Agent prompts in `.crew/prompts/` or `.design/prompts/` define agent behavior
3. In design-review mode, agents read each other's output, creating a potential injection chain

Mitigations:
- Review agent prompts before use
- Monitor agent logs (`crew logs <AGENT>`)
- Use `--dangerously-skip-permissions` only when you understand the implications
- Run agents in isolated environments when possible

## PID File Security

PID files in `.crew/run/` use flock-based locking to prevent race conditions. On systems without `flock`, crew falls back to best-effort (unlocked) operation. This is acceptable for a local development tool but should not be relied upon in multi-user environments.

## Reporting Vulnerabilities

If you discover a security vulnerability, please report it responsibly:

1. **Do NOT open a public issue**
2. Email the maintainers or use GitHub's private vulnerability reporting
3. Include steps to reproduce and potential impact
4. Allow reasonable time for a fix before disclosure

## Best Practices

- Run `crew` only in project directories you trust
- Review `.crew/crew.yaml` before running `crew start`
- Keep AI CLI tools updated to their latest versions
- Monitor agent logs for unexpected behavior
- Use `crew stop` to cleanly shut down all agents
- Add `.crew/` and `.design/` to `.gitignore` if they contain sensitive config

#!/bin/bash
# design - Design-review loop for design doc refinement
#
# Usage:
#   design init <idea>     Initialize new design session
#   design review          Start/continue design-review loop
#   design status          Show current review status
#   design reset           Reset to initial state

set -euo pipefail

# Get script directory (resolve symlinks for install via ~/.local/bin)
SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
  DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/orchestrator.sh"

VERSION=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "unknown")

usage() {
  cat << EOF
${BOLD}design${NC} - Design-review loop for design doc refinement

${BOLD}USAGE${NC}
  design <command> [options]

${BOLD}COMMANDS${NC}
  init <idea|file> Initialize new design session with idea or file
  review           Start or continue design-review loop
  status           Show current review status
  reset            Reset session (keeps idea.txt)
  help             Show this help message

${BOLD}OPTIONS${NC}
  --max-iter N     Maximum iterations (default: 5)
  --agent TYPE     Agent type: claude, codex, opencode, gemini, aider
                   (or set CREW_AGENT environment variable)
  --dry-run        Show what would happen without executing agents

${BOLD}EXAMPLES${NC}
  # Start a new design session with inline text
  design init "A CLI tool for managing multiple AI agents"

  # Start from a file
  design init brainstorm.md

  # Run design-review loop
  design review

  # Use a specific agent and limit iterations
  design --agent gemini --max-iter 3 review

  # Preview without executing agents
  design --dry-run review

  # Check status
  design status

${BOLD}EXIT CODES${NC}
  0  Review passed
  1  Max iterations reached
  2  Plan became stale (no changes)
  3  Recurring conflicts detected

${BOLD}FILES${NC}
  .design/
  ├── design.yaml     Config file
  ├── idea.txt        Your initial idea
  ├── plan.md         Current plan (Writer output)
  ├── review.md       Current review (Reviewer output)
  ├── history/        All iterations
  └── prompts/        Custom prompts (optional)

${BOLD}VERSION${NC}
  $VERSION
EOF
}

# Global options set during argument parsing
MAX_ITER_OVERRIDE=""
DRY_RUN=false

# Main command dispatch
main() {
  # BUG-QA-103: Resolve symlinks in project directory to prevent symlink-based attacks
  if [[ -L "$PWD" ]] || [[ "$(cd -P . && pwd)" != "$PWD" ]]; then
    cd -P .
  fi

  # Parse global options before command dispatch
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent)
        shift
        [[ $# -eq 0 ]] && { log_error "--agent requires a value"; exit 1; }
        export CREW_AGENT="$1"
        shift
        ;;
      --max-iter)
        shift
        [[ $# -eq 0 ]] && { log_error "--max-iter requires a value"; exit 1; }
        # validate: grep -qE '^[0-9]+$' and -lt 1|max-iter must be a positive integer >= 1
        if ! printf '%s' "$1" | grep -qE '^[0-9]+$' || [[ "$1" -lt 1 ]]; then
          log_error "--max-iter must be a positive integer >= 1, got: $1"
          exit 1
        fi
        MAX_ITER_OVERRIDE="$1"
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      --version|-v)
        echo "design $VERSION"
        exit 0
        ;;
      *)
        break
        ;;
    esac
  done

  local cmd="${1:-help}"
  shift 2>/dev/null || true

  case "$cmd" in
    init)
      design_init "$@"
      ;;
    review)
      cross_review_loop "$MAX_ITER_OVERRIDE" "$DRY_RUN"
      ;;
    status)
      design_status
      ;;
    reset)
      design_reset
      ;;
    help|--help|-h)
      usage
      ;;
    version|--version|-v)
      echo "design $VERSION"
      ;;
    *)
      log_error "Unknown command: $cmd"
      echo ""
      usage
      exit 1
      ;;
  esac
}

# Only run main when executed directly, not when sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

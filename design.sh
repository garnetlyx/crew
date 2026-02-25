#!/bin/bash
# design - Cross-review loop for design doc refinement
#
# Usage:
#   design init <idea>     Initialize new design session
#   design review          Start/continue cross-review loop
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

VERSION="0.2.0"

usage() {
  cat << EOF
${BOLD}design${NC} - Cross-review loop for design doc refinement

${BOLD}USAGE${NC}
  design <command> [options]

${BOLD}COMMANDS${NC}
  init <idea>      Initialize new design session with your idea
  review           Start or continue cross-review loop
  status           Show current review status
  reset            Reset session (keeps idea.txt)
  help             Show this help message

${BOLD}OPTIONS${NC}
  --max-iter N     Maximum iterations (default: 5)
  --agent TYPE     Agent type: claude, codex, opencode, gemini, aider
                   (or set CREW_AGENT environment variable)

${BOLD}EXAMPLES${NC}
  # Start a new design session
  design init "A CLI tool for managing multiple AI agents"

  # Run cross-review loop
  design review

  # Check status
  design status

${BOLD}EXIT CODES${NC}
  0  Review passed
  1  Max iterations reached
  2  Plan became stale (no changes)

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

# Parse global options
AGENT_OVERRIDE=""
MAX_ITER_OVERRIDE=""

parse_options() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent)
        shift
        export CREW_AGENT="$1"
        ;;
      --max-iter)
        shift
        MAX_ITER_OVERRIDE="$1"
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
        # Not an option, break
        break
        ;;
    esac
    shift
  done
  
  # Return remaining args
  echo "$@"
}

# Main command dispatch
main() {
  local cmd="${1:-help}"
  shift 2>/dev/null || true
  
  case "$cmd" in
    init)
      design_init "$@"
      ;;
    review)
      cross_review_loop
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

main "$@"

#!/bin/bash
# crew/lib/utils.sh - Common utility functions
set -euo pipefail

# Colors (ANSI-C quoting for correct display in heredocs and printf)
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
PURPLE=$'\033[0;35m'
CYAN=$'\033[0;36m'
NC=$'\033[0m' # No Color
BOLD=$'\033[1m'

# Logging functions
log_info()  { echo -e "${BLUE}ℹ${NC} $1"; }
log_ok()    { echo -e "${GREEN}✓${NC} $1"; }
log_warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1"; }
log_debug() { if [[ "${DEBUG:-}" == "1" ]]; then echo -e "${PURPLE}⚙${NC} $1"; fi; }

# Timestamp
timestamp() { date "+%Y-%m-%d %H:%M:%S"; }
date_only() { date "+%Y-%m-%d"; }

# Check if command exists
command_exists() {
  command -v "$1" &> /dev/null
}

# Get script directory
get_script_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

# Get crew home directory
get_crew_home() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  echo "$script_dir"
}

# Ensure directory exists
ensure_dir() {
  mkdir -p "$1"
}

# Check if file is newer than another
is_newer() {
  [[ "$1" -nt "$2" ]]
}

# Simple hash for change detection
file_hash() {
  if [[ ! -f "$1" ]]; then
    echo ""
    return 0
  fi

  if command_exists md5; then
    md5 -q "$1" 2>/dev/null || true
  elif command_exists md5sum; then
    md5sum "$1" 2>/dev/null | cut -d' ' -f1 || true
  else
    # Fallback: use file size + mtime
    stat -f "%z%m" "$1" 2>/dev/null || stat -c "%s%Y" "$1" 2>/dev/null || true
  fi
}

# Print a horizontal separator
separator() {
  local char="${1:--}"
  local width="${2:-60}"
  local str
  printf -v str '%*s' "$width" ''
  echo "${str// /$char}"
}

# Print a header
header() {
  echo ""
  echo -e "${BOLD}${CYAN}$1${NC}"
  separator "─" ${#1}
}

# Confirm action (returns 0 for yes, 1 for no)
confirm() {
  local prompt="${1:-Are you sure?}"
  read -r -p "$prompt [y/N] " response
  [[ "$response" =~ ^[Yy]$ ]]
}

# ── Input Validation ──────────────────────────────────────

# Validate agent name: [A-Za-z0-9_-], max 32 chars
validate_agent_name() {
  local name="$1"
  if [[ -z "$name" ]]; then
    log_error "Agent name cannot be empty"
    return 1
  fi
  if [[ ${#name} -gt 32 ]]; then
    log_error "Agent name too long (max 32 chars): $name"
    return 1
  fi
  if [[ ! "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
    log_error "Invalid agent name (only [A-Za-z0-9_-] allowed): $name"
    return 1
  fi
}

# Validate file path: reject .., absolute paths, null bytes
validate_file_path() {
  local path="$1"
  if [[ -z "$path" ]]; then
    log_error "File path cannot be empty"
    return 1
  fi
  if [[ "$path" == /* ]]; then
    log_error "Absolute paths not allowed: $path"
    return 1
  fi
  if [[ "$path" == *".."* ]]; then
    log_error "Path traversal not allowed: $path"
    return 1
  fi
  # Bash variables can't hold actual null bytes, but reject encoded representations
  if printf '%s' "$path" | grep -qE '\\x00|\\0|%00'; then
    log_error "Null bytes not allowed in path: $path"
    return 1
  fi
  # Reject backslashes and non-ASCII bytes (blocks Unicode homoglyph bypasses
  # like U+2024, U+FF0E and encoded escape sequences like \u2024)
  if [[ "$path" == *\\* ]]; then
    log_error "Backslashes not allowed in path: $path"
    return 1
  fi
  if printf '%s' "$path" | LC_ALL=C grep -q '[^[:print:]]'; then
    log_error "Non-ASCII characters not allowed in path: $path"
    return 1
  fi
}

# Validate interval: positive integer, max 86400 (24h)
validate_interval() {
  local value="$1"
  local max="${2:-86400}"
  if [[ -z "$value" ]]; then
    log_error "Interval cannot be empty"
    return 1
  fi
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    log_error "Interval must be a positive integer: $value"
    return 1
  fi
  if [[ "$value" -le 0 ]]; then
    log_error "Interval must be greater than 0: $value"
    return 1
  fi
  if [[ "$value" -gt "$max" ]]; then
    log_error "Interval too large (max $max): $value"
    return 1
  fi
}

# Wait with spinner
wait_with_spinner() {
  local pid=$1
  local message="${2:-Processing...}"
  local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0

  while kill -0 "$pid" 2>/dev/null; do
    printf "\r${CYAN}%s${NC} %s" "${spin:i++%${#spin}:1}" "$message"
    sleep 0.1
  done
  printf "\r"
}



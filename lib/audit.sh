#!/bin/bash
# crew/lib/audit.sh - Audit mode runtime: state management, row claiming,
#                     checkpointing, and completion gates.
#
# All JSON state lives in <crew_dir>/state/audit-results.json.
# Writes are protected by a directory lock: <crew_dir>/state/.audit.lock
# (mkdir is atomic on all POSIX systems; no flock dependency).
#
# Row state machine:
#   pending → claimed → audited → reviewed
#                ↓          ↓
#             backoff     backoff
#
# Source this file from crew.sh; do not execute it directly.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

# ── Constants ────────────────────────────────────────────────────────────────
AUDIT_LOCK_TIMEOUT=5          # seconds to wait for state lock
AUDIT_DEFAULT_BACKOFF_MIN=10  # default backoff window in minutes
AUDIT_CHECKPOINT_DIR="checkpoints"

# ── Mode Detection ────────────────────────────────────────────────────────────

# Returns 0 if config_file contains an audit: section, 1 otherwise.
# Usage: is_audit_mode <config_file>
is_audit_mode() {
  local config_file="$1"
  [[ -f "$config_file" ]] || return 1

  local val
  val=$(config_get ".audit" "" "$config_file" 2>/dev/null)
  [[ -n "$val" && "$val" != "null" ]]
}

# ── Config Accessors ─────────────────────────────────────────────────────────

# Get inventory path from config (relative to project root).
# Default: .crew/state/audit-results.json
# Usage: audit_inventory_path <config_file>
audit_inventory_path() {
  local config_file="$1"
  local val
  val=$(config_get ".audit.inventory" "" "$config_file" 2>/dev/null)
  if [[ -z "$val" || "$val" == "null" ]]; then
    echo ".crew/state/audit-results.json"
  else
    echo "$val"
  fi
}

# Get completion_command from config (empty string = use built-in check).
# Usage: audit_completion_command <config_file>
audit_completion_command() {
  local config_file="$1"
  local val
  val=$(config_get ".audit.completion_command" "" "$config_file" 2>/dev/null)
  [[ "$val" == "null" ]] && val=""
  echo "$val"
}

# Get report_command from config (empty string = use built-in renderer).
# Usage: audit_report_command <config_file>
audit_report_command() {
  local config_file="$1"
  local val
  val=$(config_get ".audit.report_command" "" "$config_file" 2>/dev/null)
  [[ "$val" == "null" ]] && val=""
  echo "$val"
}

# Get checkpoint_every from config (default: 10).
# Usage: audit_checkpoint_every <config_file>
audit_checkpoint_every() {
  local config_file="$1"
  local val
  val=$(config_get ".audit.checkpoint_every" "10" "$config_file" 2>/dev/null)
  [[ -z "$val" || "$val" == "null" ]] && val=10
  echo "$val"
}

# ── Lock Helpers ─────────────────────────────────────────────────────────────

# Acquire audit state lock (blocking, up to AUDIT_LOCK_TIMEOUT seconds).
# Usage: _audit_acquire_lock <state_dir>
_audit_acquire_lock() {
  local state_dir="$1"
  local lock_dir="$state_dir/.audit.lock"
  local waited=0

  while ! mkdir "$lock_dir" 2>/dev/null; do
    waited=$((waited + 1))
    if [[ "$waited" -ge "$AUDIT_LOCK_TIMEOUT" ]]; then
      log_error "Could not acquire audit state lock after ${AUDIT_LOCK_TIMEOUT}s: $lock_dir"
      return 1
    fi
    sleep 1
  done
  return 0
}

# Release audit state lock.
# Usage: _audit_release_lock <state_dir>
_audit_release_lock() {
  local state_dir="$1"
  rmdir "$state_dir/.audit.lock" 2>/dev/null || true
}

# ── Atomic JSON Write ─────────────────────────────────────────────────────────

# Write JSON array to inventory atomically (tmp file + mv).
# Usage: _audit_write_json <inventory_path> <json_content>
_audit_write_json() {
  local inventory_path="$1"
  local json_content="$2"
  local tmp_file="${inventory_path}.tmp.$$"

  # Write to temp file with restrictive perms
  (umask 077; printf '%s\n' "$json_content" > "$tmp_file")
  mv "$tmp_file" "$inventory_path"
}

# ── State Initialization ─────────────────────────────────────────────────────

# Initialize audit state directory and inventory file.
# Creates state/, output/, checkpoints/ directories and an empty inventory
# if not already present.
# Usage: audit_init_state <crew_dir> [inventory_path]
audit_init_state() {
  local crew_dir="${1:-.crew}"
  local inventory_path="${2:-$crew_dir/state/audit-results.json}"

  ensure_dir "$crew_dir/state"
  ensure_dir "$crew_dir/state/$AUDIT_CHECKPOINT_DIR"
  ensure_dir "$crew_dir/output"
  ensure_dir "$crew_dir/output/logs"

  # Create empty inventory if not present
  if [[ ! -f "$inventory_path" ]]; then
    _audit_write_json "$inventory_path" "[]"
    log_ok "Created empty inventory: $inventory_path"
  fi

  # Create manifest
  local manifest_file="$crew_dir/state/manifest.json"
  if [[ ! -f "$manifest_file" ]]; then
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%MZ")
    local manifest
    manifest=$(python3 -c "
import json, sys
print(json.dumps({
    'created_at': sys.argv[1],
    'inventory': sys.argv[2],
    'checkpoints': [],
    'version': '1'
}, indent=2))
" "$now" "$inventory_path" 2>/dev/null) || manifest="{}"
    (umask 077; printf '%s\n' "$manifest" > "$manifest_file")
    log_ok "Created manifest: $manifest_file"
  fi
}

# ── Row Counters ─────────────────────────────────────────────────────────────

# Count rows by status from the inventory JSON.
# Outputs: pending claimed audited reviewed skipped backoff (space-separated)
# Usage: audit_count_rows <inventory_path>
audit_count_rows() {
  local inventory_path="$1"

  if [[ ! -f "$inventory_path" ]]; then
    echo "0 0 0 0 0 0"
    return 0
  fi

  python3 - "$inventory_path" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    rows = json.load(f)
pending = claimed = audited = reviewed = skipped = backoff = 0
for r in rows:
    s = r.get("status", "pending")
    if   s == "pending":  pending  += 1
    elif s == "claimed":  claimed  += 1
    elif s == "audited":  audited  += 1
    elif s == "reviewed": reviewed += 1
    elif s == "skipped":  skipped  += 1
    elif s == "backoff":  backoff  += 1
    else:                 pending  += 1  # unknown = treat as pending
print(pending, claimed, audited, reviewed, skipped, backoff)
PYEOF
}

# ── Claim / Release ───────────────────────────────────────────────────────────

# Claim the next available row for a worker.
# Prints the claimed row ID on success, empty string if no row available.
# Usage: audit_claim_row <inventory_path> <worker_name>
audit_claim_row() {
  local inventory_path="$1"
  local worker_name="$2"
  local state_dir
  state_dir="$(dirname "$inventory_path")"

  _audit_acquire_lock "$state_dir" || return 1

  local result
  result=$(python3 - "$inventory_path" "$worker_name" <<'PYEOF'
import json, sys
from datetime import datetime, timezone

path   = sys.argv[1]
worker = sys.argv[2]
now    = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

with open(path) as f:
    rows = json.load(f)

now_ts = datetime.now(timezone.utc)

for row in rows:
    s = row.get("status", "pending")
    if s != "pending":
        continue
    # Check backoff
    bu = row.get("backoff_until", "")
    if bu:
        try:
            bu_dt = datetime.fromisoformat(bu.replace("Z", "+00:00"))
            if bu_dt > now_ts:
                continue  # still in backoff window
        except (ValueError, TypeError):
            pass  # invalid backoff_until — treat as expired

    # Claim it
    row["status"]     = "claimed"
    row["claimed_by"] = worker
    row["claimed_at"] = now

    with open(path + ".tmp." + str(id(row)), "w") as f:
        json.dump(rows, f, indent=2)
    import os
    os.rename(path + ".tmp." + str(id(row)), path)

    print(row.get("id", ""))
    sys.exit(0)

# No claimable row
print("")
sys.exit(0)
PYEOF
  )

  _audit_release_lock "$state_dir"
  echo "$result"
}

# Release (un-claim) a row back to pending for retry.
# Usage: audit_release_row <inventory_path> <row_id> [diagnostics]
audit_release_row() {
  local inventory_path="$1"
  local row_id="$2"
  local diagnostics="${3:-}"
  local state_dir
  state_dir="$(dirname "$inventory_path")"

  _audit_acquire_lock "$state_dir" || return 1

  python3 - "$inventory_path" "$row_id" "$diagnostics" <<'PYEOF'
import json, sys
path        = sys.argv[1]
row_id      = sys.argv[2]
diagnostics = sys.argv[3]

with open(path) as f:
    rows = json.load(f)

for row in rows:
    if str(row.get("id", "")) == row_id:
        row["status"] = "pending"
        row.pop("claimed_by",  None)
        row.pop("claimed_at",  None)
        if diagnostics:
            row["diagnostics"] = diagnostics
        fc = row.get("failure_count", 0)
        row["failure_count"] = int(fc) + 1
        break

import os, tempfile
tmp = path + ".tmp.rel"
with open(tmp, "w") as f:
    json.dump(rows, f, indent=2)
os.rename(tmp, path)
PYEOF

  _audit_release_lock "$state_dir"
}

# ── Update Row ────────────────────────────────────────────────────────────────

# Atomically update a row's fields by row_id.
# fields_json: a JSON object whose keys will be merged into the row.
# Usage: audit_update_row <inventory_path> <row_id> <fields_json>
audit_update_row() {
  local inventory_path="$1"
  local row_id="$2"
  local fields_json="$3"
  local state_dir
  state_dir="$(dirname "$inventory_path")"

  _audit_acquire_lock "$state_dir" || return 1

  python3 - "$inventory_path" "$row_id" "$fields_json" <<'PYEOF'
import json, sys, os
path       = sys.argv[1]
row_id     = sys.argv[2]
new_fields = json.loads(sys.argv[3])

with open(path) as f:
    rows = json.load(f)

found = False
for row in rows:
    if str(row.get("id", "")) == row_id:
        row.update(new_fields)
        found = True
        break

if not found:
    print(f"WARNING: row_id '{row_id}' not found in inventory", file=sys.stderr)
    sys.exit(0)

tmp = path + ".tmp.upd"
with open(tmp, "w") as f:
    json.dump(rows, f, indent=2)
os.rename(tmp, path)
PYEOF

  _audit_release_lock "$state_dir"
}

# ── Stale Claim Cleanup ───────────────────────────────────────────────────────

# Release stale claims (claimed_at older than <max_age_minutes> minutes).
# Called by watchdog / periodic status check.
# Usage: audit_release_stale_claims <inventory_path> [max_age_minutes]
audit_release_stale_claims() {
  local inventory_path="$1"
  local max_age_min="${2:-30}"
  local state_dir
  state_dir="$(dirname "$inventory_path")"

  [[ ! -f "$inventory_path" ]] && return 0

  _audit_acquire_lock "$state_dir" || return 1

  local released
  released=$(python3 - "$inventory_path" "$max_age_min" <<'PYEOF'
import json, sys, os
from datetime import datetime, timezone, timedelta

path        = sys.argv[1]
max_age_min = int(sys.argv[2])
now         = datetime.now(timezone.utc)
threshold   = now - timedelta(minutes=max_age_min)

with open(path) as f:
    rows = json.load(f)

released = []
for row in rows:
    if row.get("status") != "claimed":
        continue
    ca = row.get("claimed_at", "")
    if not ca:
        row["status"] = "pending"
        row.pop("claimed_by", None)
        row.pop("claimed_at", None)
        released.append(str(row.get("id", "")))
        continue
    try:
        ca_dt = datetime.fromisoformat(ca.replace("Z", "+00:00"))
        if ca_dt < threshold:
            row["status"] = "pending"
            row.pop("claimed_by", None)
            row.pop("claimed_at", None)
            released.append(str(row.get("id", "")))
    except (ValueError, TypeError):
        pass

if released:
    tmp = path + ".tmp.stale"
    with open(tmp, "w") as f:
        json.dump(rows, f, indent=2)
    os.rename(tmp, path)

print(len(released))
PYEOF
  )

  _audit_release_lock "$state_dir"

  if [[ "$released" -gt 0 ]]; then
    log_info "Audit: released $released stale claim(s)"
  fi
}

# ── Checkpointing ─────────────────────────────────────────────────────────────

# Copy current inventory state to checkpoints/<timestamp>.json.
# Usage: audit_checkpoint <inventory_path>
audit_checkpoint() {
  local inventory_path="$1"
  local state_dir
  state_dir="$(dirname "$inventory_path")"
  local checkpoint_dir="$state_dir/$AUDIT_CHECKPOINT_DIR"

  [[ ! -f "$inventory_path" ]] && return 0
  ensure_dir "$checkpoint_dir"

  local ts
  ts=$(date -u +"%Y%m%dT%H%M%SZ" 2>/dev/null || date -u +"%Y%m%dT%H%MZ")
  local dst="$checkpoint_dir/${ts}.json"

  cp "$inventory_path" "$dst"
  log_ok "Audit checkpoint saved: $dst"

  # Update manifest
  local manifest_file="$state_dir/manifest.json"
  if [[ -f "$manifest_file" ]] && command -v python3 &>/dev/null; then
    python3 - "$manifest_file" "$dst" <<'PYEOF'
import json, sys
path = sys.argv[1]
chk  = sys.argv[2]
with open(path) as f:
    m = json.load(f)
m.setdefault("checkpoints", []).append(chk)
import os
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(m, f, indent=2)
os.rename(tmp, path)
PYEOF
  fi
}

# ── Completion Gate ───────────────────────────────────────────────────────────

# Run the configured completion check.
# Returns 0 if audit is complete, 1 otherwise.
# Usage: audit_check_completion <config_file> [inventory_path]
audit_check_completion() {
  local config_file="$1"
  local inventory_path="${2:-}"

  if [[ -z "$inventory_path" ]]; then
    inventory_path=$(audit_inventory_path "$config_file")
  fi

  local completion_cmd
  completion_cmd=$(audit_completion_command "$config_file")

  if [[ -n "$completion_cmd" && -f "$completion_cmd" ]]; then
    # User-provided completion script
    bash "$completion_cmd" "$inventory_path"
  else
    # Built-in: all rows must be in a final state
    _audit_builtin_completion_check "$inventory_path"
  fi
}

# Built-in completion check: all rows must be reviewed/skipped.
_audit_builtin_completion_check() {
  local inventory_path="$1"

  [[ ! -f "$inventory_path" ]] && return 1

  python3 - "$inventory_path" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    rows = json.load(f)
FINAL = {"reviewed", "skipped"}
non_final = [r for r in rows if r.get("status", "pending") not in FINAL]
sys.exit(0 if not non_final else 1)
PYEOF
}

# ── Report Rendering ──────────────────────────────────────────────────────────

# Run the configured report command (or built-in renderer).
# Usage: audit_render_report <config_file> [inventory_path]
audit_render_report() {
  local config_file="$1"
  local inventory_path="${2:-}"

  if [[ -z "$inventory_path" ]]; then
    inventory_path=$(audit_inventory_path "$config_file")
  fi

  local report_cmd
  report_cmd=$(audit_report_command "$config_file")

  if [[ -n "$report_cmd" && -f "$report_cmd" ]]; then
    bash "$report_cmd" "$inventory_path"
  else
    log_warn "No report_command configured; set audit.report_command in crew.yaml"
  fi
}

# ── Audit Status Display ──────────────────────────────────────────────────────

# Print audit-mode row counters for show_status().
# Usage: show_audit_counters <config_file> <crew_dir>
show_audit_counters() {
  local config_file="$1"
  local crew_dir="${2:-.crew}"

  local inventory_path
  inventory_path=$(audit_inventory_path "$config_file")

  if [[ ! -f "$inventory_path" ]]; then
    log_warn "Audit inventory not found: $inventory_path (run 'crew start' to initialize)"
    return 0
  fi

  local counts
  counts=$(audit_count_rows "$inventory_path")
  local pending claimed audited reviewed skipped backoff
  read -r pending claimed audited reviewed skipped backoff <<< "$counts"

  local total=$((pending + claimed + audited + reviewed + skipped + backoff))

  echo ""
  echo "${BOLD}Audit Inventory${NC}  ($inventory_path)"
  separator "-" 60
  printf "  %-12s %s\n" "Total:"    "$total"
  printf "  %-12s %s\n" "Pending:"  "$pending"
  printf "  %-12s %s\n" "Claimed:"  "$claimed"
  printf "  %-12s %s\n" "Audited:"  "$audited"
  printf "  %-12s %s\n" "Reviewed:" "$reviewed"
  printf "  %-12s %s\n" "Skipped:"  "$skipped"
  printf "  %-12s %s\n" "Backoff:"  "$backoff"

  # Completion check
  if _audit_builtin_completion_check "$inventory_path" 2>/dev/null; then
    echo ""
    echo -e "  ${GREEN}✓ Completion check: PASSED${NC}"
  else
    echo ""
    echo -e "  ${YELLOW}○ Completion check: PENDING${NC}"
  fi

  # Checkpoint count
  local checkpoint_dir
  checkpoint_dir="$(dirname "$inventory_path")/$AUDIT_CHECKPOINT_DIR"
  if [[ -d "$checkpoint_dir" ]]; then
    local ckpt_count
    ckpt_count=$(ls "$checkpoint_dir"/*.json 2>/dev/null | wc -l | tr -d ' ')
    printf "  %-12s %s\n" "Checkpoints:" "$ckpt_count"
  fi

  echo ""
}

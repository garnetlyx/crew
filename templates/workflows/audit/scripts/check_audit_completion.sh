#!/usr/bin/env bash
# check_audit_completion.sh — Default completion gate for audit mode.
#
# Exits 0 when ALL rows in audit-results.json have a final status
# (audited, reviewed, or skipped). Exits 1 otherwise.
#
# Called by crew via: audit.completion_command in crew.yaml.
# Can be replaced with any shell command that follows the same contract.
set -euo pipefail

INVENTORY="${1:-.crew/state/audit-results.json}"

if [[ ! -f "$INVENTORY" ]]; then
  echo "ERROR: Inventory not found: $INVENTORY" >&2
  exit 1
fi

if ! command -v python3 &>/dev/null; then
  echo "ERROR: python3 required for completion check" >&2
  exit 1
fi

python3 - "$INVENTORY" <<'PYEOF'
import json
import sys

path = sys.argv[1]
with open(path) as f:
    rows = json.load(f)

if not isinstance(rows, list):
    print("ERROR: audit-results.json must be a JSON array", file=sys.stderr)
    sys.exit(1)

total = len(rows)
if total == 0:
    print("WARNING: inventory is empty — nothing to audit")
    sys.exit(0)

FINAL_STATUSES = {"audited", "reviewed", "skipped"}
NON_FINAL = [r for r in rows if r.get("status", "pending") not in FINAL_STATUSES]

pending   = sum(1 for r in rows if r.get("status", "pending") == "pending")
claimed   = sum(1 for r in rows if r.get("status") == "claimed")
audited   = sum(1 for r in rows if r.get("status") == "audited")
reviewed  = sum(1 for r in rows if r.get("status") == "reviewed")
skipped   = sum(1 for r in rows if r.get("status") == "skipped")
backoff   = sum(1 for r in rows if r.get("status") == "backoff")

print(f"Audit completion check: {path}")
print(f"  Total:    {total}")
print(f"  Pending:  {pending}")
print(f"  Claimed:  {claimed}")
print(f"  Audited:  {audited}")
print(f"  Reviewed: {reviewed}")
print(f"  Skipped:  {skipped}")
print(f"  Backoff:  {backoff}")
print(f"  Non-final:{len(NON_FINAL)}")

if NON_FINAL:
    print(f"\nNOT COMPLETE — {len(NON_FINAL)} row(s) not yet in final state")
    sys.exit(1)

print("\nCOMPLETE — all rows in final state")
sys.exit(0)
PYEOF

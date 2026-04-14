#!/usr/bin/env bash
# render_audit_report.sh — Render a markdown report from audit-results.json.
#
# Reads .crew/state/audit-results.json and writes .crew/output/report.md.
# Called by crew via: audit.report_command in crew.yaml.
# Can be replaced with any shell command that writes a report file.
set -euo pipefail

INVENTORY="${1:-.crew/state/audit-results.json}"
REPORT_DIR=".crew/output"
REPORT_FILE="$REPORT_DIR/report.md"

mkdir -p "$REPORT_DIR"

if [[ ! -f "$INVENTORY" ]]; then
  echo "ERROR: Inventory not found: $INVENTORY" >&2
  exit 1
fi

if ! command -v python3 &>/dev/null; then
  echo "ERROR: python3 required for report rendering" >&2
  exit 1
fi

python3 - "$INVENTORY" "$REPORT_FILE" <<'PYEOF'
import json
import sys
from datetime import datetime, timezone

inventory_path = sys.argv[1]
report_path    = sys.argv[2]

with open(inventory_path) as f:
    rows = json.load(f)

if not isinstance(rows, list):
    print("ERROR: audit-results.json must be a JSON array", file=sys.stderr)
    sys.exit(1)

total    = len(rows)
reviewed = sum(1 for r in rows if r.get("status") == "reviewed")
audited  = sum(1 for r in rows if r.get("status") == "audited")
skipped  = sum(1 for r in rows if r.get("status") == "skipped")
backoff  = sum(1 for r in rows if r.get("status") == "backoff")
pending  = sum(1 for r in rows if r.get("status", "pending") in ("pending", "claimed"))

now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

lines = [
    f"# Audit Report",
    f"",
    f"**Generated**: {now}  ",
    f"**Inventory**: `{inventory_path}`  ",
    f"",
    f"## Summary",
    f"",
    f"| Status | Count |",
    f"|--------|-------|",
    f"| Total | {total} |",
    f"| Reviewed | {reviewed} |",
    f"| Audited (pending review) | {audited} |",
    f"| Skipped | {skipped} |",
    f"| Backoff | {backoff} |",
    f"| Pending / In-progress | {pending} |",
    f"",
    f"## Row Details",
    f"",
]

# Determine which fields to use as columns
all_keys = set()
for r in rows:
    all_keys.update(r.keys())
# Always show these first if present
preferred = ["id", "status", "verdict", "reviewer_verdict", "notes", "error"]
cols = [k for k in preferred if k in all_keys]
# Append remaining keys alphabetically
for k in sorted(all_keys):
    if k not in cols:
        cols.append(k)

header = "| " + " | ".join(cols) + " |"
sep    = "| " + " | ".join("---" for _ in cols) + " |"
lines += [header, sep]

for row in rows:
    cells = []
    for col in cols:
        val = row.get(col, "")
        if val is None:
            val = ""
        # Escape pipe characters in cell values
        cells.append(str(val).replace("|", "\\|"))
    lines.append("| " + " | ".join(cells) + " |")

lines.append("")

with open(report_path, "w") as f:
    f.write("\n".join(lines))

print(f"Report written to: {report_path}")
PYEOF

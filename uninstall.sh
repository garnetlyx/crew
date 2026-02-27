#!/bin/bash
# crew uninstaller - removes symlinks from ~/.local/bin

set -euo pipefail

INSTALL_DIR="$HOME/.local/bin"

echo "Uninstalling crew tools..."

for cmd in crew design; do
  local_bin="$INSTALL_DIR/$cmd"
  if [[ -L "$local_bin" ]]; then
    rm -f "$local_bin"
    echo "✓ Removed $local_bin"
  elif [[ -f "$local_bin" ]]; then
    echo "⚠ $local_bin is not a symlink, skipping"
  else
    echo "  $local_bin not found, skipping"
  fi
done

echo ""
echo "✓ Uninstall complete"
echo "  Project-local .crew/ and .design/ dirs are NOT removed."
echo "  Delete them manually if no longer needed."

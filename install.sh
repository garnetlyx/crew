#!/bin/bash
# crew installer - creates symlinks in ~/.local/bin

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.local/bin"

echo "Installing crew tools..."

# Make scripts executable
chmod +x "$SCRIPT_DIR/crew.sh"
chmod +x "$SCRIPT_DIR/design.sh"
chmod +x "$SCRIPT_DIR/lib/"*.sh
chmod +x "$SCRIPT_DIR/plugins/"*.sh

# Ensure ~/.local/bin exists
mkdir -p "$INSTALL_DIR"

# Create symlinks
ln -sf "$SCRIPT_DIR/crew.sh" "$INSTALL_DIR/crew"
ln -sf "$SCRIPT_DIR/design.sh" "$INSTALL_DIR/design"
echo "✓ Created symlinks in $INSTALL_DIR"

# Check if ~/.local/bin is in PATH
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
  echo ""
  echo "⚠ $INSTALL_DIR is not in your PATH"
  echo "  Add this line to your ~/.zshrc or ~/.bashrc:"
  echo ""
  echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
  echo ""
fi

# Check for yq
if ! command -v yq &> /dev/null; then
  echo ""
  echo "⚠ yq not found. Install for better YAML parsing:"
  echo "  brew install yq"
fi

echo ""
echo "✓ Installation complete!"
echo ""
echo "Commands available:"
echo "  crew    - Multi-agent parallel orchestration"
echo "  design  - Design-review loop for design docs"
echo ""
echo "Get started:"
echo "  cd your-project"
echo "  crew init              # For parallel agents"
echo "  design init \"Your idea\" # For design doc refinement"

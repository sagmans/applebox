#!/bin/bash
#
# Setup script to configure git hooks for AppleBox
# Run this once after cloning the repository
#

set -e

# Get the root directory of the git repository
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)

if [ -z "$REPO_ROOT" ]; then
    echo "Error: Not in a git repository"
    exit 1
fi

echo "Setting up git hooks for AppleBox..."
echo ""

# Configure git to use the .githooks directory
git config core.hooksPath .githooks

# Verify the hook is executable
HOOK_FILE="$REPO_ROOT/.githooks/pre-commit"
if [ -f "$HOOK_FILE" ]; then
    chmod +x "$HOOK_FILE"
    echo "✓ Pre-commit hook configured"
else
    echo "Warning: Pre-commit hook file not found at $HOOK_FILE"
fi

echo ""
echo "Git hooks setup complete!"
echo ""
echo "The following hooks are now active:"
echo "  - pre-commit: Runs swift build and swift test before each commit"
echo ""
echo "To disable hooks temporarily, use: git commit --no-verify"
echo "To remove hooks, run: git config --unset core.hooksPath"

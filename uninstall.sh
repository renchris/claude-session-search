#!/bin/bash
# Uninstall claude-session-search from ~/.claude/
# Removes symlinks and hook entries. Leaves DB intact.
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
BIN_DIR="$CLAUDE_DIR/bin"
SETTINGS="$CLAUDE_DIR/settings.json"

echo "Uninstalling claude-session-search..."

# ─── Remove Symlinks ─────────────────────────────────────

remove_symlink() {
    local path="$1"
    if [ -L "$path" ]; then
        rm "$path"
        echo "  ✓ Removed $path"
    elif [ -f "$path" ]; then
        echo "  ⚠ $path is not a symlink, skipping"
    else
        echo "  - $path (not found)"
    fi
}

echo "Hooks:"
remove_symlink "$HOOKS_DIR/session-index-end.sh"
remove_symlink "$HOOKS_DIR/session-index-start.sh"
remove_symlink "$HOOKS_DIR/lib/session-index-helpers.sh"

echo ""
echo "Bin:"
remove_symlink "$BIN_DIR/session-search.py"
remove_symlink "$BIN_DIR/claude-search"

# ─── Remove Hook Entries from settings.json ───────────────

echo ""
echo "Settings:"

if [ -f "$SETTINGS" ]; then
    cp "$SETTINGS" "$SETTINGS.bak"
    echo "  Backup: $SETTINGS.bak"

    TEMP=$(mktemp)

    # Remove session-index-end entries from SessionEnd
    jq '
        .hooks.SessionEnd = [
            .hooks.SessionEnd // [] | .[] |
            .hooks = [.hooks // [] | .[] | select(.command | test("session-index-end") | not)] |
            select(.hooks | length > 0)
        ]
    ' "$SETTINGS" > "$TEMP" && mv "$TEMP" "$SETTINGS"

    TEMP=$(mktemp)

    # Remove session-index-start entries from SessionStart
    jq '
        .hooks.SessionStart = [
            .hooks.SessionStart // [] | .[] |
            .hooks = [.hooks // [] | .[] | select(.command | test("session-index-start") | not)] |
            select(.hooks | length > 0)
        ]
    ' "$SETTINGS" > "$TEMP" && mv "$TEMP" "$SETTINGS"

    if jq empty "$SETTINGS" 2>/dev/null; then
        echo "  ✓ Hook entries removed from settings.json"
    else
        echo "  ERROR: settings.json invalid after edit, restoring backup" >&2
        cp "$SETTINGS.bak" "$SETTINGS"
    fi
else
    echo "  - settings.json not found"
fi

echo ""
echo "────────────────────────────────────────────"
echo "Uninstall complete."
echo ""
echo "Database preserved at: $CLAUDE_DIR/session-index.db"
echo "To delete: rm $CLAUDE_DIR/session-index.db"
echo "────────────────────────────────────────────"

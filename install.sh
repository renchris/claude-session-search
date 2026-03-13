#!/bin/bash
# Install claude-session-search into ~/.claude/
# Symlinks hooks + bin, patches settings.json.
# Idempotent: safe to run multiple times.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
HOOKS_LIB="$HOOKS_DIR/lib"
BIN_DIR="$CLAUDE_DIR/bin"
SETTINGS="$CLAUDE_DIR/settings.json"

echo "Installing claude-session-search..."
echo "Repo: $REPO_DIR"
echo ""

# ─── Prerequisites ────────────────────────────────────────

MISSING=()
command -v sqlite3 &>/dev/null || MISSING+=("sqlite3")
command -v python3 &>/dev/null || MISSING+=("python3")
command -v jq &>/dev/null || MISSING+=("jq")

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "ERROR: Missing required tools: ${MISSING[*]}" >&2
    echo "Install with: brew install ${MISSING[*]}" >&2
    exit 1
fi

# Check FTS5 support
if ! sqlite3 :memory: "CREATE VIRTUAL TABLE t USING fts5(c);" ".quit" 2>/dev/null; then
    echo "ERROR: SQLite FTS5 not available." >&2
    exit 1
fi

# Optional: fzf
if ! command -v fzf &>/dev/null; then
    echo "NOTE: fzf not found. Interactive mode (--fzf) won't work."
    echo "      Install with: brew install fzf"
    echo ""
fi

# ─── Create Directories ──────────────────────────────────

mkdir -p "$HOOKS_DIR" "$HOOKS_LIB" "$BIN_DIR"

# ─── Symlink Hooks ────────────────────────────────────────

symlink_file() {
    local src="$1" dst="$2"
    if [ -L "$dst" ]; then
        local current
        current=$(readlink "$dst")
        if [ "$current" = "$src" ]; then
            echo "  ✓ $dst (already linked)"
            return
        fi
        rm "$dst"
    elif [ -f "$dst" ]; then
        echo "  ⚠ $dst exists (not a symlink), skipping"
        return
    fi
    ln -s "$src" "$dst"
    echo "  → $dst"
}

echo "Hooks:"
symlink_file "$REPO_DIR/hooks/session-index-end.sh" "$HOOKS_DIR/session-index-end.sh"
symlink_file "$REPO_DIR/hooks/session-index-start.sh" "$HOOKS_DIR/session-index-start.sh"
symlink_file "$REPO_DIR/hooks/lib/session-index-helpers.sh" "$HOOKS_LIB/session-index-helpers.sh"

echo ""
echo "Bin:"
symlink_file "$REPO_DIR/bin/session-search.py" "$BIN_DIR/session-search.py"
symlink_file "$REPO_DIR/bin/claude-search" "$BIN_DIR/claude-search"

# Make executable
chmod +x "$HOOKS_DIR/session-index-end.sh"
chmod +x "$HOOKS_DIR/session-index-start.sh"
chmod +x "$BIN_DIR/claude-search"
chmod +x "$BIN_DIR/session-search.py"

# ─── Patch settings.json ─────────────────────────────────

echo ""
echo "Settings:"

if [ ! -f "$SETTINGS" ]; then
    echo "  ⚠ $SETTINGS not found, skipping settings patch"
    echo "  Manually add hooks to your settings.json"
else
    # Backup
    cp "$SETTINGS" "$SETTINGS.bak"
    echo "  Backup: $SETTINGS.bak"

    # Check if hooks already registered
    SESSION_END_REGISTERED=$(jq '.hooks.SessionEnd // [] | [.[].hooks // [] | .[] | select(.command | test("session-index-end"))] | length' "$SETTINGS" 2>/dev/null || echo 0)
    SESSION_START_REGISTERED=$(jq '.hooks.SessionStart // [] | [.[].hooks // [] | .[] | select(.command | test("session-index-start"))] | length' "$SETTINGS" 2>/dev/null || echo 0)

    TEMP=$(mktemp)

    if [ "$SESSION_END_REGISTERED" -eq 0 ]; then
        # Add session-index-end.sh to SessionEnd hooks array
        jq '.hooks.SessionEnd = (.hooks.SessionEnd // []) + [{
            "hooks": [{
                "type": "command",
                "command": "~/.claude/hooks/session-index-end.sh",
                "timeout": 10
            }]
        }]' "$SETTINGS" > "$TEMP" && mv "$TEMP" "$SETTINGS"
        echo "  + SessionEnd hook registered"
    else
        echo "  ✓ SessionEnd hook already registered"
    fi

    if [ "$SESSION_START_REGISTERED" -eq 0 ]; then
        TEMP=$(mktemp)
        jq '.hooks.SessionStart = (.hooks.SessionStart // []) + [{
            "hooks": [{
                "type": "command",
                "command": "~/.claude/hooks/session-index-start.sh",
                "timeout": 5
            }]
        }]' "$SETTINGS" > "$TEMP" && mv "$TEMP" "$SETTINGS"
        echo "  + SessionStart hook registered"
    else
        echo "  ✓ SessionStart hook already registered"
    fi

    # Validate JSON
    if ! jq empty "$SETTINGS" 2>/dev/null; then
        echo "  ERROR: settings.json is invalid JSON! Restoring backup." >&2
        cp "$SETTINGS.bak" "$SETTINGS"
        exit 1
    fi
fi

# ─── Add claude-search to PATH hint ──────────────────────

echo ""
echo "────────────────────────────────────────────"
echo "Installation complete!"
echo ""
echo "Next steps:"
echo "  1. Run backfill:  cd $REPO_DIR && ./scripts/session-index-backfill.sh"
echo "  2. Test search:   $BIN_DIR/claude-search \"bottle menu\""
echo "  3. Add to PATH:   echo 'export PATH=\"\$HOME/.claude/bin:\$PATH\"' >> ~/.zshrc"
echo ""
echo "Optional:"
echo "  Tag sessions:     ./scripts/session-index-tag.sh --regex-only"
echo "  With Haiku:       ANTHROPIC_API_KEY=sk-... ./scripts/session-index-tag.sh"
echo "────────────────────────────────────────────"

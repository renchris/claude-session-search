#!/bin/bash
# Install claude-session-search into ~/.claude/
# One command: symlinks hooks + bin, patches settings.json, backfills index, adds PATH.
# Idempotent: safe to run multiple times.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
HOOKS_LIB="$HOOKS_DIR/lib"
BIN_DIR="$CLAUDE_DIR/bin"
SETTINGS="$CLAUDE_DIR/settings.json"
SHELL_RC="$HOME/.zshrc"
[ -f "$SHELL_RC" ] || SHELL_RC="$HOME/.bashrc"

# ─── Prerequisites ────────────────────────────────────────

MISSING=()
command -v sqlite3 &>/dev/null || MISSING+=("sqlite3")
command -v python3 &>/dev/null || MISSING+=("python3")
command -v jq &>/dev/null || MISSING+=("jq")

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "Missing required: ${MISSING[*]}" >&2
    if command -v brew &>/dev/null; then
        echo "  brew install ${MISSING[*]}" >&2
    elif command -v apt-get &>/dev/null; then
        echo "  sudo apt-get install ${MISSING[*]}" >&2
    elif command -v dnf &>/dev/null; then
        echo "  sudo dnf install ${MISSING[*]}" >&2
    else
        echo "  Install via your system package manager." >&2
    fi
    exit 1
fi

if ! sqlite3 :memory: "CREATE VIRTUAL TABLE t USING fts5(c);" ".quit" 2>/dev/null; then
    echo "SQLite FTS5 not available." >&2
    exit 1
fi

# ─── Symlink ──────────────────────────────────────────────

symlink_file() {
    local src="$1" dst="$2"
    if [ -L "$dst" ]; then
        local current
        current=$(readlink "$dst")
        [ "$current" = "$src" ] && return
        rm "$dst"
    elif [ -f "$dst" ]; then
        return  # Don't overwrite non-symlink files
    fi
    ln -s "$src" "$dst"
}

mkdir -p "$HOOKS_DIR" "$HOOKS_LIB" "$BIN_DIR"

echo "1/4  Symlinking hooks + bin..."
symlink_file "$REPO_DIR/hooks/session-index-end.sh" "$HOOKS_DIR/session-index-end.sh"
symlink_file "$REPO_DIR/hooks/session-index-start.sh" "$HOOKS_DIR/session-index-start.sh"
symlink_file "$REPO_DIR/hooks/lib/session-index-helpers.sh" "$HOOKS_LIB/session-index-helpers.sh"
symlink_file "$REPO_DIR/bin/session-search.py" "$BIN_DIR/session-search.py"
symlink_file "$REPO_DIR/bin/claude-search" "$BIN_DIR/claude-search"

chmod +x "$HOOKS_DIR/session-index-end.sh" "$HOOKS_DIR/session-index-start.sh" \
         "$BIN_DIR/claude-search" "$BIN_DIR/session-search.py"

# ─── Patch settings.json ─────────────────────────────────

echo "2/4  Registering hooks in settings.json..."

if [ -f "$SETTINGS" ]; then
    cp "$SETTINGS" "$SETTINGS.bak"

    SESSION_END_REGISTERED=$(jq '.hooks.SessionEnd // [] | [.[].hooks // [] | .[] | select(.command | test("session-index-end"))] | length' "$SETTINGS" 2>/dev/null || echo 0)
    SESSION_START_REGISTERED=$(jq '.hooks.SessionStart // [] | [.[].hooks // [] | .[] | select(.command | test("session-index-start"))] | length' "$SETTINGS" 2>/dev/null || echo 0)

    if [ "$SESSION_END_REGISTERED" -eq 0 ]; then
        TEMP=$(mktemp)
        jq '.hooks.SessionEnd = (.hooks.SessionEnd // []) + [{
            "hooks": [{"type": "command", "command": "~/.claude/hooks/session-index-end.sh", "timeout": 10}]
        }]' "$SETTINGS" > "$TEMP" && mv "$TEMP" "$SETTINGS"
    fi

    if [ "$SESSION_START_REGISTERED" -eq 0 ]; then
        TEMP=$(mktemp)
        jq '.hooks.SessionStart = (.hooks.SessionStart // []) + [{
            "hooks": [{"type": "command", "command": "~/.claude/hooks/session-index-start.sh", "timeout": 5}]
        }]' "$SETTINGS" > "$TEMP" && mv "$TEMP" "$SETTINGS"
    fi

    if ! jq empty "$SETTINGS" 2>/dev/null; then
        cp "$SETTINGS.bak" "$SETTINGS"
        echo "  settings.json corrupted, restored backup" >&2
        exit 1
    fi
else
    echo "  No settings.json found — add hooks manually"
fi

# ─── Backfill index ──────────────────────────────────────

echo "3/4  Indexing existing sessions..."
"$REPO_DIR/scripts/session-index-backfill.sh" --quiet

# Tag with regex (fast, no API needed)
"$REPO_DIR/scripts/session-index-tag.sh" --regex-only --limit 1000 > /dev/null 2>&1 || true

# Rebuild FTS with tags
sqlite3 "$CLAUDE_DIR/session-index.db" "DELETE FROM sessions_fts; INSERT INTO sessions_fts (session_id, summary, first_prompt, tags, keywords, project_name, context_text) SELECT session_id, summary, first_prompt, tags, keywords, project_name, context_text FROM sessions;" 2>/dev/null || true

TOTAL=$(sqlite3 "$CLAUDE_DIR/session-index.db" "SELECT COUNT(*) FROM sessions;" 2>/dev/null || echo 0)
TAGGED=$(sqlite3 "$CLAUDE_DIR/session-index.db" "SELECT COUNT(*) FROM sessions WHERE tagged_at IS NOT NULL;" 2>/dev/null || echo 0)

# ─── Add to PATH ─────────────────────────────────────────

echo "4/4  Configuring PATH..."

PATH_LINE='export PATH="$HOME/.claude/bin:$PATH"'
if [ -f "$SHELL_RC" ] && ! grep -qF '.claude/bin' "$SHELL_RC" 2>/dev/null; then
    echo "" >> "$SHELL_RC"
    echo "# claude-session-search" >> "$SHELL_RC"
    echo "$PATH_LINE" >> "$SHELL_RC"
    PATH_MSG="Added to $(basename "$SHELL_RC"). Run: source $SHELL_RC"
else
    PATH_MSG="Already in $(basename "$SHELL_RC")"
fi

# ─── Done ─────────────────────────────────────────────────

echo ""
echo "Done. $TOTAL sessions indexed, $TAGGED tagged."
echo "PATH: $PATH_MSG"
echo ""
echo "Try:  claude-search \"your query\""
if ! command -v fzf &>/dev/null; then
    echo "Tip:  Install fzf for interactive mode (--fzf)"
fi
if ! python3 -c "import rapidfuzz" 2>/dev/null; then
    echo "Tip:  pip install rapidfuzz   for fuzzy typo correction"
fi

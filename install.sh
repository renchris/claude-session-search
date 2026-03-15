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

# ─── Progress UI ─────────────────────────────────────────────
# Source shared library (always available when running from repo).

_UI_LIB="$REPO_DIR/scripts/lib/progress-ui.sh"
if [ ! -f "$_UI_LIB" ]; then
    echo "error: missing $REPO_DIR/scripts/lib/progress-ui.sh" >&2
    echo "  Re-clone the repo or restore the file." >&2
    exit 1
fi
# shellcheck source=scripts/lib/progress-ui.sh
source "$_UI_LIB"

# ─── Installer step helpers (built on shared lib primitives) ─
# The installer uses a "show all pending, then overwrite in-place" UX
# that needs thin wrappers around the shared lib's ANSI variables.

_INST_SYM_DONE="$_G✓$_R"
_INST_SYM_FAIL="$_RD✗$_R"
_INST_SYM_PENDING="$_D○$_R"
_INST_SYM_ACTIVE="$_C⠹$_R"

if ! $_UI_IS_TTY; then
    _INST_SYM_DONE="[ok]"
    _INST_SYM_FAIL="[!!]"
    _INST_SYM_PENDING="[ ]"
    _INST_SYM_ACTIVE="[..]"
fi

_inst_step_line() {
    local sym="$1" label="$2" detail="$3"
    local label_plain
    label_plain=$(printf '%s' "$label" | sed $'s/\033\\[[0-9;]*m//g')
    local pad=$((18 - ${#label_plain}))
    [ "$pad" -lt 1 ] && pad=1
    local spaces=""
    for ((i = 0; i < pad; i++)); do spaces+=" "; done
    if $_UI_IS_TTY; then
        printf "  %s %b%s%b%s%b%s%b\n" "$sym" "$_B" "$label" "$_R" "$spaces" "$_D" "$detail" "$_R"
    else
        printf "  %s %-18s %s\n" "$sym" "$label" "$detail"
    fi
}

inst_step_pending() { $_UI_IS_TTY && _inst_step_line "$_INST_SYM_PENDING" "$1" "—"; true; }
inst_step_active()  { $_UI_IS_TTY && _inst_step_line "$_INST_SYM_ACTIVE" "$1" "$2"; true; }

inst_step_replace() {
    local label="$1" detail="$2" sym="${3:-$_INST_SYM_DONE}"
    if $_UI_IS_TTY; then
        printf '%b%b' "$_UP" "$_CL"
    fi
    _inst_step_line "$sym" "$label" "$detail"
}

_INST_START_MS=""
inst_timer_start() { _INST_START_MS=$(_ui_now); }
inst_timer_elapsed() { _ui_elapsed "$_INST_START_MS"; }

# ─── Prerequisites ───────────────────────────────────────────

MISSING=()
command -v sqlite3 &>/dev/null || MISSING+=("sqlite3")
command -v python3 &>/dev/null || MISSING+=("python3")
command -v jq &>/dev/null || MISSING+=("jq")

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "" >&2
    printf '  %bMissing required:%b %s\n' "$_RD" "$_R" "${MISSING[*]}" >&2
    if command -v brew &>/dev/null; then
        printf '  %bbrew install %s%b\n' "$_D" "${MISSING[*]}" "$_R" >&2
    elif command -v apt-get &>/dev/null; then
        printf '  %bsudo apt-get install %s%b\n' "$_D" "${MISSING[*]}" "$_R" >&2
    elif command -v dnf &>/dev/null; then
        printf '  %bsudo dnf install %s%b\n' "$_D" "${MISSING[*]}" "$_R" >&2
    else
        printf '  %bInstall via your system package manager.%b\n' "$_D" "$_R" >&2
    fi
    echo "" >&2
    exit 1
fi

if ! sqlite3 :memory: "CREATE VIRTUAL TABLE t USING fts5(c);" ".quit" 2>/dev/null; then
    echo "" >&2
    printf '  %bSQLite FTS5 not available.%b\n' "$_RD" "$_R" >&2
    echo "" >&2
    exit 1
fi

# ─── Start ───────────────────────────────────────────────────

inst_timer_start
ui_cursor_hide

ui_header "claude-session-search installer"

# Show all steps as pending (TTY only — gives the full roadmap upfront)
inst_step_pending "Symlinks"
inst_step_pending "Settings"
inst_step_pending "Indexing"
inst_step_pending "PATH"

# Move cursor back up 4 lines to overwrite steps in-place
if $_UI_IS_TTY; then
    printf "\033[4A"
fi

# ─── Step 1: Symlinks ───────────────────────────────────────

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

$_UI_IS_TTY && printf '%b' "$_CL"
inst_step_active "Symlinks" "linking hooks + bin..."

mkdir -p "$HOOKS_DIR" "$HOOKS_LIB" "$BIN_DIR"

symlink_file "$REPO_DIR/hooks/session-index-end.sh" "$HOOKS_DIR/session-index-end.sh"
symlink_file "$REPO_DIR/hooks/session-index-start.sh" "$HOOKS_DIR/session-index-start.sh"
symlink_file "$REPO_DIR/hooks/lib/session-index-helpers.sh" "$HOOKS_LIB/session-index-helpers.sh"
symlink_file "$REPO_DIR/bin/session-search.py" "$BIN_DIR/session-search.py"
symlink_file "$REPO_DIR/bin/claude-search" "$BIN_DIR/claude-search"
symlink_file "$REPO_DIR/scripts/session-index-tag.py" "$BIN_DIR/session-index-tag.py"

chmod +x "$HOOKS_DIR/session-index-end.sh" "$HOOKS_DIR/session-index-start.sh" \
         "$BIN_DIR/claude-search" "$BIN_DIR/session-search.py" \
         "$REPO_DIR/scripts/session-index-tag.py"

inst_step_replace "Symlinks" "hooks + bin linked"

# ─── Step 2: Settings ───────────────────────────────────────

$_UI_IS_TTY && printf '%b' "$_CL"
inst_step_active "Settings" "patching settings.json..."

SETTINGS_DETAIL=""
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
        inst_step_replace "Settings" "corrupted, restored backup" "$_INST_SYM_FAIL"
        printf '  %bsettings.json was corrupted during patching. Backup restored.%b\n' "$_RD" "$_R" >&2
        exit 1
    fi

    if [ "$SESSION_END_REGISTERED" -gt 0 ] && [ "$SESSION_START_REGISTERED" -gt 0 ]; then
        SETTINGS_DETAIL="hooks already registered"
    else
        SETTINGS_DETAIL="hooks registered in settings.json"
    fi
else
    SETTINGS_DETAIL="no settings.json — add hooks manually"
fi

inst_step_replace "Settings" "$SETTINGS_DETAIL"

# ─── Step 3: Indexing ────────────────────────────────────────

$_UI_IS_TTY && printf '%b' "$_CL"
inst_step_active "Indexing" "scanning sessions..."

"$REPO_DIR/scripts/session-index-backfill.sh" --quiet

# Tag with regex (fast, no API needed)
python3 "$REPO_DIR/scripts/session-index-tag.py" --regex-only --limit 1000 --quiet 2>/dev/null || true

# Rebuild FTS with tags
sqlite3 "$CLAUDE_DIR/session-index.db" "DELETE FROM sessions_fts; INSERT INTO sessions_fts (session_id, summary, first_prompt, tags, keywords, project_name, context_text, assistant_text, files_changed, commands_run) SELECT session_id, summary, first_prompt, tags, keywords, project_name, context_text, assistant_text, files_changed, commands_run FROM sessions;" 2>/dev/null || true

TOTAL=$(sqlite3 "$CLAUDE_DIR/session-index.db" "SELECT COUNT(*) FROM sessions;" 2>/dev/null || echo 0)
TAGGED=$(sqlite3 "$CLAUDE_DIR/session-index.db" "SELECT COUNT(*) FROM sessions WHERE tagged_at IS NOT NULL;" 2>/dev/null || echo 0)

inst_step_replace "Indexing" "${TOTAL} sessions, ${TAGGED} tagged"

# ─── Step 4: PATH ────────────────────────────────────────────

$_UI_IS_TTY && printf '%b' "$_CL"
inst_step_active "PATH" "checking shell config..."

PATH_LINE='export PATH="$HOME/.claude/bin:$PATH"'
PATH_DETAIL=""
if [ -f "$SHELL_RC" ] && ! grep -qF '.claude/bin' "$SHELL_RC" 2>/dev/null; then
    echo "" >> "$SHELL_RC"
    echo "# claude-session-search" >> "$SHELL_RC"
    echo "$PATH_LINE" >> "$SHELL_RC"
    PATH_DETAIL="added to $(basename "$SHELL_RC")"
else
    PATH_DETAIL="already in $(basename "$SHELL_RC")"
fi

inst_step_replace "PATH" "$PATH_DETAIL"

# ─── Summary ────────────────────────────────────────────────

ELAPSED="$(inst_timer_elapsed)s"

ui_summary "Ready" "$ELAPSED" \
    "Sessions" "$TOTAL" \
    "Tagged" "$TAGGED" \
    "Search" "claude-search \"query\""

# ─── Optional Dependencies ──────────────────────────────────

OPTIONAL_DEPS=()

if ! python3 -c "import yake" 2>/dev/null; then
    OPTIONAL_DEPS+=("pip install yake=multi-word key phrases")
fi
if ! python3 -c "import rapidfuzz" 2>/dev/null; then
    OPTIONAL_DEPS+=("pip install rapidfuzz=fuzzy typo correction")
fi
if ! python3 -c "import anthropic" 2>/dev/null; then
    OPTIONAL_DEPS+=("pip install anthropic=LLM query expansion")
fi
if ! command -v fzf &>/dev/null; then
    OPTIONAL_DEPS+=("brew install fzf=interactive mode (--fzf)")
fi

if [ ${#OPTIONAL_DEPS[@]} -gt 0 ]; then
    echo ""
    if $_UI_IS_TTY; then
        printf '  %bOptional:%b\n' "$_D" "$_R"
        for entry in "${OPTIONAL_DEPS[@]}"; do
            cmd="${entry%%=*}"
            desc="${entry#*=}"
            printf '    %b%-26s %s%b\n' "$_D" "$cmd" "$desc" "$_R"
        done
    else
        echo "  Optional:"
        for entry in "${OPTIONAL_DEPS[@]}"; do
            cmd="${entry%%=*}"
            desc="${entry#*=}"
            printf "    %-26s %s\n" "$cmd" "$desc"
        done
    fi
fi

echo ""

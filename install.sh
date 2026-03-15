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
# Source shared library if available; otherwise define inline.

if [ -f "$REPO_DIR/scripts/lib/progress-ui.sh" ]; then
    # shellcheck source=scripts/lib/progress-ui.sh
    source "$REPO_DIR/scripts/lib/progress-ui.sh"
else

# --- Inline UI definitions (same API as progress-ui.sh) ------

if [ -t 1 ]; then
    UI_IS_TTY=true
else
    UI_IS_TTY=false
fi

if $UI_IS_TTY; then
    UI_BOLD=$'\033[1m'
    UI_DIM=$'\033[2m'
    UI_RESET=$'\033[0m'
    UI_GREEN=$'\033[32m'
    UI_CYAN=$'\033[36m'
    UI_YELLOW=$'\033[33m'
    UI_RED=$'\033[31m'
    UI_WHITE=$'\033[97m'
    UI_HIDE_CURSOR=$'\033[?25l'
    UI_SHOW_CURSOR=$'\033[?25h'
    UI_CLEAR_LINE=$'\033[2K'
    UI_MOVE_UP=$'\033[1A'
else
    UI_BOLD="" UI_DIM="" UI_RESET="" UI_GREEN="" UI_CYAN=""
    UI_YELLOW="" UI_RED="" UI_WHITE=""
    UI_HIDE_CURSOR="" UI_SHOW_CURSOR="" UI_CLEAR_LINE="" UI_MOVE_UP=""
fi

if $UI_IS_TTY; then
    UI_SYM_DONE="${UI_GREEN}✓${UI_RESET}"
    UI_SYM_FAIL="${UI_RED}✗${UI_RESET}"
    UI_SYM_PENDING="${UI_DIM}○${UI_RESET}"
    UI_SYM_ACTIVE="${UI_CYAN}⠹${UI_RESET}"
else
    UI_SYM_DONE="[ok]"
    UI_SYM_FAIL="[!!]"
    UI_SYM_PENDING="[ ]"
    UI_SYM_ACTIVE="[..]"
fi

ui_box_top() {
    local w="${1:-48}" bar=""
    for ((i = 0; i < w; i++)); do bar+="─"; done
    printf "  ╭%s╮\n" "$bar"
}
ui_box_mid() {
    local w="${1:-48}" bar=""
    for ((i = 0; i < w; i++)); do bar+="─"; done
    printf "  ├%s┤\n" "$bar"
}
ui_box_bottom() {
    local w="${1:-48}" bar=""
    for ((i = 0; i < w; i++)); do bar+="─"; done
    printf "  ╰%s╯\n" "$bar"
}
ui_box_line() {
    local left="$1" right="${2:-}" w="${3:-48}"
    local left_plain right_plain
    left_plain=$(printf '%s' "$left" | sed 's/\x1b\[[0-9;]*m//g')
    right_plain=$(printf '%s' "$right" | sed 's/\x1b\[[0-9;]*m//g')
    local padding=$((w - 2 - ${#left_plain} - ${#right_plain}))
    [ "$padding" -lt 1 ] && padding=1
    local spaces=""
    for ((i = 0; i < padding; i++)); do spaces+=" "; done
    printf "  │ %s%s%s │\n" "$left" "$spaces" "$right"
}

ui_header() {
    local title="$1" w=48
    echo ""
    if $UI_IS_TTY; then
        ui_box_top "$w"
        ui_box_line "${UI_BOLD}${title}${UI_RESET}" "" "$w"
        ui_box_bottom "$w"
    else
        echo "  $title"
        echo "  $(printf '=%.0s' $(seq 1 ${#title}))"
    fi
    echo ""
}

_ui_step_line() {
    local sym="$1" label="$2" detail="$3"
    local label_plain
    label_plain=$(printf '%s' "$label" | sed 's/\x1b\[[0-9;]*m//g')
    local pad=$((18 - ${#label_plain}))
    [ "$pad" -lt 1 ] && pad=1
    local spaces=""
    for ((i = 0; i < pad; i++)); do spaces+=" "; done
    if $UI_IS_TTY; then
        printf "  %s %s%s%s%s\n" "$sym" "${UI_BOLD}${label}${UI_RESET}" "$spaces" "${UI_DIM}" "$detail${UI_RESET}"
    else
        printf "  %s %-18s %s\n" "$sym" "$label" "$detail"
    fi
}

ui_step_pending() { $UI_IS_TTY && _ui_step_line "$UI_SYM_PENDING" "$1" "—"; true; }
ui_step_active()  { $UI_IS_TTY && _ui_step_line "$UI_SYM_ACTIVE" "$1" "$2"; true; }
ui_step_done()    { _ui_step_line "$UI_SYM_DONE" "$1" "$2"; }
ui_step_fail()    { _ui_step_line "$UI_SYM_FAIL" "$1" "$2"; }

ui_step_replace() {
    local label="$1" detail="$2" sym="${3:-$UI_SYM_DONE}"
    if $UI_IS_TTY; then
        printf "%s%s" "$UI_MOVE_UP" "$UI_CLEAR_LINE"
    fi
    _ui_step_line "$sym" "$label" "$detail"
}

ui_summary() {
    local title="$1" duration="$2" w=48
    shift 2
    echo ""
    if $UI_IS_TTY; then
        ui_box_top "$w"
        ui_box_line "${UI_BOLD}${title}${UI_RESET}" "${UI_DIM}${duration}${UI_RESET}" "$w"
        ui_box_mid "$w"
        for pair in "$@"; do
            local key="${pair%%=*}" val="${pair#*=}"
            ui_box_line "${UI_DIM}${key}${UI_RESET}    ${val}" "" "$w"
        done
        ui_box_bottom "$w"
    else
        echo "  $title ($duration)"
        echo "  $(printf -- '-%.0s' $(seq 1 48))"
        for pair in "$@"; do
            local key="${pair%%=*}" val="${pair#*=}"
            printf "  %-12s %s\n" "$key" "$val"
        done
    fi
}

UI_TIMER_START=""
ui_timer_start() {
    UI_TIMER_START=$(perl -MTime::HiRes=time -e 'printf "%.3f", time' 2>/dev/null || date +%s)
}
ui_timer_elapsed() {
    local now
    now=$(perl -MTime::HiRes=time -e 'printf "%.3f", time' 2>/dev/null || date +%s)
    local elapsed
    elapsed=$(perl -e "printf '%.1f', $now - $UI_TIMER_START" 2>/dev/null || echo "?")
    echo "${elapsed}s"
}

ui_cleanup() { $UI_IS_TTY && printf "%s" "$UI_SHOW_CURSOR"; true; }

fi  # end inline UI

# ─── Ensure cursor restored on exit ─────────────────────────

trap ui_cleanup EXIT

# ─── Prerequisites ───────────────────────────────────────────

MISSING=()
command -v sqlite3 &>/dev/null || MISSING+=("sqlite3")
command -v python3 &>/dev/null || MISSING+=("python3")
command -v jq &>/dev/null || MISSING+=("jq")

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "" >&2
    echo "  ${UI_RED}Missing required:${UI_RESET} ${MISSING[*]}" >&2
    if command -v brew &>/dev/null; then
        echo "  ${UI_DIM}brew install ${MISSING[*]}${UI_RESET}" >&2
    elif command -v apt-get &>/dev/null; then
        echo "  ${UI_DIM}sudo apt-get install ${MISSING[*]}${UI_RESET}" >&2
    elif command -v dnf &>/dev/null; then
        echo "  ${UI_DIM}sudo dnf install ${MISSING[*]}${UI_RESET}" >&2
    else
        echo "  ${UI_DIM}Install via your system package manager.${UI_RESET}" >&2
    fi
    echo "" >&2
    exit 1
fi

if ! sqlite3 :memory: "CREATE VIRTUAL TABLE t USING fts5(c);" ".quit" 2>/dev/null; then
    echo "" >&2
    echo "  ${UI_RED}SQLite FTS5 not available.${UI_RESET}" >&2
    echo "" >&2
    exit 1
fi

# ─── Start ───────────────────────────────────────────────────

ui_timer_start
if $UI_IS_TTY; then printf "%s" "$UI_HIDE_CURSOR"; fi

ui_header "claude-session-search installer"

# Show all steps as pending (TTY only — gives the full roadmap upfront)
ui_step_pending "Symlinks"
ui_step_pending "Settings"
ui_step_pending "Indexing"
ui_step_pending "PATH"

# Move cursor back up 4 lines to overwrite steps in-place
if $UI_IS_TTY; then
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

if $UI_IS_TTY; then
    printf "%s" "$UI_CLEAR_LINE"
fi
ui_step_active "Symlinks" "linking hooks + bin..."

mkdir -p "$HOOKS_DIR" "$HOOKS_LIB" "$BIN_DIR"

symlink_file "$REPO_DIR/hooks/session-index-end.sh" "$HOOKS_DIR/session-index-end.sh"
symlink_file "$REPO_DIR/hooks/session-index-start.sh" "$HOOKS_DIR/session-index-start.sh"
symlink_file "$REPO_DIR/hooks/lib/session-index-helpers.sh" "$HOOKS_LIB/session-index-helpers.sh"
symlink_file "$REPO_DIR/bin/session-search.py" "$BIN_DIR/session-search.py"
symlink_file "$REPO_DIR/bin/claude-search" "$BIN_DIR/claude-search"

chmod +x "$HOOKS_DIR/session-index-end.sh" "$HOOKS_DIR/session-index-start.sh" \
         "$BIN_DIR/claude-search" "$BIN_DIR/session-search.py"

ui_step_replace "Symlinks" "hooks + bin linked"

# ─── Step 2: Settings ───────────────────────────────────────

if $UI_IS_TTY; then
    printf "%s" "$UI_CLEAR_LINE"
fi
ui_step_active "Settings" "patching settings.json..."

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
        ui_step_replace "Settings" "corrupted, restored backup" "$UI_SYM_FAIL"
        echo "  ${UI_RED}settings.json was corrupted during patching. Backup restored.${UI_RESET}" >&2
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

ui_step_replace "Settings" "$SETTINGS_DETAIL"

# ─── Step 3: Indexing ────────────────────────────────────────

if $UI_IS_TTY; then
    printf "%s" "$UI_CLEAR_LINE"
fi
ui_step_active "Indexing" "scanning sessions..."

"$REPO_DIR/scripts/session-index-backfill.sh" --quiet

# Tag with regex (fast, no API needed)
"$REPO_DIR/scripts/session-index-tag.sh" --regex-only --limit 1000 > /dev/null 2>&1 || true

# Rebuild FTS with tags
sqlite3 "$CLAUDE_DIR/session-index.db" "DELETE FROM sessions_fts; INSERT INTO sessions_fts (session_id, summary, first_prompt, tags, keywords, project_name, context_text, assistant_text, files_changed, commands_run) SELECT session_id, summary, first_prompt, tags, keywords, project_name, context_text, assistant_text, files_changed, commands_run FROM sessions;" 2>/dev/null || true

TOTAL=$(sqlite3 "$CLAUDE_DIR/session-index.db" "SELECT COUNT(*) FROM sessions;" 2>/dev/null || echo 0)
TAGGED=$(sqlite3 "$CLAUDE_DIR/session-index.db" "SELECT COUNT(*) FROM sessions WHERE tagged_at IS NOT NULL;" 2>/dev/null || echo 0)

ui_step_replace "Indexing" "${TOTAL} sessions, ${TAGGED} tagged"

# ─── Step 4: PATH ────────────────────────────────────────────

if $UI_IS_TTY; then
    printf "%s" "$UI_CLEAR_LINE"
fi
ui_step_active "PATH" "checking shell config..."

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

ui_step_replace "PATH" "$PATH_DETAIL"

# ─── Summary ────────────────────────────────────────────────

ELAPSED=$(ui_timer_elapsed)

ui_summary "Ready" "$ELAPSED" \
    "Sessions=$TOTAL" \
    "Tagged=$TAGGED" \
    "Search=claude-search \"query\""

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
    if $UI_IS_TTY; then
        printf "  ${UI_DIM}Optional:${UI_RESET}\n"
        for entry in "${OPTIONAL_DEPS[@]}"; do
            cmd="${entry%%=*}"
            desc="${entry#*=}"
            printf "    ${UI_DIM}%-26s %s${UI_RESET}\n" "$cmd" "$desc"
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

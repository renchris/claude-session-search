#!/bin/bash
# Install claude-session-search into ~/.claude/
# One command: symlinks hooks + bin, patches settings.json, backfills index, adds PATH.
# Idempotent: safe to run multiple times.
set -euo pipefail

usage() {
    cat <<'EOF'
Install claude-session-search into ~/.claude/: links for its hooks and commands, its hook entries in
settings.json, the session index, PATH in your shell config and, on macOS, its LaunchAgents. Runs
without prompting and is safe to run again.

Usage: ./install.sh [options]

Options:
  --json             Print one JSON document of outcomes on stdout, and progress on stderr
  --no-color         Print no color
  --non-interactive  Accepted; has no effect yet, because the installer never prompts
  -v, --version      Print the version and exit
  -h, --help         Print this help and exit

Examples:
  ./install.sh
  ./install.sh --json
  ./install.sh --no-color

Exit codes:
  0  Success
  1  A required step failed
  2  Usage error
EOF
}

# Before anything else, so help works with HOME unset or the libraries missing.
for _inst_arg in "$@"; do
    case "$_inst_arg" in
        --) break ;;
        -h | --help)
            usage
            exit 0
            ;;
    esac
done
if [ "${1:-}" = help ]; then
    usage
    exit 0
fi

REPO_DIR="$(CDPATH='' cd "$(dirname "$0")" && pwd)"
# The repo path as a shell word, for the commands printed in recovery text.
printf -v REPO_WORD '%q' "$REPO_DIR"

# Written out by hand: with this file missing there is no error layout to call, and no parser to say
# whether --json was given. Stdout stays empty and the exit code is still 1.
if [ ! -f "$REPO_DIR/scripts/lib/cli-common.sh" ]; then
    printf "Error: Can't load %s. The file is missing.\n\n" "$REPO_DIR/scripts/lib/cli-common.sh" >&2
    printf 'Restore it:\n    git -C %s restore scripts/lib/cli-common.sh\n' "$REPO_WORD" >&2
    exit 1
fi
# shellcheck disable=SC1091 # linted on its own; the gates run shellcheck without -x
source "$REPO_DIR/scripts/lib/cli-common.sh"

# The options from C9 join this table only when C9 ships.
css_parse_args ./install.sh \
    "json||bool|OPT_JSON" \
    "version|v|bool|OPT_VERSION" \
    "no-color||bool|OPT_NO_COLOR" \
    "non-interactive||bool|OPT_NON_INTERACTIVE" \
    -- "$@"

# Printed through printf because jq has not been checked yet.
if [ "$OPT_VERSION" = 1 ]; then
    if [ "$OPT_JSON" = 1 ]; then
        printf '{"version":"%s"}\n' "$(_css_json_escape "$(css_version "$REPO_DIR")")"
    else
        css_version "$REPO_DIR"
    fi
    exit 0
fi

if [ "$OPT_NO_COLOR" = 1 ]; then
    export __SESSION_SEARCH_NO_COLOR=1
fi
if [ "$OPT_NON_INTERACTIVE" = 1 ] || [ "$OPT_JSON" = 1 ]; then
    export __SESSION_SEARCH_NON_INTERACTIVE=1
fi
if [ "$OPT_JSON" = 1 ]; then
    # Every progress line moves to stderr; fd 3 keeps stdout for the one document.
    exec 3>&1 1>&2
fi

# ─── Failure reporting ───────────────────────────────────────

_INST_FAIL_REASON=""
_INST_FAIL_MESSAGE=""
_INST_STEP="startup"
_INST_ROWS_LEFT=0 # roadmap rows still below the cursor; only a terminal draws them

# _inst_fail REASON HEADLINE [INSTRUCTION [COMMAND...]]: css_fail, keeping the reason and headline for
# --json's error line, and with each command cyan on a stderr that takes colour.
_inst_fail() {
    local headline="$2" instruction="${3:-}" coloured="" commands=()
    _INST_FAIL_REASON="$1"
    _INST_FAIL_MESSAGE="$2"
    if [ "$#" -ge 3 ]; then
        shift 3
    else
        shift 2
    fi
    while [ "$#" -gt 0 ]; do
        printf -v coloured '%b%s%b' "${_E_C:-}" "$1" "${_E_R:-}"
        commands+=("$coloured")
        shift
    done
    # Below the remaining roadmap rows, not over them.
    while [ "$_INST_ROWS_LEFT" -gt 0 ]; do
        printf '\n'
        _INST_ROWS_LEFT=$((_INST_ROWS_LEFT - 1))
    done
    css_fail "$headline" "$instruction" ${commands[@]+"${commands[@]}"}
}

# Chains _ui_cleanup rather than replacing it. Any failure under --json ends here, a set -e abort
# included, and gets one error line on stderr.
_inst_on_exit() {
    local rc=$?
    if declare -F _ui_cleanup >/dev/null; then
        _ui_cleanup
    fi
    if [ "$rc" != 0 ] && [ "$OPT_JSON" = 1 ]; then
        css_json_error "${_INST_FAIL_REASON:-install_failed}" \
            "${_INST_FAIL_MESSAGE:-install.sh stopped during $_INST_STEP (exit $rc)}"
    fi
}
trap _inst_on_exit EXIT

# ─── Libraries ───────────────────────────────────────────────

for _inst_lib in progress-ui.sh settings-edit.sh; do
    if [ ! -f "$REPO_DIR/scripts/lib/$_inst_lib" ]; then
        _inst_fail missing_file "Can't load $REPO_DIR/scripts/lib/$_inst_lib. The file is missing." \
            "Restore it" "git -C $REPO_WORD restore scripts/lib/$_inst_lib"
    fi
done
# shellcheck disable=SC1091 # linted on its own; the gates run shellcheck without -x
source "$REPO_DIR/scripts/lib/progress-ui.sh"
# shellcheck disable=SC1091
source "$REPO_DIR/scripts/lib/settings-edit.sh"
# progress-ui.sh set its own EXIT trap, which _inst_on_exit already calls.
trap _inst_on_exit EXIT

# Under --json, stdout is stderr by now and could be a terminal: no redraws, whatever it is.
if [ "$OPT_JSON" = 1 ]; then
    _UI_IS_TTY=false
fi

CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
HOOKS_LIB="$HOOKS_DIR/lib"
BIN_DIR="$CLAUDE_DIR/bin"
SETTINGS="$CLAUDE_DIR/settings.json"
SHELL_RC="$HOME/.zshrc"
[ -f "$SHELL_RC" ] || SHELL_RC="$HOME/.bashrc"

# ─── Installer step helpers (built on shared lib primitives) ─
# The installer uses a "show all pending, then overwrite in-place" UX
# that needs thin wrappers around the shared lib's ANSI variables.

# _inst_step_line STATE LABEL DETAIL, where STATE is done, fail, open (ran, but did not get the job
# done), pending or active. Plain mode says it in words.
_inst_step_line() {
    local state="$1" label="$2" detail="$3" sym=""
    if ! $_UI_IS_TTY; then
        if [ "$state" = fail ]; then
            printf 'Error: %s: %s\n' "$label" "$detail"
        else
            printf '%s: %s\n' "$label" "$detail"
        fi
        return 0
    fi
    case "$state" in
        done) sym="$_UI_SYM_DONE" ;;
        fail) sym="$_UI_SYM_FAIL" ;;
        active) sym="$_UI_SYM_ACTIVE" ;;
        *) sym="$_UI_SYM_PENDING" ;;
    esac
    printf '  %b %b%-18s%b%b%s%b\n' "$sym" "$_B" "$label" "$_R" "$_D" "$detail" "$_R"
}

inst_step_pending() { $_UI_IS_TTY && _inst_step_line pending "$1" "—"; true; }

inst_step_active() {
    _INST_STEP="$1"
    $_UI_IS_TTY && _inst_step_line active "$1" "$2"
    true
}

# inst_step_replace LABEL DETAIL [STATE]
inst_step_replace() {
    local label="$1" detail="$2" state="${3:-done}"
    if $_UI_IS_TTY; then
        printf '%b%b' "$_UP" "$_CL"
    fi
    _inst_step_line "$state" "$label" "$detail"
    if [ "$_INST_ROWS_LEFT" -gt 0 ]; then
        _INST_ROWS_LEFT=$((_INST_ROWS_LEFT - 1))
    fi
}

# _inst_next HEADING [COMMAND...]: one next step after the summary.
_inst_next() {
    printf '%s\n' "$1"
    shift
    while [ "$#" -gt 0 ]; do
        printf '    %b%s%b\n' "$_C" "$1" "$_R"
        shift
    done
    printf '\n'
}

# The install command for this host's package manager, or nothing when none is known.
_inst_package_command() {
    if command -v brew &>/dev/null; then
        printf 'brew install %s' "$*"
    elif command -v apt-get &>/dev/null; then
        printf 'sudo apt-get install %s' "$*"
    elif command -v dnf &>/dev/null; then
        printf 'sudo dnf install %s' "$*"
    fi
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
    PACKAGE_COMMAND="$(_inst_package_command "${MISSING[@]}")"
    if [ -n "$PACKAGE_COMMAND" ]; then
        _inst_fail missing_dependency "Can't install. Missing ${MISSING[*]}." \
            "Install it, then re-run" "$PACKAGE_COMMAND" "$REPO_WORD/install.sh"
    fi
    _inst_fail missing_dependency "Can't install. Missing ${MISSING[*]}." \
        "Install it with your system package manager, then re-run" "$REPO_WORD/install.sh"
fi

if ! FTS5_ERROR="$(sqlite3 :memory: "CREATE VIRTUAL TABLE t USING fts5(c);" ".quit" 2>&1)"; then
    FTS5_HEADLINE="Can't create an FTS5 table with $(command -v sqlite3)."$'\n'"    $FTS5_ERROR"
    if command -v brew &>/dev/null; then
        _inst_fail sqlite_without_fts5 "$FTS5_HEADLINE" \
            "Install a SQLite with FTS5, then re-run with it first on PATH" \
            "brew install sqlite" "PATH=\"\$(brew --prefix sqlite)/bin:\$PATH\" $REPO_WORD/install.sh"
    fi
    _inst_fail sqlite_without_fts5 "$FTS5_HEADLINE" \
        "Install a SQLite with FTS5, put it first on PATH, then re-run" "$REPO_WORD/install.sh"
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
inst_step_pending "Scheduler"

# Move cursor back up 5 lines to overwrite steps in-place
ui_cursor_up 5
if $_UI_IS_TTY; then
    _INST_ROWS_LEFT=5
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
symlink_file "$REPO_DIR/hooks/session-index-sweep.sh" "$HOOKS_DIR/session-index-sweep.sh"
symlink_file "$REPO_DIR/hooks/lib/session-index-helpers.sh" "$HOOKS_LIB/session-index-helpers.sh"
symlink_file "$REPO_DIR/bin/session-search.py" "$BIN_DIR/session-search.py"
symlink_file "$REPO_DIR/bin/claude-search" "$BIN_DIR/claude-search"
symlink_file "$REPO_DIR/scripts/session-index-tag.py" "$BIN_DIR/session-index-tag.py"
symlink_file "$REPO_DIR/scripts/session-index-backfill.sh" "$BIN_DIR/session-index-backfill.sh"
symlink_file "$REPO_DIR/scripts/session-index-chunk.py" "$BIN_DIR/session-index-chunk.py"

chmod +x "$HOOKS_DIR/session-index-end.sh" "$HOOKS_DIR/session-index-start.sh" \
         "$HOOKS_DIR/session-index-sweep.sh" \
         "$BIN_DIR/claude-search" "$BIN_DIR/session-search.py" \
         "$REPO_DIR/scripts/session-index-tag.py" \
         "$REPO_DIR/scripts/session-index-backfill.sh" \
         "$REPO_DIR/scripts/session-index-chunk.py" 2>/dev/null || true

# Pre-compile Python for faster startup
python3 -m compileall -q "$BIN_DIR/session-search.py" 2>/dev/null || true

inst_step_replace "Symlinks" "hooks + bin linked"

# ─── Step 2: Settings ───────────────────────────────────────

$_UI_IS_TTY && printf '%b' "$_CL"
inst_step_active "Settings" "patching settings.json..."

# The first path in the hook entries this installer reads or writes whose value has the wrong type.
# A wrong type elsewhere in the file is not this installer's to judge.
# shellcheck disable=SC2016 # jq's own variables
SETTINGS_SHAPE_FILTER='
def need($path; $want):
    if type == $want or type == "null" then empty
    else "\($path) should be of type \($want), found \(type)" end;
def check_hook($path):
    need($path; "object"),
    (objects | .command | need("\($path).command"; "string"));
def check_entry($path):
    need($path; "object"),
    (objects | .hooks | need("\($path).hooks"; "array"),
        (arrays | to_entries[] | .key as $i | .value | check_hook("\($path).hooks[\($i)]")));
def check_event($path):
    need($path; "array"),
    (arrays | to_entries[] | .key as $i | .value | check_entry("\($path)[\($i)]"));
first(
    (.hooks | need(".hooks"; "object")),
    (.hooks | objects | ("SessionEnd", "SessionStart") as $event | .[$event]
        | check_event(".hooks.\($event)"))
)'

# Tolerates a hook with no command: a plain select on .command fails on one, which read as "not
# registered" and appended a duplicate on every run.
# shellcheck disable=SC2016 # jq's own variables
SETTINGS_HOOK_DEFS='
def has_hook($event; $name):
    any((.hooks[$event] // [])[] | (.hooks // [])[]; (.command // "") | test($name));
def ensure_hook($event; $name; $timeout):
    if has_hook($event; $name) then .
    else .hooks[$event] = ((.hooks[$event] // []) + [{
        "hooks": [{"type": "command", "command": "~/.claude/hooks/\($name).sh", "timeout": $timeout}]
    }]) end;
'
SETTINGS_ALL_REGISTERED="$SETTINGS_HOOK_DEFS"'
has_hook("SessionEnd"; "session-index-end") and has_hook("SessionStart"; "session-index-start")'
SETTINGS_ADD_HOOKS="$SETTINGS_HOOK_DEFS"'
ensure_hook("SessionEnd"; "session-index-end"; 10) | ensure_hook("SessionStart"; "session-index-start"; 5)'

SETTINGS_DETAIL=""
SETTINGS_STATE="done"
SETTINGS_MISSING=false
SETTINGS_BACKUP=""
if [ -f "$SETTINGS" ]; then
    # Before any backup: a broken file must not overwrite a good copy of itself.
    if ! SETTINGS_WHY="$(css_settings_validate "$SETTINGS" 2>&1)"; then
        inst_step_replace "Settings" "not changed" fail
        case "$SETTINGS_WHY" in
            *"expected one JSON object")
                _inst_fail invalid_settings "settings.json is not one JSON object: $SETTINGS_WHY" \
                    "Fix the file, then re-run ./install.sh. The file was not changed."
                ;;
        esac
        _inst_fail invalid_settings "settings.json is not valid JSON: $SETTINGS_WHY" \
            "Fix that line, then re-run ./install.sh. The file was not changed."
    fi

    if ! SETTINGS_WHY="$(jq -r "$SETTINGS_SHAPE_FILTER" "$SETTINGS" 2>&1)"; then
        inst_step_replace "Settings" "not changed" fail
        _inst_fail invalid_settings "Can't read settings.json: $SETTINGS: $SETTINGS_WHY" \
            "Fix the file, then re-run ./install.sh. The file was not changed."
    fi
    if [ -n "$SETTINGS_WHY" ]; then
        inst_step_replace "Settings" "not changed" fail
        _inst_fail invalid_settings "settings.json has the wrong shape: $SETTINGS: $SETTINGS_WHY" \
            "Fix that key, then re-run ./install.sh. The file was not changed."
    fi

    # jq -e: 0 true, 1 false, anything higher is an error of its own, which stays visible.
    SETTINGS_PROBE=0
    jq -e "$SETTINGS_ALL_REGISTERED" "$SETTINGS" >/dev/null || SETTINGS_PROBE=$?
    case "$SETTINGS_PROBE" in
        0)
            SETTINGS_DETAIL="hooks already registered"
            ;;
        1)
            SETTINGS_ERR="$(mktemp)"
            if ! css_settings_patch "$SETTINGS" "$SETTINGS_ADD_HOOKS" 2>"$SETTINGS_ERR"; then
                SETTINGS_WHY="$(cat "$SETTINGS_ERR")"
                rm -f "$SETTINGS_ERR"
                inst_step_replace "Settings" "not changed" fail
                _inst_fail settings_patch_failed "Can't patch settings.json: $SETTINGS_WHY" \
                    "The file was not changed. Clear the cause, then re-run" "$REPO_WORD/install.sh"
            fi
            rm -f "$SETTINGS_ERR"
            SETTINGS_BACKUP="$CSS_SETTINGS_BACKUP"
            SETTINGS_DETAIL="hooks registered in settings.json"
            ;;
        *)
            inst_step_replace "Settings" "not changed" fail
            _inst_fail invalid_settings "Can't read settings.json: $SETTINGS (jq exit $SETTINGS_PROBE)" \
                "Fix the file, then re-run ./install.sh. The file was not changed."
            ;;
    esac
else
    SETTINGS_DETAIL="no settings.json, hooks not registered"
    SETTINGS_STATE=open
    SETTINGS_MISSING=true
fi

inst_step_replace "Settings" "$SETTINGS_DETAIL" "$SETTINGS_STATE"

# ─── Step 3: Indexing ────────────────────────────────────────

$_UI_IS_TTY && printf '%b' "$_CL"
inst_step_active "Indexing" "scanning sessions..."

"$REPO_DIR/scripts/session-index-backfill.sh" --quiet

# Tag with regex (fast, no API needed)
python3 "$REPO_DIR/scripts/session-index-tag.py" --regex-only --limit 1000 --quiet 2>/dev/null || true

# Rebuild FTS with tags. Kept here: it repairs a non-fatal tag.py FTS failure that would otherwise wait
# for the weekly job. A subshell because the helpers are not meant to stay sourced in this script; the
# helpers own the column list.
FTS_NOTE=""
INDEX_STATE="done"
# shellcheck disable=SC1091 # linted on its own; the gates run shellcheck without -x
if ! ( source "$REPO_DIR/hooks/lib/session-index-helpers.sh" && session_index_rebuild_fts ) >/dev/null; then
    FTS_NOTE=" (search index rebuild failed; rerun scripts/session-index-backfill.sh)"
    INDEX_STATE=open
fi

TOTAL=$(sqlite3 "$CLAUDE_DIR/session-index.db" "SELECT COUNT(*) FROM sessions;" 2>/dev/null || echo 0)
TAGGED=$(sqlite3 "$CLAUDE_DIR/session-index.db" "SELECT COUNT(*) FROM sessions WHERE tagged_at IS NOT NULL;" 2>/dev/null || echo 0)

inst_step_replace "Indexing" "${TOTAL} sessions, ${TAGGED} tagged${FTS_NOTE}" "$INDEX_STATE"

# ─── Step 4: PATH ────────────────────────────────────────────

$_UI_IS_TTY && printf '%b' "$_CL"
inst_step_active "PATH" "checking shell config..."

PATH_LINE='export PATH="$HOME/.claude/bin:$PATH"'
PATH_DETAIL=""
PATH_STATE="done"
SHELL_RC_MISSING=false
if [ ! -f "$SHELL_RC" ]; then
    # Not created here: SHELL_RC falls back to .bashrc even for a zsh user.
    PATH_DETAIL="no shell config found"
    PATH_STATE=open
    SHELL_RC_MISSING=true
elif ! grep -qF '.claude/bin' "$SHELL_RC" 2>/dev/null; then
    echo "" >> "$SHELL_RC"
    echo "# claude-session-search" >> "$SHELL_RC"
    echo "$PATH_LINE" >> "$SHELL_RC"
    PATH_DETAIL="added to $(basename "$SHELL_RC")"
else
    PATH_DETAIL="already in $(basename "$SHELL_RC")"
fi

inst_step_replace "PATH" "$PATH_DETAIL" "$PATH_STATE"

# ─── Step 5: Scheduled Jobs ───────────────────────────────
PLIST_SRC="$REPO_DIR/config/com.claude.session-search-backfill.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.claude.session-search-backfill.plist"
SWEEP_PLIST_SRC="$REPO_DIR/config/com.claude.session-search-sweep.plist"
SWEEP_PLIST_DST="$HOME/Library/LaunchAgents/com.claude.session-search-sweep.plist"

$_UI_IS_TTY && printf '%b' "$_CL"
inst_step_active "Scheduler" "registering scheduled jobs..."

SCHED_DETAIL=""

# _inst_scheduler_fail HEADLINE: everything before this step has applied, so say so and how to retry.
_inst_scheduler_fail() {
    local applied="Symlinks, settings, the index and PATH are done"
    if [ -n "$SCHED_DETAIL" ]; then
        applied="$applied, and so is the $SCHED_DETAIL job"
    fi
    inst_step_replace "Scheduler" "failed" fail
    _inst_fail scheduler_failed "$1" "$applied. Clear the cause, then re-run" "$REPO_WORD/install.sh"
}

# _inst_install_plist SRC DST
_inst_install_plist() {
    local why
    launchctl unload "$2" 2>/dev/null || true
    if ! why="$(cp "$1" "$2" 2>&1)"; then
        _inst_scheduler_fail "Can't copy the scheduled job to $2. It stays unloaded until a re-run succeeds."$'\n'"    $why"
    fi
    launchctl load "$2" 2>/dev/null || true
}

SCHED_RESULT=""
SCHED_STATE="done"
SCHED_UNSUPPORTED=false
if [ "$(uname -s)" != Darwin ]; then
    SCHED_RESULT="skipped: launchd is macOS-only"
    SCHED_STATE=open
    SCHED_UNSUPPORTED=true
else
    if ! SCHED_WHY="$(mkdir -p "$HOME/Library/LaunchAgents" 2>&1)"; then
        _inst_scheduler_fail "Can't create $HOME/Library/LaunchAgents."$'\n'"    $SCHED_WHY"
    fi

    if [ -f "$PLIST_SRC" ]; then
        _inst_install_plist "$PLIST_SRC" "$PLIST_DST"
        SCHED_DETAIL="backfill"
    fi

    if [ -f "$SWEEP_PLIST_SRC" ]; then
        _inst_install_plist "$SWEEP_PLIST_SRC" "$SWEEP_PLIST_DST"
        [ -n "$SCHED_DETAIL" ] && SCHED_DETAIL="$SCHED_DETAIL + "
        SCHED_DETAIL="${SCHED_DETAIL}sweep (60s)"
    fi

    if [ -n "$SCHED_DETAIL" ]; then
        SCHED_RESULT="$SCHED_DETAIL registered"
    else
        SCHED_RESULT="plist not found, skipped"
        SCHED_STATE=open
    fi
fi

inst_step_replace "Scheduler" "$SCHED_RESULT" "$SCHED_STATE"

# ─── Summary ────────────────────────────────────────────────

ELAPSED="$(inst_timer_elapsed)s"

ui_summary "Installed" "$ELAPSED" \
    "Sessions" "$TOTAL" \
    "Tagged" "$TAGGED"

# ─── Recovery ───────────────────────────────────────────────
# After the summary, because the terminal's roadmap redraws in place until then.

if [ -n "$SETTINGS_BACKUP" ]; then
    _inst_next "jq reformatted settings.json when it added the hooks. The previous copy: $SETTINGS_BACKUP"
fi
if $SETTINGS_MISSING; then
    _inst_next "Hooks aren't registered. Create settings.json, then rerun:" \
        "printf '{}\n' > ~/.claude/settings.json" "$REPO_WORD/install.sh"
fi
if $SHELL_RC_MISSING; then
    _inst_next "No ~/.zshrc or ~/.bashrc found. To keep claude-search on PATH, add this line to your shell config:" \
        "$PATH_LINE"
fi
if $SCHED_UNSUPPORTED; then
    # shellcheck disable=SC2088 # printed for the user's shell to expand
    _inst_next "The sweep and weekly backfill are not scheduled. To run the backfill by hand:" \
        "~/.claude/bin/session-index-backfill.sh --quiet"
fi

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
    # No `=` before the description: the loop below splits on the first one.
    FZF_COMMAND="$(_inst_package_command fzf)"
    OPTIONAL_DEPS+=("${FZF_COMMAND:-fzf from your package manager}=interactive mode (--fzf)")
fi

if [ ${#OPTIONAL_DEPS[@]} -gt 0 ]; then
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
    echo ""
fi

# ─── Next Steps ─────────────────────────────────────────────

# Whether this shell can find the command, not whether this run edited a config: a rerun in the same
# old shell finds the line already in the file and the command still missing.
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) _inst_next "Add claude-search to this shell:" "$PATH_LINE" ;;
esac
_inst_next "Search your sessions:" "claude-search <QUERY>"

# ─── Machine Output ─────────────────────────────────────────

if [ "$OPT_JSON" = 1 ]; then
    jq -cn --arg sessions "$TOTAL" --arg tagged "$TAGGED" --arg settings "$SETTINGS_DETAIL" \
        --arg path "$PATH_DETAIL" --arg scheduler "$SCHED_RESULT" --arg claude_dir "$CLAUDE_DIR" \
        '{installation: {sessions: ($sessions | tonumber? // 0), tagged: ($tagged | tonumber? // 0),
          settings: $settings, path: $path, scheduler: $scheduler, claude_dir: $claude_dir},
          outcome: "installed"}' >&3
fi

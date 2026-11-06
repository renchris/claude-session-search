#!/bin/bash
# Uninstall claude-session-search from ~/.claude/
# Removes symlinks and hook entries. Leaves DB intact.
set -euo pipefail

usage() {
    cat <<'EOF'
Remove claude-session-search from ~/.claude/: its links, its hook entries in settings.json and its
LaunchAgents. session-index.db stays. Runs without prompting; ./install.sh puts everything back.

Usage: ./uninstall.sh [options]

Options:
  --dry-run          Print the plan and change nothing
  --json             Print one JSON document of outcomes on stdout, and progress on stderr
  --no-color         Print no color (the output has none today)
  --non-interactive  Never prompt (it never does today)
  -v, --version      Print the version and exit
  -h, --help         Print this help and exit

Examples:
  ./uninstall.sh --dry-run
  ./uninstall.sh
  ./uninstall.sh --json

Exit codes:
  0  Success
  1  settings.json could not be edited, or another step failed
  2  Usage error
EOF
}

# Before anything else, so help works with HOME unset or the libraries missing.
for arg in "$@"; do
    case "$arg" in
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
for lib in cli-common.sh settings-edit.sh; do
    if [ ! -f "$REPO_DIR/scripts/lib/$lib" ]; then
        echo "error: missing $REPO_DIR/scripts/lib/$lib" >&2
        echo "  Re-clone the repo or restore the file." >&2
        exit 1
    fi
done
# shellcheck disable=SC1091 # linted on their own; the gates run shellcheck without -x
. "$REPO_DIR/scripts/lib/cli-common.sh"
# shellcheck disable=SC1091
. "$REPO_DIR/scripts/lib/settings-edit.sh"

css_parse_args ./uninstall.sh \
    "dry-run||bool|OPT_DRY_RUN" \
    "json||bool|OPT_JSON" \
    "version|v|bool|OPT_VERSION" \
    "no-color||bool|OPT_NO_COLOR" \
    "non-interactive||bool|OPT_NON_INTERACTIVE" \
    -- "$@"

if [ "$OPT_NO_COLOR" = 1 ]; then
    export __SESSION_SEARCH_NO_COLOR=1
fi
if [ "$OPT_NON_INTERACTIVE" = 1 ] || [ "$OPT_JSON" = 1 ]; then
    export __SESSION_SEARCH_NON_INTERACTIVE=1
fi

if [ "$OPT_VERSION" = 1 ]; then
    if [ "$OPT_JSON" = 1 ]; then
        printf '{"version":"%s"}\n' "$(_css_json_escape "$(css_version "$REPO_DIR")")"
    else
        css_version "$REPO_DIR"
    fi
    exit 0
fi

if [ "$OPT_JSON" = 1 ]; then
    if ! command -v jq >/dev/null 2>&1; then
        css_json_error missing_dependency "--json needs jq, and jq was not found"
        exit 1
    fi
    # Every progress line moves to stderr; fd 3 keeps stdout for the one document.
    exec 3>&1 1>&2
fi

CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
BIN_DIR="$CLAUDE_DIR/bin"
SETTINGS="$CLAUDE_DIR/settings.json"
DB="$CLAUDE_DIR/session-index.db"
BACKFILL_PLIST="$HOME/Library/LaunchAgents/com.claude.session-search-backfill.plist"
SWEEP_PLIST="$HOME/Library/LaunchAgents/com.claude.session-search-sweep.plist"
PYC_PATTERN="$BIN_DIR/__pycache__/session-search.*.pyc"

HOOK_LINKS=(
    "$HOOKS_DIR/session-index-end.sh"
    "$HOOKS_DIR/session-index-start.sh"
    "$HOOKS_DIR/session-index-sweep.sh"
    "$HOOKS_DIR/lib/session-index-helpers.sh"
)
BIN_LINKS=(
    "$BIN_DIR/session-search.py"
    "$BIN_DIR/claude-search"
    "$BIN_DIR/session-index-tag.py"
    "$BIN_DIR/session-index-backfill.sh"
    "$BIN_DIR/session-index-chunk.py"
)

# Both filters read the same entries, and neither one creates a key or trips on a commandless hook.
# shellcheck disable=SC2016 # $k and $p are jq's
HOOKS_PRESENT_FILTER='def hit($k;$p): [.hooks? | objects | .[$k]? | arrays | .[] | objects | .hooks? | arrays | .[] | .command? | strings | select(test($p))] | length > 0; hit("SessionEnd";"session-index-end") or hit("SessionStart";"session-index-start")'
# shellcheck disable=SC2016
STRIP_HOOKS_FILTER='def strip($k;$p): if (.hooks?|type)=="object" and (.hooks[$k]|type)=="array" then .hooks[$k] |= map(if type=="object" and (.hooks|type)=="array" then (.hooks |= map(select((((.command?)|strings|test($p))//false)|not))) | select(.hooks|length>0) else . end) else . end; strip("SessionEnd";"session-index-end") | strip("SessionStart";"session-index-start")'

# ─── Outcomes (--json) ───────────────────────────────────

ROWS=()

# record ID OUTCOME [ERROR]: one row of the document.
record() {
    if [ "$OPT_JSON" = 1 ]; then
        ROWS+=("$(jq -cn --arg id "$1" --arg outcome "$2" --arg error "${3:-}" \
            '{id: $id, outcome: $outcome} + (if $error == "" then {} else {error: $error} end)')")
    fi
}

emit_document() {
    if [ "$OPT_JSON" = 1 ]; then
        printf '%s\n' "${ROWS[@]}" | jq -cs --argjson dry "$OPT_DRY_RUN" '
            def n(f): map(select(f)) | length;
            {
                results: .,
                summary: ({
                    succeeded: n(.outcome == "removed"),
                    failed: n(.outcome == "failed"),
                    skipped: n(.outcome == "skipped" or .outcome == "not_found"),
                    unknown: 0
                } + (if $dry == 1 then {planned: n(.outcome == "planned")} else {} end))
            } + (if $dry == 1 then {dry_run: true} else {} end)
        ' >&3
    fi
}

# ─── Plan ────────────────────────────────────────────────

# Sets STATE for settings.json: absent, no_jq, invalid, clean (nothing to remove) or edit. Only reads.
settings_state() {
    if [ ! -f "$SETTINGS" ]; then
        STATE=absent
    elif ! command -v jq >/dev/null 2>&1; then
        STATE=no_jq
    elif ! css_settings_validate "$SETTINGS" 2>/dev/null; then
        STATE=invalid
    elif jq -e "$HOOKS_PRESENT_FILTER" "$SETTINGS" >/dev/null 2>&1; then
        STATE=edit
    else
        STATE=clean
    fi
}

pyc_present() {
    local file
    for file in "$BIN_DIR/__pycache__"/session-search.*.pyc; do
        if [ -f "$file" ]; then
            return 0
        fi
    done
    return 1
}

# plan_row ACTION TARGET [NOTE] [OUTCOME [ERROR]]: one plan line, and on a dry run the row it stands for.
plan_row() {
    printf '  %-6s %s%s\n' "$1" "$2" "${3:+ ($3)}"
    if [ "$OPT_DRY_RUN" = 1 ]; then
        record "$2" "${4:-}" "${5:-}"
    fi
}

plan_link() {
    if [ -L "$1" ]; then
        plan_row remove "$1" "" planned
    elif [ -e "$1" ]; then
        plan_row skip "$1" "not a symlink" skipped
    else
        plan_row absent "$1" "" not_found
    fi
}

plan_plist() {
    if [ -f "$1" ]; then
        plan_row remove "$1" "unload and delete" planned
    else
        plan_row absent "$1" "" not_found
    fi
}

print_plan() {
    local path
    echo "Plan:"
    for path in "${HOOK_LINKS[@]}" "${BIN_LINKS[@]}"; do
        plan_link "$path"
    done
    if pyc_present; then
        plan_row remove "$PYC_PATTERN" "" planned
    else
        plan_row absent "$PYC_PATTERN" "" not_found
    fi
    settings_state
    case "$STATE" in
        edit) plan_row edit "$SETTINGS" "remove hook entries, keep a backup" planned ;;
        clean) plan_row skip "$SETTINGS" "no hook entries" not_found ;;
        invalid) plan_row skip "$SETTINGS" "not valid JSON, left unchanged" skipped "not valid JSON" ;;
        no_jq) plan_row skip "$SETTINGS" "jq not found, left unchanged" skipped "jq not found" ;;
        *) plan_row absent "$SETTINGS" "" not_found ;;
    esac
    plan_plist "$BACKFILL_PLIST"
    plan_plist "$SWEEP_PLIST"
    if [ -e "$DB" ]; then
        plan_row keep "$DB" "" skipped
    else
        plan_row absent "$DB" "" not_found
    fi
}

if [ "$OPT_DRY_RUN" = 1 ]; then
    print_plan
    echo "Dry run: nothing changed."
    emit_document
    exit 0
fi

print_plan >&2

echo "Uninstalling claude-session-search..."

status=0
fix_hint="fix $SETTINGS"

# ─── Remove Symlinks ─────────────────────────────────────

remove_symlink() {
    local path="$1"
    if [ -L "$path" ]; then
        rm "$path"
        echo "  ✓ Removed $path"
        record "$path" removed
    elif [ -e "$path" ]; then
        echo "  ⚠ $path is not a symlink, skipping"
        record "$path" skipped
    else
        echo "  - $path (not found)"
        record "$path" not_found
    fi
}

# install.sh compiles session-search.py next to its link, so these go with it.
remove_pyc() {
    local file
    if pyc_present; then
        for file in "$BIN_DIR/__pycache__"/session-search.*.pyc; do
            if [ -f "$file" ]; then
                rm -f "$file"
            fi
        done
        echo "  ✓ Removed $PYC_PATTERN"
        record "$PYC_PATTERN" removed
    else
        echo "  - $PYC_PATTERN (not found)"
        record "$PYC_PATTERN" not_found
    fi
}

echo "Hooks:"
for path in "${HOOK_LINKS[@]}"; do
    remove_symlink "$path"
done

echo ""
echo "Bin:"
for path in "${BIN_LINKS[@]}"; do
    remove_symlink "$path"
done
remove_pyc

# ─── Remove Hook Entries from settings.json ───────────────

echo ""
echo "Settings:"

settings_state
case "$STATE" in
    absent)
        echo "  - settings.json not found"
        record "$SETTINGS" not_found
        ;;
    clean)
        echo "  - no hook entries in settings.json"
        record "$SETTINGS" not_found
        ;;
    no_jq)
        echo "ERROR: jq not found, so $SETTINGS was left unchanged" >&2
        status=1
        fix_hint="install jq"
        record "$SETTINGS" failed "jq not found"
        ;;
    invalid)
        # Says why, with jq's line and column. Not fatal: the LaunchAgents still have to go.
        css_settings_validate "$SETTINGS" || true
        echo "ERROR: $SETTINGS is not valid JSON; left unchanged" >&2
        status=1
        record "$SETTINGS" failed "not valid JSON"
        ;;
    *)
        if ! css_settings_patch "$SETTINGS" "$STRIP_HOOKS_FILTER"; then
            echo "ERROR: could not edit $SETTINGS; left unchanged" >&2
            status=1
            record "$SETTINGS" failed "could not edit"
        elif [ -n "$CSS_SETTINGS_BACKUP" ]; then
            echo "  Backup: $CSS_SETTINGS_BACKUP"
            echo "  ✓ Hook entries removed from settings.json"
            record "$SETTINGS" removed
        else
            # Another writer removed them after the check above.
            echo "  - no hook entries in settings.json"
            record "$SETTINGS" not_found
        fi
        ;;
esac

# ─── Unload LaunchAgents ──────────────────────────────────

remove_plist() {
    local path="$1" label="$2"
    if [ -f "$path" ]; then
        launchctl unload "$path" 2>/dev/null || true
        rm "$path"
        echo "  ✓ Removed $label plist"
        record "$path" removed
    else
        echo "  - $label plist (not found)"
        record "$path" not_found
    fi
}

echo ""
echo "LaunchAgents:"

remove_plist "$BACKFILL_PLIST" backfill
remove_plist "$SWEEP_PLIST" sweep

if [ -e "$DB" ]; then
    record "$DB" skipped
else
    record "$DB" not_found
fi

echo ""
echo "────────────────────────────────────────────"
if [ "$status" = 0 ]; then
    echo "Uninstall complete."
else
    echo "Uninstall incomplete: $fix_hint, then re-run ./uninstall.sh" >&2
fi
echo ""
echo "Database preserved at: $DB"
echo "To delete it:"
printf '  rm -f %q %q %q\n' "$DB" "$DB-wal" "$DB-shm"
echo "────────────────────────────────────────────"

emit_document
exit "$status"

#!/usr/bin/env bats
# scripts/lib/progress-ui.sh. Every case runs through $LIB, a #!/bin/bash strict-mode script like the
# two that source this library, so on macOS it proves bash 3.2 whatever bash runs bats.
#
# shellcheck disable=SC2016,SC2030,SC2031 # snippets expand in $LIB; bats's $output is per test

load helpers_scripts

ESC=$'\033'

# Every row that draws on a terminal, cursor moves included.
ALL_ROWS='ui_header T D; ui_cursor_hide; ui_cursor_up 2
    ui_phase_pending P; ui_phase_active P 1 2 0; ui_phase_active_simple P d 0
    ui_phase_done P d 0; ui_phase_skip P r; ui_item_ok abc d; ui_item_fail abc r
    ui_summary T 1s K "1 v"; ui_cursor_show'

setup() {
    script_sandbox_setup
    LIB="$BATS_TEST_TMPDIR/lib-run"
    cat >"$LIB" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
. "$REPO/scripts/lib/progress-ui.sh"
snippet="$1"
shift
eval "$snippet"
SCRIPT
    chmod +x "$LIB"
}
teardown() { sandbox_teardown; }

# has <text>: $output contains text. A helper rather than [[ ]], which bash 3.2's set -e ignores.
has() {
    case "$output" in
        *"$1"*) ;;
        *)
            echo "has: no [$1] in: $output" >&2
            return 1
            ;;
    esac
}

# lacks <text>: $output does not contain text.
lacks() {
    case "$output" in
        *"$1"*)
            echo "lacks: found [$1] in: $output" >&2
            return 1
            ;;
    esac
}

# Colour and weight are the SGR codes, which all end in m.
lacks_sgr() {
    local sgr="${ESC}\\[[0-9;]*m"
    if [[ "$output" =~ $sgr ]]; then
        echo "lacks_sgr: colour left in: $output" >&2
        return 1
    fi
}

# matches <regex> <text>
matches() {
    if ! [[ "$2" =~ $1 ]]; then
        echo "matches: [$2] is not [$1]" >&2
        return 1
    fi
}

@test "a rich terminal gets both colour and cursor control" {
    run run_in_pty "$LIB" "$ALL_ROWS"
    [ "$status" -eq 0 ]
    has "${ESC}[32m"
    has "${ESC}[?25l"
    has "${ESC}[2A"
    has "╭"
}

@test "NO_COLOR drops colour but keeps cursor control on a TTY" {
    local off
    for off in "NO_COLOR=1" "__SESSION_SEARCH_NO_COLOR=1" "FORCE_COLOR=0"; do
        run run_in_pty env "$off" "$LIB" "$ALL_ROWS"
        [ "$status" -eq 0 ]
        lacks_sgr
        # Glyphs, layout and redraw stay (R207).
        has "${ESC}[?25l"
        has "${ESC}[?25h"
        has "${ESC}[K"
        has "${ESC}[2A"
        has "╭"
        has "✓"
    done
}

@test "TERM=dumb drops both" {
    run run_in_pty env TERM=dumb "$LIB" "$ALL_ROWS"
    [ "$status" -eq 0 ]
    assert_no_ansi
    lacks "╭"
    has "P: done, d ("
}

@test "accessible mode on a terminal gets plain words and no redraw" {
    run run_in_pty env SESSION_SEARCH_ACCESSIBLE=1 "$LIB" "$ALL_ROWS"
    [ "$status" -eq 0 ]
    assert_no_ansi
    lacks "╭"
    lacks "◐"
    lacks "✓"
    has "P: done, d ("
    has "Error: abc: r"
    # Only the value 1 turns it on, as in cli-common.sh.
    run run_in_pty env SESSION_SEARCH_ACCESSIBLE=0 "$LIB" "$ALL_ROWS"
    [ "$status" -eq 0 ]
    has "╭"
}

@test "FORCE_COLOR on a pipe adds no cursor codes" {
    run env FORCE_COLOR=1 "$LIB" 'printf "[%s]\n" "$_G"; '"$ALL_ROWS"
    [ "$status" -eq 0 ]
    # The colour decision did go on, or the checks below prove nothing.
    [ "${lines[0]}" = '[\033[32m]' ]
    assert_no_ansi
    lacks "╭"
    has "P: done, d ("
}

@test "each stream decides its own colour" {
    local show='printf "out[%s] err[%s]\n" "$_C" "$_E_C"'
    local src='. "$REPO/scripts/lib/progress-ui.sh"'
    run run_in_pty /bin/bash -c "$src; $show"
    has 'out[\033[36m] err[\033[36m]'
    # Sourced with one stream away from the terminal, then printed to the terminal.
    run run_in_pty /bin/bash -c "$src >/dev/null; $show"
    has 'out[] err[\033[36m]'
    run run_in_pty /bin/bash -c "$src 2>/dev/null; $show"
    has 'out[\033[36m] err[]'
}

@test "plain rows carry no glyph and start at column 0" {
    run "$LIB" 'ui_header "Session Index Backfill" "4 existing"
        ui_phase_done "Phase 1" "3 indexed" 0
        ui_phase_skip "Phase 2" "no entries"
        ui_phase_skip "Phase 3"
        ui_item_ok abcdefghijkl "a title" extra
        ui_item_fail abcdefghijkl "no transcript"
        ui_summary "Backfill Complete" 2s Sessions "4 total"'
    [ "$status" -eq 0 ]
    # run drops the blank lines around the header and the summary from $lines.
    [ "${lines[0]}" = "Session Index Backfill  4 existing" ]
    matches '^Phase 1: done, 3 indexed \([0-9.]+s\)$' "${lines[1]}"
    [ "${lines[2]}" = "Phase 2: skipped (no entries)" ]
    [ "${lines[3]}" = "Phase 3: skipped" ]
    [ "${lines[4]}" = "abcdefgh: ok, a title" ]
    [ "${lines[5]}" = "Error: abcdefgh: no transcript" ]
    [ "${lines[6]}" = "Backfill Complete  2s" ]
    [ "${lines[7]}" = "Sessions: 4 total" ]
}

@test "rich rows keep their glyphs" {
    run run_in_pty "$LIB" 'ui_phase_done D d 0; ui_phase_skip S; ui_item_ok abc d; ui_item_fail xyz r'
    [ "$status" -eq 0 ]
    has "✓ d"
    has "○ S  skipped"
    has "${ESC}[32m✓${ESC}[0m ${ESC}[36mabc"
    has "${ESC}[31m✗${ESC}[0m ${ESC}[2mxyz"
}

@test "one line per row" {
    local row
    for row in 'ui_phase_done L d 0' 'ui_phase_skip L r' 'ui_item_ok abc d' 'ui_item_fail abc r'; do
        run "$LIB" "$row"
        [ "$status" -eq 0 ]
        [ "${#lines[@]}" -eq 1 ] || { echo "$row: $output" >&2; return 1; }
    done
}

@test "100 ui_phase_active calls print one line" {
    run "$LIB" '_UI_PHASE_LINES=true
        for ((i = 1; i <= 100; i++)); do ui_phase_active "Phase 1" "$i" 100 0; done
        ui_phase_active_simple "Phase 6" "loading" 0
        ui_phase_active_simple "Phase 6" "rebuilding" 0'
    [ "$status" -eq 0 ]
    [ "$output" = $'Phase 1: started\nPhase 6: started' ]
}

@test "quiet leaves phase lines off" {
    run "$LIB" 'for ((i = 1; i <= 100; i++)); do ui_phase_active "Phase 1" "$i" 100 0; done
        ui_phase_active_simple "Phase 6" "loading" 0'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "phase lines stay out of a terminal's redraw" {
    run run_in_pty "$LIB" '_UI_PHASE_LINES=true; ui_phase_active "Phase 1" 1 2 0'
    [ "$status" -eq 0 ]
    lacks "started"
    has "◐"
}

@test "captured helpers keep printing to stdout" {
    run --separate-stderr "$LIB" 'printf "%s|%s|%s|%s\n" "$(_ui_spin)" "$(_ui_bar 1 2 4)" "$(_ui_eta 1 2 3)" "$(_ui_elapsed "$(_ui_now)")"'
    [ "$status" -eq 0 ]
    matches '^⠋\|██░░\|~3s\|[0-9.]+$' "$output"
}

@test "ui_cursor_up moves up N lines on a terminal and exits 0 off one" {
    run run_in_pty "$LIB" 'ui_cursor_up 5'
    [ "$status" -eq 0 ]
    has "${ESC}[5A"
    run "$LIB" 'ui_cursor_up 5'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "the glyph set is empty in plain mode and has no colour with NO_COLOR" {
    local show='printf "[%s]" "$_UI_SYM_DONE" "$_UI_SYM_FAIL" "$_UI_SYM_PENDING" "$_UI_SYM_ACTIVE"'
    run "$LIB" "$show"
    [ "$status" -eq 0 ]
    [ "$output" = "[][][][]" ]
    run run_in_pty env NO_COLOR=1 "$LIB" "$show"
    [ "$status" -eq 0 ]
    has "[✓][✗][○][⠹]"
}

@test "finds cli-common.sh through a chain of symlinks from any directory" {
    local away="$BATS_TEST_TMPDIR/away/deep"
    mkdir -p "$away"
    ln -s "$REPO/scripts/lib/progress-ui.sh" "$away/absolute.sh"
    # A relative target, so the second hop resolves against the link's own directory.
    ln -s "absolute.sh" "$away/relative.sh"
    ln -s "$away/relative.sh" "$BATS_TEST_TMPDIR/entry.sh"
    cd "$away"
    run /bin/bash -c 'set -euo pipefail; . "$1"; css_version "$REPO" >/dev/null; printf ok' _ "$BATS_TEST_TMPDIR/entry.sh"
    [ "$status" -eq 0 ]
    [ "$output" = ok ]
}

@test "a missing cli-common.sh names the path and stops a strict caller" {
    local dir="$BATS_TEST_TMPDIR/lib"
    mkdir -p "$dir"
    cp "$REPO/scripts/lib/progress-ui.sh" "$dir/"
    run /bin/bash -c 'set -euo pipefail; . "$1"; echo reached' _ "$dir/progress-ui.sh"
    [ "$status" -ne 0 ]
    [ "$output" = "Error: Can't load $dir/cli-common.sh. The file is missing." ]
}

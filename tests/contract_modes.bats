#!/usr/bin/env bats
# One success and one failure of five commands in every mode a person or a program runs them in, then
# the same commands' styling. This file is the source of truth where a unit's own colour check overlaps.
#
# The modes are real: "redirected" and "stdin piped" run from inside a pty, as they do from a shell.
# A pty merges stdout and stderr, so a case asserts streams apart only where they are apart: in
# redirected (stdout goes to a file, stderr stays on the pty) and agent (no terminal at all).
#
# "A prompt appeared" means fzf ran, the only prompt these commands have. Every other command gets a
# terminal on stdin and nothing to read, so one that asked would hang until CI's job timeout; and no
# output may read like a question.
#
# RED-proof: not run, while the machine was under load. These pin today's behaviour, as measured
# (decision packet ad226c7513ea: C2, C7, C8 keep).
#
# shellcheck disable=SC2016,SC2030,SC2031 # text for another shell; bats's vars are per test

load helpers_scripts

ID=b4e8d1f6a2c39075
UUID=123e4567-e89b-12d3-a456-426614174000

setup_file() {
    export BATS_NO_PARALLELIZE_WITHIN_FILE=true
    sandbox_setup
    export ENGINE="$HOME/.claude/bin/session-search.py"
    export WRAPPER="$HOME/.claude/bin/claude-search"
    export INSTALL="$REPO/install.sh"
    export BACKFILL="$REPO/scripts/session-index-backfill.sh"
    export TAG="$REPO/scripts/session-index-tag.py"
    # A --dry-run row needs an untagged session.
    sqlite3 "$HOME/.claude/session-index.db" "UPDATE sessions SET tags = '', tagged_at = NULL"
}

teardown_file() {
    sandbox_teardown
}

setup() {
    M_OUT="$BATS_TEST_TMPDIR/stdout"
    FAILS=""
}

note() {
    FAILS="$FAILS
$1"
}

# mode_run <mode> <cmd...>: sets M_STATUS, M_STDOUT and M_STDERR where the mode keeps them apart, and
# M_MERGED where it does not. The extra flag in json and non_interactive goes last.
mode_run() {
    local mode="$1"
    shift
    M_STDOUT=""
    M_STDERR=""
    M_MERGED=""
    case "$mode" in
        tty) run run_in_pty "$@" </dev/null ;;
        stdin_piped) run run_in_pty /bin/bash -c 'printf "" | "$@"' _ "$@" </dev/null ;;
        json) run run_in_pty "$@" --json </dev/null ;;
        non_interactive) run run_in_pty "$@" --non-interactive </dev/null ;;
        ci) run run_in_pty env CI=1 "$@" </dev/null ;;
        redirected)
            run run_in_pty /bin/bash -c 'out="$1"; shift; "$@" >"$out"' _ "$M_OUT" "$@" </dev/null
            M_STATUS="$status"
            M_STDOUT="$(cat "$M_OUT")"
            M_STDERR="$(printf '%s' "$output" | tr -d '\r')"
            return
            ;;
        agent)
            run --separate-stderr env CLAUDECODE=1 "$@" </dev/null
            M_STATUS="$status"
            M_STDOUT="$output"
            M_STDERR="$stderr"
            return
            ;;
    esac
    M_STATUS="$status"
    M_MERGED="$(printf '%s' "$output" | tr -d '\r')"
}

# cell <mode> <status> <in stdout> <in stderr> <cmd...>: one mode of one command. An empty <in stdout>
# or <in stderr> means that stream is empty where the mode keeps them apart. The word NOTHING is the
# same, and also claims the merged output has no such text to look for.
cell() {
    local mode="$1" want="$2" in_out="$3" in_err="$4" all
    shift 4
    mode_run "$mode" "$@"
    all="$M_STDOUT$M_STDERR$M_MERGED"
    [ "$M_STATUS" = "$want" ] || note "$mode: status $M_STATUS, want $want: $all"
    case "$all" in
        *"[y/N]"* | *"[Y/n]"* | *"(y/n)"* | *"Are you sure"* | *"Press "*) note "$mode: a prompt: $all" ;;
    esac
    if [ "$mode" = redirected ] || [ "$mode" = agent ]; then
        if [ -n "$in_out" ]; then
            case "$M_STDOUT" in *"$in_out"*) ;; *) note "$mode: no [$in_out] on stdout: $M_STDOUT | stderr: $M_STDERR" ;; esac
            case "$M_STDERR" in *"$in_out"*) note "$mode: [$in_out] on stderr too: $M_STDERR" ;; esac
        else
            [ -z "$M_STDOUT" ] || note "$mode: stdout should be empty: $M_STDOUT"
        fi
        if [ -n "$in_err" ]; then
            case "$M_STDERR" in *"$in_err"*) ;; *) note "$mode: no [$in_err] on stderr: $M_STDERR | stdout: $M_STDOUT" ;; esac
            case "$M_STDOUT" in *"$in_err"*) note "$mode: [$in_err] on stdout too: $M_STDOUT" ;; esac
        fi
        # Plain stdout is never styled, in the two modes where it is not a terminal.
        assert_no_ansi "$M_STDOUT" || note "$mode: ESC on stdout"
    else
        case "$M_MERGED" in *"$in_out"*) ;; *) note "$mode: no [$in_out] in: $M_MERGED" ;; esac
        case "$M_MERGED" in *"$in_err"*) ;; *) note "$mode: no [$in_err] in: $M_MERGED" ;; esac
    fi
}

verdict() {
    [ -z "$FAILS" ] || {
        printf '%s\n' "$FAILS" >&2
        return 1
    }
}

# Whether fzf ran since the last call, and the log emptied for the next.
fzf_ran() {
    if [ -s "$HOME/calls/fzf" ]; then
        rm -f "$HOME/calls/fzf"
        return 0
    fi
    return 1
}

# plain_text <text>: without styling and CRs, and without what varies between runs: the spinner, which
# draws only if the search is slow, the duration, and the padding a longer duration takes.
plain_text() {
    printf '%s' "$1" | LC_ALL=C sed -E $'s/\033\\[[0-9;?]*[A-Za-z]//g; s/\r//g' |
        LC_ALL=C sed -E 's/^.*Searching…//; s/[0-9.]+m?s( |$)/<t>\1/g; s/ +/ /g'
}

# ─── Per-mode matrix ──────────────────────────────────────

@test "engine search succeeds in every mode with no prompt" {
    local -a e=(python3 "$ENGINE" auth)
    cell tty 0 "Session Search" "Migrate" "${e[@]}"
    cell redirected 0 "Migrate" "" "${e[@]}"
    cell stdin_piped 0 "Session Search" "Migrate" "${e[@]}"
    cell json 0 '"sessions"' "$ID" "${e[@]}"
    cell non_interactive 0 "Session Search" "Migrate" "${e[@]}"
    cell ci 0 "Session Search" "Migrate" "${e[@]}"
    cell agent 0 "Migrate" "" "${e[@]}"
    verdict
}

@test "engine search fails with exit 2 in every mode, and nothing on stdout" {
    local -a e=(python3 "$ENGINE" --bogus auth)
    local mode
    for mode in tty stdin_piped non_interactive ci; do
        cell "$mode" 2 "unrecognized arguments: --bogus" "See 'claude-search --help'." "${e[@]}"
    done
    cell redirected 2 "" "unrecognized arguments: --bogus" "${e[@]}"
    cell agent 2 "" "unrecognized arguments: --bogus" "${e[@]}"
    cell json 2 '"status":"action_required"' "unrecognized arguments: --bogus" "${e[@]}"
    verdict
}

@test "wrapper --fzf prompts only on an interactive terminal, and otherwise exits 2" {
    export FZF_OUT=$'\nrow\t'"$UUID"
    local -a w=("$WRAPPER" --fzf auth)
    local mode refusal="--fzf needs an interactive terminal."

    cell tty 0 "" "" "${w[@]}"
    fzf_ran || note "tty: no prompt"
    [ "$(calls claude | tail -1)" = "$UUID" ] || note "tty: claude got: $(calls claude)"

    # Only stdin and stderr decide, so a redirected stdout still gets the picker.
    cell redirected 0 "" "" "${w[@]}"
    fzf_ran || note "redirected: no prompt"

    for mode in stdin_piped non_interactive ci; do
        cell "$mode" 2 "$refusal" "Search without the picker:" "${w[@]}"
        ! fzf_ran || note "$mode: a prompt"
    done
    cell agent 2 "" "$refusal" "${w[@]}"
    ! fzf_ran || note "agent: a prompt"
    cell json 2 "--fzf can't be used with --json." "" "${w[@]}"
    ! fzf_ran || note "json: a prompt"
    verdict
}

@test "wrapper --fzf failure exits 2 in every mode and never prompts" {
    local -a w=("$WRAPPER" --fzf --resume 1 auth)
    local mode msg="--fzf can't be used with --resume."
    for mode in tty stdin_piped non_interactive ci json; do
        cell "$mode" 2 "$msg" "" "${w[@]}"
    done
    cell redirected 2 "" "$msg" "${w[@]}"
    cell agent 2 "" "$msg" "${w[@]}"
    ! fzf_ran || note "a prompt"
    verdict
}

@test "install.sh --version prints only the version in every mode" {
    local -a c=("$INSTALL" --version)
    local version mode
    version="$(cat "$REPO/VERSION")"
    for mode in tty stdin_piped non_interactive ci; do
        cell "$mode" 0 "$version" "" "${c[@]}"
    done
    cell redirected 0 "$version" "" "${c[@]}"
    [ -z "$M_STDERR" ] || note "redirected: stderr: $M_STDERR"
    cell agent 0 "$version" "" "${c[@]}"
    [ -z "$M_STDERR" ] || note "agent: stderr: $M_STDERR"
    cell json 0 "\"version\"" "$version" "${c[@]}"
    verdict
}

@test "install.sh with an unknown option exits 2 in every mode" {
    local -a c=("$INSTALL" --bogus)
    local mode msg="unknown option: --bogus"
    for mode in tty stdin_piped non_interactive ci; do
        cell "$mode" 2 "$msg" "See './install.sh --help'." "${c[@]}"
    done
    cell redirected 2 "" "$msg" "${c[@]}"
    cell agent 2 "" "$msg" "${c[@]}"
    cell json 2 "$msg" "" "${c[@]}"
    verdict
}

@test "backfill --help is on stdout in every mode" {
    local -a c=("$BACKFILL" --help)
    local mode
    for mode in tty stdin_piped non_interactive ci json; do
        cell "$mode" 0 "Usage: session-index-backfill.sh" "Exit codes:" "${c[@]}"
    done
    cell redirected 0 "Usage: session-index-backfill.sh" "" "${c[@]}"
    [ -z "$M_STDERR" ] || note "redirected: stderr: $M_STDERR"
    cell agent 0 "Usage: session-index-backfill.sh" "" "${c[@]}"
    [ -z "$M_STDERR" ] || note "agent: stderr: $M_STDERR"
    verdict
}

@test "backfill with an unknown option exits 2 in every mode" {
    local -a c=("$BACKFILL" --bogus)
    local mode msg="unknown option: --bogus"
    for mode in tty stdin_piped non_interactive ci json; do
        cell "$mode" 2 "$msg" "See 'session-index-backfill.sh --help'." "${c[@]}"
    done
    cell redirected 2 "" "$msg" "${c[@]}"
    cell agent 2 "" "$msg" "${c[@]}"
    verdict
}

@test "tag.py --dry-run: rows on stdout, banner on stderr, in every mode" {
    local -a c=(python3 "$TAG" --dry-run --limit 2)
    local mode
    for mode in tty stdin_piped non_interactive ci; do
        cell "$mode" 0 "regex" "Session Tagger (dry run)" "${c[@]}"
    done
    cell redirected 0 "	regex" "Session Tagger (dry run)" "${c[@]}"
    cell agent 0 "	regex" "Session Tagger (dry run)" "${c[@]}"
    cell json 0 '"outcome": "planned"' '"results"' "${c[@]}"
    verdict
}

@test "tag.py --dry-run with an unknown option exits 2 in every mode, and nothing on stdout" {
    local -a c=(python3 "$TAG" --dry-run --bogus)
    local mode msg="unrecognized arguments: --bogus"
    for mode in tty stdin_piped non_interactive ci json; do
        cell "$mode" 2 "$msg" "usage:" "${c[@]}"
    done
    cell redirected 2 "" "$msg" "${c[@]}"
    cell agent 2 "" "$msg" "${c[@]}"
    verdict
}

# ─── Styling ──────────────────────────────────────────────

# plain_everywhere <cmd...>: no ESC on --no-color, TERM=dumb or redirected, with stdout and stderr
# captured apart in the last.
plain_everywhere() {
    run run_in_pty "$@" --no-color </dev/null
    assert_no_ansi "$output" || note "--no-color: $*"
    run run_in_pty env TERM=dumb "$@" </dev/null
    assert_no_ansi "$output" || note "TERM=dumb: $*"
    run --separate-stderr "$@" </dev/null
    assert_no_ansi "$output" || note "redirected stdout: $*"
    assert_no_ansi "$stderr" || note "redirected stderr: $*"
}

# styled_and_plain <label> <cmd...>
styled_and_plain() {
    local label="$1" styled bare
    shift
    run run_in_pty "$@" </dev/null
    styled="$output"
    case "$styled" in *$'\033['*) ;; *) note "$label: no styling on a terminal: $styled" ;; esac
    run run_in_pty "$@" --no-color </dev/null
    bare="$output"
    [ "$(plain_text "$styled")" = "$(plain_text "$bare")" ] ||
        note "$label: stripped text differs:
$(plain_text "$styled")
---
$(plain_text "$bare")"
    plain_everywhere "$@"
}

@test "styled on a terminal, plain otherwise, and stripping the styling recovers the text" {
    styled_and_plain engine python3 "$ENGINE" auth
    styled_and_plain tag python3 "$TAG" --dry-run --limit 2
    verdict
}

@test "the picker's rows are styled on a terminal and not under --no-color or TERM=dumb" {
    export FZF_OUT=""
    local stdin_log="$HOME/calls/fzf.stdin"
    rm -f "$stdin_log"
    run run_in_pty "$WRAPPER" --fzf auth </dev/null
    grep -q $'\033\\[' "$stdin_log" || note "no styling in the rows"
    rm -f "$stdin_log"
    run run_in_pty "$WRAPPER" --fzf auth --no-color </dev/null
    [ -s "$stdin_log" ] || note "--no-color: no rows"
    assert_no_ansi "$(cat "$stdin_log")" || note "--no-color: styled rows"
    verdict
}

@test "commands with no styling have none on a terminal either" {
    local args
    for args in "$INSTALL --version" "$BACKFILL --help" "$INSTALL --bogus" "$BACKFILL --bogus"; do
        # shellcheck disable=SC2086 # the rows are words
        run run_in_pty $args </dev/null
        assert_no_ansi "$output" || note "$args"
    done
    verdict
}

@test "JSON, identifiers and TSV stay unstyled with FORCE_COLOR=1" {
    export FORCE_COLOR=1
    run --separate-stderr python3 "$ENGINE" --json auth
    assert_no_ansi "$output" || note "engine --json stdout"
    run --separate-stderr python3 "$ENGINE" --format=fzf auth
    assert_no_ansi "$output" || note "--format=fzf stdout"
    [ "${lines[0]##*$'\t'}" = "$ID" ] || note "fzf last field: ${lines[0]}"
    run --separate-stderr python3 "$ENGINE" --format=json auth
    assert_no_ansi "$output" || note "--format=json stdout"
    run run_in_pty python3 "$ENGINE" --json auth </dev/null
    assert_no_ansi "$output" || note "engine --json on a terminal"
    run --separate-stderr python3 "$ENGINE" --resume-result 1
    [ "$status" -eq 0 ] || note "--resume-result: status $status: $stderr"
    assert_no_ansi "$output" || note "--resume-result stdout"
    [ "${#lines[@]}" -eq 1 ] || note "--resume-result: $output"
    run --separate-stderr python3 "$TAG" --dry-run --limit 2
    assert_no_ansi "$output" || note "tag --dry-run rows"
    case "$stderr" in *$'\033['*) ;; *) note "tag --dry-run: FORCE_COLOR styles the banner on stderr, and did not: $stderr" ;; esac
    run --separate-stderr python3 "$TAG" --dry-run --limit 2 --json
    assert_no_ansi "$output" || note "tag --json stdout"
    run --separate-stderr "$INSTALL" --version
    assert_no_ansi "$output" || note "install --version"
    run --separate-stderr "$BACKFILL" --help
    assert_no_ansi "$output" || note "backfill --help"
    verdict
}

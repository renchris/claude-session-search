#!/usr/bin/env bats
# The shared harness (tests/helpers.bash) tested on its own: every other suite trusts its sandbox,
# stubs and assertions, so a broken helper would otherwise read as a green or red CLI.

load helpers

ORIG_HOME="$HOME"
ORIG_PATH="$PATH"

setup() { sandbox_setup; }
teardown() { sandbox_teardown; }

# Plain `run` may reset $output and $stderr before the command reads them, and these negatives
# need their defaults intact.
fails() {
    if "$@" 2>/dev/null; then
        return 1
    fi
}

@test "sandbox_setup: HOME is a fresh css-test temp dir, not the real one" {
    [ "$HOME" != "$ORIG_HOME" ]
    [ "$REAL_HOME" = "$ORIG_HOME" ]
    [ -d "$HOME" ]
    case "$HOME" in
        "${TMPDIR:-/tmp}"*/css-test.*) ;;
        *) echo "unexpected HOME: $HOME" >&2; return 1 ;;
    esac
}

@test "sandbox_setup: the engine in the sandbox answers from the demo DB" {
    [ "$(sqlite3 "$HOME/.claude/session-index.db" "SELECT value != '' FROM meta WHERE key='last_backfill';")" = 1 ]
    run --separate-stderr python3 "$HOME/.claude/bin/session-search.py" --format=json aurora --limit 1
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.[0].session_id == "7f3a9c21e4d50a18"'
}

@test "sandbox_setup: copies the wrapper and the hooks with their lib" {
    [ -x "$HOME/.claude/bin/claude-search" ]
    [ -x "$HOME/.claude/hooks/session-index-end.sh" ]
    [ -f "$HOME/.claude/hooks/lib/session-index-helpers.sh" ]
}

@test "sandbox_setup: PATH resolves stubs, wrapper and tools inside the sandbox" {
    local name
    for name in claude fzf pbcopy open; do
        [ "$(command -v "$name")" = "$HOME/stubs/$name" ]
    done
    [ "$(command -v claude-search)" = "$HOME/.claude/bin/claude-search" ]
    for name in python3 jq sqlite3 awk; do
        [ "$(command -v "$name")" = "$HOME/tools/$name" ]
    done
}

@test "sandbox_setup: scrubs the agent, CI and color environment, by prefix for ours" {
    sandbox_teardown
    export CI=true CLAUDECODE=1 NO_COLOR=1 FORCE_COLOR=1 CLICOLOR_FORCE=1 COLORTERM=truecolor
    export ANTHROPIC_API_KEY=not-a-key TERM=dumb
    export SESSION_SEARCH_DEBUG=1 SESSION_SEARCH_NOT_YET_INVENTED=1 __SESSION_SEARCH_PICKER=1
    sandbox_setup
    local name
    for name in CI CLAUDECODE NO_COLOR FORCE_COLOR CLICOLOR_FORCE COLORTERM ANTHROPIC_API_KEY \
        SESSION_SEARCH_DEBUG SESSION_SEARCH_NOT_YET_INVENTED __SESSION_SEARCH_PICKER; do
        [ -z "${!name+set}" ]
    done
    [ "$TERM" = xterm-256color ]
}

@test "stubs: each logs NUL-separated argv and calls reads it back" {
    local name expected
    expected=$'--flag\na b\nc'
    for name in claude fzf pbcopy open; do
        "$name" --flag 'a b' c </dev/null
        [ "$(tr -cd '\000' <"$HOME/calls/$name" | wc -c | tr -d ' ')" = 3 ]
        [ "$(calls "$name")" = "$expected" ]
    done
}

@test "calls: accumulates across invocations, empty and successful for a stub never run" {
    claude first
    claude second
    [ "$(calls claude)" = $'first\nsecond' ]
    run calls open
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "pbcopy stub: keeps what was piped in" {
    printf 'sid-1' | pbcopy
    [ "$(cat "$HOME/calls/pbcopy.stdin")" = sid-1 ]
}

@test "fzf stub: FZF_OUT is stdout, FZF_RC is the exit code, stdin is drained" {
    FZF_OUT=$'row\tsid-1' FZF_RC=130 run fzf --ansi < <(printf 'piped rows\n')
    [ "$status" -eq 130 ]
    [ "$output" = $'row\tsid-1' ]
    [ "$(cat "$HOME/calls/fzf.stdin")" = 'piped rows' ]
    run fzf </dev/null
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "fzf stub: FZF_RUN_RELOAD runs the bind with {q} as one literal word, in either bind form" {
    local q=$'it\'s a; touch "$HOME/pwned" & $(touch "$HOME/pwned2")'
    FZF_RUN_RELOAD="$q" fzf "--bind=ctrl-y:abort" "--bind=change:reload:printf '[%s]' {q}; echo" </dev/null
    FZF_RUN_RELOAD="$q" fzf --bind "change:reload:printf '[%s]' {q}; echo" </dev/null
    [ "$(calls fzf.reload)" = "[$q]"$'\n'"[$q]" ]
    [ ! -e "$HOME/pwned" ]
    [ ! -e "$HOME/pwned2" ]
}

@test "fzf stub: FZF_RUN_RELOAD with no reload bind is an error, not a silent skip" {
    FZF_RUN_RELOAD=x run fzf --bind=ctrl-y:abort </dev/null
    [ "$status" -eq 99 ]
}

@test "fzf stub: recognizes the reload bind bin/claude-search really passes" {
    use_stub_engine
    FZF_RUN_RELOAD='typed words' run claude-search --fzf seed
    [ "$status" -eq 0 ]
    calls engine | grep -Fx 'typed words'
}

@test "use_stub_engine: logs argv and honors STUB_OUT, STUB_ERR, STUB_RC" {
    use_stub_engine
    STUB_OUT=to-stdout STUB_ERR=to-stderr STUB_RC=3 run --separate-stderr \
        python3 "$HOME/.claude/bin/session-search.py" --flag 'a b'
    [ "$status" -eq 3 ]
    [ "$output" = to-stdout ]
    [ "$stderr" = to-stderr ]
    [ "$(calls engine)" = $'--flag\na b' ]
}

@test "use_stub_engine: exits 0 and prints nothing by default" {
    use_stub_engine
    run --separate-stderr python3 "$HOME/.claude/bin/session-search.py"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
}

@test "assert_one_json_doc: accepts one document on one line" {
    assert_one_json_doc '{"a":1}'
    assert_one_json_doc '[1,2]'
    assert_one_json_doc $'{"a":1}\n'
    output='[3]'
    assert_one_json_doc
}

@test "assert_one_json_doc: rejects empty, multi-line, two-document and non-JSON text" {
    local bad
    for bad in '' $'{\n  "a": 1\n}' $'{}\n{}' '{} {}' 'not json' '{"a":'; do
        fails assert_one_json_doc "$bad"
    done
    output='not json'
    fails assert_one_json_doc
}

@test "assert_no_ansi: passes clean text and catches ESC in text, output and stderr" {
    assert_no_ansi 'plain [1m text'
    fails assert_no_ansi $'\033[1mbold'

    output=clean stderr=clean
    assert_no_ansi
    output=$'\033[0m' stderr=clean
    fails assert_no_ansi
    output=clean stderr=$'\033[0m'
    fails assert_no_ansi
}

@test "run_in_pty: gives the command a terminal, where plain run does not" {
    run bash -c '[ -t 1 ]'
    [ "$status" -ne 0 ]
    run run_in_pty bash -c '[ -t 0 ] && [ -t 1 ] && [ -t 2 ] && echo all-tty'
    [ "$status" -eq 0 ]
    case "$output" in
        all-tty*) ;;
        *) echo "unexpected output: $output" >&2; return 1 ;;
    esac
}

@test "run_in_pty: returns the command's exit code" {
    run run_in_pty bash -c 'exit 7'
    [ "$status" -eq 7 ]
}

@test "sandbox_teardown: removes the sandbox and restores HOME and PATH" {
    local sandbox="$HOME"
    sandbox_teardown
    [ ! -e "$sandbox" ]
    [ "$HOME" = "$ORIG_HOME" ]
    [ "$PATH" = "$ORIG_PATH" ]
}

@test "sandbox_teardown: leaves a HOME that is not a css-test dir alone" {
    local other
    other="$(mktemp -d "${TMPDIR:-/tmp}/css-keep.XXXXXX")"
    touch "$other/keep"
    (
        export HOME="$other"
        sandbox_teardown
    )
    [ -f "$other/keep" ]
    rm -f "$other/keep"
    rmdir "$other"
}

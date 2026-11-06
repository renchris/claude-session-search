# shellcheck shell=bash
# Shared bats harness: `load helpers`, then call sandbox_setup / sandbox_teardown from
# setup() / teardown(). Every test gets a throwaway HOME holding a copy of the CLI, the hooks and
# the synthetic demo DB, so nothing here can read or write the real ~/.claude.
#
# Stubs (claude, fzf, pbcopy, open; `engine` after use_stub_engine) append their NUL-separated
# argv to $HOME/calls/<name>. A call with no arguments records one empty argument.
#
# Bash 3.2: bin/claude-search runs on it, and so can this file. Do not use mapfile,
# associative arrays or `${v,,}`.

bats_require_minimum_version 1.5.0

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The suite runs inside agent sessions (CLAUDECODE) and on CI (CI=true), and each changes what the
# CLI prints. A test that wants one of these sets it explicitly. TERM is pinned rather than unset
# because it differs between those two places.
_sandbox_scrub_env() {
    local name
    unset CI CLAUDECODE NO_COLOR FORCE_COLOR CLICOLOR CLICOLOR_FORCE COLORTERM COLUMNS LINES
    unset ANTHROPIC_API_KEY
    for name in $(compgen -v | grep -E '^(__)?SESSION_(SEARCH|INDEX)_' || true); do
        unset "$name"
    done
    export TERM=xterm-256color
}

# Writes $HOME/stubs/<name>: a script that logs its argv, then runs the body given on stdin.
_write_stub() {
    local path="$HOME/stubs/$1"
    {
        cat <<'STUB'
#!/bin/bash
printf '%s\0' "$@" >>"$HOME/calls/${0##*/}"
STUB
        cat
    } >"$path" && chmod +x "$path"
}

sandbox_setup() {
    local sandbox tool tool_path

    sandbox="$(mktemp -d "${TMPDIR:-/tmp}/css-test.XXXXXX")" || return 1
    export REAL_HOME="$HOME"
    export REAL_PATH="$PATH"
    export REPO
    export HOME="$sandbox"
    _sandbox_scrub_env

    mkdir -p "$HOME/.claude/bin" "$HOME/.claude/hooks" "$HOME/stubs" "$HOME/tools" "$HOME/calls" || return 1
    cp "$REPO/bin/session-search.py" "$REPO/bin/claude-search" "$HOME/.claude/bin/" || return 1
    cp -R "$REPO/hooks/." "$HOME/.claude/hooks/" || return 1
    # The demo DB seeds last_backfill, so the engine's freshness check spawns nothing.
    python3 "$REPO/assets/demo/build_demo_db.py" "$HOME/.claude/session-index.db" >/dev/null || return 1

    # Symlinks, not the directories that hold them: fzf on macOS sits in /opt/homebrew/bin next to
    # jq, so a test decides which commands exist by what is on this PATH.
    for tool in python3 jq sqlite3 awk; do
        tool_path="$(command -v "$tool")" || { echo "sandbox_setup: $tool not found" >&2; return 1; }
        ln -s "$tool_path" "$HOME/tools/$tool" || return 1
    done
    export PATH="$HOME/stubs:$HOME/.claude/bin:$HOME/tools:/usr/bin:/bin"

    _write_stub claude </dev/null
    _write_stub open </dev/null
    # pbcopy and fzf read stdin, so a producer piped into them must not die of SIGPIPE.
    _write_stub pbcopy <<'STUB'
[ -t 0 ] || cat >>"$HOME/calls/pbcopy.stdin"
STUB
    # FZF_OUT is the selection, FZF_RC the exit code. FZF_RUN_RELOAD=<q> runs this fzf's own
    # change:reload: command as if <q> had been typed, shell-quoting {q} the way real fzf does, and
    # keeps the rows in $HOME/calls/fzf.reload. A set FZF_RUN_RELOAD with no such bind is exit 99,
    # so a wrapper that stops passing the bind fails its test instead of skipping the reload.
    _write_stub fzf <<'STUB'
[ -t 0 ] || cat >>"$HOME/calls/fzf.stdin"
if [ -n "${FZF_RUN_RELOAD+set}" ]; then
    rest=""
    for arg in "$@"; do
        case "$arg" in
            *change:reload:*) rest="${arg#*change:reload:}" ;;
        esac
    done
    if [ -z "$rest" ]; then
        echo "fzf stub: FZF_RUN_RELOAD is set but argv has no change:reload: bind" >&2
        exit 99
    fi
    printf -v quoted '%q' "$FZF_RUN_RELOAD"
    # A loop, because ${v//pat/rep} treats & in rep specially on bash 5.2 and later.
    cmd=""
    while [ "${rest#*\{q\}}" != "$rest" ]; do
        cmd="$cmd${rest%%\{q\}*}$quoted"
        rest="${rest#*\{q\}}"
    done
    bash -c "$cmd$rest" </dev/null >>"$HOME/calls/fzf.reload"
fi
[ -z "${FZF_OUT:-}" ] || printf '%s\n' "$FZF_OUT"
exit "${FZF_RC:-0}"
STUB
}

sandbox_teardown() {
    case "$HOME" in
        */css-test.*) rm -rf "${HOME:?}" ;;
    esac
    export HOME="${REAL_HOME:-$HOME}"
    export PATH="${REAL_PATH:-$PATH}"
}

# Replaces the sandbox's engine with a logger that writes STUB_OUT and STUB_ERR verbatim and exits
# STUB_RC. It stays Python because the wrapper runs it as `python3 "$SEARCH_PY"`.
use_stub_engine() {
    cat >"$HOME/.claude/bin/session-search.py" <<'STUB'
#!/usr/bin/env python3
import os
import sys

with open(os.path.join(os.environ["HOME"], "calls", "engine"), "ab") as log:
    for arg in sys.argv[1:] or [""]:
        log.write(os.fsencode(arg) + b"\0")
sys.stdout.write(os.environ.get("STUB_OUT", ""))
sys.stderr.write(os.environ.get("STUB_ERR", ""))
sys.exit(int(os.environ.get("STUB_RC", "0")))
STUB
    chmod +x "$HOME/.claude/bin/session-search.py"
}

# calls <name>: the recorded argv, one argument per line, across all calls. Empty when the stub
# never ran.
calls() {
    [ -e "$HOME/calls/$1" ] || return 0
    tr '\0' '\n' <"$HOME/calls/$1"
}

# assert_one_json_doc [text]: text (default $output) is one line holding one JSON document that
# `jq -e .` accepts, so a bare `null` or `false` does not pass. One line alone is not enough:
# `{} {}` is one line, and jq parses it as two documents.
assert_one_json_doc() {
    local doc="${1-${output-}}" newline=$'\n'
    doc="${doc%"$newline"}"
    case "$doc" in
        "")
            echo "assert_one_json_doc: empty" >&2
            return 1
            ;;
        *"$newline"*)
            echo "assert_one_json_doc: more than one line: $doc" >&2
            return 1
            ;;
    esac
    if ! printf '%s' "$doc" | jq -e . >/dev/null; then
        echo "assert_one_json_doc: jq -e . rejected: $doc" >&2
        return 1
    fi
    if ! printf '%s' "$doc" | jq -e -s 'length == 1' >/dev/null; then
        echo "assert_one_json_doc: more than one document: $doc" >&2
        return 1
    fi
}

# assert_no_ansi [text]: no ESC byte in text (default $output, plus $stderr after
# `run --separate-stderr`).
assert_no_ansi() {
    local text esc=$'\033'
    if [ $# -gt 0 ]; then
        text="$1"
    else
        text="${output-}${stderr-}"
    fi
    case "$text" in
        *"$esc"*)
            echo "assert_no_ansi: ESC byte in output" >&2
            return 1
            ;;
    esac
}

# run_in_pty <cmd> [args...]: runs cmd with a terminal on all three streams and returns its exit
# code. Portable on macOS and Linux. The pty merges stdout and stderr, and its line endings are CRLF.
run_in_pty() {
    python3 -I -c 'import os,pty,sys; sys.exit(os.waitstatus_to_exitcode(pty.spawn(sys.argv[1:])))' "$@"
}

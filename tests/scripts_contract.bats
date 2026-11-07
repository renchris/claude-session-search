#!/usr/bin/env bats
# What crosses the CLIs' own suites: the invocations other programs depend on, the install and
# uninstall round trip, the installed links, and how each process treats exit codes, argv, a closed
# pipe and signals.
#
# One sandbox per file: setup_file runs the real installer once from a copy of the checkout, with no
# synonyms/default.json (one sqlite3 process per row) and no demo DB (its synonyms table lacks a
# column backfill writes). The cases then run against that install, and the round trip, which
# removes it, comes last. backfill_pipeline.bats owns the backfill's own signals.
#
# RED-proof: not run, while the machine was under load. The closed-pipe cases were measured first:
# they are what the code does today, so they pin it rather than prove a fix.
#
# shellcheck disable=SC2016,SC2030,SC2031,SC2329 # text for another shell; bats's vars are per test

load helpers_scripts

SID=11111111-2222-4333-8444-555555555555

setup_file() {
    # Order matters: the last case uninstalls.
    export BATS_NO_PARALLELIZE_WITHIN_FILE=true
    script_sandbox_setup
    export STUB_UNAME=Darwin
    # A case below stubs python3 on PATH, and its own driver still needs the real one.
    REAL_PYTHON="$(command -v python3)"
    export REAL_PYTHON
    export CLAUDE_HOME="$HOME/.claude"
    export DB="$CLAUDE_HOME/session-index.db"
    export ENGINE="$CLAUDE_HOME/bin/session-search.py"
    export WRAPPER="$CLAUDE_HOME/bin/claude-search"

    # sandbox_setup's regular copies stand where install.sh links, and it never overwrites a file.
    rm -f "$DB" "$ENGINE" "$WRAPPER" "$CLAUDE_HOME"/hooks/session-index-*.sh \
        "$CLAUDE_HOME/hooks/lib/session-index-helpers.sh"
    rm -f "$CLAUDE_HOME"/projects/*/*.jsonl

    mkdir -p "$HOME/copy" "$CLAUDE_HOME/projects/-p"
    cp -R "$REPO/install.sh" "$REPO/uninstall.sh" "$REPO/VERSION" \
        "$REPO/bin" "$REPO/hooks" "$REPO/scripts" "$REPO/config" "$HOME/copy/"
    # The physical path: macOS's TMPDIR sits behind a symlink, and install.sh links what it resolves.
    COPY="$(cd -P "$HOME/copy" && pwd)"
    export COPY
    export TRANSCRIPT="$CLAUDE_HOME/projects/-p/$SID.jsonl"
    python3 -I -c '
import json, sys
with open(sys.argv[1], "w") as f:
    for i in range(8):
        f.write(json.dumps({"type": "user", "message": {"role": "user", "content":
            f"please fix the zephyr parser bug number {i} today, it fails on long inputs"}}) + "\n")
        f.write(json.dumps({"type": "assistant", "message": {"role": "assistant", "content":
            [{"type": "text", "text": f"zephyr reply {i} with enough text to be part of a chunk"}]}}) + "\n")
' "$TRANSCRIPT"

    "$COPY/install.sh" >"$BATS_FILE_TMPDIR/install.out" 2>"$BATS_FILE_TMPDIR/install.err"
    echo "$?" >"$BATS_FILE_TMPDIR/install.rc"
}

teardown_file() {
    sandbox_teardown
}

has() {
    case "$1" in
        *"$2"*) ;;
        *)
            printf 'expected to find: %s\nin: %s\n' "$2" "$1" >&2
            return 1
            ;;
    esac
}

lacks() {
    case "$1" in
        *"$2"*)
            printf 'expected not to find: %s\nin: %s\n' "$2" "$1" >&2
            return 1
            ;;
    esac
}

# A HOME of its own, for a case about a failure or a stub, so the shared install stays as it was.
scratch_home() {
    export HOME="$BATS_TEST_TMPDIR/h"
    mkdir -p "$HOME/.claude/bin" "$HOME/calls" "$HOME/stubs" "$HOME/Library/LaunchAgents"
    export PATH="$HOME/stubs:$PATH"
}

# closed_pipe <default|ignore> <cmd...>: cmd with stdout on a pipe whose reader has already gone,
# which is `| head -1` without its race, and SIGPIPE at that disposition. CI's runner ignores it.
closed_pipe() {
    python3 -I -c '
import os, subprocess, sys
r, w = os.pipe()
os.close(r)
rc = subprocess.run(sys.argv[2:], stdin=subprocess.DEVNULL, stdout=w,
                    restore_signals=sys.argv[1] == "default").returncode
sys.exit(128 - rc if rc < 0 else rc)
' "$@"
}

# signal_at_reader <SIGNAL> <fifo> <cmd...>: starts cmd as a terminal's foreground group would be,
# sends the signal once something has the fifo open to read, and returns cmd's exit code. SIGINT goes
# to the group, as Ctrl-C does; SIGTERM to the process, as kill does. 99 means it never got there.
signal_at_reader() {
    "$REAL_PYTHON" -I -c '
import errno, os, signal, subprocess, sys, time
name, fifo = sys.argv[1:3]
proc = subprocess.Popen(sys.argv[3:], stdin=subprocess.DEVNULL, start_new_session=True,
                        preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL))
held, deadline = None, time.time() + 60
while held is None and time.time() < deadline and proc.poll() is None:
    try:
        held = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
    except OSError as err:
        if err.errno != errno.ENXIO:
            raise
        time.sleep(0.02)
if held is None:
    proc.kill()
    proc.wait()
    sys.exit(99)
if name == "SIGINT":
    os.killpg(proc.pid, signal.SIGINT)
else:
    proc.send_signal(getattr(signal, name))
try:
    rc = proc.wait(timeout=60)
except subprocess.TimeoutExpired:
    os.killpg(proc.pid, signal.SIGKILL)
    sys.exit(99)
sys.exit(128 - rc if rc < 0 else rc)
' "$@"
}

# ─── Old inputs: each invocation in the caller census ─────

@test "the installer ran from the copy and exited 0" {
    [ "$(cat "$BATS_FILE_TMPDIR/install.rc")" -eq 0 ]
    [ -s "$DB" ]
    [ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM sessions WHERE session_id = '$SID'")" -eq 1 ]
}

@test "session-index-backfill.sh --quiet and --since 7 --quiet exit 0 under the plists' 50 lines" {
    run --separate-stderr "$COPY/scripts/session-index-backfill.sh" --quiet
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -lt 50 ]
    assert_no_ansi
    run --separate-stderr "$COPY/scripts/session-index-backfill.sh" --since 7 --quiet
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -lt 50 ]
    assert_no_ansi
}

@test "plist path: the installed link through head -50 exits 0 and records last_backfill" {
    local link="$CLAUDE_HOME/bin/session-index-backfill.sh" log="$BATS_TEST_TMPDIR/plist.log"
    [ -L "$link" ]
    sqlite3 "$DB" "DELETE FROM meta WHERE key = 'last_backfill'"
    run bash -c '"$1" --quiet 2>&1 | head -50 >>"$2"; echo "${PIPESTATUS[0]}"' _ "$link" "$log"
    [ "$status" -eq 0 ]
    [ "$output" = 0 ]
    [ "$(wc -l <"$log")" -lt 50 ]
    [ -n "$(sqlite3 "$DB" "SELECT value FROM meta WHERE key = 'last_backfill'")" ]
}

@test "session-index-chunk.py --backfill and --backfill --since 7 exit 0 through the link" {
    run --separate-stderr "$CLAUDE_HOME/bin/session-index-chunk.py" --backfill
    [ "$status" -eq 0 ]
    has "$output" "Chunked 1 sessions"
    has "$stderr" "1 succeeded, 0 skipped, 0 failed"
    run --separate-stderr "$CLAUDE_HOME/bin/session-index-chunk.py" --backfill --since 7
    [ "$status" -eq 0 ]
    has "$output" "Chunked 1 sessions"
}

@test "session-index-tag.py --regex-only --limit 1000 --quiet is silent through the link" {
    run --separate-stderr "$CLAUDE_HOME/bin/session-index-tag.py" --regex-only --limit 1000 --quiet
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
}

@test "--context-inject stays one string a hook can pass through jq -Rs" {
    run --separate-stderr python3 "$ENGINE" --context-inject "$HOME"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [ "$(printf '%s' "$output" | jq -Rs 'type')" = '"string"' ]
    has "$output" "1 session."
}

@test "--format=fzf q keeps the full session ID as the last tab field" {
    run --separate-stderr python3 "$ENGINE" --format=fzf zephyr
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [ "${#lines[@]}" -eq 1 ]
    [ "${output##*$'\t'}" = "$SID" ]
}

@test "--format=json q is a bare indent=2 array on stdout and its warning is on stderr" {
    run --separate-stderr python3 "$ENGINE" --format=json zephyr
    [ "$status" -eq 0 ]
    has "$stderr" "--format json is deprecated"
    lacks "$output" "deprecated"
    printf '%s\n' "$output" | python3 -I -c '
import json, sys
text = sys.stdin.read()
doc = json.loads(text)
assert isinstance(doc, list) and doc[0]["session_id"] == sys.argv[1], doc
assert json.dumps(doc, indent=2, default=str) + "\n" == text, "not indent=2"
' "$SID"
}

@test "the cue's command: claude-search '<nouns>' --deep-search searches" {
    run --separate-stderr claude-search 'zephyr parser' --deep-search
    [ "$status" -eq 0 ]
    has "$output" "${SID:0:8}"
}

# ─── Process ──────────────────────────────────────────────

@test "a child's exit 42 passes through both wrappers" {
    local wrapper="$WRAPPER" tag_sh="$COPY/scripts/session-index-tag.sh"
    scratch_home
    use_stub_engine
    STUB_RC=42 run "$wrapper" anything
    [ "$status" -eq 42 ]
    printf 'exit 42\n' | _write_stub python3
    run "$tag_sh" --dry-run
    [ "$status" -eq 42 ]
}

@test "argv with spaces and metacharacters reaches the child whole through both wrappers" {
    local wrapper="$WRAPPER" tag_sh="$COPY/scripts/session-index-tag.sh" arg
    local -a weird=('two words' '$HOME' '*' 'a;b' "it's" '"quoted"' 'x|y' $'tab\there' '`id`' '&')
    scratch_home
    use_stub_engine
    run "$wrapper" --project 'my project' -- "${weird[@]}"
    [ "$status" -eq 0 ]
    for arg in 'my project' "${weird[@]}"; do
        calls engine | grep -qxF -- "$arg"
    done
    _write_stub python3 </dev/null
    run "$tag_sh" --project "${weird[@]}"
    [ "$status" -eq 0 ]
    for arg in "${weird[@]}"; do
        calls python3 | grep -qxF -- "$arg"
    done
}

@test "a closed pipe is quiet on every command that prints, unless it writes to stderr anyway" {
    local fail=""
    # Each row: what stderr holds whatever the pipe does, or nothing | the command.
    while IFS='|' read -r expect cmd; do
        # shellcheck disable=SC2086 # the rows are words; none has a space that matters
        run --separate-stderr closed_pipe default $cmd
        case "$status" in 0 | 141) ;; *) fail="$fail
status $status: $cmd" ;; esac
        if [ -z "$expect" ]; then
            [ -z "$stderr" ] || fail="$fail
stderr: $cmd: $stderr"
        else
            case "$stderr" in *"$expect"*) ;; *) fail="$fail
missing [$expect]: $cmd: $stderr" ;; esac
        fi
        case "$stderr" in *Traceback*) fail="$fail
traceback: $cmd" ;; esac
    done <<ROWS
|python3 $ENGINE zephyr
|python3 $ENGINE --stats
|python3 $ENGINE --analytics
|python3 $ENGINE --json zephyr
|python3 $ENGINE --format=fzf zephyr
--format json is deprecated|python3 $ENGINE --format=json zephyr
|python3 $ENGINE --context-inject $HOME
|python3 $ENGINE --help
|$WRAPPER zephyr
|$WRAPPER --help
|$WRAPPER --stats
|$COPY/install.sh --help
|$COPY/install.sh --version
|$COPY/uninstall.sh --help
|$COPY/uninstall.sh --dry-run
|$COPY/scripts/session-index-backfill.sh --help
|$COPY/scripts/session-index-chunk.py --help
1 succeeded|$COPY/scripts/session-index-chunk.py --backfill
|$COPY/scripts/session-index-tag.py --help
|$COPY/scripts/session-index-tag.sh --help
Nothing to tag|$COPY/scripts/session-index-tag.py --dry-run
|$COPY/scripts/session-index-tag.py --regex-only --limit 10
ROWS
    [ -z "$fail" ] || {
        printf '%s\n' "$fail" >&2
        return 1
    }
}

@test "a closed pipe with SIGPIPE ignored, as on CI's runner, is never a traceback or a hang" {
    local cmd
    for cmd in "python3 $ENGINE zephyr" "$WRAPPER zephyr" "$WRAPPER --help" "$COPY/install.sh --version" \
        "$COPY/uninstall.sh --dry-run" "$COPY/scripts/session-index-backfill.sh --help" \
        "$COPY/scripts/session-index-chunk.py --backfill" "$COPY/scripts/session-index-tag.py --dry-run"; do
        # shellcheck disable=SC2086 # the rows are words
        run --separate-stderr closed_pipe ignore $cmd
        case "$status" in 0 | 1 | 141) ;; *)
            echo "status $status: $cmd: $stderr" >&2
            return 1
            ;;
        esac
        lacks "$stderr" "Traceback"
    done
}

@test "TERM exits 143 and INT exits 130 from a real read, through the wrapper and the chunker" {
    local fifo="$TRANSCRIPT.held" sig rc
    mv "$TRANSCRIPT" "$fifo.saved"
    mkfifo "$TRANSCRIPT"
    for sig in SIGTERM:143 SIGINT:130; do
        rc="${sig#*:}"
        run signal_at_reader "${sig%:*}" "$TRANSCRIPT" "$WRAPPER" --preview "$SID"
        [ "$status" -eq "$rc" ] || {
            echo "wrapper ${sig%:*}: status $status" >&2
            mv -f "$fifo.saved" "$TRANSCRIPT"
            return 1
        }
        run signal_at_reader "${sig%:*}" "$TRANSCRIPT" "$CLAUDE_HOME/bin/session-index-chunk.py" "$SID" --transcript "$TRANSCRIPT"
        [ "$status" -eq "$rc" ] || {
            echo "chunk ${sig%:*}: status $status" >&2
            mv -f "$fifo.saved" "$TRANSCRIPT"
            return 1
        }
    done
    mv -f "$fifo.saved" "$TRANSCRIPT"
}

@test "TERM and INT leave session-index-tag.sh with the signal's exit code" {
    local tag_sh="$COPY/scripts/session-index-tag.sh" fifo="$BATS_TEST_TMPDIR/hold"
    scratch_home
    mkfifo "$fifo"
    # The wrapper execs this stub, whose read on the fifo is the wait. exit 7 would mean no signal.
    printf 'read -r _ <"%s"\nexit 7\n' "$fifo" | _write_stub python3
    run signal_at_reader SIGTERM "$fifo" "$tag_sh" --dry-run
    [ "$status" -eq 143 ]
    run signal_at_reader SIGINT "$fifo" "$tag_sh" --dry-run
    [ "$status" -eq 130 ]
}

# ─── Partial failure ──────────────────────────────────────

@test "a settings.json that fails patching exits 1 with its bytes unchanged, both ways" {
    local install="$COPY/install.sh" uninstall="$COPY/uninstall.sh" settings
    scratch_home
    settings="$HOME/.claude/settings.json"
    printf '{ "hooks": [ broken\n' >"$settings"
    cp "$settings" "$HOME/settings.before"
    run "$install"
    [ "$status" -eq 1 ]
    cmp "$settings" "$HOME/settings.before"
    run "$uninstall"
    [ "$status" -eq 1 ]
    cmp "$settings" "$HOME/settings.before"
}

# ─── Round trip: last, because it removes the install ─────

@test "uninstall undoes install, and keeps the DB and what C19 decided stays" {
    local settings="$CLAUDE_HOME/settings.json" name db_before verb path
    local agents="$HOME/Library/LaunchAgents"
    local backfill_plist="$agents/com.claude.session-search-backfill.plist"
    local sweep_plist="$agents/com.claude.session-search-sweep.plist"

    [ "$(cat "$BATS_FILE_TMPDIR/install.rc")" -eq 0 ]
    for name in bin/session-index-tag.py bin/session-index-backfill.sh bin/session-index-chunk.py \
        bin/session-search.py bin/claude-search hooks/session-index-end.sh hooks/session-index-start.sh \
        hooks/session-index-sweep.sh hooks/lib/session-index-helpers.sh; do
        [ "$(readlink "$CLAUDE_HOME/$name")" != "" ]
    done
    [ "$(jq '[.. | objects | .command? // empty | select(test("session-index"))] | length' "$settings")" -ge 2 ]
    [ -f "$backfill_plist" ]
    [ -f "$sweep_plist" ]

    # What a machine that has searched holds. A filtered run has not searched yet.
    python3 "$ENGINE" zephyr >/dev/null 2>&1
    [ -f "$CLAUDE_HOME/.last-search-results.json" ]
    [ -f "$CLAUDE_HOME/.session-search-tips.json" ] || printf '[]\n' >"$CLAUDE_HOME/.session-search-tips.json"
    db_before="$(cksum <"$DB")"

    run "$COPY/uninstall.sh"
    [ "$status" -eq 0 ]

    for name in bin/session-index-tag.py bin/session-index-backfill.sh bin/session-index-chunk.py \
        bin/session-search.py bin/claude-search hooks/session-index-end.sh hooks/session-index-start.sh \
        hooks/session-index-sweep.sh hooks/lib/session-index-helpers.sh; do
        [ ! -e "$CLAUDE_HOME/$name" ] && [ ! -L "$CLAUDE_HOME/$name" ]
    done

    [ "$(jq '[.. | objects | .command? // empty | select(test("session-index"))] | length' "$settings")" -eq 0 ]
    jq -e '.model == "opus" and ([.hooks.PreToolUse[].hooks[].command] == ["~/unrelated-hook.sh"])' "$settings"

    # Each plist was loaded, and the last thing launchctl heard about it was unload.
    [ ! -e "$backfill_plist" ]
    [ ! -e "$sweep_plist" ]
    for path in "$backfill_plist" "$sweep_plist"; do
        calls launchctl | grep -xF -B1 -- "$path" | grep -qx load
        verb="$(calls launchctl | grep -xF -B1 -- "$path" | grep -xE 'load|unload' | tail -1)"
        [ "$verb" = unload ]
    done

    # Invariant 14 and decision C19: these stay.
    [ "$(cksum <"$DB")" = "$db_before" ]
    grep -q '\.claude/bin' "$HOME/.zshrc"
    [ -n "$(find "$CLAUDE_HOME" -name 'settings.json.bak*')" ]
    [ -d "$CLAUDE_HOME/logs" ]
    [ -f "$CLAUDE_HOME/.last-search-results.json" ]
    [ -f "$CLAUDE_HOME/.session-search-tips.json" ]
}

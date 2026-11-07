#!/usr/bin/env bats
# scripts/session-index-backfill.sh once it is past parsing: the lock and the busy timeout, signals
# and temp files, date and stat on this host, and what a run prints. backfill_cli.bats owns the
# parser and help.
#
# Every run uses the sandbox HOME, from a copy of the checkout with no synonyms/default.json: that
# file takes one sqlite3 process per row. The demo DB is removed first, as backfill_cli.bats explains.
#
# RED-proof: not run. Mutation runs were left out while the machine was under load, so no test here
# has been seen to fail on the code before this commit. The golden in "What a run prints" was compared
# by hand with that code's --quiet output, durations aside, and had no differences.

load helpers_scripts

setup() {
    script_sandbox_setup
    DB="$HOME/.claude/session-index.db"
    HELPERS="$REPO/hooks/lib/session-index-helpers.sh"
    rm -f "$DB"
    mkdir "$HOME/copy" "$HOME/bf-tmp"
    cp -R "$REPO/scripts" "$REPO/hooks" "$HOME/copy/"
    # The physical path: macOS's TMPDIR sits behind a symlink.
    COPY="$(cd -P "$HOME/copy" && pwd)"
    BACKFILL="$COPY/scripts/session-index-backfill.sh"
    PROJECT="$HOME/.claude/projects/-p"
    mkdir -p "$PROJECT"
    BG_PIDS=""
}

teardown() {
    local pid
    for pid in ${BG_PIDS:-}; do
        kill "$pid" 2>/dev/null || true
    done
    sandbox_teardown
}

# has <text> <fragment> and lacks <text> <fragment>. Not [[ ]], which errexit misses on bash 3.2.
has() {
    case "$1" in
        *"$2"*) ;;
        *)
            echo "no [$2] in: $1" >&2
            return 1
            ;;
    esac
}

lacks() {
    case "$1" in
        *"$2"*)
            echo "[$2] in: $1" >&2
            return 1
            ;;
    esac
}

# Two rows in sessions-index.json. seed_row <id> <modified> adds more.
seed_index() {
    printf '{"entries":[]}\n' >"$PROJECT/sessions-index.json"
    seed_row s-one 2026-01-02T00:00:00.000Z
    seed_row s-two 2026-01-03T00:00:00.000Z
}

seed_row() {
    local file="$PROJECT/sessions-index.json"
    jq --arg id "$1" --arg modified "$2" '.entries += [{sessionId: $id, summary: "sum", firstPrompt: "prompt",
        gitBranch: "main", created: "2026-01-01T00:00:00.000Z", modified: $modified, messageCount: 3,
        projectPath: "/p"}]' "$file" >"$file.new"
    mv "$file.new" "$file"
}

# One row for each phase that writes: index, history, legacy history and a transcript.
seed_all_phases() {
    printf '{"entries":[]}\n' >"$PROJECT/sessions-index.json"
    seed_row s-one 2026-01-02T00:00:00.000Z
    printf '%s\n' '{"sessionId":"s-hist","display":"hello there","project":"/p","timestamp":1767225600000}' \
        '{"display":"legacy one","project":"/p","timestamp":1767225600000}' >"$HOME/.claude/history.jsonl"
    seed_transcript 11111111-1111-1111-1111-111111111111
}

seed_transcript() {
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"please fix the bug in the parser today"}}' \
        '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done with it"}]}}' \
        >"$PROJECT/$1.jsonl"
}

# fake_chunk <python>: the copy's chunk script becomes this body.
fake_chunk() {
    printf '%s\n' "$1" >"$COPY/scripts/session-index-chunk.py"
}

# Every statement waits, so a fixture write can't lose to a slow close of the last process.
db() {
    sqlite3 "$DB" ".timeout 60000" "$1"
}

indexed() {
    [ "$(db "SELECT COUNT(*) FROM sessions WHERE session_id='$1';")" = 1 ]
}

# Durations and the DB's size vary. Everything else is compared byte for byte.
normalized() {
    sed -E 's/\([0-9.]+s\)/(Ts)/; s/^(Backfill Complete  )[0-9.]+s$/\1Ts/; s/^(Database: ).*/\1SIZE/'
}

# hold_write_lock: another process holds SQLite's write lock until the test ends.
hold_write_lock() {
    python3 -I -c '
import os, sqlite3, sys, time
conn = sqlite3.connect(sys.argv[1], isolation_level=None)
conn.execute("BEGIN IMMEDIATE")
open(sys.argv[2], "w").close()
time.sleep(600)
' "$DB" "$HOME/write-locked" >/dev/null 2>&1 3>&- &
    BG_PIDS="$BG_PIDS $!"
    wait_for "$HOME/write-locked"
}

# hold_index_lock: another process holds the index lock until the test ends, by flock or mkdir.
hold_index_lock() {
    HOME="$HOME" HELPERS="$HELPERS" /bin/bash -c '
        source "$HELPERS"
        session_index_trylock || exit 7
        : >"$HOME/index-locked"
        exec sleep 600' >/dev/null 2>&1 3>&- &
    BG_PIDS="$BG_PIDS $!"
    wait_for "$HOME/index-locked"
}

index_lock_is_free() {
    HOME="$HOME" HELPERS="$HELPERS" /bin/bash -c 'source "$HELPERS"; session_index_trylock'
}

wait_for() {
    local i
    for ((i = 0; i < 1200; i++)); do
        [ ! -e "$1" ] || return 0
        sleep 0.05
    done
    echo "never appeared: $1" >&2
    return 1
}

# stop_at <tool> <argv fragment>: the first call of tool with that fragment records the temp dir, then
# waits for the test to have sent its signal. So the signal lands in that phase, deterministically.
stop_at() {
    _write_stub "$1" <<STUB
case "\$*" in
    *"$2"*)
        if [ ! -e "\$HOME/gate" ]; then
            ls -A "\$HOME/bf-tmp" >"\$HOME/tmp-at-gate"
            : >"\$HOME/gate"
            while [ ! -e "\$HOME/signalled" ]; do sleep 0.05; done
        fi
        ;;
esac
PATH="\$HOME/tools:/usr/bin:/bin" exec "$1" "\$@"
STUB
}

# signal_in_pty <SIGNAME>: runs the backfill on a terminal, sends the signal once stop_at's gate opens,
# and leaves what the terminal showed in $HOME/pty.out. Exits with the backfill's status.
signal_in_pty() {
    # In a known place, whatever the host: macOS's bare mktemp ignores TMPDIR.
    _write_stub mktemp <<'STUB'
[ "$#" -eq 0 ] && set -- "$HOME/bf-tmp/tmp.XXXXXX"
PATH=/usr/bin:/bin exec mktemp "$@"
STUB
    run python3 -I -c '
import os, pty, select, signal, sys, time
home, name = sys.argv[1:3]
pid, fd = pty.fork()
if pid == 0:
    os.execv(sys.argv[3], sys.argv[3:])
output, sent, deadline = [], False, time.time() + 300
while time.time() < deadline:
    if not sent and os.path.exists(home + "/gate"):
        os.kill(pid, getattr(signal, name))
        open(home + "/signalled", "w").close()
        sent = True
    ready, _, _ = select.select([fd], [], [], 0.05)
    if ready:
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        output.append(chunk)
else:
    os.kill(pid, signal.SIGKILL)
open(home + "/pty.out", "wb").write(b"".join(output))
sys.exit(os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]))
' "$HOME" "$1" "$BACKFILL"
}

# assert_stopped_clean <status>: the status, a cursor shown again after it was hidden, no temp files
# left though one existed at the signal, and the index lock free.
assert_stopped_clean() {
    [ "$status" -eq "$1" ] || {
        echo "status $status, wanted $1: $output" >&2
        return 1
    }
    [ -s "$HOME/tmp-at-gate" ]
    python3 -I -c '
import sys
shown = open(sys.argv[1], "rb").read()
hide, show = shown.rfind(b"\x1b[?25l"), shown.rfind(b"\x1b[?25h")
sys.exit(0 if 0 <= hide < show else 1)
' "$HOME/pty.out"
    [ -z "$(ls -A "$HOME/bf-tmp")" ]
    index_lock_is_free
}

# ─── Busy timeout and lock ───────────────────────────────

@test "every sqlite3 call in backfill sets a timeout" {
    # The wrapper is the rule. The heredocs and -separator can't use it, so each carries .timeout.
    run awk '
        expect { if ($0 != ".timeout $SESSION_INDEX_BUSY_TIMEOUT") print "no timeout after line " NR - 1; expect = 0 }
        /sqlite3[[:space:]]+(-|"|\$)/ {
            if ($0 ~ /<<SQL$/) { heredocs++; expect = 1 }
            else if ($0 ~ /sqlite3 -separator .* ".timeout \$SESSION_INDEX_BUSY_TIMEOUT"/) separators++
            else print "raw call at line " NR ": " $0
        }
        END { print heredocs + 0, "heredocs", separators + 0, "separator" }
    ' "$BACKFILL"
    [ "$status" -eq 0 ]
    [ "$output" = "3 heredocs 1 separator" ]
}

@test "init_db runs after the lock" {
    hold_index_lock
    run --separate-stderr "$BACKFILL" --if-idle
    [ "$status" -eq 0 ]
    [ ! -e "$DB" ]
}

@test "a locked DB retries, then exits nonzero" {
    seed_index
    "$BACKFILL" --quiet >/dev/null
    local stamped
    stamped="$(db "SELECT value FROM meta WHERE key='last_backfill';")"
    hold_write_lock

    run --separate-stderr env SESSION_INDEX_BUSY_TIMEOUT=10 "$BACKFILL"
    [ "$status" -eq 5 ]
    [ "$(printf '%s\n' "$stderr" | grep -c 'Retrying automatically…')" -eq 1 ]
    [ "$(printf '%s\n' "$stderr" | grep -c 'database is locked')" -eq 4 ]
    [ "$(db "SELECT value FROM meta WHERE key='last_backfill';")" = "$stamped" ]
    index_lock_is_free

    run --separate-stderr env SESSION_INDEX_BUSY_TIMEOUT=10 "$BACKFILL" --quiet
    [ "$status" -eq 5 ]
    lacks "$stderr" "Retrying automatically"
}

@test "a command that stops being locked succeeds, and only a lock is retried" {
    run env HELPERS="$HELPERS" /bin/bash -c '
        set -euo pipefail
        source "$HELPERS"
        tries=0
        twice_locked() { tries=$((tries + 1)); [ "$tries" -gt 2 ] || return 5; }
        session_index_retry_busy twice_locked
        echo "locked: $tries tries"
        tries=0
        broken() { tries=$((tries + 1)); return 3; }
        rc=0
        session_index_retry_busy broken || rc=$?
        echo "broken: $tries try, rc $rc"'
    [ "$status" -eq 0 ]
    has "$output" "locked: 3 tries"
    has "$output" "broken: 1 try, rc 3"
}

@test "a failed row in the middle of the synonyms still fails the load" {
    "$BACKFILL" --quiet >/dev/null
    printf '%s\n' '[{"term":"a","category":"c","expansions":["b","c","d"]}]' >"$HOME/syn.json"
    # Only the first write fails, so the loop's last status alone would read as success.
    _write_stub sqlite3 <<'STUB'
if [ ! -e "$HOME/failed-once" ]; then
    : >"$HOME/failed-once"
    exit 5
fi
exec "$HOME/tools/sqlite3" "$@"
STUB
    run env HELPERS="$HELPERS" /bin/bash -c '
        set -euo pipefail
        source "$HELPERS"
        rc=0
        session_index_load_synonyms "$HOME/syn.json" || rc=$?
        echo "rc $rc"'
    [ "$status" -eq 0 ]
    [ "$output" = "rc 5" ]
}

@test "a failed rebuild leaves the old index" {
    seed_index
    "$BACKFILL" --quiet >/dev/null
    [ "$(db "SELECT COUNT(*) FROM sessions_fts;")" -eq 2 ]
    # The DELETE succeeds, then the INSERT can't compile.
    db "ALTER TABLE sessions RENAME COLUMN search_aliases TO renamed;"

    run --separate-stderr env HELPERS="$HELPERS" /bin/bash -c 'source "$HELPERS"; session_index_rebuild_fts'
    [ "$status" -ne 0 ]
    [ "$(db "SELECT COUNT(*) FROM sessions_fts;")" -eq 2 ]
}

# ─── Signals and temp files ──────────────────────────────

@test "SIGINT exits 130, restores the cursor, removes temp files and unlocks" {
    seed_index
    stop_at jq ".sid"
    signal_in_pty SIGINT
    assert_stopped_clean 130
}

@test "SIGTERM exits 143, restores the cursor, removes Phase 5's temp file and unlocks" {
    seed_index
    stop_at sed "s|/|-|g"
    signal_in_pty SIGTERM
    assert_stopped_clean 143
}

@test "SIGHUP exits 129, restores the cursor, removes temp files and unlocks" {
    seed_index
    stop_at jq ".sid"
    signal_in_pty SIGHUP
    assert_stopped_clean 129
}

@test "TERM during Phase 7 exits promptly and leaves no child" {
    fake_chunk 'import os, time
home = os.environ["HOME"]
with open(home + "/chunk.pid", "w") as f:
    f.write(str(os.getpid()))
open(home + "/chunk.ready", "w").close()
time.sleep(600)'
    "$BACKFILL" >/dev/null 2>&1 3>&- &
    local pid=$! child i rc=0 started
    BG_PIDS="$BG_PIDS $pid"
    wait_for "$HOME/chunk.ready"
    child="$(cat "$HOME/chunk.pid")"
    BG_PIDS="$BG_PIDS $child"

    started=$SECONDS
    kill -TERM "$pid"
    wait "$pid" || rc=$?
    [ "$rc" -eq 143 ]
    # Well under the child's 600 seconds, and generous for a loaded machine.
    [ $((SECONDS - started)) -lt 60 ]
    for ((i = 0; i < 200; i++)); do
        kill -0 "$child" 2>/dev/null || break
        sleep 0.05
    done
    if kill -0 "$child" 2>/dev/null; then
        echo "child $child still alive" >&2
        return 1
    fi
    index_lock_is_free
}

@test "a set -e failure keeps its status" {
    fake_chunk 'import sys
sys.exit(7)'
    run --separate-stderr "$BACKFILL"
    [ "$status" -eq 7 ]
    index_lock_is_free
    # last_backfill is what a scheduled run's freshness check reads.
    [ -z "$(db "SELECT value FROM meta WHERE key='last_backfill';")" ]
}

@test "a failing Phase 7 names the line and keeps the exit code" {
    fake_chunk 'import sys
sys.exit(7)'
    run --separate-stderr "$BACKFILL" --quiet
    [ "$status" -eq 7 ]
    # The wait, except on bash 3.2, whose LINENO in a trap is the end of the enclosing `if`.
    local first last line
    first="$(grep -n '^    wait "\$_BF_CHILD"$' "$BACKFILL" | cut -d: -f1)"
    last="$(awk -v from="$first" 'NR > from && /^fi$/ { print NR; exit }' "$BACKFILL")"
    line="${stderr#error: backfill failed at line }"
    line="${line% (exit 7)}"
    [ "$stderr" = "error: backfill failed at line $line (exit 7)" ]
    [ "$line" -ge "$first" ]
    [ "$line" -le "$last" ]
}

# ─── date and stat on this host ──────────────────────────

# iso_ago <seconds>: that long ago, in the form sessions-index.json holds. Python is the oracle because
# it shares no code with either dialect.
iso_ago() {
    python3 -I -c 'import datetime, sys
now = datetime.datetime.now(datetime.timezone.utc)
print((now - datetime.timedelta(seconds=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%S.000Z"))' "$1"
}

since_run() {
    fake_chunk 'pass'
    printf '{"entries":[]}\n' >"$PROJECT/sessions-index.json"
    seed_row s-recent "$(iso_ago 21600)"
    seed_row s-stale "$(iso_ago 72000)"
    # Modified values are UTC. Read as local time at UTC-12 the stale row looks 8 hours old, and at
    # UTC+9 the recent row looks 15 hours old.
    run --separate-stderr env TZ=Etc/GMT+12 "$BACKFILL" --since 12h
    [ "$status" -eq 0 ]
    lacks "$stderr" "Warning"
    indexed s-recent
    run ! indexed s-stale
    printf '{"entries":[]}\n' >"$PROJECT/sessions-index.json"
    seed_row s-recent-east "$(iso_ago 21600)"
    seed_row s-stale-east "$(iso_ago 72000)"
    run --separate-stderr env TZ=Asia/Tokyo "$BACKFILL" --since 12h
    [ "$status" -eq 0 ]
    indexed s-recent-east
    run ! indexed s-stale-east
}

@test "--since keeps recent Phase 1 rows on this host's date dialect" {
    since_run
}

# The transcript's mtime in local time labelled Z, as macOS has always stored it.
mtime_oracle() {
    TZ="$2" python3 -I -c 'import datetime, os, sys
print(datetime.datetime.fromtimestamp(os.stat(sys.argv[1]).st_mtime).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"
}

assert_transcript_mtime() {
    fake_chunk 'pass'
    seed_transcript 22222222-2222-2222-2222-222222222222
    local file="$PROJECT/22222222-2222-2222-2222-222222222222.jsonl" want
    touch -t 202603011030.15 "$file"
    want="$(mtime_oracle "$file" Asia/Tokyo)"
    run --separate-stderr env TZ=Asia/Tokyo "$BACKFILL"
    [ "$status" -eq 0 ]
    [ "$(db "SELECT created_at FROM sessions WHERE session_id='22222222-2222-2222-2222-222222222222';")" = "$want" ]
}

@test "transcript mtime is one ISO line" {
    assert_transcript_mtime
}

@test "history times are UTC on this host's date dialect" {
    fake_chunk 'pass'
    printf '%s\n' '{"sessionId":"s-hist","display":"hello there","project":"/p","timestamp":1767225600000}' \
        '{"display":"legacy one","project":"/p","timestamp":1767229200000}' >"$HOME/.claude/history.jsonl"
    run --separate-stderr env TZ=Asia/Tokyo "$BACKFILL"
    [ "$status" -eq 0 ]
    [ "$(db "SELECT modified_at FROM sessions WHERE session_id='s-hist';")" = 2026-01-01T00:00:00Z ]
    [ "$(db "SELECT modified_at FROM sessions WHERE source='history-legacy';")" = 2026-01-01T01:00:00Z ]
}

@test "unknown time keeps the row and warns once" {
    fake_chunk 'pass'
    printf '{"entries":[]}\n' >"$PROJECT/sessions-index.json"
    seed_row s-bad-one "not a time"
    seed_row s-bad-two "also not a time"
    run --separate-stderr "$BACKFILL" --since 7 --quiet
    [ "$status" -eq 0 ]
    indexed s-bad-one
    indexed s-bad-two
    [ "$(printf '%s\n' "$stderr" | grep -c '^Warning: ')" -eq 1 ]
}

@test "a transcript whose mtime can't be read stays, with one warning" {
    fake_chunk 'pass'
    seed_transcript 33333333-3333-3333-3333-333333333333
    # Answers the dialect probe as the real one does, and fails on every file.
    _write_stub stat <<'STUB'
[ "${1:-}" != --version ] && exit 1
PATH=/usr/bin:/bin exec stat "$@"
STUB
    run --separate-stderr "$BACKFILL" --since 7 --quiet
    [ "$status" -eq 0 ]
    indexed 33333333-3333-3333-3333-333333333333
    [ "$(printf '%s\n' "$stderr" | grep -c '^Warning: ')" -eq 1 ]
}

@test "on a Mac with GNU tools first on PATH, the GNU branches give the same answers" {
    local gdate gstat
    gdate="$(PATH="$REAL_PATH" command -v gdate || true)"
    gstat="$(PATH="$REAL_PATH" command -v gstat || true)"
    if [ -z "$gdate" ] || [ -z "$gstat" ]; then
        skip "no gdate and gstat: on Linux the other tests run these branches"
    fi
    ln -s "$gdate" "$HOME/stubs/date"
    ln -s "$gstat" "$HOME/stubs/stat"
    since_run
    assert_transcript_mtime
}

# ─── What a run prints ───────────────────────────────────

# A plain run over seed_all_phases, as it read before this file's commit, durations aside.
golden() {
    cat <<'GOLDEN'

Session Index Backfill  0 existing

Phase 1: Session index scan: done, 1 indexed (Ts)
Phase 2: History gap fill: done, 1 new, 0 skipped (Ts)
Phase 3: Legacy entries: done, 1 synthetic (Ts)
Phase 4: Transcript enrichment: done, 0 enriched, 1 new (Ts)
Phase 4b: Workflow results: skipped (no workflow files)
Phase 5: Enrichment gap-fill: done, 0 enriched, 1 empty, 2 no transcript (Ts)
Phase 6: FTS rebuild: done, 4 entries, 0 synonyms (Ts)
Phase 7: Chunk generation: done, 0 chunks (Ts)

Backfill Complete  Ts
Sessions: 4 total
Untagged: 4 remaining
FTS index: 4 entries
Database: SIZE

GOLDEN
}

@test "not quiet names the DB on stderr first" {
    fake_chunk 'pass'
    run --separate-stderr "$BACKFILL"
    [ "$status" -eq 0 ]
    [ "$stderr" = "Session index: $DB" ]
    # It precedes the wait for the lock, so a blocked run has already said what it is waiting on.
    hold_index_lock
    run --separate-stderr "$BACKFILL" --if-idle
    [ "$status" -eq 0 ]
    [ "$stderr" = "Session index: $DB" ]
}

@test "--quiet output is byte-identical" {
    fake_chunk 'pass'
    seed_all_phases
    run --separate-stderr "$BACKFILL" --quiet
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [ "$(printf '%s\n' "$output" | normalized)" = "$(golden)" ]
}

@test "default output is unchanged" {
    fake_chunk 'pass'
    seed_all_phases
    run --separate-stderr "$BACKFILL"
    [ "$status" -eq 0 ]
    # Only the phase-start lines are new on stdout, one per phase that ran.
    [ "$(printf '%s\n' "$output" | grep -c ': started$')" -eq 7 ]
    [ "$(printf '%s\n' "$output" | grep -v ': started$' | normalized)" = "$(golden)" ]
    # The repo plist pipes this into head -50, and SIGPIPE before the end would lose last_backfill.
    [ "$(printf '%s\n' "$output" | wc -l)" -lt 50 ]
    assert_no_ansi
}

@test "--json stdout is one document with phase counts" {
    fake_chunk 'pass'
    seed_all_phases
    run --separate-stderr "$BACKFILL" --json
    [ "$status" -eq 0 ]
    assert_one_json_doc "$output"
    printf '%s' "$output" | jq -e --arg db "$DB" '.ok == true and .database == $db and .total == 4 and .untagged == 4
        and .phases.phase1.indexed == 1
        and .phases.phase2 == {new: 1, skipped: 0}
        and .phases.phase3.synthetic == 1
        and .phases.phase4 == {enriched: 0, inserted: 1, skipped: 0}
        and .phases.phase5 == {enriched: 0, empty: 1, no_transcript: 2}
        and .phases.phase6 == {fts_entries: 4, synonyms: 0}'
    # The human output moved, whole, and --json does not imply --quiet.
    has "$stderr" "Session index: $DB"
    has "$stderr" "Phase 1: Session index scan: started"
    has "$stderr" "Backfill Complete"
}

@test "--json counts what really ran, with the phases --enrich-only skips at 0" {
    fake_chunk 'pass'
    seed_all_phases
    run --separate-stderr "$BACKFILL" --json --enrich-only
    [ "$status" -eq 0 ]
    assert_one_json_doc "$output"
    printf '%s' "$output" | jq -e '.ok == true and .phases.phase1.indexed == 0 and .phases.phase4.inserted == 1'
}

@test "--json on failure has an error document and the original rc" {
    fake_chunk 'import sys
sys.exit(7)'
    seed_index
    run --separate-stderr "$BACKFILL" --json
    [ "$status" -eq 7 ]
    assert_one_json_doc "$output"
    printf '%s' "$output" | jq -e '.ok == false and .exit_code == 7 and .phase == "Phase 7: Chunk generation"
        and .phases.phase1.indexed == 2 and (.message | contains("re-run"))'
}

@test "--json keeps its document when the lock skips the run" {
    hold_index_lock
    run --separate-stderr "$BACKFILL" --json --if-idle
    [ "$status" -eq 0 ]
    assert_one_json_doc "$output"
    printf '%s' "$output" | jq -e '.ok == true and .skipped == true'
}

@test "--json before any phase still fails with one document" {
    run --separate-stderr "$BACKFILL" --json --since abc
    [ "$status" -eq 2 ]
    assert_one_json_doc "$output"
    printf '%s' "$output" | jq -e '.ok == false and .exit_code == 2 and .phase == "Startup"'
    has "$stderr" "invalid --since"
}

@test "--version needs no HOME and prints the VERSION file" {
    printf '9.8.7\n' >"$COPY/VERSION"
    run --separate-stderr env -u HOME "$BACKFILL" --version
    [ "$status" -eq 0 ]
    [ "$output" = 9.8.7 ]
    run --separate-stderr env -u HOME "$BACKFILL" -v --json
    [ "$status" -eq 0 ]
    [ "$output" = '{"version":"9.8.7"}' ]
}

@test "--no-color removes color on a terminal and keeps the cursor control" {
    fake_chunk 'pass'
    run run_in_pty "$BACKFILL"
    [ "$status" -eq 0 ]
    has "$output" $'\033[32m'
    run run_in_pty "$BACKFILL" --no-color
    [ "$status" -eq 0 ]
    lacks "$output" $'\033[32m'
    has "$output" $'\033[?25l'
}

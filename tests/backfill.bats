#!/usr/bin/env bats
# What a failure looks like from outside: the engine's exit codes and streams when the index, the
# cache or the chunk table is bad, and backfill --if-idle with the lock held. Each backfill run
# starts from no DB, as backfill_cli.bats explains, in a copy of the checkout with no synonyms file.

load helpers_scripts

setup() {
    script_sandbox_setup
    ENGINE="$HOME/.claude/bin/session-search.py"
    DB="$HOME/.claude/session-index.db"
    CACHE="$HOME/.claude/.last-search-results.json"
    LOCK="$HOME/.claude/session-index.lock"
    HELPERS="$REPO/hooks/lib/session-index-helpers.sh"
}

teardown() {
    sandbox_teardown
}

engine() { python3 "$ENGINE" "$@"; }

use_backfill_copy() {
    rm -f "$DB"
    mkdir "$HOME/copy"
    cp -R "$REPO/scripts" "$REPO/hooks" "$HOME/copy/"
    BACKFILL="$(cd -P "$HOME/copy" && pwd)/scripts/session-index-backfill.sh"
}

# flock on a host that has it, which is ubuntu-latest. macOS has none, so the mkdir lock there.
hold_index_lock() {
    if command -v flock >/dev/null 2>&1; then
        exec 8>"$LOCK"
        flock -x 8
    else
        mkdir "$LOCK.d"
    fi
}

backfilled() {
    [ -n "$(sqlite3 "$DB" "SELECT value FROM meta WHERE key = 'last_backfill';")" ]
}

# trylock_in_shell <path>: session_index_trylock in a fresh bash on that PATH. The EXIT trap it sets
# releases the lock, so the shell prints what the lock looked like while held.
trylock_in_shell() {
    run env PATH="$1" LOCK="$LOCK" HELPERS="$HELPERS" /bin/bash -c '
        source "$HELPERS"
        session_index_trylock || exit 7
        [ -d "$LOCK.d" ] && echo holds-mkdir
        echo got-lock'
}

# A PATH with what the trylock needs and no flock, whatever the host has.
no_flock_path() {
    local tool tool_path
    mkdir -p "$HOME/noflock"
    for tool in mkdir rmdir dirname; do
        tool_path="$(command -v "$tool")"
        ln -sf "$tool_path" "$HOME/noflock/$tool"
    done
    printf '%s' "$HOME/noflock"
}

# ─── Failures are not empty results ──────────────────────

@test "broken index fails with exit 1 naming the DB" {
    sqlite3 "$DB" "DROP TABLE sessions_fts;"
    run --separate-stderr engine rum
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *session-index.db* ]]
    [[ "$stderr" == *session-index-backfill.sh* ]]
    [[ "$stderr" != *Traceback* ]]
}

@test "broken index under --json is one error document" {
    sqlite3 "$DB" "DROP TABLE sessions_fts;"
    run --separate-stderr engine --json rum
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    assert_one_json_doc "$stderr"
    printf '%s' "$stderr" | jq -e '.status=="error" and (.message|contains("session-index.db"))'
}

@test "a query FTS5 rejects is an empty result, exit 0" {
    run --separate-stderr engine --json '"'
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.sessions==[]'
}

@test "--deep-search with no chunk index still searches and says how to build it" {
    run --separate-stderr engine --format=json rum --deep-search
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e 'length > 0'
    [[ "$stderr" == *"Deep search unavailable: the chunk index isn't built."* ]]
    printf '%s\n' "$stderr" | grep -Fxq 'Build it:'
    printf '%s\n' "$stderr" | grep -Fxq '    ~/.claude/bin/session-index-chunk.py --backfill'
}

@test "--json --deep-search with no chunk index carries the warning in the document" {
    run --separate-stderr engine --json rum --deep-search
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    assert_one_json_doc "$output"
    printf '%s' "$output" | jq -e '(.sessions|length > 0) and (.warnings[0].message|contains("--backfill"))'
}

# ─── --before ────────────────────────────────────────────

@test "--before alone narrows results" {
    run --separate-stderr engine --json rum
    printf '%s' "$output" | jq -e '.sessions|length > 0'
    run --separate-stderr engine --json --before 2000-01-01 rum
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.sessions|length==0'
}

# ─── Result cache ────────────────────────────────────────

@test "a corrupt result cache is an error, not an empty list" {
    printf '{' >"$CACHE"
    run --separate-stderr engine --resume-result 1
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"Can't read the result cache at ~/.claude/.last-search-results.json"* ]]
    [[ "$stderr" == *'claude-search "<QUERY>"'* ]]
}

@test "no result cache is the missing-search usage error" {
    rm -f "$CACHE"
    run --separate-stderr engine --resume-result 1
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"No cached results to resume."* ]]
}

@test "a search still saves its results for --resume" {
    run --separate-stderr engine --json rum
    [ "$status" -eq 0 ]
    jq -e 'length > 0' "$CACHE"
    run --separate-stderr engine --resume-result 1
    [ "$status" -eq 0 ]
    [ "$output" = "$(jq -r '.[0].session_id' "$CACHE")" ]
}

# ─── Analytics ───────────────────────────────────────────

@test "--json --analytics prints one document" {
    engine --json rum >/dev/null
    run --separate-stderr engine --json --analytics
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    assert_one_json_doc "$output"
    printf '%s' "$output" | jq -e '.analytics.total==1 and (.analytics.top_queries[0].query=="rum") and (.analytics.recent|length==1)'
}

@test "--json --analytics --fails has only the zero-result side" {
    engine --json rum >/dev/null
    sqlite3 "$DB" "INSERT INTO search_log (query, result_count, pipeline_ms) VALUES ('nothing here', 0, 5);"
    run --separate-stderr engine --json --analytics --fails
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.analytics.zero_result_queries==[{"query":"nothing here","count":1}] and (.analytics|has("top_queries")|not)'
}

@test "--json --analytics with no history is still a document" {
    run --separate-stderr engine --json --analytics
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.analytics.total==0'
}

# ─── Backfill --if-idle ──────────────────────────────────

@test "backfill --if-idle exits 0 when the lock is held" {
    use_backfill_copy
    hold_index_lock
    run --separate-stderr "$BACKFILL" --if-idle
    [ "$status" -eq 0 ]
    grep -q 'Backfill skipped: index busy' "$HOME/.claude/logs/session-index.log"
    run ! backfilled
    # The holder's lock is not this run's to release.
    if ! command -v flock >/dev/null 2>&1; then
        [ -d "$LOCK.d" ]
    fi
}

@test "backfill --if-idle runs when the lock is free, and releases it" {
    use_backfill_copy
    run --separate-stderr "$BACKFILL" --if-idle --since 7 --quiet
    [ "$status" -eq 0 ]
    backfilled
    [ ! -e "$LOCK.d" ]
    run ! grep -q 'Backfill skipped' "$HOME/.claude/logs/session-index.log"
}

@test "backfill help documents --if-idle, and it parses" {
    use_backfill_copy
    run "$BACKFILL" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--if-idle"* ]]
    run env __SESSION_SEARCH_PARSE_ONLY=1 "$BACKFILL" --if-idle --since 7 --quiet
    [ "$status" -eq 0 ]
}

# ─── session_index_trylock ───────────────────────────────

@test "trylock on a host with flock: a held lock returns 1 and takes no mkdir lock" {
    _write_stub flock <<'STUB'
exit 1
STUB
    trylock_in_shell "$HOME/stubs:/usr/bin:/bin"
    [ "$status" -eq 7 ]
    [ ! -e "$LOCK.d" ]
}

@test "trylock on a host with flock: a free lock is taken with flock alone" {
    _write_stub flock <<'STUB'
exit 0
STUB
    trylock_in_shell "$HOME/stubs:/usr/bin:/bin"
    [ "$status" -eq 0 ]
    [ "$output" = got-lock ]
}

@test "trylock with no flock: the mkdir lock is taken and released" {
    trylock_in_shell "$(no_flock_path)"
    [ "$status" -eq 0 ]
    [[ "$output" == *holds-mkdir* ]]
    [ ! -e "$LOCK.d" ]
}

@test "trylock with no flock: a held mkdir lock returns 1 and stays" {
    mkdir "$LOCK.d"
    trylock_in_shell "$(no_flock_path)"
    [ "$status" -eq 7 ]
    [ -d "$LOCK.d" ]
}

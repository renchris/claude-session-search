#!/usr/bin/env bats
# bin/session-search.py run for real in the sandbox: what each outcome prints, on which stream, with
# which exit code. The wrapper has its own suite.

load helpers

setup() {
    sandbox_setup
    ENGINE="$HOME/.claude/bin/session-search.py"
    DB="$HOME/.claude/session-index.db"
    CACHE="$HOME/.claude/.last-search-results.json"
}
teardown() { sandbox_teardown; }

engine() { python3 "$ENGINE" "$@"; }

# seed_workflow_file <id>: the file workflow_result_path falls back to when no tracking row names one.
# WF_FILE is relative to HOME: a TMPDIR ending in / gives HOME a // that Python's Path normalizes away.
seed_workflow_file() {
    WF_FILE=".claude/projects/-x/sess/workflows/$1.json"
    mkdir -p "$(dirname "$HOME/$WF_FILE")"
    printf '{}' >"$HOME/$WF_FILE"
}

# seed_session_row <id>: a sessions row only. Preview reads it directly, so FTS needs no entry.
seed_session_row() {
    sqlite3 "$DB" "INSERT INTO sessions (session_id, project_path, project_name, summary, created_at, modified_at, indexed_at)
        VALUES ('$1', '/p', 'p', 'seeded', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');"
}

# ─── Missing index ───────────────────────────────────────

@test "missing index names the file and the build command" {
    rm -f "$DB"
    run --separate-stderr engine aurora
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *session-index.db* ]]
    printf '%s\n' "$stderr" | grep -Eq '^    .*session-index-backfill\.sh$'
}

@test "--json missing index is one error document asking for a human step" {
    rm -f "$DB"
    run --separate-stderr engine --json aurora
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    assert_one_json_doc "$stderr"
    printf '%s' "$stderr" | jq -e '.status=="action_required" and .reason=="not_found" and (.next[0].argv[0]|endswith("session-index-backfill.sh"))'
}

# ─── Missing query ───────────────────────────────────────

@test "missing query is a usage error on stderr" {
    run --separate-stderr engine --limit 3
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    [[ "$stderr" == *"missing search query"* ]]
    [[ "$stderr" == *"claude-search --help"* ]]
}

@test "empty fzf feed prints no help rows" {
    run --separate-stderr engine --format=fzf
    [ "$status" -eq 2 ]
    [ -z "$output" ]
}

# ─── Preview ─────────────────────────────────────────────

@test "unknown session preview fails on stderr" {
    run --separate-stderr engine --preview nope
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"Couldn't find session nope."* ]]
    printf '%s\n' "$stderr" | grep -Eq '^    claude-search "<QUERY>"$'
}

@test "unknown session preview strips terminal escapes from the echoed ID" {
    run --separate-stderr engine --preview $'no\033[31mpe'
    [ "$status" -eq 1 ]
    assert_no_ansi "$stderr"
    [[ "$stderr" == *"Couldn't find session nope."* ]]
}

@test "known session preview exits 0" {
    id="$(sqlite3 "$DB" 'select session_id from sessions limit 1')"
    run --separate-stderr engine --preview "$id"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

# ─── Resume ──────────────────────────────────────────────

@test "resume out of range exits 2 with a runnable next command" {
    run --separate-stderr engine --resume-result 999 migration
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    [[ "$stderr" == *"Result #999 is out of range: the last search returned "*" results."* ]]
    printf '%s\n' "$stderr" | grep -Eq '^    claude-search --resume 1$'
}

@test "resume with no cache exits 2" {
    run --separate-stderr engine --resume-result 1
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    [[ "$stderr" == *"No cached results to resume."* ]]
    printf '%s\n' "$stderr" | grep -Eq '^    claude-search "<QUERY>"$'
    printf '%s\n' "$stderr" | grep -Eq '^    claude-search --resume 1$'
}

@test "resume with a query that matches nothing exits 1" {
    run --separate-stderr engine --resume-result 1 zzzqqqxxxnomatch
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *'No sessions match "zzzqqqxxxnomatch".'* ]]
}

@test "resume refuses a legacy session" {
    printf '[{"session_id":"legacy-1","summary":"old"}]' >"$CACHE"
    run --separate-stderr engine --resume-result 1
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"legacy session"* ]]
}

@test "resume prints the target on stderr and only the ID on stdout" {
    run --separate-stderr engine --resume-result 1 migration
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [[ "$output" =~ ^[A-Za-z0-9_-]+$ ]]
    [[ "$stderr" == *"#1"* ]]
    [[ "$stderr" == *"$output"* ]]
    [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "resume from the cache still names the project" {
    run --separate-stderr engine aurora --limit 1
    [ "$status" -eq 0 ]
    id="$(jq -r '.[0].session_id' "$CACHE")"
    project="$(sqlite3 "$DB" "select project_name from sessions where session_id='$id'")"
    [ -n "$project" ]
    run --separate-stderr engine --resume-result 1
    [ "$status" -eq 0 ]
    [ "$output" = "$id" ]
    [[ "$stderr" == *"($project, $id)"* ]]
}

@test "resume target line strips terminal escapes from the summary" {
    printf '[{"session_id":"abc-1","summary":"bad\\u001b[31mtitle"}]' >"$CACHE"
    run --separate-stderr engine --resume-result 1
    [ "$status" -eq 0 ]
    [ "$output" = "abc-1" ]
    assert_no_ansi "$stderr"
    [[ "$stderr" == *"badtitle"* ]]
}

@test "resume refuses a workflow result" {
    seed_workflow_file wf_demo-1
    printf '[{"session_id":"wf_demo-1","summary":"a workflow"}]' >"$CACHE"
    run --separate-stderr engine --resume-result 1
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"$WF_FILE"* ]]
}

@test "--json resume refuses a workflow result with one error document" {
    seed_workflow_file wf_demo-1
    printf '[{"session_id":"wf_demo-1","summary":"a workflow"}]' >"$CACHE"
    run --separate-stderr engine --json --resume-result 1
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    assert_one_json_doc "$stderr"
    printf '%s' "$stderr" | jq -e --arg f "/$WF_FILE" '.status=="error" and (.message|endswith($f))'
}

@test "--json resume prints one document and nothing on stderr" {
    run --separate-stderr engine --json --resume-result 1 migration
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    assert_one_json_doc
    printf '%s' "$output" | jq -e '.session.rank==1 and (.session.session_id|length>0)'
}

@test "--json resume out of range writes nothing to stdout" {
    run --separate-stderr engine --json --resume-result 999 migration
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    assert_one_json_doc "$stderr"
    printf '%s' "$stderr" | jq -e '.status=="action_required" and .next[0].argv==["claude-search","--resume","1"]'
}

# ─── JSON ────────────────────────────────────────────────

@test "--json search prints one compact document" {
    run --separate-stderr engine --json migration
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    assert_one_json_doc
    assert_no_ansi
    [[ "$output" != *$'\x02'* ]]
    [[ "$output" != *'\u0002'* ]]
    printf '%s' "$output" | jq -e '.sessions|type=="array" and length>0'
    printf '%s' "$output" | jq -e '.pagination.next==null'
    printf '%s' "$output" | jq -e '.sessions[0]|has("bm25")|not'
}

@test "--json results have exactly the public fields" {
    run --separate-stderr engine --json migration
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '
        (.sessions[0]|keys) == (["created_at","git_branch","message_count","modified_at","project_name",
            "project_path","rank","score","session_id","summary","tags","workflow_path"])
        and .sessions[0].rank==1
        and (.sessions[0].tags|type=="array")
        and .sessions[0].workflow_path==null
        and (.sessions[0].score|type=="number")'
}

@test "--json with no match is an empty list and exit 0" {
    run --separate-stderr engine --json zzzqqqxxxnomatch
    [ "$status" -eq 0 ]
    assert_one_json_doc
    printf '%s' "$output" | jq -e '.sessions==[]'
}

@test "--format json keeps the legacy array" {
    run --separate-stderr engine --format json migration
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e 'type=="array"'
    [ "${#lines[@]}" -gt 1 ]
}

@test "--json failure writes one error line to stderr" {
    run --separate-stderr engine --json --preview nope
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    assert_one_json_doc "$stderr"
    printf '%s' "$stderr" | jq -e '.status=="error" and (.reason|length>0)'
}

@test "--json --preview and --json --stats print one document" {
    id="$(sqlite3 "$DB" 'select session_id from sessions limit 1')"
    run --separate-stderr engine --json --preview "$id"
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    assert_one_json_doc
    printf '%s' "$output" | jq -e --arg id "$id" '.session.session_id==$id and (.session.project_path|length>0) and (.session.tags|type=="array")'

    run --separate-stderr engine --json --stats
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    assert_one_json_doc
    printf '%s' "$output" | jq -e '.stats.total>0 and (.stats.by_source|type=="array")'
}

@test "--json --preview carries workflow_path on a workflow row" {
    seed_workflow_file wf_demo-2
    seed_session_row wf_demo-2
    run --separate-stderr engine --json --preview wf_demo-2
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e --arg f "/$WF_FILE" '.session.workflow_path|endswith($f)'
}

@test "--format=json --preview has project_path" {
    id="$(sqlite3 "$DB" 'select session_id from sessions limit 1')"
    run --separate-stderr engine --format=json --preview "$id"
    [ "$status" -eq 0 ]
    assert_one_json_doc
    printf '%s' "$output" | jq -e --arg id "$id" 'type=="object" and .session_id==$id and (.project_path|length>0)'
}

# ─── Validation before side effects ──────────────────────

@test "invalid input fails before a search is logged" {
    before="$(sqlite3 "$DB" 'select count(*) from search_log')"
    run --separate-stderr engine --after 3/1 q
    [ "$status" -eq 2 ]
    run --separate-stderr engine --limit 0 q
    [ "$status" -eq 2 ]
    run --separate-stderr engine --deep q
    [ "$status" -eq 2 ]
    run --separate-stderr engine --stats q
    [ "$status" -eq 2 ]
    run --separate-stderr engine --fails q
    [ "$status" -eq 2 ]
    run --separate-stderr engine --explain --json q
    [ "$status" -eq 2 ]
    [ "$(sqlite3 "$DB" 'select count(*) from search_log')" = "$before" ]
    [ ! -e "$CACHE" ]
}

@test "a valid search does log, so the test above can fail" {
    before="$(sqlite3 "$DB" 'select count(*) from search_log')"
    run --separate-stderr engine aurora
    [ "$status" -eq 0 ]
    [ "$(sqlite3 "$DB" 'select count(*) from search_log')" -gt "$before" ]
    [ -e "$CACHE" ]
}

@test "--limit 500 is clamped with a warning" {
    run --separate-stderr engine --limit 500 migration
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"clamped to 200"* ]]
}

@test "--json --limit 500 reports limit_clamped in the document" {
    run --separate-stderr engine --json --limit 500 migration
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    printf '%s' "$output" | jq -e '.warnings[0].reason=="limit_clamped"'
}

@test "--after still works and warns once" {
    run --separate-stderr engine --after 2026-03-01 --before 2026-04-01 q
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$stderr" | grep -c 'deprecated')" -eq 1 ]
    [[ "$stderr" == *--since* ]]
    [[ "$stderr" == *--until* ]]
}

@test "--since accepts ISO and relative values" {
    run --separate-stderr engine --since 7d q
    [ "$status" -eq 0 ]
    run --separate-stderr engine --since 2026-03-01 q
    [ "$status" -eq 0 ]
    run --separate-stderr engine -s 7 q
    [ "$status" -eq 0 ]
    run --separate-stderr engine --since abc q
    [ "$status" -eq 2 ]
}

@test "--format json warns once on stderr and keeps stdout" {
    run --separate-stderr engine --format json migration
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$stderr" | grep -c -- '--json')" -eq 1 ]
    printf '%s' "$output" | jq -e 'type=="array"'
}

# ─── Spinner ─────────────────────────────────────────────

@test "search with a terminal on every stream finishes and prints results" {
    run run_in_pty python3 "$ENGINE" migration
    [ "$status" -eq 0 ]
    [[ "$output" == *migration* || "$output" == *Migration* ]]
}

# ─── Invariants other callers rely on ────────────────────

@test "--context-inject stays one string with exit 0" {
    run --separate-stderr engine --context-inject "$HOME"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

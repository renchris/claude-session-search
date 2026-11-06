#!/usr/bin/env bats
# scripts/session-index-tag.sh, run from a copy so a test can remove the files it depends on. The
# wrapper's #!/bin/bash proves bash 3.2 on macOS whatever bash runs bats.

load helpers_scripts

setup() {
    script_sandbox_setup
    COPY="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$COPY/scripts/lib"
    cp "$REPO/scripts/session-index-tag.sh" "$REPO/scripts/session-index-tag.py" "$COPY/scripts/"
    cp "$REPO/scripts/lib/cli-common.sh" "$COPY/scripts/lib/"
    WRAPPER="$COPY/scripts/session-index-tag.sh"
    TAGGER="$COPY/scripts/session-index-tag.py"
    GITLESS="$BATS_TEST_TMPDIR/gitless"
    mkdir -p "$GITLESS"
    ln -s "$(command -v dirname)" "$GITLESS/dirname"
}
teardown() { sandbox_teardown; }

@test "child exit code passes through" {
    _write_stub python3 <<'STUB'
exit 42
STUB
    run "$WRAPPER"
    [ "$status" -eq 42 ]
}

@test "argv with spaces passes through" {
    _write_stub python3 </dev/null
    run "$WRAPPER" --project "two words" --limit 5
    [ "$status" -eq 0 ]
    [ "$(calls python3)" = "$TAGGER
--project
two words
--limit
5" ]
}

@test "the real tagger answers --help through the wrapper" {
    run --separate-stderr "$REPO/scripts/session-index-tag.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"ANTHROPIC_API_KEY"* ]]
}

@test "missing script offers git restore" {
    git -C "$COPY" init -q
    git -C "$COPY" add scripts/session-index-tag.py
    rm "$TAGGER"
    run --separate-stderr "$WRAPPER"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == "Error: Missing $TAGGER"* ]]
    [[ "$stderr" == *"Restore it:"* ]]
    [[ "$stderr" == *"    git -C $COPY restore scripts/session-index-tag.py"* ]]
    [[ "$stderr" != *"install.sh"* ]]
    # The offered command works.
    git -C "$COPY" restore scripts/session-index-tag.py
    [ -f "$TAGGER" ]
}

@test "no git offers clone" {
    rm "$TAGGER"
    run --separate-stderr env PATH="$GITLESS" "$WRAPPER"
    [ "$status" -eq 1 ]
    [[ "$stderr" == "Error: Missing $TAGGER"* ]]
    [[ "$stderr" == *"Clone a fresh copy:"* ]]
    [[ "$stderr" == *"    git clone https://github.com/renchris/claude-session-search.git"* ]]
    [[ "$stderr" != *"git -C"* ]]
}

@test "an untracked script offers clone" {
    git -C "$COPY" init -q
    rm "$TAGGER"
    run --separate-stderr "$WRAPPER"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"Clone a fresh copy:"* ]]
}

@test "no python3 exits 1 with a named failure" {
    run --separate-stderr env PATH="$GITLESS" "$WRAPPER" --project "two words"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == "Error: Cannot start tagger: python3 not found"* ]]
    [[ "$stderr" == *"Install Python 3, then re-run:"* ]]
    [[ "$stderr" == *'two\ words'* ]]
}

@test "no python3 and no arguments still names the failure" {
    run --separate-stderr env PATH="$GITLESS" "$WRAPPER"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"    $WRAPPER"* ]]
}

@test "without cli-common.sh a missing script prints one plain Error line and the recovery" {
    rm "$COPY/scripts/lib/cli-common.sh" "$TAGGER"
    run --separate-stderr env PATH="$GITLESS" "$WRAPPER"
    [ "$status" -eq 1 ]
    [ "$stderr" = "Error: Missing $TAGGER

Clone a fresh copy:
    git clone https://github.com/renchris/claude-session-search.git" ]
}

@test "without cli-common.sh a present script still runs" {
    rm "$COPY/scripts/lib/cli-common.sh"
    _write_stub python3 <<'STUB'
exit 7
STUB
    run "$WRAPPER"
    [ "$status" -eq 7 ]
}

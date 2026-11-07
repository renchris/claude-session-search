#!/usr/bin/env bats
# The engine run as a real piped process: stdout holds results and nothing else.

load helpers

setup() {
    sandbox_setup
    ENGINE="$HOME/.claude/bin/session-search.py"
}
teardown() { sandbox_teardown; }

@test "zero results: piped stdout is empty and prose is on stderr" {
    run --separate-stderr python3 "$ENGINE" zzqqxxnomatch
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"No sessions match"* ]]
}

@test "piped search prints no tip" {
    run --separate-stderr python3 "$ENGINE" aurora
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [[ "$output" != *"--resume 1"* ]]
    [[ "$stderr" != *"--resume 1"* ]]
    [ ! -e "$HOME/.claude/.session-search-tips.json" ]
}

#!/usr/bin/env bats
# scripts/session-index-backfill.sh: how it starts and what it accepts, up to the first phase. Every
# run uses the sandbox HOME from script_sandbox_setup, whose demo DB is removed first: the backfill
# only finishes on the schema its own session_index_init_db creates.
#
# The script runs from a copy of the checkout with no synonyms/default.json. That file is optional
# and takes one sqlite3 process per row, which is minutes per run on a loaded machine.
#
# RED-proof: measured before this change in a temp HOME. Through a symlink, exit 1 with
# `.claude/hooks/lib/session-index-helpers.sh: No such file or directory`. `--bogus`, exit 1 with
# `Unknown flag`. `--since` with no value, exit 1 with `$2: unbound variable`.

load helpers_scripts

setup() {
    script_sandbox_setup
    DB="$HOME/.claude/session-index.db"
    rm -f "$DB"
    mkdir "$HOME/copy"
    cp -R "$REPO/scripts" "$REPO/hooks" "$HOME/copy/"
    # The physical path, the form the script reports.
    COPY="$(cd -P "$HOME/copy" && pwd)"
    BACKFILL="$COPY/scripts/session-index-backfill.sh"
    tree_snapshot
}

teardown() {
    sandbox_teardown
}

# has <text> <fragment>
has() {
    case "$1" in
        *"$2"*) ;;
        *)
            echo "no [$2] in: $1" >&2
            return 1
            ;;
    esac
}

# parses <args...>: a clean parse that runs nothing.
parses() {
    run --separate-stderr env __SESSION_SEARCH_PARSE_ONLY=1 "$BACKFILL" "$@"
    [ "$status" -eq 0 ] || {
        echo "status $status for: $*: $stderr" >&2
        return 1
    }
    assert_tree_unchanged
}

# refused <args...>: exit 2, nothing on stdout, nothing done. Leaves $stderr for the caller.
refused() {
    run --separate-stderr "$BACKFILL" "$@"
    [ "$status" -eq 2 ] || {
        echo "status $status for: $*: $stderr" >&2
        return 1
    }
    [ -z "$output" ] || {
        echo "stdout for: $*: $output" >&2
        return 1
    }
    assert_tree_unchanged
}

# In the copy, a chunk script that only logs its argv to $HOME/calls/chunk. It stays Python because
# Phase 7 runs it as `python3 "$CHUNK_SCRIPT"`.
use_stub_chunk() {
    cat >"$COPY/scripts/session-index-chunk.py" <<'STUB'
import os
import sys

with open(os.path.join(os.environ["HOME"], "calls", "chunk"), "ab") as log:
    for arg in sys.argv[1:]:
        log.write(os.fsencode(arg) + b"\0")
STUB
}

# chunk_days_for <TIME> <days>: a full run with --since TIME hands the chunk script exactly <days>.
chunk_days_for() {
    rm -f "$HOME/calls/chunk"
    run --separate-stderr "$BACKFILL" --since "$1"
    [ "$status" -eq 0 ] || {
        echo "status $status for --since $1: $stderr" >&2
        return 1
    }
    [ "$(calls chunk)" = "--backfill"$'\n'"--since"$'\n'"$2" ] || {
        echo "--since $1 gave: $(calls chunk)" >&2
        return 1
    }
}

# The named section of the help: its heading to the next blank line.
help_section() {
    "$BACKFILL" --help | awk -v heading="$1" '$0 == heading { on = 1; next } /^$/ { on = 0 } on'
}

@test "backfill runs through a symlink" {
    ln -s "$BACKFILL" "$HOME/.claude/bin/session-index-backfill.sh"
    run --separate-stderr "$HOME/.claude/bin/session-index-backfill.sh" --quiet
    [ "$status" -eq 0 ]
    case "$stderr" in *"No such file"*) false ;; esac
    [ -n "$(sqlite3 "$DB" "SELECT value FROM meta WHERE key = 'last_backfill';")" ]
}

@test "backfill runs through a chained symlink" {
    mkdir "$HOME/.claude/links"
    ln -s "$BACKFILL" "$HOME/.claude/links/second"
    ln -s ../links/second "$HOME/.claude/bin/session-index-backfill.sh"
    run --separate-stderr "$HOME/.claude/bin/session-index-backfill.sh" --since 7 --quiet
    [ "$status" -eq 0 ]
    case "$stderr" in *"No such file"*) false ;; esac
}

@test "a missing required file is named and exits 1" {
    local file
    for file in scripts/lib/cli-common.sh hooks/lib/session-index-helpers.sh scripts/lib/progress-ui.sh \
        scripts/lib/cli_common.py; do
        mv "$COPY/$file" "$COPY/$file.aside"
        run --separate-stderr "$BACKFILL"
        mv "$COPY/$file.aside" "$COPY/$file"
        [ "$status" -eq 1 ] || {
            echo "status $status without $file: $stderr" >&2
            return 1
        }
        has "$stderr" "cannot find $COPY/$file (resolved repo: $COPY)"
        has "$stderr" "Re-run install.sh"
    done
    [ ! -e "$DB" ]
}

@test "a missing prerequisite is named and exits 1" {
    local tool other
    for tool in sqlite3 jq python3; do
        mkdir "$HOME/narrow"
        ln -s "$(command -v dirname)" "$HOME/narrow/dirname"
        for other in sqlite3 jq python3; do
            if [ "$other" != "$tool" ]; then
                ln -s "$(command -v "$other")" "$HOME/narrow/$other"
            fi
        done
        run --separate-stderr env PATH="$HOME/narrow" /bin/bash "$BACKFILL"
        [ "$status" -eq 1 ] || {
            echo "status $status without $tool: $stderr" >&2
            return 1
        }
        has "$stderr" "$tool not found"
        rm -f "$HOME/narrow/"*
        rmdir "$HOME/narrow"
    done
    [ ! -e "$DB" ]
}

@test "--help works with no DB and no libraries loaded" {
    mkdir "$HOME/lone"
    cp "$BACKFILL" "$HOME/lone/"
    tree_snapshot
    run --separate-stderr "$HOME/lone/session-index-backfill.sh" --help
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    has "$output" "Usage: session-index-backfill.sh [options]"
    has "$output" "Options:"
    has "$output" "Examples:"
    has "$output" "Notes:"
    has "$output" "all history"
    has "$output" "UTC"
    assert_tree_unchanged
}

@test "help says --quiet has no effect" {
    run "$BACKFILL" --help
    [ "$status" -eq 0 ]
    case "$output" in
        *"--quiet"*"no effect"*) ;;
        *)
            echo "$output" >&2
            return 1
            ;;
    esac
}

@test "help lists the exit codes" {
    local block code
    block="$(help_section "Exit codes:")"
    for code in 0 1 2 129 130 143; do
        printf '%s\n' "$block" | grep -Eq "^ *([0-9]+, )*$code(,| )" || {
            echo "no exit code $code in: $block" >&2
            return 1
        }
    done
}

@test "help word shows help" {
    local want
    want="$("$BACKFILL" --help)"
    run "$BACKFILL" help
    [ "$status" -eq 0 ]
    [ "$output" = "$want" ]
    run "$BACKFILL" -h
    [ "$status" -eq 0 ]
    [ "$output" = "$want" ]
    # Only as the first argument: anywhere else it is a stray positional.
    refused --quiet help
}

@test "--bogus exits 2 naming the option" {
    refused --bogus
    has "$stderr" "--bogus"
    has "$stderr" "--help"
}

@test "--bogus --help prints help" {
    run "$BACKFILL" --bogus --help
    [ "$status" -eq 0 ]
    has "$output" "Usage: session-index-backfill.sh"
}

@test "-- ends the options and a positional exits 2" {
    parses --enrich-only --
    refused stray
    has "$stderr" "stray"
    refused -- --help
    has "$stderr" "--help"
}

@test "every backfill help example parses" {
    local line words n=0
    while IFS= read -r line; do
        # shellcheck disable=SC2206 # the examples are plain words
        words=($line)
        [ "${words[0]}" = session-index-backfill.sh ]
        parses ${words[@]+"${words[@]:1}"}
        n=$((n + 1))
    done <<<"$(help_section "Examples:")"
    [ "$n" -gt 0 ]
    # An example with a bad value would fail here too, rather than parse and stop early.
    run env __SESSION_SEARCH_PARSE_ONLY=1 "$BACKFILL" --since abc
    [ "$status" -eq 2 ]
}

@test "--since accepts 7, 36500, 7d and an ISO date" {
    local value
    for value in 7 36500 7d 12h 2026-03-01 2026-03-01T12:00:00Z; do
        parses --since "$value"
        parses "--since=$value"
        parses -s "$value"
    done
}

@test "--since refuses 0, 100000, 007, abc, empty, 1.5 and -3 with exit 2" {
    local value
    for value in 0 100000 007 abc "" 1.5 -3 00 0d 0h 100000d 99999999999 d "1'; DROP TABLE sessions;--"; do
        refused --since "$value"
        has "$stderr" "invalid --since '$value': whole days 1-36500"
    done
    refused --since=
    has "$stderr" "invalid --since ''"
    # argparse would read this as its own help and exit 0.
    refused --since=-h
    has "$stderr" "invalid --since '-h'"
}

@test "invalid --since leaves no DB behind" {
    refused --since abc
    [ ! -e "$DB" ]
}

@test "--since with no value exits 2, not 127" {
    refused --since
    has "$stderr" "--since"
    refused --since --quiet
    has "$stderr" "--since"
    refused -s
}

@test "--since 7d hands the chunk script a whole number of days" {
    use_stub_chunk
    chunk_days_for 7d 7
    chunk_days_for 7 7
    chunk_days_for 12h 1
}

@test "a date far off still hands the chunk script a day count it reads as a cutoff" {
    use_stub_chunk
    # chunk.py reads 0 as no cutoff, so a future date must not round down to it.
    chunk_days_for 2099-01-01 1
    # chunk.py overflows on a cutoff before year 1.
    chunk_days_for 0001-01-01 36500
}

@test "the real chunk script takes the longest window backfill passes" {
    run --separate-stderr "$BACKFILL" --since 0001-01-01
    [ "$status" -eq 0 ]
}

@test "the header names the window as given" {
    run "$BACKFILL" --since 7d
    [ "$status" -eq 0 ]
    has "$output" "last 7d"
    case "$output" in *7dd*) false ;; esac
    run "$BACKFILL" --since 2026-03-01
    [ "$status" -eq 0 ]
    has "$output" "since 2026-03-01"
}

# Phase 5 is the phase that reads SINCE_FILTER for its count. It swallows an sqlite3 error as
# "no gaps", so a broken filter shows up only as a missing row.
@test "--since narrows the rows the SQL selects" {
    local now
    run "$BACKFILL"
    [ "$status" -eq 0 ]
    now="$(date -u +%Y-%m-%dT%H:%M:%S+00:00)"
    sqlite3 "$DB" "INSERT INTO sessions (session_id, project_path, project_name, created_at, modified_at, indexed_at)
        VALUES ('recent', '/p', 'p', '$now', '$now', '$now'),
               ('old', '/p', 'p', '$now', '2000-01-01T00:00:00+00:00', '$now');"

    run "$BACKFILL" --since 3
    [ "$status" -eq 0 ]
    has "$output" "1 no transcript"

    run "$BACKFILL"
    [ "$status" -eq 0 ]
    has "$output" "2 no transcript"
}

@test "repo plist parses" {
    skip "config plist :11 has a bare & (invalid XML); decision C18 open"
    python3 -I -c 'import plistlib,sys; plistlib.load(open(sys.argv[1],"rb"))' \
        "$REPO/config/com.claude.session-search-backfill.plist"
}

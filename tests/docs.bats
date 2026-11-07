#!/usr/bin/env bats
# README.md against the parsers: what it teaches must parse, and what the parsers offer must be taught.
# Examples are only parsed here, never run.
#
# shellcheck disable=SC2016 # awk programs and regexes are literal

load helpers

setup() {
    sandbox_setup
    README="$REPO/README.md"
}

teardown() {
    sandbox_teardown
}

# Lines inside ```bash fences.
fenced_bash() {
    awk '/^```/ { if (in_block) { in_block = 0 } else if ($0 == "```bash") { in_block = 1 }; next } in_block' "$README"
}

@test "README option table lists every visible engine option" {
    local option
    run python3 "$REPO/bin/session-search.py" --help
    [ "$status" -eq 0 ]
    local missing=""
    while IFS= read -r option; do
        grep -qF -- "\`$option" "$README" || missing="$missing $option"
    done < <(printf '%s\n' "$output" | grep -oE -- '--[a-z-]+' | sort -u)
    [ -z "$missing" ] || { echo "not in README:$missing" >&2; return 1; }
}

@test "README examples parse" {
    local known line option bad=""
    known="$(bash "$REPO/bin/claude-search" --help | grep -oE -- '--[a-z-]+' | sort -u)"
    [ -n "$known" ]
    while IFS= read -r line; do
        case "$line" in claude-search\ *) ;; *) continue ;; esac
        # Drop the query text and the trailing comment, so only real options remain.
        line="${line%%#*}"
        while IFS= read -r option; do
            [ -n "$option" ] || continue
            printf '%s\n' "$known" | grep -qxF -- "$option" || bad="$bad $option"
        done < <(printf '%s\n' "$line" | sed -E 's/"[^"]*"//g' | grep -oE -- '--[a-z-]+' || true)
    done < <(fenced_bash)
    [ -z "$bad" ] || { echo "not parser options:$bad" >&2; return 1; }
}

@test "README script examples parse" {
    local spec script args count=0
    while IFS= read -r spec; do
        script="${spec%% *}"
        [ "$script" = "$spec" ] && args="" || args="${spec#* }"
        case "$script" in
            ./install.sh | ./uninstall.sh) script="$REPO/${script#./}" ;;
            ./scripts/*) script="$REPO/${script#./}" ;;
            session-index-*) script="$REPO/scripts/$script" ;;
            *) echo "unexpected script: $spec" >&2; return 1 ;;
        esac
        count=$((count + 1))
        case "$script" in
            *.py)
                run python3 -I - "$script" "$args" <<'PY'
import importlib.util
import shlex
import sys

spec = importlib.util.spec_from_file_location("cli_under_test", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.build_parser().parse_args(shlex.split(sys.argv[2]))
PY
                ;;
            *)
                # shellcheck disable=SC2086 # the example's words are meant to split
                run env __SESSION_SEARCH_PARSE_ONLY=1 "$script" $args
                ;;
        esac
        [ "$status" -eq 0 ] || { echo "does not parse: $spec: $output" >&2; return 1; }
    done < <(
        {
            fenced_bash
            grep -oE '`(\./install\.sh|\./uninstall\.sh|\./scripts/session-index-[a-z]+\.(sh|py)|session-index-[a-z]+\.(sh|py))[^`]*`' "$README" | tr -d '`'
        } | grep -E '^(\./install\.sh|\./uninstall\.sh|\./scripts/session-index-[a-z]+\.(sh|py)|session-index-[a-z]+\.(sh|py))( |$)' | sort -u
    )
    [ "$count" -gt 0 ]
}

@test "README teaches no inline API key" {
    run grep -n 'ANTHROPIC_API_KEY=sk' "$README"
    [ "$status" -eq 1 ]
}

@test "README teaches session-index-tag.py, not the .sh wrapper" {
    grep -qF 'session-index-tag.py --regex-only' "$README"
    run grep -n 'session-index-tag\.sh' "$README"
    [ "$status" -eq 1 ]
}

@test "README has no Flag heading and no 3-phase claim" {
    run grep -nE '\| Flag \||Flag-style|3-phase' "$README"
    [ "$status" -eq 1 ]
}

@test "README states the real Python floor" {
    grep -qF 'python3` ≥ 3.10' "$README"
}

@test "README sample shows no footer box and teaches no hidden date options as current" {
    run grep -nF -- '--resume N' "$README"
    [ "$status" -eq 1 ]
    run grep -nE '^claude-search --(after|before) ' "$README"
    [ "$status" -eq 1 ]
}

@test "every SESSION_SEARCH_ variable the code reads is in the README table" {
    local name missing=""
    while IFS= read -r name; do
        case "$name" in SESSION_SEARCH_REPO | SESSION_SEARCH_PYTHON_DEPS) continue ;; esac
        grep -qF -- "\`$name\`" "$README" || missing="$missing $name"
    done < <(
        grep -rhoE '(^|[^_A-Z])SESSION_SEARCH_[A-Z_]+' "$REPO/bin" "$REPO/scripts" "$REPO/hooks" --include='*' \
            | grep -oE 'SESSION_SEARCH_[A-Z_]+' | sort -u
    )
    [ -z "$missing" ] || { echo "not in README:$missing" >&2; return 1; }
}

@test "internal __SESSION_SEARCH_ variables stay undocumented" {
    run grep -n '__SESSION_SEARCH_' "$REPO/README.md"
    [ "$status" -eq 1 ]
}

@test "the exit-code table names every maintenance script" {
    local name
    for name in claude-search ./install.sh ./uninstall.sh session-index-backfill.sh session-index-chunk.py session-index-tag.py; do
        grep -qF -- "| \`$name\` | 0 |" "$README"
    done
}

#!/usr/bin/env bats
# bin/claude-search: its parse table, what it hands the engine, and resume and picker outcomes. The
# argv cases use the stub engine; the end-to-end cases use the real one. claude, fzf, pbcopy and open
# are always stubs.

load helpers

UUID=11111111-2222-4333-8444-555555555555

setup() {
    sandbox_setup
    ENGINE="$HOME/.claude/bin/session-search.py"
    DB="$HOME/.claude/session-index.db"
    CACHE="$HOME/.claude/.last-search-results.json"
}
teardown() { sandbox_teardown; }

seed_session_row() {
    sqlite3 "$DB" "INSERT INTO sessions (session_id, project_path, project_name, summary, created_at, modified_at, indexed_at)
        VALUES ('$1', '/p', 'p', 'seeded', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');"
}

# recorded_argv <name>: fills ARGV with a stub's recorded arguments. A stub's log has no boundary
# between calls, so remove the log first to see one call.
recorded_argv() {
    local arg
    ARGV=()
    [ -e "$HOME/calls/$1" ] || return 0
    while IFS= read -r -d '' arg; do
        ARGV+=("$arg")
    done <"$HOME/calls/$1"
}

# fzf_bind <prefix>: the recorded fzf argument that starts with prefix, with the prefix removed.
fzf_bind() {
    local arg
    recorded_argv fzf
    for arg in "${ARGV[@]}"; do
        case "$arg" in
            "$1"*)
                printf '%s\n' "${arg#"$1"}"
                return 0
                ;;
        esac
    done
    echo "fzf_bind: no argument starts with $1" >&2
    return 1
}

# ─── B6.1 Parse table ────────────────────────────────────

@test "trailing --resume is a usage error" {
    use_stub_engine
    run --separate-stderr claude-search --resume
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    [[ "$stderr" == *"claude-search: Missing value for --resume."* ]]
    [[ "$stderr" == *"See 'claude-search --help'."* ]]
    [ -z "$(calls engine)" ]
}

@test "--resume= with no value is a usage error" {
    use_stub_engine
    run --separate-stderr claude-search --resume=
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"Missing value for --resume"* ]]
    [ -z "$(calls engine)" ]
}

@test "a pair option with no value is a usage error for each spelling" {
    use_stub_engine
    for opt in --after --before --since --until --project --limit --min-msgs --format \
        -s -u -p -n --preview --context-inject; do
        run --separate-stderr claude-search "$opt"
        [ "$status" -eq 2 ]
        [[ "$stderr" == *"Missing value for $opt."* ]]
    done
    [ -z "$(calls engine)" ]
}

@test "--resume=3 resumes result 3" {
    use_stub_engine
    STUB_OUT="$UUID"$'\n' run --separate-stderr claude-search --resume=3
    [ "$status" -eq 0 ]
    [ "$(calls claude)" = $'--resume\n'"$UUID" ]
    [ "$(calls engine)" = $'--resume-result\n3\n--' ]
}

@test "-- ends option parsing" {
    use_stub_engine
    run claude-search -- --help
    [ "$status" -eq 0 ]
    [ "$(calls engine)" = $'--\n--help' ]
}

@test "unknown option exits 2 even without a query" {
    run --separate-stderr claude-search --bogus
    [ "$status" -eq 2 ]
    [[ "$stderr" == *--bogus* ]]
}

@test "pair options and --x=v forms reach the engine unchanged" {
    use_stub_engine
    run claude-search --project 'a b' -n 5 --since=7d -s 1d -u 2d -p q --limit=3 --min-msgs 2 word1 word2
    [ "$status" -eq 0 ]
    [ "$(calls engine)" = $'--project\na b\n-n\n5\n--since=7d\n-s\n1d\n-u\n2d\n-p\nq\n--limit=3\n--min-msgs\n2\n--\nword1\nword2' ]
}

@test "lone options are forwarded alone and a pair value is not a query word" {
    use_stub_engine
    run claude-search --no-color --non-interactive -d --debug --format table word
    [ "$status" -eq 0 ]
    [ "$(calls engine)" = $'--no-color\n--non-interactive\n-d\n--debug\n--format\ntable\n--\nword' ]
}

@test "-v and --version ask the engine for its version" {
    use_stub_engine
    run claude-search -v
    [ "$status" -eq 0 ]
    [ "$(calls engine)" = --version ]
    rm -f "$HOME/calls/engine"
    run claude-search --version ignored words
    [ "$status" -eq 0 ]
    [ "$(calls engine)" = --version ]
}

@test "--version --json gets the engine's JSON answer; --version --help gets help" {
    run --separate-stderr claude-search --version --json
    [ "$status" -eq 0 ]
    assert_one_json_doc
    printf '%s' "$output" | jq -e '.version'
    run --separate-stderr claude-search --version --help
    [ "$status" -eq 0 ]
    [[ "$output" == "Usage: claude-search"* ]]
}

@test "--fzf with --json is a usage error" {
    use_stub_engine
    run --separate-stderr claude-search --fzf --json q
    [ "$status" -eq 2 ]
    [[ "$stderr" == *--fzf* ]]
    [[ "$stderr" == *--json* ]]
    [ -z "$(calls engine)" ]
    [ -z "$(calls fzf)" ]
}

@test "--resume with --stats is a usage error" {
    use_stub_engine
    run --separate-stderr claude-search --resume 1 --stats
    [ "$status" -eq 2 ]
    [[ "$stderr" == *--resume* ]]
    [[ "$stderr" == *--stats* ]]
    [ -z "$(calls engine)" ]
    [ -z "$(calls claude)" ]
}

@test "every conflict names both tokens, whichever spelling and order" {
    use_stub_engine
    for first in --fzf --resume=1; do
        name="${first%%=*}"
        for pair in --json --stats --analytics '--preview x' '--preview=x' \
            '--context-inject d' '--context-inject=d'; do
            # shellcheck disable=SC2086
            run --separate-stderr claude-search "$first" $pair
            [ "$status" -eq 2 ]
            [[ "$stderr" == *"$name can't be used with ${pair%%[ =]*}."* ]]
            # shellcheck disable=SC2086
            run --separate-stderr claude-search $pair "$first"
            [ "$status" -eq 2 ]
            [[ "$stderr" == *"$name can't be used with ${pair%%[ =]*}."* ]]
        done
    done
    run --separate-stderr claude-search --fzf --resume 1
    [ "$status" -eq 2 ]
    [[ "$stderr" == *"--fzf can't be used with --resume."* ]]
    [ -z "$(calls engine)" ]
    [ -z "$(calls fzf)" ]
    [ -z "$(calls claude)" ]
}

# ─── B6.2 Dispatch ───────────────────────────────────────

@test "--json forwards and prints one JSON document" {
    run --separate-stderr claude-search --json migration
    [ "$status" -eq 0 ]
    assert_one_json_doc
    printf '%s' "$output" | jq -e '.sessions'
}

@test "--analytics runs without a query" {
    run claude-search --analytics
    [ "$status" -eq 0 ]
    [[ "$output" != *Usage:* ]]
}

@test "--analytics --fails runs without a query" {
    run claude-search --analytics --fails
    [ "$status" -eq 0 ]
    [[ "$output" != *Usage:* ]]
}

@test "--stats and --preview run through the engine" {
    run claude-search --stats
    [ "$status" -eq 0 ]
    [[ "$output" != *Usage:* ]]
    run --separate-stderr claude-search --preview no-such-session
    [ "$status" -eq 1 ]
    [[ "$stderr" == *no-such-session* ]]
}

@test "engine exit code passes through" {
    use_stub_engine
    STUB_RC=2 run claude-search anything
    [ "$status" -eq 2 ]
    STUB_RC=1 run claude-search --stats
    [ "$status" -eq 1 ]
}

@test "bare claude-search prints usage and exit 0" {
    use_stub_engine
    run --separate-stderr claude-search
    [ "$status" -eq 0 ]
    [[ "$output" == "Usage: claude-search"* ]]
    [ -z "$stderr" ]
    [ -z "$(calls engine)" ]
}

@test "the cue's command keeps searching: a query then --deep-search" {
    run --separate-stderr claude-search 'migration bug' --deep-search
    [ "$status" -eq 0 ]
    [[ "$output" != *Usage:* ]]
    [ -n "$output" ]
}

# ─── B6.3 Help ───────────────────────────────────────────

@test "--help works without the engine installed" {
    rm -f "$ENGINE"
    run --separate-stderr claude-search --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: claude-search"* ]]
    [ -z "$stderr" ]
}

@test "help word shows help; -- help searches" {
    use_stub_engine
    run claude-search help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: claude-search"* ]]
    [ -z "$(calls engine)" ]
    run claude-search -- help
    [ "$status" -eq 0 ]
    [ "$(calls engine)" = $'--\nhelp' ]
    rm -f "$HOME/calls/engine"
    run claude-search help me
    [ "$status" -eq 0 ]
    [ "$(calls engine)" = $'--\nhelp\nme' ]
}

@test "--help wins over other options" {
    use_stub_engine
    for argv in '--stats --help' '--bogus -h' '--fzf --json --help' '--resume --help' \
        '--project --help' '--help --resume'; do
        # shellcheck disable=SC2086
        run claude-search $argv
        [ "$status" -eq 0 ]
        [[ "$output" == "Usage: claude-search"* ]]
    done
    [ -z "$(calls engine)" ]
    [ -z "$(calls claude)" ]
}

@test "help lists every visible engine option" {
    run claude-search --help
    [ "$status" -eq 0 ]
    help_text="$output"
    run python3 "$REPO/bin/session-search.py" --help
    [ "$status" -eq 0 ]
    options="$(printf '%s\n' "$output" | grep -oE -- '--[a-z-]+' | sort -u)"
    [ "$(printf '%s\n' "$options" | wc -l)" -gt 10 ]
    while IFS= read -r option; do
        printf '%s\n' "$help_text" | grep -qF -- "$option" || {
            echo "help is missing $option"
            return 1
        }
    done <<<"$options"
}

@test "help never teaches a hidden, removed or internal name" {
    run claude-search --help
    [ "$status" -eq 0 ]
    for name in --format --after --before --color= '--color ' --resume-result --context-inject \
        --no-log __SESSION_SEARCH; do
        [[ "$output" != *"$name"* ]]
    done
}

@test "every help example parses" {
    use_stub_engine
    run claude-search --help
    [ "$status" -eq 0 ]
    examples=()
    while IFS= read -r line; do
        line="${line//<QUERY>/q}"
        line="${line//<SESSION>/$UUID}"
        line="${line//<NUMBER>/1}"
        examples+=("$line")
    done < <(printf '%s\n' "$output" | awk '/^Examples:/{on=1;next} /^[A-Z]/{on=0} on && /^    claude-search /')
    [ "${#examples[@]}" -ge 3 ]
    for example in "${examples[@]}"; do
        rm -f "$HOME/calls/engine"
        eval "set -- $example"
        FZF_RC=1 run run_in_pty "$@"
        [ "$status" -eq 0 ]
        recorded_argv engine
        [ "${#ARGV[@]}" -gt 0 ]
        PYTHONDONTWRITEBYTECODE=1 python3 -c '
import os, sys
sys.path.insert(0, os.path.join(os.environ["REPO"], "tests"))
from engine_loader import load_engine
engine = load_engine()
parser = engine.build_parser()
engine.validate_args(parser, parser.parse_args(sys.argv[1:]))
' "${ARGV[@]}"
    done
}

@test "help examples use long options and placeholders only" {
    run claude-search --help
    [ "$status" -eq 0 ]
    examples="$(printf '%s\n' "$output" | awk '/^Examples:/{on=1;next} /^[A-Z]/{on=0} on && /^    /')"
    [ -n "$examples" ]
    ! printf '%s\n' "$examples" | grep -E -- ' -[a-z]( |$)'
    ! printf '%s\n' "$examples" | grep -F -- '[options]'
}

@test "help sections are in order and fit 80 columns" {
    run claude-search --help
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "Usage: claude-search [options] <QUERY>..." ]
    [ "${lines[1]}" = "Search your Claude Code sessions and resume one." ]
    sections="$(printf '%s\n' "$output" | grep -E '^[A-Z][A-Za-z ]*:( |$)' | cut -d: -f1 | tr '\n' ',')"
    [ "$sections" = "Usage,Arguments,Options,Examples,Notes,Learn more," ]
    [ -z "$(printf '%s\n' "$output" | awk 'length > 80')" ]
    [[ "$output" == *"https://github.com/renchris/claude-session-search"* ]]
}

@test "help options are in alphabetical order" {
    run claude-search --help
    [ "$status" -eq 0 ]
    names="$(printf '%s\n' "$output" | awk '/^Options:/{on=1;next} /^[A-Z]/{on=0} on && /^  -/' \
        | sed -E 's/^  (-[a-z], )?(--[a-z-]+).*/\2/')"
    [ "$(printf '%s\n' "$names" | wc -l)" -gt 10 ]
    [ "$names" = "$(printf '%s\n' "$names" | LC_ALL=C sort)" ]
}

@test "help states the exit codes" {
    run claude-search --help
    [ "$status" -eq 0 ]
    flat="$(printf '%s\n' "$output" | tr -s ' \n' ' ')"
    [[ "$flat" == *"Exit codes: 0 success or empty result; 1 failure, including a missing engine, fzf or claude; 2 usage error; 130 canceled."* ]]
}

@test "help notes name the privacy path and the variables" {
    run claude-search --help
    [ "$status" -eq 0 ]
    for text in api.anthropic.com ANTHROPIC_API_KEY SESSION_SEARCH_NO_LLM=1 search_log \
        .last-search-results.json SESSION_SEARCH_GUIDANCE_DISABLED SESSION_SEARCH_DEBUG \
        SESSION_SEARCH_ACCESSIBLE "claude-search -- help searches for the word help"; do
        [[ "$output" == *"$text"* ]]
    done
}

# ─── B6.4 Engine missing ─────────────────────────────────

@test "missing engine names the install command" {
    rm -f "$ENGINE"
    run --separate-stderr claude-search anything
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"Can't run claude-search: engine not found at ~/.claude/bin/session-search.py."* ]]
    printf '%s\n' "$stderr" | grep -Fxq 'Install it:'
    printf '%s\n' "$stderr" | grep -Fxq '    bash /path/to/claude-session-search/install.sh'
}

@test "missing engine names the real repo when the wrapper is a symlink" {
    rm -f "$ENGINE"
    mkdir -p "$HOME/repo/bin"
    mv "$HOME/.claude/bin/claude-search" "$HOME/repo/bin/claude-search"
    ln -s "$HOME/repo/bin/claude-search" "$HOME/.claude/bin/claude-search"
    run --separate-stderr claude-search anything
    [ "$status" -eq 1 ]
    printf '%s\n' "$stderr" | grep -Fxq "    bash $HOME/repo/install.sh"
}

@test "missing engine stops every path that needs it" {
    rm -f "$ENGINE"
    for argv in --version --stats '--resume 1' "--resume $UUID" --fzf; do
        # shellcheck disable=SC2086
        run --separate-stderr claude-search $argv
        [ "$status" -eq 1 ]
        [[ "$stderr" == *"engine not found"* ]]
    done
    [ -z "$(calls claude)" ]
    [ -z "$(calls fzf)" ]
}

# ─── B6.5 Resume ─────────────────────────────────────────

@test "engine error on resume reaches stderr with its exit code" {
    use_stub_engine
    STUB_RC=2 STUB_ERR='Result #9 is out of range' run --separate-stderr claude-search --resume 9
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    [[ "$stderr" == *"Result #9 is out of range"* ]]
    [ -z "$(calls claude)" ]
}

@test "engine warnings on resume reach stderr and leave the ID alone" {
    run --separate-stderr claude-search --resume 1 --after 3650d --limit 500 migration
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"--after is deprecated"* ]]
    [[ "$stderr" == *"clamped"* ]]
    recorded_argv claude
    [ "${#ARGV[@]}" -eq 2 ]
    [ "${ARGV[0]}" = --resume ]
    [[ "${ARGV[1]}" =~ ^[A-Za-z0-9_-]+$ ]]
    [ "$(sqlite3 "$DB" "select count(*) from sessions where session_id='${ARGV[1]}'")" = 1 ]
}

@test "malformed session ID is refused" {
    use_stub_engine
    for bad in 'a b' '-x' $'one\ntwo' ''; do
        STUB_OUT="$bad" run --separate-stderr claude-search --resume 1
        [ "$status" -eq 1 ]
    done
    [ -z "$(calls claude)" ]
}

@test "a wf_ ID from the engine never reaches claude" {
    use_stub_engine
    STUB_OUT=$'wf_demo-1\n' run --separate-stderr claude-search --resume 1
    [ "$status" -eq 1 ]
    [[ "$stderr" == *wf_demo-1* ]]
    [ -z "$(calls claude)" ]
}

@test "a workflow result in the last search is refused end to end" {
    printf '[{"session_id":"wf_demo-1","summary":"a workflow"}]' >"$CACHE"
    run --separate-stderr claude-search --resume 1
    [ "$status" -eq 1 ]
    [ -z "$(calls claude)" ]
}

@test "--resume with a wf_ value is a usage error" {
    use_stub_engine
    run --separate-stderr claude-search --resume wf_demo-1
    [ "$status" -eq 2 ]
    [ -z "$(calls engine)" ]
    [ -z "$(calls claude)" ]
}

@test "--resume with neither a number nor a full ID is a usage error" {
    use_stub_engine
    for bad in abc 0 1x 11111111-2222; do
        run --separate-stderr claude-search --resume "$bad"
        [ "$status" -eq 2 ]
        [[ "$stderr" == *"$bad"* ]]
    done
    [ -z "$(calls engine)" ]
}

@test "Resuming line goes to stderr" {
    use_stub_engine
    STUB_OUT="$UUID"$'\n' run --separate-stderr claude-search --resume 1
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"Resuming session $UUID"* ]]
}

@test "--resume <uuid> resumes that exact session" {
    seed_session_row "$UUID"
    run --separate-stderr claude-search --resume "$UUID"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(calls claude)" = $'--resume\n'"$UUID" ]
}

@test "--resume <unknown uuid> fails" {
    run --separate-stderr claude-search --resume "$UUID"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"Couldn't find session $UUID"* ]]
    [[ "$stderr" != '{'* ]]
    [ -z "$(calls claude)" ]
}

@test "--resume <uuid> with a query is a usage error" {
    use_stub_engine
    run --separate-stderr claude-search --resume "$UUID" extra words
    [ "$status" -eq 2 ]
    [ -z "$(calls engine)" ]
    [ -z "$(calls claude)" ]
}

@test "--resume <uuid> still rejects an unknown option" {
    seed_session_row "$UUID"
    run --separate-stderr claude-search --resume "$UUID" --bogus
    [ "$status" -eq 2 ]
    [ -z "$(calls claude)" ]
}

@test "a missing claude exits 1 and keeps the ID visible" {
    use_stub_engine
    rm -f "$HOME/stubs/claude"
    STUB_OUT="$UUID"$'\n' run --separate-stderr claude-search --resume 1
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"$UUID"* ]]
    printf '%s\n' "$stderr" | grep -Fxq 'Install it:'
}

# ─── B6.6 fzf ────────────────────────────────────────────

@test "fzf: project with spaces and ; reaches the engine as one argument" {
    use_stub_engine
    cd "$HOME"
    FZF_RUN_RELOAD=x FZF_RC=1 run run_in_pty claude-search --fzf --project 'a b; touch X' q
    [ "$status" -eq 0 ]
    [ "$(calls engine | grep -Fx -A1 -- --project | grep -Fxc 'a b; touch X')" -eq 2 ]
    [ ! -e "$HOME/X" ]
}

@test "fzf: reload searches the typed words without logging them, however they are quoted" {
    use_stub_engine
    cd "$HOME"
    typed=$'it\'s; touch Y'
    FZF_RUN_RELOAD="$typed" FZF_RC=1 run run_in_pty claude-search --fzf --project p q
    [ "$status" -eq 0 ]
    expected=$'--format=fzf\n--project\np\n--\nq\n--format=fzf\n--no-log\n--no-llm\n--project\np\n--\n'"$typed"
    [ "$(calls engine)" = "$expected" ]
    [ ! -e "$HOME/Y" ]
}

@test "fzf: expansion stays on for the first search and off for the as-you-type reload" {
    use_stub_engine
    cd "$HOME"
    FZF_RUN_RELOAD=typed FZF_RC=1 run run_in_pty claude-search --fzf q
    [ "$status" -eq 0 ]
    # The engine's argv, one per line: everything up to the first query, then the reload's.
    first="$(calls engine | sed '/^q$/q')"
    reload="$(calls engine | sed '1,/^q$/d')"
    [ "$(printf '%s\n' "$reload" | tail -n 1)" = typed ]
    run ! grep -Fx -- --no-llm <<<"$first"
    grep -Fx -- --no-llm <<<"$reload"
}

@test "fzf: Esc exits 130 and says Canceled" {
    use_stub_engine
    FZF_RC=130 run run_in_pty claude-search --fzf q
    [ "$status" -eq 130 ]
    [[ "$output" == *Canceled.* ]]
    [ -z "$(calls claude)" ]
}

@test "fzf: no match exits 0" {
    use_stub_engine
    FZF_RC=1 run run_in_pty claude-search --fzf q
    [ "$status" -eq 0 ]
    [[ "$output" == *"No session selected."* ]]
    [ -z "$(calls claude)" ]
}

@test "fzf: any other fzf failure exits with its code" {
    use_stub_engine
    FZF_RC=2 run run_in_pty claude-search --fzf q
    [ "$status" -eq 2 ]
    [ -z "$(calls claude)" ]
}

@test "fzf: rc 0 with an empty selection exits 1" {
    use_stub_engine
    run run_in_pty claude-search --fzf q
    [ "$status" -eq 1 ]
    FZF_OUT=$'\n ' run run_in_pty claude-search --fzf q
    [ "$status" -eq 1 ]
    [ -z "$(calls claude)" ]
}

@test "fzf: Enter resumes the selected row's session and leaves no temp file" {
    use_stub_engine
    mkdir "$HOME/tmp"
    TMPDIR="$HOME/tmp" FZF_OUT=$'\nsummary\tmore\t'"$UUID" run run_in_pty claude-search --fzf q
    [ "$status" -eq 0 ]
    [[ "$output" == *"Resuming session $UUID"* ]]
    [ "$(calls claude)" = $'--resume\n'"$UUID" ]
    [ -z "$(ls -A "$HOME/tmp")" ]
}

@test "fzf: a malformed selected ID is refused" {
    use_stub_engine
    FZF_OUT=$'\nsummary\tnot an id' run run_in_pty claude-search --fzf q
    [ "$status" -eq 1 ]
    [ -z "$(calls claude)" ]
}

@test "fzf: ctrl-y copies the ID and exits 0" {
    use_stub_engine
    mkdir "$HOME/tmp"
    TMPDIR="$HOME/tmp" FZF_OUT=$'ctrl-y\nsummary\t'"$UUID" run run_in_pty claude-search --fzf q
    [ "$status" -eq 0 ]
    [[ "$output" == *"Copied session ID $UUID"* ]]
    [ "$(cat "$HOME/calls/pbcopy.stdin")" = "$UUID" ]
    [ -z "$(calls claude)" ]
    [ -z "$(ls -A "$HOME/tmp")" ]
    recorded_argv fzf
    [[ " ${ARGV[*]} " == *" --expect=ctrl-y "* ]]
}

@test "fzf: engine failure stops before fzf starts" {
    use_stub_engine
    STUB_RC=1 STUB_ERR=boom-from-engine run run_in_pty claude-search --fzf q
    [ "$status" -eq 1 ]
    [[ "$output" == *boom-from-engine* ]]
    [ -z "$(calls fzf)" ]
}

@test "fzf: refuses without a terminal" {
    use_stub_engine
    run --separate-stderr claude-search --fzf q
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    [[ "$stderr" == *"claude-search: --fzf needs an interactive terminal."* ]]
    printf '%s\n' "$stderr" | grep -Fxq 'Search without the picker:'
    printf '%s\n' "$stderr" | grep -Fxq '    claude-search "<QUERY>"'
    [ -z "$(calls engine)" ]
    [ -z "$(calls fzf)" ]
}

@test "fzf: refuses under CI" {
    use_stub_engine
    CI=true run run_in_pty claude-search --fzf q
    [ "$status" -eq 2 ]
    [[ "$output" == *"needs an interactive terminal"* ]]
    [ -z "$(calls fzf)" ]
}

@test "fzf: refuses under CLAUDECODE" {
    use_stub_engine
    CLAUDECODE=1 run run_in_pty claude-search --fzf q
    [ "$status" -eq 2 ]
    [[ "$output" == *"needs an interactive terminal"* ]]
    [ -z "$(calls fzf)" ]
}

@test "fzf: refuses under --non-interactive and in accessible mode" {
    use_stub_engine
    run run_in_pty claude-search --fzf --non-interactive q
    [ "$status" -eq 2 ]
    SESSION_SEARCH_ACCESSIBLE=1 run run_in_pty claude-search --fzf q
    [ "$status" -eq 2 ]
    [ -z "$(calls fzf)" ]
    FZF_RC=1 SESSION_SEARCH_ACCESSIBLE=0 run run_in_pty claude-search --fzf q
    [ "$status" -eq 0 ]
    [ -n "$(calls fzf)" ]
}

@test "fzf: a wf_ selection previews and does not call claude" {
    use_stub_engine
    FZF_OUT=$'\nsummary\twf_demo-1' run run_in_pty claude-search --fzf q
    [ "$status" -eq 0 ]
    [ "$(calls engine | tail -n 2 | tr '\n' ' ')" = '--preview wf_demo-1 ' ]
    [ -z "$(calls claude)" ]
}

@test "fzf: missing fzf exits 1 with the install command" {
    use_stub_engine
    rm -f "$HOME/stubs/fzf"
    run --separate-stderr claude-search --fzf q
    [ "$status" -eq 1 ]
    [[ "$stderr" == "--fzf needs fzf."* ]]
    printf '%s\n' "$stderr" | grep -Fxq 'Install it:'
    printf '%s\n' "$stderr" | grep -Fxq '    brew install fzf'
    printf '%s\n' "$stderr" | grep -Fxq '    claude-search "<QUERY>"'
    [ -z "$(calls engine)" ]
}

@test "fzf: empty query opens the picker without calling the engine" {
    use_stub_engine
    FZF_RC=1 run run_in_pty claude-search --fzf
    [ "$status" -eq 0 ]
    [ -z "$(calls engine)" ]
    [ -n "$(calls fzf)" ]
    recorded_argv fzf
    [[ " ${ARGV[*]} " == *" --query= "* ]]
}

@test "fzf: the picker and its feed run with the picker variable and bash" {
    printf '%s\n' 'import os' \
        'open(os.path.join(os.environ["HOME"], "feed.env"), "w").write(os.environ.get("__SESSION_SEARCH_PICKER", "unset"))' \
        >"$ENGINE"
    _write_stub fzf <<'STUB'
printf '%s %s' "${__SESSION_SEARCH_PICKER:-unset}" "$SHELL" >"$HOME/fzf.env"
exit 1
STUB
    SHELL=/bin/zsh run run_in_pty claude-search --fzf q
    [ "$status" -eq 0 ]
    [ "$(cat "$HOME/feed.env")" = 1 ]
    [ "$(cat "$HOME/fzf.env")" = '1 /bin/bash' ]
}

@test "fzf: the initial list reaches fzf and the query is prefilled" {
    FZF_RC=1 run run_in_pty claude-search --fzf migration bug
    [ "$status" -eq 0 ]
    [ -s "$HOME/calls/fzf.stdin" ]
    awk -F'\t' '{print $NF}' "$HOME/calls/fzf.stdin" | grep -Eq '^[0-9a-f]{16}$'
    recorded_argv fzf
    [[ " ${ARGV[*]} " == *" --query=migration bug "* ]]
}

@test "fzf: ctrl-o opens the project the engine reports" {
    FZF_RC=1 run run_in_pty claude-search --fzf migration
    [ "$status" -eq 0 ]
    bind="$(fzf_bind '--bind=ctrl-o:execute(')"
    bind="${bind%)}"
    id=7f3a9c21e4d50a18
    bash -c "${bind//\{-1\}/$id}" || true
    [ "$(calls open)" = "$(sqlite3 "$DB" "select project_path from sessions where session_id='$id'")" ]
    rm -f "$HOME/calls/open"
    bash -c "${bind//\{-1\}/no-such-session}" || true
    [ -z "$(calls open)" ]
}

@test "fzf: the preview bind shows the selected session" {
    FZF_RC=1 run run_in_pty claude-search --fzf migration
    [ "$status" -eq 0 ]
    bind="$(fzf_bind '--preview=')"
    run bash -c "${bind//\{-1\}/7f3a9c21e4d50a18}"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "fzf: real fzf accepts the options the wrapper passes" {
    real="$(PATH="$REAL_PATH" command -v fzf)" || skip "fzf is not installed"
    use_stub_engine
    FZF_RC=1 run run_in_pty claude-search --fzf q
    [ "$status" -eq 0 ]
    recorded_argv fzf
    # --filter runs no bind and draws nothing, but fzf still parses every option.
    run env -u FZF_DEFAULT_OPTS -u FZF_DEFAULT_OPTS_FILE "$real" --filter x "${ARGV[@]}" </dev/null
    [ "$status" -le 1 ]
    run env -u FZF_DEFAULT_OPTS -u FZF_DEFAULT_OPTS_FILE "$real" --filter x --bind=ctrl-o:not-an-action </dev/null
    [ "$status" -eq 2 ]
}

@test "demo tape unsets CI" {
    grep -q 'unset CI' "$REPO/assets/demo/fzf-demo.tape"
}

# ─── B6.7 Header ─────────────────────────────────────────

@test "header comment shows --json, --since and --analytics, not --after" {
    header="$(awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$REPO/bin/claude-search")"
    [[ "$header" == *--analytics* ]]
    [[ "$header" == *--since* ]]
    [[ "$header" == *--json* ]]
    [[ "$header" != *--after* ]]
}

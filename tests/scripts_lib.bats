#!/usr/bin/env bats
# scripts/lib/cli-common.sh, scripts/lib/settings-edit.sh and the script sandbox. Every case runs
# through $LIB, a #!/bin/bash strict-mode script like the ones that source these libraries, so on
# macOS it proves bash 3.2 whatever bash runs bats.
#
# shellcheck disable=SC2016,SC2030,SC2031 # snippets expand in $LIB; bats's $output is per test

load helpers_scripts

# Files still carrying a lint hit, as path:count. U21 empties both lists.
PENDING_TTY_LINT_FILES="scripts/lib/progress-ui.sh:1"
PENDING_ESCAPE_LINT_FILES="install.sh:1"

setup() {
    script_sandbox_setup
    SETTINGS="$HOME/.claude/settings.json"
    LIB="$BATS_TEST_TMPDIR/lib-run"
    cat >"$LIB" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
. "$REPO/scripts/lib/cli-common.sh"
. "$REPO/scripts/lib/settings-edit.sh"
snippet="$1"
shift
eval "$snippet"
SCRIPT
    chmod +x "$LIB"
}
teardown() { sandbox_teardown; }

# Plain `run` may reset $output before the command reads it, as in harness.bats.
fails() {
    if "$@" 2>/dev/null; then
        return 1
    fi
}

PARSE='css_parse_args prog "quiet|q|bool|QUIET" "since|s|value|SINCE" -- "$@"; printf "%s/%s\n" "$QUIET" "$SINCE"'

# parsed <expected> <args...>: a clean parse, and every VAR readable under set -u.
parsed() {
    local want="$1"
    shift
    run --separate-stderr "$LIB" "$PARSE" "$@"
    [ "$status" -eq 0 ] || { echo "status $status for: $*: $stderr" >&2; return 1; }
    [ "$output" = "$want" ] || { echo "for: $*: got [$output], want [$want]" >&2; return 1; }
}

# usage_fails <stderr fragment> <args...>: exit 2, naming the fragment and help, no stdout.
usage_fails() {
    local want="$1"
    shift
    run --separate-stderr "$LIB" "$PARSE touch \"\$HOME/effect\"" "$@"
    [ "$status" -eq 2 ] || { echo "status $status for: $*" >&2; return 1; }
    [ -z "$output" ] || { echo "stdout for: $*: $output" >&2; return 1; }
    case "$stderr" in
        "prog: "*"$want"*$'\n'"See 'prog --help'.") ;;
        *) echo "for: $*: stderr [$stderr], want [$want]" >&2; return 1 ;;
    esac
    [ ! -e "$HOME/effect" ]
}

@test "parser handles --x=v, --x v, -x v and --" {
    parsed "0/"
    parsed "1/" --quiet
    parsed "1/" -q
    parsed "0/7" --since=7
    parsed "0/7" --since 7
    parsed "0/7" -s 7
    parsed "0/" --since=
    parsed "0/a=b" --since=a=b
    parsed "0/-x" --since=-x
    parsed "0/-1" --since -1
    parsed "0/-" -s -
    parsed "1/9" --since=7 -q --since 9
    parsed "0/" --

    # Everything after -- is a positional, even what looks like an option, and options mix with them.
    run --separate-stderr "$LIB" 'css_parse_args prog "quiet|q|bool|QUIET" "since|s|value|SINCE" "||args|REST" -- "$@"
        printf "%s/%s/%s\n" "$QUIET" "$SINCE" "${#REST[@]}"; printf "[%s]\n" ${REST[@]+"${REST[@]}"}' \
        a -q -- --since "b c" ""
    [ "$status" -eq 0 ]
    [ "$output" = $'1//4\n[a]\n[--since]\n[b c]\n[]' ]

    # No positionals: the array is set and empty under set -u.
    run --separate-stderr "$LIB" 'css_parse_args prog "||args|REST" -- "$@"; echo "n=${#REST[@]}"'
    [ "$status" -eq 0 ]
    [ "$output" = "n=0" ]
}

@test "parser sets a caller's locals and ignores an exported variable of the same name" {
    run --separate-stderr env QUIET=1 SINCE=99 "$LIB" 'f() {
            local QUIET SINCE
            css_parse_args prog "quiet|q|bool|QUIET" "since|s|value|SINCE" -- "$@"
            echo "$QUIET/$SINCE"
        }
        f --since 7
        echo "${QUIET}/${SINCE}"'
    [ "$status" -eq 0 ]
    [ "$output" = $'0/7\n1/99' ]
}

@test "a missing value exits 2 naming the option" {
    usage_fails "option --since needs a value" --since
    usage_fails "option -s needs a value" -s
    usage_fails "option --since needs a value" --since --quiet
    usage_fails "option -s needs a value" -s -q
    usage_fails "option --since needs a value" --since --
    usage_fails "option --quiet takes no value" --quiet=1
}

@test "unknown option exits 2 with one close match and no effect" {
    usage_fails "unknown option: --quiett (did you mean --quiet?)" --quiett
    usage_fails "unknown option: --snice (did you mean --since?)" --snice=7
    usage_fails "unknown option: -quiet (did you mean --quiet?)" -quiet
    usage_fails "unknown option: --bogus" --bogus
    usage_fails "unknown option: -z" -z
    # A prefix is a typo to report, never an option to infer (R065).
    usage_fails "unknown option: --qui" --qui

    # What follows `=` may be a secret.
    run --separate-stderr "$LIB" "$PARSE" --tokn=hunter2
    [ "$status" -eq 2 ]
    case "$stderr" in *hunter2*) false ;; esac

    # Two equally close options: no guess.
    run --separate-stderr "$LIB" 'css_parse_args prog "color||bool|A" "colon||bool|B" -- "$@"' --colox
    [ "$status" -eq 2 ]
    [ "$stderr" = $'prog: unknown option: --colox\nSee \'prog --help\'.' ]
}

@test "an extra positional exits 2 unless the spec collects positionals" {
    usage_fails "unexpected argument: stray" stray
    usage_fails "unexpected argument: --quiet" -- --quiet
    usage_fails "unexpected argument: stray" --quiet stray
}

@test "parse-only exits 0 after a clean parse, before any effect, and still rejects a bad one" {
    run env __SESSION_SEARCH_PARSE_ONLY=1 "$LIB" "$PARSE touch \"\$HOME/effect\"" --since 7
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$HOME/effect" ]

    run env __SESSION_SEARCH_PARSE_ONLY=1 "$LIB" "$PARSE" --bogus
    [ "$status" -eq 2 ]
}

@test "a malformed spec exits 2 and runs nothing it carries" {
    local spec
    for spec in 'x|y' 'a|bb|bool|V' 'a||flag|V' '||bool|V' 'a||bool|1V' 'a||bool|__css_var' \
        '-a||bool|V' 'a||bool|V;touch${IFS}"$HOME/effect"' 'a||args|V=$(touch${IFS}"$HOME/effect")'; do
        run --separate-stderr "$LIB" "css_parse_args prog '$spec' -- ; echo reached"
        [ "$status" -eq 2 ] || { echo "status $status for spec: $spec" >&2; return 1; }
        [ -z "$output" ]
        [ ! -e "$HOME/effect" ]
    done
    run --separate-stderr "$LIB" 'css_parse_args prog "a||bool|V"; echo reached'
    [ "$status" -eq 2 ]
    [ -z "$output" ]
}

@test "css_version reads the first line of VERSION, else unknown" {
    local dir="$BATS_TEST_TMPDIR/v"
    mkdir -p "$dir"
    [ "$("$LIB" 'css_version "$1"' "$dir")" = unknown ]
    printf '1.2.3\nsecond\n' >"$dir/VERSION"
    [ "$("$LIB" 'css_version "$1"' "$dir")" = 1.2.3 ]
    printf ' 1.2.4\r\n' >"$dir/VERSION"
    [ "$("$LIB" 'css_version "$1"' "$dir")" = 1.2.4 ]
    printf '1.2.5' >"$dir/VERSION"
    [ "$("$LIB" 'css_version "$1"' "$dir")" = 1.2.5 ]
    : >"$dir/VERSION"
    [ "$("$LIB" 'css_version "$1"' "$dir")" = unknown ]
}

# on_stream <tty|pipe> <want> <env words> <snippet> [args...]: the snippet's stdout, or the pty's.
on_stream() {
    local stream="$1" want="$2" envs="$3"
    shift 3
    if [ "$stream" = tty ]; then
        # shellcheck disable=SC2086 # word splitting is the point: each word is one VAR=value
        run run_in_pty env $envs "$LIB" "$@"
    else
        # shellcheck disable=SC2086
        run env $envs "$LIB" "$@"
    fi
    output="${output//$'\r'/}"
    [ "$output" = "$want" ] || { echo "$stream [$envs]: got [$output] status $status, want [$want]" >&2; return 1; }
}

COLOR='css_parse_args prog "no-color||bool|__SESSION_SEARCH_NO_COLOR" -- "$@"; if css_color_enabled 1; then echo on; else echo off; fi'

@test "colour precedence follows R206" {
    on_stream tty on "" "$COLOR"
    on_stream pipe off "" "$COLOR"
    on_stream tty off "" "$COLOR" --no-color
    on_stream pipe off "FORCE_COLOR=1" "$COLOR" --no-color
    on_stream tty off "NO_COLOR=1" "$COLOR"
    on_stream pipe off "NO_COLOR=1 FORCE_COLOR=1" "$COLOR"
    on_stream tty on "NO_COLOR=" "$COLOR"
    on_stream tty off "FORCE_COLOR=0" "$COLOR"
    on_stream pipe on "FORCE_COLOR=1" "$COLOR"
    on_stream tty on "FORCE_COLOR=" "$COLOR"
    on_stream tty off "TERM=dumb" "$COLOR"
    on_stream pipe on "TERM=dumb FORCE_COLOR=1" "$COLOR"
}

@test "css_rich answers for the stream it is asked about" {
    on_stream tty "1 off, 2 on" "" 'if css_rich 1 >/dev/null; then a=on; else a=off; fi
        if css_rich 2 >/dev/null; then b=on; else b=off; fi; echo "1 $a, 2 $b"'
    on_stream tty "off" "TERM=dumb" 'if css_rich 1; then echo on; else echo off; fi'
}

@test "css_interactive is false under CI and CLAUDECODE" {
    local ask='if css_interactive; then echo yes; else echo no; fi'
    on_stream tty yes "" "$ask"
    on_stream tty yes "CI=" "$ask"
    on_stream tty no "CI=true" "$ask"
    on_stream tty no "CLAUDECODE=1" "$ask"
    on_stream tty no "__SESSION_SEARCH_NON_INTERACTIVE=1" "$ask"
    on_stream tty yes "__SESSION_SEARCH_NON_INTERACTIVE=0" "$ask"
    on_stream pipe no "" "$ask"
    on_stream tty no "" 'if css_interactive </dev/null; then echo yes; else echo no; fi'
    on_stream tty no "" 'if css_interactive 2>/dev/null; then echo yes; else echo no; fi'

    ask='if css_guidance_on; then echo yes; else echo no; fi'
    on_stream tty yes "" "$ask"
    on_stream tty no "SESSION_SEARCH_GUIDANCE_DISABLED=1" "$ask"
    on_stream tty no "CI=true" "$ask"
}

@test "css_fail lays out the error on stderr and exits 1, with or without recovery" {
    run --separate-stderr "$LIB" 'css_fail "It broke" "Run this" "cmd one" "cmd two"; echo reached'
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [ "$stderr" = $'Error: It broke\n\nRun this:\n    cmd one\n    cmd two' ]

    # Headline only must reach exit 1 under set -e, not die early with no message.
    run --separate-stderr "$LIB" 'css_fail "It broke"; echo reached'
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [ "$stderr" = "Error: It broke" ]

    # An instruction with no command is a plain sentence (R280).
    run --separate-stderr "$LIB" 'css_fail "It broke" "Install jq first."'
    [ "$status" -eq 1 ]
    [ "$stderr" = $'Error: It broke\n\nInstall jq first.' ]

    on_stream tty $'✗ It broke\n\nRun this:\n    cmd' "" 'css_fail "It broke" "Run this:" "cmd"'
    [ "$status" -eq 1 ]
    on_stream tty "Error: It broke" "TERM=dumb" 'css_fail "It broke"'
    on_stream tty "Error: It broke" "SESSION_SEARCH_ACCESSIBLE=1" 'css_fail "It broke"'
}

@test "css_warn prints one row on stderr and does not exit" {
    run --separate-stderr "$LIB" 'css_warn "No index"; echo reached'
    [ "$status" -eq 0 ]
    [ "$output" = reached ]
    [ "$stderr" = "Warning: No index" ]

    on_stream tty $'! No index\nreached' "" 'css_warn "No index"; echo reached'
    on_stream tty $'Warning: No index\nreached' "SESSION_SEARCH_ACCESSIBLE=1" 'css_warn "No index"; echo reached'
}

@test "css_json_error writes one JSON line on stderr, with jq and without" {
    # Bytes here are checked by the real jq, never by the code under test.
    local tricky=$'say "hi" \\ there\nnext\tline\rend\001.'
    local want='.status == "error" and .reason == "db_locked" and .next == []
        and .message == "say \"hi\" \\ there\nnext\tline\rend."'
    local snippet='css_json_error "$1" "$2"; echo reached'

    run --separate-stderr "$LIB" "$snippet" db_locked "${tricky//$'\001'/}"
    [ "$status" -eq 0 ]
    [ "$output" = reached ]
    assert_one_json_doc "$stderr"
    printf '%s' "$stderr" | jq -e "$want"

    mkdir "$HOME/nojq"
    run --separate-stderr env PATH="$HOME/nojq" "$LIB" "$snippet" db_locked "$tricky"
    [ "$status" -eq 0 ]
    [ "$output" = reached ]
    assert_one_json_doc "$stderr"
    printf '%s' "$stderr" | jq -e "$want"

    # The engine's shape for a usage failure.
    run --separate-stderr "$LIB" 'css_json_error invalid_arguments nope'
    printf '%s' "$stderr" | jq -e '.status == "action_required"'
}

@test "sourcing the libraries has no side effect and a patch keeps the caller's EXIT trap" {
    # Named signals only: a bare `trap -p` also lists what the runner already ignores (SIGPIPE on CI).
    run "$LIB" 'trap -p EXIT INT TERM HUP; echo sourced'
    [ "$status" -eq 0 ]
    [ "$output" = sourced ]
    assert_tree_unchanged

    run "$LIB" 'trap "echo caller-trap" EXIT; css_settings_patch "$1" ".a = 1"; echo patched' "$SETTINGS"
    [ "$status" -eq 0 ]
    [ "$output" = $'patched\ncaller-trap' ]
}

# no_patch_residue: only the settings file itself, with no lock, temp file or backup beside it.
no_patch_residue() {
    local left
    left="$(find "$(dirname "$SETTINGS")" -maxdepth 1 \( -name '.settings.json.*' -o -name '*.lock.d' -o -name '*.bak.*' \))"
    [ -z "$left" ] || { echo "left behind: $left" >&2; return 1; }
}

@test "settings patch keeps a symlink, the file mode and unrelated keys" {
    local real="$HOME/dotfiles/settings.json" before
    mkdir "$HOME/dotfiles"
    mv "$SETTINGS" "$real"
    ln -s "$real" "$SETTINGS"
    chmod 640 "$real"
    before="$(cat "$real")"

    run --separate-stderr "$LIB" 'css_settings_patch "$1" ".added = true"; echo "$CSS_SETTINGS_BACKUP"' "$SETTINGS"
    [ "$status" -eq 0 ]

    [ -L "$SETTINGS" ]
    [ "$(readlink "$SETTINGS")" = "$real" ]
    [ -n "$(find "$real" -perm 640)" ]
    jq -e '.added == true and .model == "opus"
        and .hooks.PreToolUse[0].hooks[0].command == "~/unrelated-hook.sh"' "$real"

    # The backup holds the previous contents, next to the real file; no lock or temp remains.
    # Matched by suffix: the library resolves the path, and macOS's temp dir is under a symlink.
    case "$output" in */dotfiles/settings.json.bak.*) ;; *) echo "backup: $output" >&2; return 1 ;; esac
    [ "$(cat "$output")" = "$before" ]
    [ "$(find "$HOME/dotfiles" -mindepth 1 | wc -l | tr -d ' ')" = 2 ]
}

@test "settings patch on a failing filter leaves no temp file and exits 1" {
    local filter
    # A jq error, a syntax error, and three that exit 0 but would wreck the file.
    for filter in 'error("nope")' '.a |' 'empty' '.a = 1, .b = 2' '.hooks.PreToolUse'; do
        run --separate-stderr "$LIB" 'css_settings_patch "$1" "$2"; echo reached' "$SETTINGS" "$filter"
        [ "$status" -eq 1 ] || { echo "status $status for filter: $filter" >&2; return 1; }
        [ -z "$output" ]
        case "$stderr" in */.claude/settings.json:\ *) ;; *) echo "stderr: $stderr" >&2; return 1 ;; esac
        assert_tree_unchanged
    done
}

@test "settings patch refuses a broken file or a missing one and writes nothing" {
    local content
    for content in '{"a": 1,' ''; do
        printf '%s' "$content" >"$SETTINGS"
        tree_snapshot
        run --separate-stderr "$LIB" 'css_settings_patch "$1" ".a = 2"' "$SETTINGS"
        [ "$status" -eq 1 ]
        assert_tree_unchanged
    done

    mv "$SETTINGS" "$SETTINGS.moved"
    tree_snapshot
    run --separate-stderr "$LIB" 'css_settings_patch "$1" ".a = 2"' "$SETTINGS"
    [ "$status" -eq 1 ]
    [ "$stderr" = "$SETTINGS: no such file" ]
    assert_tree_unchanged
}

@test "settings patch that changes nothing adds no backup" {
    run "$LIB" 'css_settings_patch "$1" ". + {a: 1}"' "$SETTINGS"
    [ "$status" -eq 0 ]
    tree_snapshot
    run "$LIB" 'css_settings_patch "$1" ". + {a: 1}"; echo "[$CSS_SETTINGS_BACKUP]"' "$SETTINGS"
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
    assert_tree_unchanged
}

# A second writer that takes no lock, as Claude Code does: real jq reads the file, then this edits
# it in place before the patch can rename its result over it, for the first STUB_WRITES patch passes.
stub_second_writer() {
    _write_stub jq <<'STUB'
"$HOME/tools/jq" "$@"
rc=$?
if [ "${1:-}" = '.patched = true' ]; then
    n="$(cat "$HOME/calls/writes" 2>/dev/null || echo 0)"
    if [ "$n" -lt "$STUB_WRITES" ]; then
        echo "$((n + 1))" >"$HOME/calls/writes"
        "$HOME/tools/jq" '.other = ((.other // 0) + 1)' "$2" >"$HOME/calls/next"
        cat "$HOME/calls/next" >"$2"
    fi
fi
exit "$rc"
STUB
}

@test "settings patch aborts when the file changes while patching" {
    stub_second_writer
    run --separate-stderr env STUB_WRITES=99 "$LIB" 'css_settings_patch "$1" ".patched = true"; echo reached' "$SETTINGS"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    # The other writer's edits stand and ours did not overwrite them.
    jq -e '.patched == null and .other >= 1' "$SETTINGS"
    no_patch_residue
}

@test "settings patch retries once the other writer stops, keeping that writer's edit" {
    stub_second_writer
    run --separate-stderr env STUB_WRITES=1 "$LIB" 'css_settings_patch "$1" ".patched = true"' "$SETTINGS"
    [ "$status" -eq 0 ]
    jq -e '.patched == true and .other == 1 and .model == "opus"' "$SETTINGS"
}

@test "settings patch gives up on a held lock, writes nothing and leaves the lock alone" {
    mkdir "$SETTINGS.lock.d"
    tree_snapshot
    run --separate-stderr "$LIB" 'css_settings_patch "$1" ".a = 1"' "$SETTINGS"
    [ "$status" -eq 1 ]
    case "$stderr" in *"rmdir "*/.claude/settings.json.lock.d) ;; *) echo "stderr: $stderr" >&2; return 1 ;; esac
    assert_tree_unchanged
}

@test "concurrent settings patches each land" {
    local i pids=""
    for i in 1 2 3 4; do
        "$LIB" 'css_settings_patch "$1" ".k$2 = true"' "$SETTINGS" "$i" &
        pids="$pids $!"
    done
    for i in $pids; do
        wait "$i"
    done
    jq -e '.k1 and .k2 and .k3 and .k4 and .model == "opus"' "$SETTINGS"
    [ "$(find "$(dirname "$SETTINGS")" -maxdepth 1 -name '*.bak.*' | wc -l | tr -d ' ')" = 4 ]
}

@test "css_settings_validate names the file, line and column, and never writes" {
    run --separate-stderr "$LIB" 'css_settings_validate "$1"' "$SETTINGS"
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]

    printf '{\n  "a": 1,\n}\n' >"$SETTINGS"
    tree_snapshot
    run --separate-stderr "$LIB" 'css_settings_validate "$1"; echo reached' "$SETTINGS"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    case "$stderr" in
        "$SETTINGS: "*"line 3"*"column"*) ;;
        *) echo "stderr: $stderr" >&2; return 1 ;;
    esac
    assert_tree_unchanged

    # Valid JSON that is not a settings document: `jq empty` alone passes all of these.
    local content
    for content in '' '[]' '{} {}'; do
        printf '%s' "$content" >"$SETTINGS"
        run --separate-stderr "$LIB" 'css_settings_validate "$1"' "$SETTINGS"
        [ "$status" -eq 1 ] || { echo "status $status for: $content" >&2; return 1; }
        [ "$stderr" = "$SETTINGS: expected one JSON object" ]
    done
}

# lint <regex> <pending path:count list> <exempt file>: over the install and index shell scripts,
# a listed file may not exceed its count and any other may have no hit.
lint() {
    local regex="$1" pending="$2" exempt="$3" path rel hits allowed entry bad=0 count=0
    for path in "$REPO"/install.sh "$REPO"/uninstall.sh "$REPO"/scripts/*.sh "$REPO"/scripts/lib/*.sh; do
        rel="${path#"$REPO"/}"
        [ "$rel" != "$exempt" ] || continue
        [ -f "$path" ] || { echo "lint: missing $rel" >&2; return 1; }
        count=$((count + 1))
        hits="$(grep -cE -- "$regex" "$path" || true)"
        allowed=0
        for entry in $pending; do
            if [ "${entry%:*}" = "$rel" ]; then
                allowed="${entry##*:}"
            fi
        done
        if [ "$hits" -gt "$allowed" ]; then
            echo "$rel: $hits hits, $allowed allowed" >&2
            grep -nE -- "$regex" "$path" >&2
            bad=1
        fi
    done
    # The glob must have found the scripts it exists to guard.
    [ "$count" -ge 5 ] || { echo "lint: scanned only $count files" >&2; return 1; }
    [ "$bad" = 0 ]
}

# R408. bin/claude-search is exempt because it deploys as one copied file.
@test "TTY checks live only in cli-common.sh" {
    lint '\[ -t [012] \]' "$PENDING_TTY_LINT_FILES" scripts/lib/cli-common.sh
}

# R199, R412.
@test "no raw colour escapes outside progress-ui.sh" {
    lint '\\033\[' "$PENDING_ESCAPE_LINT_FILES" scripts/lib/progress-ui.sh
}

@test "script_sandbox_setup stubs launchctl and uname and seeds what install.sh acts on" {
    [ "$(command -v launchctl)" = "$HOME/stubs/launchctl" ]
    run launchctl load "$HOME/x.plist"
    [ "$status" -eq 0 ]
    [ "$(calls launchctl)" = $'load\n'"$HOME/x.plist" ]

    [ "$(STUB_UNAME=Linux uname)" = Linux ]
    [ "$(STUB_UNAME=Darwin uname -s)" = Darwin ]
    [ "$(STUB_UNAME=Linux uname -m)" = "$(/usr/bin/uname -m)" ]
    [ "$(uname -s)" = "$(/usr/bin/uname -s)" ]

    [ -d "$HOME/Library/LaunchAgents" ]
    [ -s "$HOME/.zshrc" ]
    jq -e '.hooks.PreToolUse | length == 1' "$HOME/.claude/settings.json"
    [ -z "${ANTHROPIC_API_KEY+set}" ]
}

@test "assert_tree_unchanged sees an edit, a removal, an empty directory, a mode and a symlink" {
    assert_tree_unchanged

    echo more >>"$HOME/.zshrc"
    fails assert_tree_unchanged
    tree_snapshot

    rm "$HOME/.zshrc"
    fails assert_tree_unchanged
    tree_snapshot

    mkdir "$HOME/new-dir"
    fails assert_tree_unchanged
    tree_snapshot

    chmod 604 "$HOME/.claude/settings.json"
    fails assert_tree_unchanged
    tree_snapshot

    ln -s a "$HOME/link"
    tree_snapshot
    rm "$HOME/link"
    ln -s b "$HOME/link"
    fails assert_tree_unchanged
    tree_snapshot

    # The stubs' own log is not the subject's doing.
    launchctl list
    assert_tree_unchanged
}

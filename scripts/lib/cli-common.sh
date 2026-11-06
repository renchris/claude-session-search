# shellcheck shell=bash
# Shared CLI contract for the shell scripts: argument parsing, mode detection and error layout.
# The Python engine holds the same rules in resolve_mode() and render_error() (bin/session-search.py),
# so the two read an environment variable the same way: empty counts as unset.
#
# Bash 3.2 (macOS /bin/bash): no mapfile, associative arrays or ${v,,}. Sourcing this file has no
# side effects: no trap, no exec, no write. Every function is safe to call under `set -euo pipefail`.
# This is the only file allowed to test a stream with `[ -t N ]` (R408); tests/scripts_lib.bats
# enforces that.
#
# Internal switches, never shown in help (R079). A script's flag parser sets them:
#   __SESSION_SEARCH_NO_COLOR=1         --no-color
#   __SESSION_SEARCH_NON_INTERACTIVE=1  --non-interactive or --json
#   __SESSION_SEARCH_PARSE_ONLY=1       css_parse_args stops after a clean parse (R100)

# css_version REPO_DIR: the first line of REPO_DIR/VERSION, trimmed, else "unknown".
css_version() {
    local line=""
    if [ -f "$1/VERSION" ] && [ -r "$1/VERSION" ]; then
        # read fails on a last line with no newline, yet still fills the variable.
        IFS= read -r line <"$1/VERSION" || true
    fi
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    printf '%s\n' "${line:-unknown}"
}

# css_usage_fail PROG MESSAGE: the usage error layout on stderr, then exit 2 (R055, R337).
css_usage_fail() {
    printf '%s: %s\n' "$1" "$2" >&2
    printf "See '%s --help'.\n" "$1" >&2
    exit 2
}

# Levenshtein distance between $1 and $2, printed.
_css_edit_distance() {
    local a="$1" b="$2" i j cost best previous=() current=()
    for ((j = 0; j <= ${#b}; j++)); do
        previous[j]=$j
    done
    for ((i = 1; i <= ${#a}; i++)); do
        current[0]=$i
        for ((j = 1; j <= ${#b}; j++)); do
            cost=1
            if [ "${a:i-1:1}" = "${b:j-1:1}" ]; then
                cost=0
            fi
            best=$((previous[j - 1] + cost))
            if [ "$((previous[j] + 1))" -lt "$best" ]; then
                best=$((previous[j] + 1))
            fi
            if [ "$((current[j - 1] + 1))" -lt "$best" ]; then
                best=$((current[j - 1] + 1))
            fi
            current[j]=$best
        done
        previous=("${current[@]}")
    done
    printf '%s\n' "${previous[${#b}]}"
}

# The one declared long option close to the mistyped token $1, printed; nothing when none is close
# or two are equally close (R304). Reads css_parse_args's __css_longs.
_css_close_option() {
    local bare="${1#-}" best="" best_distance=99 tied=0 limit=2 i candidate gap distance
    bare="${bare#-}"
    if [ "${#bare}" -lt 2 ]; then
        return 0
    fi
    if [ "${#bare}" -le 3 ]; then
        limit=1
    fi
    for ((i = 0; i < ${#__css_longs[@]}; i++)); do
        candidate="${__css_longs[i]}"
        gap=$((${#bare} - ${#candidate}))
        # Length alone rules most out, and it bounds the work on an absurdly long token.
        if [ -z "$candidate" ] || [ "$gap" -gt "$limit" ] || [ "$gap" -lt "-$limit" ]; then
            continue
        fi
        distance=$(_css_edit_distance "$bare" "$candidate")
        if [ "$distance" -gt "$limit" ]; then
            continue
        fi
        if [ "$distance" -lt "$best_distance" ]; then
            best="$candidate"
            best_distance=$distance
            tied=0
        elif [ "$distance" -eq "$best_distance" ]; then
            tied=1
        fi
    done
    if [ -n "$best" ] && [ "$tied" = 0 ]; then
        printf -- '--%s\n' "$best"
    fi
}

# A malformed spec is a bug in the calling script, not a user mistake, so it does not point at help.
_css_bad_spec() {
    printf 'css_parse_args: bad spec: %s\n' "$1" >&2
    exit 2
}

# css_parse_args PROG SPEC... -- "$@"
#
# SPEC is "long|short|kind|VAR". Either name may be empty; names carry no dashes.
#   bool    VAR is 1 when given, else 0.
#   value   VAR is the value, else empty. Takes --name value, --name=value and -x value.
#   args    "||args|VAR": VAR is an array of the positionals. Read it with ${VAR[@]+"${VAR[@]}"}.
#           With no args spec, any positional is a usage error (R064).
#
# Options and positionals may mix; `--` ends the options and what follows is positional, literally
# (R066). Names match exactly, never by prefix (R065). A next token that starts with `-` is not taken
# as a value, except `-` and negative numbers; --name=-x passes one. The last of a repeated option wins.
#
# Every VAR is set on return, in the caller's scope (a caller's `local VAR` works), so it reads
# safely under `set -u`. Each is reset first, so an exported variable of the same name cannot pose as
# a flag: apply a default after the call with VAR=${VAR:-default}. Declare --help yourself, since an
# undeclared one is an unknown option. Bad usage exits 2 through css_usage_fail before the caller does
# any work; __SESSION_SEARCH_PARSE_ONLY=1 exits 0 right after a clean parse (R100).
css_parse_args() {
    local __css_prog="$1"
    local __css_longs=() __css_shorts=() __css_kinds=() __css_vars=()
    local __css_args_var="" __css_n=0 __css_spec __css_rest __css_long __css_short __css_kind __css_var
    local __css_arg __css_name __css_value __css_has_value __css_i __css_found __css_close
    shift

    while :; do
        if [ "$#" -eq 0 ]; then
            _css_bad_spec "no -- before the arguments"
        fi
        __css_spec="$1"
        shift
        if [ "$__css_spec" = "--" ]; then
            break
        fi
        __css_long="${__css_spec%%|*}"
        __css_rest="${__css_spec#*|}"
        __css_short="${__css_rest%%|*}"
        __css_rest="${__css_rest#*|}"
        __css_kind="${__css_rest%%|*}"
        __css_var="${__css_rest#*|}"
        # The names reach eval below, so only a plain identifier passes; __css_ would hit our locals.
        case "$__css_var" in
            "" | [0-9]* | *[!a-zA-Z0-9_]* | __css_*) _css_bad_spec "$__css_spec" ;;
        esac
        case "$__css_long" in
            -* | *[!a-zA-Z0-9-]*) _css_bad_spec "$__css_spec" ;;
        esac
        case "$__css_short" in
            "" | [a-zA-Z0-9]) ;;
            *) _css_bad_spec "$__css_spec" ;;
        esac
        case "$__css_kind" in
            bool) eval "$__css_var=0" ;;
            value) eval "$__css_var=" ;;
            args) ;;
            *) _css_bad_spec "$__css_spec" ;;
        esac
        if [ "$__css_kind" = args ]; then
            __css_args_var="$__css_var"
            eval "$__css_var=()"
            continue
        fi
        if [ -z "$__css_long$__css_short" ]; then
            _css_bad_spec "$__css_spec"
        fi
        __css_longs[__css_n]="$__css_long"
        __css_shorts[__css_n]="$__css_short"
        __css_kinds[__css_n]="$__css_kind"
        __css_vars[__css_n]="$__css_var"
        __css_n=$((__css_n + 1))
    done

    while [ "$#" -gt 0 ]; do
        __css_arg="$1"
        shift
        __css_has_value=0
        __css_value=""
        case "$__css_arg" in
            --)
                for __css_arg in "$@"; do
                    if [ -z "$__css_args_var" ]; then
                        css_usage_fail "$__css_prog" "unexpected argument: $__css_arg"
                    fi
                    eval "$__css_args_var+=(\"\$__css_arg\")"
                done
                break
                ;;
            --?*=*)
                __css_name="${__css_arg%%=*}"
                __css_value="${__css_arg#*=}"
                __css_has_value=1
                ;;
            -?*)
                __css_name="$__css_arg"
                ;;
            *)
                if [ -z "$__css_args_var" ]; then
                    css_usage_fail "$__css_prog" "unexpected argument: $__css_arg"
                fi
                eval "$__css_args_var+=(\"\$__css_arg\")"
                continue
                ;;
        esac

        __css_found=""
        for ((__css_i = 0; __css_i < __css_n; __css_i++)); do
            if [ "$__css_name" = "--${__css_longs[__css_i]}" ] || [ "$__css_name" = "-${__css_shorts[__css_i]}" ]; then
                __css_found=$__css_i
                break
            fi
        done
        if [ -z "$__css_found" ]; then
            # Never echo what follows an `=`: it may be a secret.
            __css_name="${__css_name%%=*}"
            __css_close="$(_css_close_option "$__css_name")"
            if [ -n "$__css_close" ]; then
                css_usage_fail "$__css_prog" "unknown option: $__css_name (did you mean $__css_close?)"
            fi
            css_usage_fail "$__css_prog" "unknown option: $__css_name"
        fi

        __css_var="${__css_vars[__css_found]}"
        if [ "${__css_kinds[__css_found]}" = bool ]; then
            if [ "$__css_has_value" = 1 ]; then
                css_usage_fail "$__css_prog" "option $__css_name takes no value"
            fi
            eval "$__css_var=1"
            continue
        fi
        if [ "$__css_has_value" = 0 ]; then
            if [ "$#" -eq 0 ]; then
                css_usage_fail "$__css_prog" "option $__css_name needs a value"
            fi
            case "$1" in
                - | -[0-9]*) ;;
                -*) css_usage_fail "$__css_prog" "option $__css_name needs a value" ;;
            esac
            __css_value="$1"
            shift
        fi
        eval "$__css_var=\$__css_value"
    done

    if [ "${__SESSION_SEARCH_PARSE_ONLY:-}" = 1 ]; then
        exit 0
    fi
}

# css_rich FD: FD may take cursor control and redraws (R115, R207). An unset TERM promises nothing.
css_rich() {
    [ -t "$1" ] && [ "${TERM:-dumb}" != dumb ]
}

# True when an internal switch is on: set, and neither empty nor 0.
_css_switch_on() {
    case "$1" in
        "" | 0) return 1 ;;
    esac
}

# css_color_enabled FD. Precedence, highest first (R206): --no-color, a non-empty NO_COLOR,
# FORCE_COLOR (0 is off), then whether FD is rich.
css_color_enabled() {
    if _css_switch_on "${__SESSION_SEARCH_NO_COLOR:-}" || [ -n "${NO_COLOR:-}" ]; then
        return 1
    fi
    if [ -n "${FORCE_COLOR:-}" ]; then
        [ "$FORCE_COLOR" != 0 ]
        return
    fi
    css_rich "$1"
}

# css_interactive: a person can answer on this terminal (R113, R117).
css_interactive() {
    [ -t 0 ] && [ -t 2 ] && [ -z "${CI:-}" ] && [ -z "${CLAUDECODE:-}" ] &&
        ! _css_switch_on "${__SESSION_SEARCH_NON_INTERACTIVE:-}"
}

# css_guidance_on: optional tips and offers may show (R238, R240).
css_guidance_on() {
    css_interactive && [ -z "${SESSION_SEARCH_GUIDANCE_DISABLED:-}" ]
}

# Glyph rows on stderr: a rich stream, and not accessible mode, which keeps plain words (R205).
_css_glyphs_on() {
    css_rich 2 && [ "${SESSION_SEARCH_ACCESSIBLE:-}" != 1 ]
}

# css_fail HEADLINE [INSTRUCTION [COMMAND...]]: the R276/R280 layout on stderr, then exit 1. With
# commands the instruction ends in `:` and they follow indented; with none it stands as a sentence.
css_fail() {
    local headline="$1" instruction="${2:-}"
    if _css_glyphs_on; then
        printf '✗ %s\n' "$headline" >&2
    else
        printf 'Error: %s\n' "$headline" >&2
    fi
    # Not `shift 2` unguarded: with one argument it fails, and set -e would abort before exit 1.
    if [ "$#" -ge 2 ]; then
        shift 2
    else
        shift
    fi
    if [ -n "$instruction" ]; then
        printf '\n' >&2
        if [ "$#" -gt 0 ]; then
            printf '%s:\n' "${instruction%:}" >&2
            printf '    %s\n' "$@" >&2
        else
            printf '%s\n' "$instruction" >&2
        fi
    fi
    exit 1
}

# css_warn TEXT: one warning row on stderr (R205, R307). It does not exit.
css_warn() {
    if _css_glyphs_on; then
        printf '! %s\n' "$1" >&2
    else
        printf 'Warning: %s\n' "$1" >&2
    fi
}

# css_json_error REASON MESSAGE: one line of JSON on stderr, the document render_error() prints for
# a failure with no recovery commands (R253). It does not exit; the caller picks the code.
css_json_error() {
    local reason="$1" message="$2" status=error doc
    if [ "$reason" = invalid_arguments ]; then
        status=action_required
    fi
    if command -v jq >/dev/null 2>&1 && doc="$(jq -cn --arg status "$status" --arg reason "$reason" \
        --arg message "$message" '{status: $status, reason: $reason, message: $message, next: []}' 2>/dev/null)"; then
        printf '%s\n' "$doc" >&2
        return 0
    fi
    printf '{"status":"%s","reason":"%s","message":"%s","next":[]}\n' \
        "$status" "$(_css_json_escape "$reason")" "$(_css_json_escape "$message")" >&2
}

# JSON string body of $1, for hosts with no jq. Other control characters are dropped, not escaped.
# A loop, because the replacement side of ${v//pat/rep} treats backslashes differently per bash
# version: 3.2 collapses `\\` to one, which writes invalid JSON.
_css_json_escape() {
    local text="$1" out="" i char
    for ((i = 0; i < ${#text}; i++)); do
        char="${text:i:1}"
        case "$char" in
            \\) out="$out\\\\" ;;
            \") out="$out\\\"" ;;
            $'\n') out="$out\\n" ;;
            $'\r') out="$out\\r" ;;
            $'\t') out="$out\\t" ;;
            [[:cntrl:]]) ;;
            *) out="$out$char" ;;
        esac
    done
    printf '%s' "$out"
}

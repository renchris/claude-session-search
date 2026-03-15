#!/bin/bash
# Async Haiku tagger for semantic enrichment.
# Tags untagged sessions with Claude Haiku for better search recall.
#
# Usage:
#   session-index-tag.sh                              # Tag all untagged
#   session-index-tag.sh --project reso-management-app # Filter by project
#   session-index-tag.sh --dry-run                     # Show what would be tagged
#   session-index-tag.sh --limit 50                    # Batch size limit
#   session-index-tag.sh --regex-only                  # Skip API, regex fallback only
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "$REPO_DIR/hooks/lib/session-index-helpers.sh"

# Defaults
DRY_RUN=false
LIMIT=100
PROJECT_FILTER=""
REGEX_ONLY=false

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --limit) LIMIT="$2"; shift 2 ;;
        --project) PROJECT_FILTER="$2"; shift 2 ;;
        --regex-only) REGEX_ONLY=true; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [ ! -f "$SESSION_INDEX_DB" ]; then
    echo "No index database. Run session-index-backfill.sh first." >&2
    exit 1
fi

# ─── Terminal Detection ─────────────────────────────────
# Rich output only when stdout is a terminal; plain for pipes/redirects.

IS_TTY=false
[ -t 1 ] && IS_TTY=true

# ─── ANSI & Progress System ─────────────────────────────

if $IS_TTY; then
    BOLD='\033[1m'
    DIM='\033[2m'
    RESET='\033[0m'
    GREEN='\033[32m'
    RED='\033[31m'
    CYAN='\033[36m'
    YELLOW='\033[33m'
    WHITE='\033[37m'
    GRAY='\033[90m'
else
    BOLD='' DIM='' RESET='' GREEN='' RED='' CYAN='' YELLOW='' WHITE='' GRAY=''
fi

SPINNER_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
SPINNER_IDX=0
BOX_WIDTH=48

progress_bar() {
    local current=$1 total=$2 width=${3:-20}
    if [ "$total" -eq 0 ]; then
        printf '%*s' "$width" '' | tr ' ' '░'
        return
    fi
    local filled=$((current * width / total))
    local empty=$((width - filled))
    local bar=""
    local i
    for ((i = 0; i < filled; i++)); do bar+="█"; done
    for ((i = 0; i < empty; i++)); do bar+="░"; done
    printf '%s' "$bar"
}

print_header() {
    local title="$1" right_text="$2"
    local inner=$((BOX_WIDTH - 4))
    local title_len=${#title}
    local right_len=${#right_text}
    local gap=$((inner - title_len - right_len))
    [ "$gap" -lt 1 ] && gap=1
    local padding=""
    local i
    for ((i = 0; i < gap; i++)); do padding+=" "; done

    printf '\n'
    printf '  %b╭%s╮%b\n' "$GRAY" "$(printf '─%.0s' $(seq 1 $((BOX_WIDTH - 2))))" "$RESET"
    printf '  %b│%b  %b%s%b%s%b%s%b  %b│%b\n' \
        "$GRAY" "$RESET" "$BOLD" "$title" "$RESET" "$padding" "$DIM" "$right_text" "$RESET" "$GRAY" "$RESET"
    printf '  %b╰%s╯%b\n' "$GRAY" "$(printf '─%.0s' $(seq 1 $((BOX_WIDTH - 2))))" "$RESET"
    printf '\n'
}

print_progress() {
    local current=$1 total=$2 tagged=$3 failed=$4 elapsed=$5
    if ! $IS_TTY; then return; fi

    local pct=0
    [ "$total" -gt 0 ] && pct=$((current * 100 / total))
    SPINNER_IDX=$(( (SPINNER_IDX + 1) % ${#SPINNER_FRAMES[@]} ))
    local spinner="${SPINNER_FRAMES[$SPINNER_IDX]}"
    local bar
    bar=$(progress_bar "$current" "$total" 20)
    local eta=""
    if [ "$current" -gt 0 ] && [ "$elapsed" -gt 0 ]; then
        local remaining=$(( (elapsed * (total - current)) / current ))
        if [ "$remaining" -ge 60 ]; then
            eta="~$((remaining / 60))m$((remaining % 60))s left"
        else
            eta="~${remaining}s left"
        fi
    fi

    printf '\r\033[K'
    printf '  %b%s%b %bTagging...%b  %s  %b%d%b/%b%d%b  (%b%d%%%b)  %b│%b %b✓ %d%b  %b✗ %d%b  %b│%b %b%s%b' \
        "$CYAN" "$spinner" "$RESET" \
        "$BOLD" "$RESET" \
        "$bar" \
        "$WHITE" "$current" "$RESET" "$DIM" "$total" "$RESET" \
        "$BOLD" "$pct" "$RESET" \
        "$GRAY" "$RESET" \
        "$GREEN" "$tagged" "$RESET" \
        "$RED" "$failed" "$RESET" \
        "$GRAY" "$RESET" \
        "$DIM" "$eta" "$RESET"
}

print_item_ok() {
    local sid="$1" tags="$2" display_summary="$3"
    if ! $IS_TTY; then
        printf '  ✓ %s  %s  "%s"\n' "${sid:0:8}" "$tags" "${display_summary:0:50}"
        return
    fi
    printf '\r\033[K'
    local tags_trunc="${tags:0:40}"
    local summary_trunc="${display_summary:0:50}"
    printf '  %b✓%b %b%-8s%b  %-40s  %b"%s"%b\n' \
        "$GREEN" "$RESET" \
        "$CYAN" "${sid:0:8}" "$RESET" \
        "$tags_trunc" \
        "$DIM" "$summary_trunc" "$RESET"
}

print_item_fail() {
    local sid="$1"
    if ! $IS_TTY; then
        printf '  ✗ %s  (no tags extracted)\n' "${sid:0:8}"
        return
    fi
    printf '\r\033[K'
    printf '  %b✗%b %b%-8s%b  %b(no tags extracted)%b\n' \
        "$RED" "$RESET" \
        "$DIM" "${sid:0:8}" "$RESET" \
        "$DIM" "$RESET"
}

print_item_dry() {
    local sid="$1" tags="$2"
    if ! $IS_TTY; then
        printf '  ~ %s  %s\n' "${sid:0:8}" "$tags"
        return
    fi
    printf '\r\033[K'
    printf '  %b~%b %b%-8s%b  %b%s%b\n' \
        "$YELLOW" "$RESET" \
        "$CYAN" "${sid:0:8}" "$RESET" \
        "$DIM" "$tags" "$RESET"
}

print_summary_box() {
    local elapsed=$1 tagged=$2 failed=$3 total=$4 summaries=$5
    local elapsed_fmt
    if [ "$elapsed" -ge 60 ]; then
        elapsed_fmt="$((elapsed / 60))m$((elapsed % 60))s"
    else
        # Use bc for decimal if available, with nanosecond precision
        if command -v bc >/dev/null 2>&1 && [ "${START_NS:-0}" != "0" ]; then
            local end_ns
            end_ns=$(date +%s%N 2>/dev/null || echo "0")
            [[ "$end_ns" == *N* ]] && end_ns="0"
            if [ "$end_ns" != "0" ] && [ "$START_NS" != "0" ]; then
                elapsed_fmt=$(echo "scale=1; ($end_ns - $START_NS) / 1000000000" | bc 2>/dev/null || echo "${elapsed}s")
                elapsed_fmt="${elapsed_fmt}s"
            else
                elapsed_fmt="${elapsed}s"
            fi
        else
            elapsed_fmt="${elapsed}s"
        fi
    fi

    local tagged_pct=0 failed_pct=0
    [ "$total" -gt 0 ] && tagged_pct=$((tagged * 100 / total))
    [ "$total" -gt 0 ] && failed_pct=$((failed * 100 / total))

    local tagged_bar failed_bar
    tagged_bar=$(progress_bar "$tagged" "$total" 20)
    failed_bar=$(progress_bar "$failed" "$total" 20)

    local sep
    sep=$(printf '─%.0s' $(seq 1 $((BOX_WIDTH - 2))))

    printf '\n'
    printf '  %b╭%s╮%b\n' "$GRAY" "$sep" "$RESET"

    # Title row: "Done" left, elapsed right
    local title="Done"
    local inner=$((BOX_WIDTH - 4))
    local title_len=${#title}
    local elapsed_len=${#elapsed_fmt}
    local tgap=$((inner - title_len - elapsed_len))
    [ "$tgap" -lt 1 ] && tgap=1
    local tpad=""
    local i
    for ((i = 0; i < tgap; i++)); do tpad+=" "; done
    printf '  %b│%b  %b%s%b%s%b%s%b  %b│%b\n' \
        "$GRAY" "$RESET" "$GREEN$BOLD" "$title" "$RESET" "$tpad" "$DIM" "$elapsed_fmt" "$RESET" "$GRAY" "$RESET"

    printf '  %b├%s┤%b\n' "$GRAY" "$sep" "$RESET"

    # Tagged row
    local tagged_label
    tagged_label=$(printf 'Tagged  %4d' "$tagged")
    local tagged_bar_and_pct
    tagged_bar_and_pct=$(printf '%s  %3d%%' "$tagged_bar" "$tagged_pct")
    local trow_len=$(( ${#tagged_label} + 2 + ${#tagged_bar_and_pct} ))
    local trow_gap=$((inner - trow_len))
    [ "$trow_gap" -lt 1 ] && trow_gap=1
    local trow_pad=""
    for ((i = 0; i < trow_gap; i++)); do trow_pad+=" "; done
    printf '  %b│%b  %b%s%b%s%s  %b│%b\n' \
        "$GRAY" "$RESET" "$GREEN" "$tagged_label" "$RESET" "$trow_pad" "$tagged_bar_and_pct" "$GRAY" "$RESET"

    # Failed row
    local failed_label
    failed_label=$(printf 'Failed  %4d' "$failed")
    local failed_bar_and_pct
    failed_bar_and_pct=$(printf '%s  %3d%%' "$failed_bar" "$failed_pct")
    local frow_len=$(( ${#failed_label} + 2 + ${#failed_bar_and_pct} ))
    local frow_gap=$((inner - frow_len))
    [ "$frow_gap" -lt 1 ] && frow_gap=1
    local frow_pad=""
    for ((i = 0; i < frow_gap; i++)); do frow_pad+=" "; done

    local failed_color="$DIM"
    [ "$failed" -gt 0 ] && failed_color="$RED"
    printf '  %b│%b  %b%s%b%s%s  %b│%b\n' \
        "$GRAY" "$RESET" "$failed_color" "$failed_label" "$RESET" "$frow_pad" "$failed_bar_and_pct" "$GRAY" "$RESET"

    # Summaries row (only if > 0)
    if [ "$summaries" -gt 0 ]; then
        local sum_label
        sum_label=$(printf 'Summaries  +%d' "$summaries")
        local sum_note="(new from Haiku)"
        local srow_len=$(( ${#sum_label} + 2 + ${#sum_note} ))
        local srow_gap=$((inner - srow_len))
        [ "$srow_gap" -lt 1 ] && srow_gap=1
        local srow_pad=""
        for ((i = 0; i < srow_gap; i++)); do srow_pad+=" "; done
        printf '  %b│%b  %b%s%b%s%b%s%b  %b│%b\n' \
            "$GRAY" "$RESET" "$CYAN" "$sum_label" "$RESET" "$srow_pad" "$DIM" "$sum_note" "$RESET" "$GRAY" "$RESET"
    fi

    printf '  %b╰%s╯%b\n' "$GRAY" "$sep" "$RESET"
    printf '\n'
}

# ─── Query Untagged Sessions ──────────────────────────────

WHERE="tagged_at IS NULL"
[ -n "$PROJECT_FILTER" ] && WHERE="$WHERE AND project_name LIKE '%${PROJECT_FILTER}%'"

UNTAGGED=$(sqlite3 "$SESSION_INDEX_DB" "SELECT COUNT(*) FROM sessions WHERE $WHERE;")

if [ "$UNTAGGED" -eq 0 ]; then
    if $IS_TTY; then
        printf '\n  %b%s%b Nothing to tag.\n\n' "$DIM" "●" "$RESET"
    else
        echo "Nothing to tag."
    fi
    exit 0
fi

# Effective count is min(UNTAGGED, LIMIT)
EFFECTIVE=$UNTAGGED
[ "$EFFECTIVE" -gt "$LIMIT" ] && EFFECTIVE=$LIMIT

# ─── Regex Fallback Tagger ────────────────────────────────

regex_tag() {
    local text="$1"
    local tags=""

    # Technology patterns
    [[ "$text" =~ [Rr]eact|[Cc]omponent|JSX|tsx ]] && tags="$tags,react"
    [[ "$text" =~ [Nn]ext\.?js|[Aa]pp\s*[Rr]outer|RSC ]] && tags="$tags,nextjs"
    [[ "$text" =~ [Tt]ypescript|[Tt]ypecheck|tsc ]] && tags="$tags,typescript"
    [[ "$text" =~ [Dd]rizzle|[Mm]igrat|[Ss]chema ]] && tags="$tags,database"
    [[ "$text" =~ [Tt]urso|[Ll]ibsql|[Ss]qlite ]] && tags="$tags,turso"
    [[ "$text" =~ [Pp]usher|[Ss]oketi|[Ww]eb[Ss]ocket|[Ww]s ]] && tags="$tags,websocket"
    [[ "$text" =~ [Rr]eplicache|[Ss]ync|[Pp]oke ]] && tags="$tags,replicache"
    [[ "$text" =~ [Cc]loud[Ww]atch|[Aa]larm|[Mm]etric|RUM ]] && tags="$tags,monitoring"
    [[ "$text" =~ [Dd]eploy|[Aa]mplify|[Ff]ly\.io ]] && tags="$tags,deployment"
    [[ "$text" =~ [Aa]uth|[Pp]asskey|[Ll]ogin|[Ss]ession ]] && tags="$tags,auth"
    [[ "$text" =~ [Cc]ss|[Ss]tyle|[Tt]heme|[Pp]anda ]] && tags="$tags,styling"
    [[ "$text" =~ [Aa]nimation|[Tt]ransition|[Mm]otion ]] && tags="$tags,animation"
    [[ "$text" =~ DNS|[Rr]oute.?53|[Dd]omain ]] && tags="$tags,dns"
    [[ "$text" =~ [Gg]rafana|[Ll]oki|[Dd]ashboard ]] && tags="$tags,grafana"
    [[ "$text" =~ [Ee][Ss][Ll]int|[Ll]int|[Pp]rettier ]] && tags="$tags,linting"
    [[ "$text" =~ [Gg]it|[Cc]ommit|[Bb]ranch|[Mm]erge|[Rr]ebase ]] && tags="$tags,git"
    [[ "$text" =~ [Aa][Pp][Ii]|[Ee]ndpoint|[Rr]oute|[Hh]andler ]] && tags="$tags,api"
    [[ "$text" =~ [Dd]ocker|[Cc]ontainer|[Kk]8s|[Kk]ubernetes ]] && tags="$tags,infrastructure"
    [[ "$text" =~ [Cc]onfig|[Ss]etup|[Ii]nstall|[Ii]nit ]] && tags="$tags,config"
    [[ "$text" =~ [Dd]epend|[Uu]pgrade|[Uu]pdate|[Vv]ersion|npm|pnpm|yarn ]] && tags="$tags,dependencies"
    [[ "$text" =~ [Ee]rror|[Ee]xcept|[Cc]rash|[Ff]ail ]] && tags="$tags,errors"
    [[ "$text" =~ [Dd]ebug|[Tt]race|[Ii]nspect|[Ii]nvestigat ]] && tags="$tags,debugging"
    [[ "$text" =~ [Ss]earch|[Ff]ind|[Qq]uery|[Ff]ilter ]] && tags="$tags,search"
    [[ "$text" =~ [Ss]cript|[Bb]ash|[Ss]hell|[Cc][Ll][Ii] ]] && tags="$tags,scripting"

    # Task type patterns
    [[ "$text" =~ [Ff]ix|[Bb]ug|[Rr]egression|[Bb]roken ]] && tags="$tags,bugfix"
    [[ "$text" =~ [Rr]efactor|[Cc]lean|[Rr]estructure ]] && tags="$tags,refactor"
    [[ "$text" =~ [Ff]eat|[Aa]dd|[Ii]mplement|[Cc]reate ]] && tags="$tags,feature"
    [[ "$text" =~ [Tt]est|[Ss]pec|[Ss]moke ]] && tags="$tags,testing"
    [[ "$text" =~ [Pp]erf|[Ll]atency|[Oo]ptim ]] && tags="$tags,performance"
    [[ "$text" =~ [Dd]ocs|[Rr]eadme|[Dd]ocument ]] && tags="$tags,docs"
    [[ "$text" =~ [Aa]udit|[Rr]eview|[Cc]heck ]] && tags="$tags,audit"
    [[ "$text" =~ [Rr]emov|[Dd]elet|[Dd]rop|[Cc]lean.?up ]] && tags="$tags,cleanup"
    [[ "$text" =~ [Pp]lan|[Dd]esign|[Aa]rchitect ]] && tags="$tags,planning"
    [[ "$text" =~ [Rr]esearch|[Aa]nalyz|[Ii]nvestigat|[Ee]xplor ]] && tags="$tags,research"

    # Domain patterns
    [[ "$text" =~ [Bb]ottle|[Mm]enu|[Cc]atalog ]] && tags="$tags,bottle-service"
    [[ "$text" =~ [Ff]loor.?[Pp]lan|[Tt]able.?[Mm]ap|[Ll]ayout ]] && tags="$tags,floor-plan"
    [[ "$text" =~ [Ss]lide.?out|[Pp]anel|[Dd]rawer ]] && tags="$tags,slide-out"
    [[ "$text" =~ [Rr]eservation|[Bb]ooking|[Gg]uest ]] && tags="$tags,reservations"
    [[ "$text" =~ [Ee]vent|[Vv]enue|[Nn]ight ]] && tags="$tags,events"
    [[ "$text" =~ [Hh]ook|[Ss]ession.?[Ss]tart|[Pp]re.?[Cc]ommit ]] && tags="$tags,hooks"
    [[ "$text" =~ [Ii]mage|[Pp]hoto|[Gg]enerat ]] && tags="$tags,images"
    [[ "$text" =~ [Ff]ont|[Tt]ypograph ]] && tags="$tags,typography"

    # Clean: remove leading comma, dedupe
    echo "$tags" | sed 's/^,//' | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//'
}

# ─── Haiku API Tagger ────────────────────────────────────

haiku_tag() {
    local summary="$1"
    local first_prompt="$2"
    local project_name="$3"

    local response
    response=$(curl -s --max-time 10 \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d "$(jq -n \
            --arg summary "$summary" \
            --arg prompt "$first_prompt" \
            --arg project "$project_name" \
            '{
                model: "claude-haiku-4-5-20251001",
                max_tokens: 150,
                messages: [{
                    role: "user",
                    content: "Tag this Claude Code session. Return ONLY a JSON object with \"tags\" (array of 5-10 lowercase-hyphenated tags) and \"summary\" (one-line, max 80 chars).\n\nProject: \($project)\nSummary: \($summary)\nFirst prompt: \($prompt | .[:300])"
                }]
            }')" \
        "https://api.anthropic.com/v1/messages" 2>/dev/null)

    if [ $? -ne 0 ] || [ -z "$response" ]; then
        return 1
    fi

    # Extract text content
    local text
    text=$(echo "$response" | jq -r '.content[0].text // empty' 2>/dev/null)
    [ -z "$text" ] && return 1

    # Strip markdown code fences (Haiku often wraps JSON in ```json ... ```)
    text=$(echo "$text" | sed 's/^```[a-z]*$//' | sed 's/^```$//' | tr -d '\r')

    # Parse JSON from response
    local tags haiku_summary
    tags=$(echo "$text" | jq -r '.tags // [] | join(",")' 2>/dev/null)
    [ -z "$tags" ] && return 1
    haiku_summary=$(echo "$text" | jq -r '.summary // ""' 2>/dev/null)

    # Output tags and summary tab-separated
    printf '%s\t%s' "$tags" "$haiku_summary"
}

# ─── Process Sessions ─────────────────────────────────────

TAGGED=0
FAILED=0
PROCESSED=0
SUMMARIES_ADDED=0

# Write to temp file to avoid subshell counter loss from pipe.
# Use JSON output to handle newlines in summary/first_prompt fields safely.
TMPFILE=$(mktemp)
sqlite3 "$SESSION_INDEX_DB" <<QUERY > "$TMPFILE"
.mode json
SELECT session_id, summary, first_prompt, project_name,
       substr(context_text, 1, 500) as context_text,
       substr(assistant_text, 1, 500) as assistant_text
FROM sessions WHERE $WHERE ORDER BY modified_at DESC LIMIT $LIMIT;
QUERY

# Parse JSON array into newline-delimited records (one JSON object per line)
RECORDS_FILE=$(mktemp)
jq -c '.[]' "$TMPFILE" > "$RECORDS_FILE" 2>/dev/null || true

# ─── Print Header ─────────────────────────────────────────

MODE_LABEL="Session Tagger"
$DRY_RUN && MODE_LABEL="Session Tagger  (dry run)"
$REGEX_ONLY && MODE_LABEL="Session Tagger  (regex)"

QUEUE_LABEL="${EFFECTIVE} queued"
[ -n "$PROJECT_FILTER" ] && QUEUE_LABEL="${EFFECTIVE} queued  ${PROJECT_FILTER}"

print_header "$MODE_LABEL" "$QUEUE_LABEL"

# Record start time (seconds for ETA, nanoseconds for precise summary)
START_TIME=$(date +%s)
# macOS date doesn't support %N — detect and fall back to 0
START_NS=$(date +%s%N 2>/dev/null || echo "0")
[[ "$START_NS" == *N* ]] && START_NS="0"

while IFS= read -r record; do
    sid=$(echo "$record" | jq -r '.session_id')
    summary=$(echo "$record" | jq -r '.summary // ""' | tr '\n' ' ')
    first_prompt=$(echo "$record" | jq -r '.first_prompt // ""' | tr '\n' ' ')
    project_name=$(echo "$record" | jq -r '.project_name // ""')
    context_text=$(echo "$record" | jq -r '.context_text // ""' | tr '\n' ' ')
    assistant_text=$(echo "$record" | jq -r '.assistant_text // ""' | tr '\n' ' ')
    text="$summary $first_prompt $context_text $assistant_text"

    if $DRY_RUN; then
        tags=$(regex_tag "$text")
        PROCESSED=$((PROCESSED + 1))
        if [ -n "$tags" ]; then
            TAGGED=$((TAGGED + 1))
            print_item_dry "$sid" "$tags"
        else
            FAILED=$((FAILED + 1))
            print_item_fail "$sid"
        fi
        if $IS_TTY; then
            NOW_SEC=$(date +%s)
            ELAPSED=$((NOW_SEC - START_TIME))
            print_progress "$PROCESSED" "$EFFECTIVE" "$TAGGED" "$FAILED" "$ELAPSED"
        fi
        continue
    fi

    tags=""
    haiku_summary=""

    # Try Haiku first (if API key available and not regex-only)
    if ! $REGEX_ONLY && [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        haiku_result=$(haiku_tag "$summary" "$first_prompt" "$project_name" 2>/dev/null || echo "")
        if [ -n "$haiku_result" ]; then
            IFS=$'\t' read -r tags haiku_summary <<< "$haiku_result"
            # Rate limit: 100ms between API calls
            sleep 0.1
        fi
    fi

    # Fallback to regex
    if [ -z "$tags" ]; then
        tags=$(regex_tag "$text")
    fi

    PROCESSED=$((PROCESSED + 1))

    if [ -n "$tags" ]; then
        NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        tags_escaped=$(echo "$tags" | sed "s/'/''/g")
        summary_escaped=$(echo "$haiku_summary" | sed "s/'/''/g")
        sid_escaped=$(echo "$sid" | sed "s/'/''/g")

        # Check if this will add a new summary (existing is empty, Haiku provided one)
        if [ -n "$haiku_summary" ]; then
            existing_summary=$(sqlite3 "$SESSION_INDEX_DB" "SELECT summary FROM sessions WHERE session_id='$sid_escaped';" 2>/dev/null || echo "")
            if [ -z "$existing_summary" ]; then
                SUMMARIES_ADDED=$((SUMMARIES_ADDED + 1))
            fi
        fi

        # Persist tags always; persist summary only if existing is empty and Haiku provided one
        sqlite3 "$SESSION_INDEX_DB" "UPDATE sessions SET tags='$tags_escaped', summary=CASE WHEN '$summary_escaped' != '' AND summary = '' THEN '$summary_escaped' ELSE summary END, tagged_at='$NOW' WHERE session_id='$sid_escaped';"
        TAGGED=$((TAGGED + 1))

        # Display summary: prefer haiku_summary, fallback to existing summary
        display_summary="$haiku_summary"
        [ -z "$display_summary" ] && display_summary="$summary"
        print_item_ok "$sid" "$tags" "$display_summary"
    else
        FAILED=$((FAILED + 1))
        print_item_fail "$sid"
    fi

    # Reprint progress line below item output
    if $IS_TTY; then
        NOW_SEC=$(date +%s)
        ELAPSED=$((NOW_SEC - START_TIME))
        print_progress "$PROCESSED" "$EFFECTIVE" "$TAGGED" "$FAILED" "$ELAPSED"
    fi
done < "$RECORDS_FILE"

rm -f "$TMPFILE" "$RECORDS_FILE"

# ─── Clear progress line and print summary ────────────────

if $IS_TTY; then
    printf '\r\033[K'
fi

END_TIME=$(date +%s)
TOTAL_ELAPSED=$((END_TIME - START_TIME))

print_summary_box "$TOTAL_ELAPSED" "$TAGGED" "$FAILED" "$PROCESSED" "$SUMMARIES_ADDED"

session_index_log "Tagging complete: $TAGGED tagged, $FAILED failed, $SUMMARIES_ADDED summaries added (${TOTAL_ELAPSED}s)"

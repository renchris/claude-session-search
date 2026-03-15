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

# ─── Query Untagged Sessions ──────────────────────────────

WHERE="tagged_at IS NULL"
[ -n "$PROJECT_FILTER" ] && WHERE="$WHERE AND project_name LIKE '%${PROJECT_FILTER}%'"

UNTAGGED=$(sqlite3 "$SESSION_INDEX_DB" "SELECT COUNT(*) FROM sessions WHERE $WHERE;")
echo "Untagged sessions: $UNTAGGED (limit: $LIMIT)"

if [ "$UNTAGGED" -eq 0 ]; then
    echo "Nothing to tag."
    exit 0
fi

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

    # Task type patterns
    [[ "$text" =~ [Ff]ix|[Bb]ug|[Rr]egression|[Bb]roken ]] && tags="$tags,bugfix"
    [[ "$text" =~ [Rr]efactor|[Cc]lean|[Rr]estructure ]] && tags="$tags,refactor"
    [[ "$text" =~ [Ff]eat|[Aa]dd|[Ii]mplement|[Cc]reate ]] && tags="$tags,feature"
    [[ "$text" =~ [Tt]est|[Ss]pec|[Ss]moke ]] && tags="$tags,testing"
    [[ "$text" =~ [Pp]erf|[Ll]atency|[Oo]ptim ]] && tags="$tags,performance"
    [[ "$text" =~ [Dd]ocs|[Rr]eadme|[Dd]ocument ]] && tags="$tags,docs"
    [[ "$text" =~ [Aa]udit|[Rr]eview|[Cc]heck ]] && tags="$tags,audit"

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

# Write to temp file to avoid subshell counter loss from pipe
TMPFILE=$(mktemp)
sqlite3 -separator $'\t' "$SESSION_INDEX_DB" \
    "SELECT session_id, summary, first_prompt, project_name FROM sessions WHERE $WHERE ORDER BY modified_at DESC LIMIT $LIMIT;" > "$TMPFILE"

while IFS=$'\t' read -r sid summary first_prompt project_name; do
    text="$summary $first_prompt"

    if $DRY_RUN; then
        tags=$(regex_tag "$text")
        echo "[DRY RUN] $sid → $tags"
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

    if [ -n "$tags" ]; then
        NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        tags_escaped=$(echo "$tags" | sed "s/'/''/g")
        summary_escaped=$(echo "$haiku_summary" | sed "s/'/''/g")
        sid_escaped=$(echo "$sid" | sed "s/'/''/g")
        # Persist tags always; persist summary only if existing is empty and Haiku provided one
        sqlite3 "$SESSION_INDEX_DB" "UPDATE sessions SET tags='$tags_escaped', summary=CASE WHEN '$summary_escaped' != '' AND summary = '' THEN '$summary_escaped' ELSE summary END, tagged_at='$NOW' WHERE session_id='$sid_escaped';"
        TAGGED=$((TAGGED + 1))
        echo "[$TAGGED] $sid → $tags"
    else
        FAILED=$((FAILED + 1))
    fi
done < "$TMPFILE"

rm -f "$TMPFILE"

echo ""
echo "Done. Tagged: $TAGGED, Failed: $FAILED"

session_index_log "Tagging complete: $TAGGED tagged, $FAILED failed"

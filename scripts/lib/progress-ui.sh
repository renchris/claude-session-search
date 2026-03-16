#!/bin/bash
# Shared progress UI library for session-search scripts.
# Sources Claude Code terminal UX patterns: braille spinners, inline progress,
# ANSI styling, clean phase transitions.
#
# Usage:
#   source "$(dirname "$0")/lib/progress-ui.sh"
#
# Non-TTY fallback: all functions degrade to clean plain text when stdout
# is not a terminal (pipes, redirects, cron).

# ─── Terminal Detection ──────────────────────────────────────

_UI_IS_TTY=false
[ -t 1 ] && _UI_IS_TTY=true

# ─── ANSI Codes ──────────────────────────────────────────────

if $_UI_IS_TTY; then
    _B='\033[1m'       # Bold
    _D='\033[2m'       # Dim
    _R='\033[0m'       # Reset
    _G='\033[32m'      # Green
    _RD='\033[31m'     # Red
    _Y='\033[33m'      # Yellow
    _C='\033[36m'      # Cyan
    _CL='\033[K'       # Clear to end of line
    _UP='\033[1A'      # Move cursor up 1 line
    _SAVE='\033[s'     # Save cursor position
    _RESTORE='\033[u'  # Restore cursor position
    _HIDE='\033[?25l'  # Hide cursor
    _SHOW='\033[?25h'  # Show cursor
else
    _B='' _D='' _R='' _G='' _RD='' _Y='' _C='' _CL=''
    _UP='' _SAVE='' _RESTORE='' _HIDE='' _SHOW=''
fi

# ─── Braille Spinner ─────────────────────────────────────────

_UI_SPINNER=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
_UI_SPIN_IDX=0

_ui_spin() {
    local s="${_UI_SPINNER[$_UI_SPIN_IDX]}"
    _UI_SPIN_IDX=$(( (_UI_SPIN_IDX + 1) % ${#_UI_SPINNER[@]} ))
    printf '%s' "$s"
}

# ─── Progress Bar ────────────────────────────────────────────

_ui_bar() {
    local current=$1 total=$2 width=${3:-20}
    if [ "$total" -eq 0 ] 2>/dev/null; then
        printf '%*s' "$width" ''
        return
    fi
    local filled=$(( current * width / total ))
    local empty=$(( width - filled ))
    local bar=""
    local i
    for (( i=0; i<filled; i++ )); do bar+="█"; done
    for (( i=0; i<empty;  i++ )); do bar+="░"; done
    printf '%s' "$bar"
}

# ─── ETA Calculation ─────────────────────────────────────────

_ui_eta() {
    local current=$1 total=$2 elapsed=$3
    if [ "$current" -le 0 ] 2>/dev/null; then
        printf '—'
        return
    fi
    # Use awk for float math (elapsed can be fractional)
    local remaining
    remaining=$(awk "BEGIN { printf \"%.0f\", ($elapsed * ($total - $current)) / $current }" 2>/dev/null)
    if [ "${remaining:-0}" -gt 60 ] 2>/dev/null; then
        printf '%dm%ds' $((remaining / 60)) $((remaining % 60))
    else
        printf '~%ss' "${remaining:-0}"
    fi
}

# ─── Elapsed Time Formatting ─────────────────────────────────

_ui_elapsed() {
    local start=$1
    local now
    now=$(_ui_now)
    local ms=$(( now - start ))
    # Format as seconds with 1 decimal
    awk "BEGIN { printf \"%.1f\", $ms / 1000 }" 2>/dev/null
}

# ─── High-Resolution Timer (milliseconds) ────────────────────

_ui_now() {
    # macOS: use perl for ms precision. Linux: date +%s%N.
    perl -MTime::HiRes=gettimeofday -e '
        my ($s, $us) = gettimeofday();
        printf "%d\n", $s * 1000 + int($us / 1000);
    ' 2>/dev/null || echo $(( $(date +%s) * 1000 ))
}

# ─── Box Drawing ─────────────────────────────────────────────
# Fixed-width box: 50 chars inner (52 total with side borders).

_UI_BOX_W=50

_ui_box_top() {
    printf '  ╭'; printf '─%.0s' $(seq 1 $_UI_BOX_W); printf '╮\n'
}

_ui_box_mid() {
    printf '  ├'; printf '─%.0s' $(seq 1 $_UI_BOX_W); printf '┤\n'
}

_ui_box_bot() {
    printf '  ╰'; printf '─%.0s' $(seq 1 $_UI_BOX_W); printf '╯\n'
}

_ui_box_row() {
    # Print a row with left-aligned content, padded to box width.
    # Usage: _ui_box_row "  content here"
    # The content string can contain ANSI codes — we measure the visible length.
    local content="$1"
    # Strip ANSI for length measurement
    local visible
    visible=$(printf '%b' "$content" | sed $'s/\033\\[[0-9;]*m//g')
    local visible_len=${#visible}
    local pad=$(( _UI_BOX_W - visible_len ))
    [ "$pad" -lt 0 ] && pad=0
    printf '  │%b%*s│\n' "$content" "$pad" ""
}

_ui_box_row_kv() {
    # Key-value row: "  Label    value       detail"
    local label="$1" value="$2" detail="${3:-}"
    if [ -n "$detail" ]; then
        _ui_box_row "$(printf '  %-14s %b%-5s%b  %s' "$label" "$_G" "$value" "$_R" "$detail")"
    else
        _ui_box_row "$(printf '  %-14s %b%s%b' "$label" "$_G" "$value" "$_R")"
    fi
}

# ─── Public API ──────────────────────────────────────────────

# ui_header TITLE [DETAIL]
# Prints a boxed header. DETAIL appears right-aligned on the title row.
ui_header() {
    local title="$1" detail="${2:-}"
    if ! $_UI_IS_TTY; then
        echo ""
        echo "  $title${detail:+  $detail}"
        echo ""
        return
    fi
    printf '\n'
    _ui_box_top
    if [ -n "$detail" ]; then
        # Title left-aligned, detail right-aligned within the box.
        local title_vis="  ${title}"
        local detail_vis="$detail"
        local gap=$(( _UI_BOX_W - ${#title_vis} - ${#detail_vis} ))
        [ "$gap" -lt 1 ] && gap=1
        local gap_spaces
        gap_spaces=$(printf '%*s' "$gap" "")
        printf '  │%b  %s%b%s%b%s%b│\n' \
            "$_B" "$title" "$_R" "$gap_spaces" "$_D" "$detail" "$_R"
    else
        _ui_box_row "$(printf '  %b%s%b' "$_B" "$title" "$_R")"
    fi
    _ui_box_bot
    printf '\n'
}

# ui_phase_pending LABEL
# Renders a pending (not yet started) phase line.
ui_phase_pending() {
    local label="$1"
    if ! $_UI_IS_TTY; then return; fi
    printf '  %b○ %s%b  %b—%b\n' "$_D" "$label" "$_R" "$_D" "$_R"
}

# ui_phase_active LABEL CURRENT TOTAL START_MS
# Overwrites the current line with an animated progress indicator.
# Call repeatedly in a loop. START_MS from _ui_now.
ui_phase_active() {
    local label="$1" current="$2" total="$3" start_ms="$4"
    if ! $_UI_IS_TTY; then return; fi
    local s=$(_ui_spin)
    local bar=$(_ui_bar "$current" "$total" 20)
    local elapsed=$(_ui_elapsed "$start_ms")
    local pct=0
    [ "$total" -gt 0 ] 2>/dev/null && pct=$(( current * 100 / total ))
    local eta_str=$(_ui_eta "$current" "$total" "$elapsed")
    printf '\r  %b◐%b %b%s%b  %s %s  %d/%d  (%d%%)  %s%b' \
        "$_Y" "$_R" "$_B" "$label" "$_R" \
        "$s" "$bar" "$current" "$total" "$pct" "$eta_str" "$_CL"
}

# ui_phase_active_simple LABEL DETAIL START_MS
# For phases without a known total — shows spinner + detail text.
ui_phase_active_simple() {
    local label="$1" detail="$2" start_ms="$3"
    if ! $_UI_IS_TTY; then return; fi
    local s=$(_ui_spin)
    local elapsed=$(_ui_elapsed "$start_ms")
    printf '\r  %b◐%b %b%s%b  %s %s  %b%ss%b%b' \
        "$_Y" "$_R" "$_B" "$label" "$_R" \
        "$s" "$detail" "$_D" "$elapsed" "$_R" "$_CL"
}

# ui_phase_done LABEL DETAIL START_MS
# Replaces the active line with a completed phase indicator.
ui_phase_done() {
    local label="$1" detail="$2" start_ms="$3"
    local elapsed=$(_ui_elapsed "$start_ms")
    if ! $_UI_IS_TTY; then
        echo "  ✓ $label  $detail  ${elapsed}s"
        return
    fi
    printf '\r  %b●%b %b%s%b  %b✓ %s%b  %b%ss%b%b\n' \
        "$_G" "$_R" "$_B" "$label" "$_R" \
        "$_G" "$detail" "$_R" \
        "$_D" "$elapsed" "$_R" "$_CL"
}

# ui_phase_skip LABEL REASON
# Shows a skipped phase.
ui_phase_skip() {
    local label="$1" reason="${2:-skipped}"
    if ! $_UI_IS_TTY; then
        echo "  ○ $label  ($reason)"
        return
    fi
    printf '  %b○ %s  %s%b\n' "$_D" "$label" "$reason" "$_R"
}

# ui_item_ok ID DETAIL [EXTRA]
# Shows a successfully processed item (verbose mode).
ui_item_ok() {
    local id="$1" detail="$2" extra="${3:-}"
    if ! $_UI_IS_TTY; then
        echo "    ✓ ${id:0:8}  $detail"
        return
    fi
    printf '\r%b  %b✓%b %b%-8s%b  %-40s  %b%s%b\n' \
        "$_CL" "$_G" "$_R" "$_C" "${id:0:8}" "$_R" \
        "${detail:0:40}" "$_D" "${extra:0:50}" "$_R"
}

# ui_item_fail ID REASON
# Shows a failed item.
ui_item_fail() {
    local id="$1" reason="$2"
    if ! $_UI_IS_TTY; then
        echo "    ✗ ${id:0:8}  $reason"
        return
    fi
    printf '\r%b  %b✗%b %b%-8s%b  %b%s%b\n' \
        "$_CL" "$_RD" "$_R" "$_D" "${id:0:8}" "$_R" \
        "$_D" "$reason" "$_R"
}

# ui_summary TITLE ELAPSED_LABEL (then pairs: LABEL VALUE ...)
# Prints a boxed completion summary.
ui_summary() {
    local title="$1"; shift
    local elapsed_label="$1"; shift
    if ! $_UI_IS_TTY; then
        echo ""
        echo "  $title  $elapsed_label"
        while [ $# -ge 2 ]; do
            echo "  $1  $2"
            shift 2
        done
        echo ""
        return
    fi
    printf '\n'
    _ui_box_top
    # Title row
    local title_vis="  $title"
    local elapsed_vis="$elapsed_label"
    local gap=$(( _UI_BOX_W - ${#title_vis} - ${#elapsed_vis} ))
    [ "$gap" -lt 1 ] && gap=1
    local gap_spaces
    gap_spaces=$(printf '%*s' "$gap" "")
    printf '  │%b  %s%b%s%b%s%b│\n' \
        "$_B" "$title" "$_R" \
        "$gap_spaces" "$_D" "$elapsed_label" "$_R"
    _ui_box_mid
    # Key-value rows
    while [ $# -ge 2 ]; do
        local kv_label="$1" kv_value="$2"
        shift 2
        local kv_detail=""
        # If value contains space, split: first word is the number, rest is detail
        if [[ "$kv_value" == *" "* ]]; then
            kv_detail="${kv_value#* }"
            kv_value="${kv_value%% *}"
        fi
        _ui_box_row_kv "$kv_label" "$kv_value" "$kv_detail"
    done
    _ui_box_bot
    printf '\n'
}

# ui_cursor_hide / ui_cursor_show
# Hide/show cursor for cleaner progress display. Always restore on exit.
ui_cursor_hide() {
    $_UI_IS_TTY && printf '%b' "$_HIDE" || true
}

ui_cursor_show() {
    $_UI_IS_TTY && printf '%b' "$_SHOW" || true
}

# ─── Update Throttle ─────────────────────────────────────────
# Calling ui_phase_active on every loop iteration spawns multiple subprocesses.
# Throttle to at most once every N iterations to keep overhead <5%.

_UI_THROTTLE_COUNTER=0
_UI_THROTTLE_INTERVAL=5  # Update display every N items

# ui_should_update
# Returns 0 (true) if the display should update, 1 (false) to skip.
# Always returns true for the first call and when current == total.
ui_should_update() {
    local current="${1:-0}" total="${2:-0}"
    _UI_THROTTLE_COUNTER=$((_UI_THROTTLE_COUNTER + 1))
    # Always update on first item, last item, or every N items
    if [ "$_UI_THROTTLE_COUNTER" -ge "$_UI_THROTTLE_INTERVAL" ] || \
       [ "$current" -eq "$total" ] || [ "$current" -le 1 ]; then
        _UI_THROTTLE_COUNTER=0
        return 0
    fi
    return 1
}

# Ensure cursor is restored if script exits unexpectedly.
_ui_cleanup() {
    $_UI_IS_TTY && printf '%b' "$_SHOW" || true
}
trap '_ui_cleanup' EXIT

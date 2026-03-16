#!/usr/bin/env python3
"""Session tagger — semantic enrichment via regex + optional Haiku API.

Tags untagged sessions in the session-index.db with descriptive labels
derived from content analysis. Uses Claude Haiku for best results with
automatic regex fallback when the API is unavailable or fails.

Usage:
    session-index-tag.py                              # Tag all untagged
    session-index-tag.py --project reso-management    # Filter by project
    session-index-tag.py --dry-run                    # Preview tags
    session-index-tag.py --limit 50                   # Batch size
    session-index-tag.py --regex-only                 # Skip API
    session-index-tag.py --quiet                      # No TTY output
    session-index-tag.py --retag-summaries            # Fill empty summaries via Haiku
"""

import argparse
import json
import os
import re
import signal
import sqlite3
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

# ─── Paths ────────────────────────────────────────────────────────

DB_PATH = Path.home() / ".claude" / "session-index.db"
LOG_PATH = Path.home() / ".claude" / "logs" / "session-index.log"

# ─── Terminal Detection & ANSI Codes ──────────────────────────────

IS_TTY = sys.stdout.isatty()

BOLD = "\033[1m" if IS_TTY else ""
DIM = "\033[2m" if IS_TTY else ""
RESET = "\033[0m" if IS_TTY else ""
GREEN = "\033[32m" if IS_TTY else ""
RED = "\033[31m" if IS_TTY else ""
CYAN = "\033[36m" if IS_TTY else ""
YELLOW = "\033[33m" if IS_TTY else ""
GRAY = "\033[90m" if IS_TTY else ""
HIDE_CURSOR = "\033[?25l" if IS_TTY else ""
SHOW_CURSOR = "\033[?25h" if IS_TTY else ""

# ─── Regex Patterns ──────────────────────────────────────────────

REGEX_PATTERNS: list[tuple[str, str]] = [
    # Technology
    (r"[Rr]eact|[Cc]omponent|JSX|tsx", "react"),
    (r"[Nn]ext\.?js|[Aa]pp\s*[Rr]outer|RSC", "nextjs"),
    (r"[Tt]ypescript|[Tt]ypecheck|tsc", "typescript"),
    (r"[Dd]rizzle|[Mm]igrat|[Ss]chema", "database"),
    (r"[Tt]urso|[Ll]ibsql|[Ss]qlite", "turso"),
    (r"[Pp]usher|[Ss]oketi|[Ww]eb[Ss]ocket|[Ww]s", "websocket"),
    (r"[Rr]eplicache|[Ss]ync|[Pp]oke", "replicache"),
    (r"[Cc]loud[Ww]atch|[Aa]larm|[Mm]etric|RUM", "monitoring"),
    (r"[Dd]eploy|[Aa]mplify|[Ff]ly\.io", "deployment"),
    (r"[Aa]uth|[Pp]asskey|[Ll]ogin|[Ss]ession", "auth"),
    (r"[Cc]ss|[Ss]tyle|[Tt]heme|[Pp]anda", "styling"),
    (r"[Aa]nimation|[Tt]ransition|[Mm]otion", "animation"),
    (r"DNS|[Rr]oute.?53|[Dd]omain", "dns"),
    (r"[Gg]rafana|[Ll]oki|[Dd]ashboard", "grafana"),
    (r"[Ee][Ss][Ll]int|[Ll]int|[Pp]rettier", "linting"),
    (r"[Gg]it|[Cc]ommit|[Bb]ranch|[Mm]erge|[Rr]ebase", "git"),
    (r"[Aa][Pp][Ii]|[Ee]ndpoint|[Rr]oute|[Hh]andler", "api"),
    (r"[Dd]ocker|[Cc]ontainer|[Kk]8s|[Kk]ubernetes", "infrastructure"),
    (r"[Cc]onfig|[Ss]etup|[Ii]nstall|[Ii]nit", "config"),
    (r"[Dd]epend|[Uu]pgrade|[Uu]pdate|[Vv]ersion|npm|pnpm|yarn", "dependencies"),
    (r"[Ee]rror|[Ee]xcept|[Cc]rash|[Ff]ail", "errors"),
    (r"[Dd]ebug|[Tt]race|[Ii]nspect|[Ii]nvestigat", "debugging"),
    (r"[Ss]earch|[Ff]ind|[Qq]uery|[Ff]ilter", "search"),
    (r"[Ss]cript|[Bb]ash|[Ss]hell|[Cc][Ll][Ii]", "scripting"),
    # Task types
    (r"[Ff]ix|[Bb]ug|[Rr]egression|[Bb]roken", "bugfix"),
    (r"[Rr]efactor|[Cc]lean|[Rr]estructure", "refactor"),
    (r"[Ff]eat|[Aa]dd|[Ii]mplement|[Cc]reate", "feature"),
    (r"[Tt]est|[Ss]pec|[Ss]moke", "testing"),
    (r"[Pp]erf|[Ll]atency|[Oo]ptim", "performance"),
    (r"[Dd]ocs|[Rr]eadme|[Dd]ocument", "docs"),
    (r"[Aa]udit|[Rr]eview|[Cc]heck", "audit"),
    (r"[Rr]emov|[Dd]elet|[Dd]rop|[Cc]lean.?up", "cleanup"),
    (r"[Pp]lan|[Dd]esign|[Aa]rchitect", "planning"),
    (r"[Rr]esearch|[Aa]nalyz|[Ii]nvestigat|[Ee]xplor", "research"),
    # Domain
    (r"[Bb]ottle|[Mm]enu|[Cc]atalog", "bottle-service"),
    (r"[Ff]loor.?[Pp]lan|[Tt]able.?[Mm]ap|[Ll]ayout", "floor-plan"),
    (r"[Ss]lide.?out|[Pp]anel|[Dd]rawer", "slide-out"),
    (r"[Rr]eservation|[Bb]ooking|[Gg]uest", "reservations"),
    (r"[Ee]vent|[Vv]enue|[Nn]ight", "events"),
    (r"[Hh]ook|[Ss]ession.?[Ss]tart|[Pp]re.?[Cc]ommit", "hooks"),
    (r"[Ii]mage|[Pp]hoto|[Gg]enerat", "images"),
    (r"[Ff]ont|[Tt]ypograph", "typography"),
]

# Pre-compile for performance
_COMPILED_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(pattern), tag) for pattern, tag in REGEX_PATTERNS
]

# ─── Box Drawing Constants ────────────────────────────────────────

BOX_WIDTH = 52


# ─── Logging ──────────────────────────────────────────────────────


def log(msg: str) -> None:
    """Append a timestamped line to the session-index log file."""
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(LOG_PATH, "a") as f:
        f.write(f"[{timestamp}] {msg}\n")


# ─── Regex Tagger ─────────────────────────────────────────────────


def regex_tag(text: str) -> list[str]:
    """Extract tags from text using compiled regex patterns.

    Returns a sorted deduplicated list of matched tag strings.
    """
    tags: set[str] = set()
    for pattern, tag in _COMPILED_PATTERNS:
        if pattern.search(text):
            tags.add(tag)
    return sorted(tags)


# ─── Haiku API Tagger ─────────────────────────────────────────────


def _haiku_call_urllib(
    summary: str, first_prompt: str, project_name: str, api_key: str
) -> tuple[list[str], str]:
    """Call Haiku via urllib.request. Returns (tags, summary_text).

    Raises on any failure (network, parse, empty response).
    """
    prompt_text = (
        "Tag this Claude Code session. Return ONLY a JSON object with "
        '"tags" (array of 5-10 lowercase-hyphenated tags) and "summary" '
        "(one-line, max 80 chars).\n\n"
        f"Project: {project_name}\n"
        f"Summary: {summary}\n"
        f"First prompt: {first_prompt[:300]}"
    )

    payload = json.dumps(
        {
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 150,
            "messages": [{"role": "user", "content": prompt_text}],
        }
    ).encode()

    req = Request(
        "https://api.anthropic.com/v1/messages",
        data=payload,
        headers={
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
    )

    with urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read())

    text_content = data.get("content", [{}])[0].get("text", "")
    if not text_content:
        raise ValueError("empty content in API response")

    # Strip markdown code fences (Haiku often wraps JSON)
    text_content = re.sub(r"^```[a-z]*\n?", "", text_content, flags=re.MULTILINE)
    text_content = re.sub(r"\n?```$", "", text_content.strip())

    parsed = json.loads(text_content)
    tags = parsed.get("tags", [])
    if not isinstance(tags, list) or not tags:
        raise ValueError("no tags in parsed response")

    haiku_summary = parsed.get("summary", "")
    if not isinstance(haiku_summary, str):
        haiku_summary = ""

    return ([t for t in tags if isinstance(t, str)], haiku_summary)


def _haiku_call_sdk(
    summary: str, first_prompt: str, project_name: str, api_key: str
) -> tuple[list[str], str]:
    """Call Haiku via the anthropic SDK if installed. Same interface as urllib variant."""
    import anthropic  # type: ignore[import-untyped]

    client = anthropic.Anthropic(api_key=api_key)
    prompt_text = (
        "Tag this Claude Code session. Return ONLY a JSON object with "
        '"tags" (array of 5-10 lowercase-hyphenated tags) and "summary" '
        "(one-line, max 80 chars).\n\n"
        f"Project: {project_name}\n"
        f"Summary: {summary}\n"
        f"First prompt: {first_prompt[:300]}"
    )

    message = client.messages.create(
        model="claude-haiku-4-5-20251001",
        max_tokens=150,
        messages=[{"role": "user", "content": prompt_text}],
    )

    text_content = message.content[0].text  # type: ignore[union-attr]
    if not text_content:
        raise ValueError("empty content in SDK response")

    text_content = re.sub(r"^```[a-z]*\n?", "", text_content, flags=re.MULTILINE)
    text_content = re.sub(r"\n?```$", "", text_content.strip())

    parsed = json.loads(text_content)
    tags = parsed.get("tags", [])
    if not isinstance(tags, list) or not tags:
        raise ValueError("no tags in parsed response")

    haiku_summary = parsed.get("summary", "")
    if not isinstance(haiku_summary, str):
        haiku_summary = ""

    return ([t for t in tags if isinstance(t, str)], haiku_summary)


# Detect SDK availability once at import time
_HAS_ANTHROPIC_SDK = False
try:
    import anthropic  # type: ignore[import-untyped]  # noqa: F811

    _HAS_ANTHROPIC_SDK = True
except ImportError:
    pass


def haiku_tag(
    summary: str, first_prompt: str, project_name: str, api_key: str
) -> tuple[list[str], str, str]:
    """Tag a session via Haiku API with SDK-first, urllib fallback.

    Returns (tags, haiku_summary, method_or_error) where:
      - On success: method_or_error is "haiku"
      - On API failure: method_or_error is "api_error"
      - On parse failure: method_or_error is "api_parse"
    """
    call_fn = _haiku_call_sdk if _HAS_ANTHROPIC_SDK else _haiku_call_urllib
    try:
        tags, haiku_summary = call_fn(summary, first_prompt, project_name, api_key)
        return (tags, haiku_summary, "haiku")
    except (json.JSONDecodeError, ValueError, KeyError, IndexError, TypeError):
        return ([], "", "api_parse")
    except (HTTPError, URLError, TimeoutError, OSError):
        return ([], "", "api_error")
    except Exception:
        # SDK-specific or unexpected errors
        return ([], "", "api_error")


# ─── Progress Bar ─────────────────────────────────────────────────


def progress_bar(current: int, total: int, width: int = 20) -> str:
    """Render a Unicode block progress bar."""
    if total == 0:
        return "░" * width
    filled = current * width // total
    empty = width - filled
    return "█" * filled + "░" * empty


# ─── Box Drawing Helpers ──────────────────────────────────────────


def _box_top() -> str:
    return f"  {GRAY}╭{'─' * (BOX_WIDTH - 2)}╮{RESET}"


def _box_bottom() -> str:
    return f"  {GRAY}╰{'─' * (BOX_WIDTH - 2)}╯{RESET}"


def _box_sep() -> str:
    return f"  {GRAY}├{'─' * (BOX_WIDTH - 2)}┤{RESET}"


def _box_row(left: str, right: str = "", left_style: str = "", right_style: str = "") -> str:
    """Render a box row with left and right content.

    Calculates padding based on visible (non-ANSI) character widths.
    """
    inner = BOX_WIDTH - 4  # space inside │  ...  │
    # Strip ANSI for length calculation
    ansi_re = re.compile(r"\033\[[0-9;]*m")
    left_visible = len(ansi_re.sub("", left))
    right_visible = len(ansi_re.sub("", right))
    gap = inner - left_visible - right_visible
    if gap < 1:
        gap = 1
    padding = " " * gap
    return f"  {GRAY}│{RESET}  {left_style}{left}{RESET}{padding}{right_style}{right}{RESET}  {GRAY}│{RESET}"


def _hline() -> str:
    return f"  {'━' * BOX_WIDTH}"


# ─── Dashboard ────────────────────────────────────────────────────


class Dashboard:
    """Thread-safe compact 6-line progress dashboard.

    Redraws in-place using cursor-up escape sequences. Throttled to
    redraw at most every 2 items to avoid flicker.
    """

    def __init__(self, total: int, quiet: bool) -> None:
        self.total = total
        self.quiet = quiet
        self.current = 0
        self.tagged = 0
        self.failed = 0
        self.skipped = 0
        self.regex_count = 0
        self.haiku_count = 0
        self.error_count = 0
        self.current_sid = ""
        self.current_method = ""
        self.current_tags = ""
        self.start_time = time.monotonic()
        self._lock = threading.Lock()
        self._drawn = False
        self._last_draw_item = -2  # Force first draw

    def update(
        self,
        sid: str,
        method: str,
        tags_str: str,
        success: bool,
    ) -> None:
        """Record one processed item and conditionally redraw."""
        with self._lock:
            self.current += 1
            self.current_sid = sid
            self.current_method = method
            self.current_tags = tags_str

            if success:
                self.tagged += 1
                if method == "haiku":
                    self.haiku_count += 1
                elif method == "regex":
                    self.regex_count += 1
            else:
                self.failed += 1
                if method in ("api_error", "api_parse"):
                    self.error_count += 1

            # Throttle: redraw every 2 items or on last item
            if (
                self.current - self._last_draw_item >= 2
                or self.current >= self.total
            ):
                self._draw()
                self._last_draw_item = self.current

    def _draw(self) -> None:
        """Render the 6-line dashboard block in-place."""
        if self.quiet or not IS_TTY:
            return

        elapsed = time.monotonic() - self.start_time
        pct = self.current * 100 // self.total if self.total > 0 else 0

        # ETA calculation
        eta_str = ""
        if self.current > 0 and elapsed > 0:
            remaining = int(elapsed * (self.total - self.current) / self.current)
            if remaining >= 60:
                eta_str = f"ETA ~{remaining // 60}m{remaining % 60:02d}s"
            else:
                eta_str = f"ETA ~{remaining}s"

        bar = progress_bar(self.current, self.total, 20)

        # Method label for current item
        method_label = f"[{self.current_method}]" if self.current_method else ""
        tags_display = self.current_tags[:30] if self.current_tags else "(none)"
        sid_short = self.current_sid[:8] if self.current_sid else "--------"

        lines = [
            _hline(),
            f"  Tagging  {bar}  {pct:>3}%  {eta_str}",
            f"  Current: {CYAN}{sid_short}{RESET} {DIM}{method_label}{RESET} → {tags_display}",
            _hline(),
            f"  Tagged: {GREEN}{self.tagged}{RESET}   Failed: {RED}{self.failed}{RESET}   Skipped: {self.skipped}",
            f"  Regex: {self.regex_count}   Haiku: {self.haiku_count}   Errors: {self.error_count}",
            _hline(),
        ]

        if self._drawn:
            # Move cursor up 7 lines (our 7-line block) and clear each
            sys.stdout.write(f"\033[{len(lines)}A")

        for line in lines:
            sys.stdout.write(f"\033[2K{line}\n")
        sys.stdout.flush()
        self._drawn = True

    def finalize(self) -> None:
        """Clear the dashboard area after completion."""
        if self.quiet or not IS_TTY or not self._drawn:
            return
        # Move up and clear the 7 dashboard lines
        sys.stdout.write(f"\033[7A")
        for _ in range(7):
            sys.stdout.write("\033[2K\n")
        # Move back up so summary box starts cleanly
        sys.stdout.write("\033[7A")
        sys.stdout.flush()


# ─── Summary Box ──────────────────────────────────────────────────


def print_mode_banner(
    total: int,
    regex_only: bool,
    api_key: str,
    dry_run: bool,
    project_filter: str,
    retag_summaries: bool = False,
) -> None:
    """Print the mode banner at startup."""
    right = f"{total} queued"
    if project_filter:
        right = f"{total} queued ({project_filter})"

    title = "Session Tagger"
    if dry_run:
        title = "Session Tagger (dry run)"
    elif retag_summaries:
        title = "Retag Summaries"

    print()
    print(_box_top())
    print(_box_row(f"{BOLD}{title}", f"{DIM}{right}"))
    print(_box_bottom())

    if regex_only:
        mode_reason = "--regex-only flag" if api_key else "no API key set"
        print(f"\n  Mode: {BOLD}Regex-only{RESET}  ({mode_reason})")
    elif api_key:
        # Mask API key: show first 14 chars + ***
        masked = api_key[:14] + "...***" if len(api_key) > 14 else api_key[:4] + "***"
        sdk_label = "SDK" if _HAS_ANTHROPIC_SDK else "urllib"
        print(f"\n  Mode: {BOLD}Haiku + Regex{RESET}  ({sdk_label}, key: {DIM}{masked}{RESET})")
    else:
        print(f"\n  Mode: {BOLD}Regex-only{RESET}  (no API key set)")

    print()


def print_summary_box(
    elapsed: float,
    tagged: int,
    failed: int,
    total: int,
    haiku_count: int,
    regex_count: int,
    summaries_added: int,
    errors: dict[str, int],
) -> None:
    """Print the final summary box with method and failure breakdown."""
    # Format elapsed time
    if elapsed >= 60:
        elapsed_fmt = f"{int(elapsed) // 60}m{int(elapsed) % 60}s"
    else:
        elapsed_fmt = f"{elapsed:.1f}s"

    tagged_pct = tagged * 100 // total if total > 0 else 0
    failed_pct = failed * 100 // total if total > 0 else 0
    tagged_bar = progress_bar(tagged, total, 20)
    failed_bar = progress_bar(failed, total, 20)

    if not IS_TTY:
        # Plain text summary for piped output
        print(
            f"Done in {elapsed_fmt}: "
            f"tagged={tagged} ({tagged_pct}%), failed={failed} ({failed_pct}%), "
            f"regex={regex_count}, haiku={haiku_count}, summaries=+{summaries_added}"
        )
        if errors:
            parts = [f"{k}={v}" for k, v in sorted(errors.items())]
            print(f"Failures: {', '.join(parts)}")
        return

    print()
    print(_box_top())
    print(_box_row(f"{GREEN}{BOLD}Done", f"{DIM}{elapsed_fmt}"))
    print(_box_sep())

    # Tagged row
    tagged_line = f"{GREEN}Tagged    {tagged:>4}{RESET}    {tagged_bar}  {tagged_pct:>3}%"
    print(f"  {GRAY}│{RESET}  {tagged_line}  {GRAY}│{RESET}")

    # Failed row
    failed_color = RED if failed > 0 else DIM
    failed_line = f"{failed_color}Failed    {failed:>4}{RESET}    {failed_bar}  {failed_pct:>3}%"
    print(f"  {GRAY}│{RESET}  {failed_line}  {GRAY}│{RESET}")

    print(_box_sep())

    # Method breakdown
    print(_box_row(f"Method     Regex: {regex_count}   Haiku: {haiku_count}"))

    # Failure breakdown
    if errors:
        parts = [f"{k}: {v}" for k, v in sorted(errors.items())]
        print(_box_row(f"Failures   {'  '.join(parts)}"))
    else:
        print(_box_row("Failures   (none)"))

    # Summaries
    print(_box_row(f"Summaries  +{summaries_added} new from Haiku"))

    print(_box_bottom())
    print()


# ─── Error Categories ────────────────────────────────────────────


def classify_failure(
    text: str, tags: list[str], api_result: str
) -> str:
    """Classify why tagging failed for a session.

    Returns one of: empty_text, no_match, api_error, api_parse
    """
    if len(text.strip()) < 10:
        return "empty_text"
    if api_result in ("api_error", "api_parse"):
        return api_result
    return "no_match"


# ─── Session Processing ──────────────────────────────────────────


class TagResult:
    """Result of tagging a single session."""

    __slots__ = (
        "session_id",
        "tags",
        "summary",
        "method",
        "error_category",
        "success",
    )

    def __init__(
        self,
        session_id: str,
        tags: list[str],
        summary: str,
        method: str,
        error_category: str,
        success: bool,
    ) -> None:
        self.session_id = session_id
        self.tags = tags
        self.summary = summary
        self.method = method
        self.error_category = error_category
        self.success = success


def process_session(
    row: dict[str, str],
    api_key: str,
    regex_only: bool,
    rate_semaphore: threading.Semaphore | None,
) -> TagResult:
    """Process a single session: try Haiku, fall back to regex.

    Thread-safe. Uses rate_semaphore to throttle API calls.
    """
    sid = row["session_id"]
    summary = (row.get("summary") or "").replace("\n", " ")
    first_prompt = (row.get("first_prompt") or "").replace("\n", " ")
    project_name = row.get("project_name") or ""
    context_text = (row.get("context_text") or "").replace("\n", " ")
    assistant_text = (row.get("assistant_text") or "").replace("\n", " ")

    combined_text = f"{summary} {first_prompt} {context_text} {assistant_text}"

    # Check for empty text
    if len(combined_text.strip()) < 10:
        return TagResult(sid, [], "", "skip", "empty_text", False)

    tags: list[str] = []
    haiku_summary = ""
    method = "regex"
    api_result = ""

    # Try Haiku first if available
    if not regex_only and api_key:
        if rate_semaphore is not None:
            rate_semaphore.acquire()
            try:
                # 0.1s delay between API submissions for rate limiting
                time.sleep(0.1)
            finally:
                rate_semaphore.release()

        tags, haiku_summary, api_result = haiku_tag(
            summary, first_prompt, project_name, api_key
        )
        if tags:
            method = "haiku"

    # Fallback to regex if Haiku failed or was skipped
    if not tags:
        tags = regex_tag(combined_text)
        method = "regex"

    if tags:
        return TagResult(sid, tags, haiku_summary, method, "", True)

    # Failed — classify the error
    error_cat = classify_failure(combined_text, tags, api_result)
    return TagResult(sid, [], "", method, error_cat, False)


# ─── Main ─────────────────────────────────────────────────────────


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Tag untagged sessions with semantic labels"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="preview tags without persisting to database",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=100,
        help="batch size (default: 100)",
    )
    parser.add_argument(
        "--project",
        type=str,
        default="",
        help="filter by project_name LIKE '%%FILTER%%'",
    )
    parser.add_argument(
        "--regex-only",
        action="store_true",
        help="skip Haiku API, use regex patterns only",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="suppress per-item output (for install.sh)",
    )
    parser.add_argument(
        "--retag-summaries",
        action="store_true",
        help="re-process tagged sessions that have empty summaries (requires Haiku API)",
    )
    args = parser.parse_args()

    # ─── Validate database exists ─────────────────────────────────

    if not DB_PATH.exists():
        print(
            "No index database. Run session-index-backfill.sh first.",
            file=sys.stderr,
        )
        sys.exit(1)

    # ─── Signal handling: restore cursor on Ctrl+C ────────────────

    original_sigint = signal.getsignal(signal.SIGINT)
    original_sigterm = signal.getsignal(signal.SIGTERM)

    def cleanup_handler(signum: int, frame: object) -> None:
        sys.stdout.write(SHOW_CURSOR)
        sys.stdout.flush()
        sys.exit(1)

    signal.signal(signal.SIGINT, cleanup_handler)
    signal.signal(signal.SIGTERM, cleanup_handler)

    # ─── Acquire script-level lock ─────────────────────────────────

    lock_path = Path.home() / ".claude" / "session-index.lock"
    lock_file = None
    try:
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        lock_file = open(lock_path, "w")
        import fcntl
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except (OSError, IOError):
        if lock_file:
            lock_file.close()
        print("Another tagger or backfill is running. Wait or retry.", file=sys.stderr)
        sys.exit(1)
    except ImportError:
        pass  # fcntl not available on Windows — skip locking

    # ─── API key detection ────────────────────────────────────────

    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    effective_regex_only = args.regex_only or not api_key

    # ─── Validate --retag-summaries constraints ────────────────────

    if args.retag_summaries and effective_regex_only:
        print(
            "--retag-summaries requires Haiku API. Set ANTHROPIC_API_KEY.",
            file=sys.stderr,
        )
        sys.exit(1)

    # ─── Query sessions ────────────────────────────────────────────

    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=5000")

    if args.retag_summaries:
        # Target sessions that have tags but empty summaries
        if args.project:
            query = (
                "SELECT session_id, summary, first_prompt, project_name, "
                "substr(context_text,1,500) as context_text, "
                "substr(assistant_text,1,500) as assistant_text "
                "FROM sessions WHERE (summary = '' OR summary IS NULL) "
                "AND project_name LIKE ? "
                "ORDER BY modified_at DESC LIMIT ?"
            )
            rows = conn.execute(query, (f"%{args.project}%", args.limit)).fetchall()
        else:
            query = (
                "SELECT session_id, summary, first_prompt, project_name, "
                "substr(context_text,1,500) as context_text, "
                "substr(assistant_text,1,500) as assistant_text "
                "FROM sessions WHERE (summary = '' OR summary IS NULL) "
                "ORDER BY modified_at DESC LIMIT ?"
            )
            rows = conn.execute(query, (args.limit,)).fetchall()

        if args.project:
            total_untagged = conn.execute(
                "SELECT COUNT(*) FROM sessions WHERE (summary = '' OR summary IS NULL) "
                "AND project_name LIKE ?",
                (f"%{args.project}%",),
            ).fetchone()[0]
        else:
            total_untagged = conn.execute(
                "SELECT COUNT(*) FROM sessions WHERE summary = '' OR summary IS NULL"
            ).fetchone()[0]

    elif args.project:
        query = (
            "SELECT session_id, summary, first_prompt, project_name, "
            "substr(context_text,1,500) as context_text, "
            "substr(assistant_text,1,500) as assistant_text "
            "FROM sessions WHERE tagged_at IS NULL AND project_name LIKE ? "
            "ORDER BY modified_at DESC LIMIT ?"
        )
        rows = conn.execute(query, (f"%{args.project}%", args.limit)).fetchall()
        total_untagged = conn.execute(
            "SELECT COUNT(*) FROM sessions WHERE tagged_at IS NULL AND project_name LIKE ?",
            (f"%{args.project}%",),
        ).fetchone()[0]
    else:
        query = (
            "SELECT session_id, summary, first_prompt, project_name, "
            "substr(context_text,1,500) as context_text, "
            "substr(assistant_text,1,500) as assistant_text "
            "FROM sessions WHERE tagged_at IS NULL "
            "ORDER BY modified_at DESC LIMIT ?"
        )
        rows = conn.execute(query, (args.limit,)).fetchall()
        total_untagged = conn.execute(
            "SELECT COUNT(*) FROM sessions WHERE tagged_at IS NULL"
        ).fetchone()[0]

    if not rows:
        if not args.quiet:
            if IS_TTY:
                print(f"\n  {DIM}●{RESET} Nothing to tag.\n")
            else:
                print("Nothing to tag.")
        conn.close()
        sys.exit(0)

    # Convert to dicts for thread-safe access
    sessions: list[dict[str, str]] = [dict(r) for r in rows]
    effective_count = len(sessions)

    # ─── Print mode banner ────────────────────────────────────────

    if not args.quiet:
        print_mode_banner(
            total_untagged, effective_regex_only, api_key, args.dry_run, args.project,
            retag_summaries=args.retag_summaries,
        )

    # ─── Hide cursor during progress ──────────────────────────────

    if IS_TTY and not args.quiet:
        sys.stdout.write(HIDE_CURSOR)
        sys.stdout.flush()

    # ─── Process sessions ─────────────────────────────────────────

    start_time = time.monotonic()
    dashboard = Dashboard(effective_count, args.quiet)

    # Rate limiter: semaphore limits concurrent API calls
    rate_semaphore = threading.Semaphore(8) if not effective_regex_only else None

    results: list[TagResult] = []
    summaries_added = 0
    error_counts: dict[str, int] = {}

    if args.dry_run:
        # Dry run: sequential, no API calls, regex only
        for session in sessions:
            combined = (
                f"{session.get('summary', '')} "
                f"{session.get('first_prompt', '')} "
                f"{session.get('context_text', '')} "
                f"{session.get('assistant_text', '')}"
            )
            tags = regex_tag(combined)
            tags_str = ",".join(tags)
            success = bool(tags)
            method = "regex" if success else "skip"

            if not success:
                cat = classify_failure(combined, tags, "")
                error_counts[cat] = error_counts.get(cat, 0) + 1

            result = TagResult(
                session["session_id"], tags, "", method,
                "" if success else classify_failure(combined, tags, ""),
                success,
            )
            results.append(result)
            dashboard.update(
                session["session_id"], method, tags_str, success
            )

    elif effective_regex_only:
        # Regex-only mode: sequential, no threading overhead needed
        for session in sessions:
            result = process_session(session, "", True, None)
            results.append(result)
            tags_str = ",".join(result.tags)

            if not result.success and result.error_category:
                error_counts[result.error_category] = (
                    error_counts.get(result.error_category, 0) + 1
                )

            dashboard.update(
                result.session_id, result.method, tags_str, result.success
            )

    else:
        # Haiku + Regex mode: parallel with ThreadPoolExecutor
        with ThreadPoolExecutor(max_workers=8) as executor:
            future_to_session = {
                executor.submit(
                    process_session, session, api_key, False, rate_semaphore
                ): session
                for session in sessions
            }

            for future in as_completed(future_to_session):
                result = future.result()
                results.append(result)
                tags_str = ",".join(result.tags)

                if not result.success and result.error_category:
                    error_counts[result.error_category] = (
                        error_counts.get(result.error_category, 0) + 1
                    )

                dashboard.update(
                    result.session_id, result.method, tags_str, result.success
                )

    # ─── Finalize dashboard ───────────────────────────────────────

    dashboard.finalize()

    # ─── Batch write results to database ──────────────────────────

    if not args.dry_run:
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        # Check which sessions currently have empty summaries (for counting new summaries)
        successful = [r for r in results if r.success]

        if not args.retag_summaries:
            # Normal mode: pre-count summaries that will be added
            haiku_with_summary = [
                r for r in successful if r.method == "haiku" and r.summary
            ]

            if haiku_with_summary:
                sids_with_haiku_summary = [r.session_id for r in haiku_with_summary]
                placeholders = ",".join("?" * len(sids_with_haiku_summary))
                existing = conn.execute(
                    f"SELECT session_id FROM sessions "
                    f"WHERE session_id IN ({placeholders}) AND summary = ''",
                    sids_with_haiku_summary,
                ).fetchall()
                summaries_added = len(existing)

        # Batch update in a single transaction
        try:
            conn.execute("BEGIN IMMEDIATE")
            for result in successful:
                if args.retag_summaries:
                    # Only update summary; preserve existing tags
                    if result.summary:
                        conn.execute(
                            "UPDATE sessions SET "
                            "summary=?, "
                            "tags=CASE WHEN tags IS NULL OR tags = '' THEN ? ELSE tags END, "
                            "tagged_at=COALESCE(tagged_at, ?) "
                            "WHERE session_id=?",
                            (result.summary, ",".join(result.tags), now, result.session_id),
                        )
                        summaries_added += 1
                else:
                    tags_str = ",".join(result.tags)
                    conn.execute(
                        "UPDATE sessions SET tags=?, "
                        "summary=CASE WHEN ? != '' AND summary = '' THEN ? ELSE summary END, "
                        "tagged_at=? WHERE session_id=?",
                        (tags_str, result.summary, result.summary, now, result.session_id),
                    )
            conn.execute("COMMIT")
        except sqlite3.Error as e:
            conn.execute("ROLLBACK")
            log(f"Database write failed: {e}")
            print(f"Database write failed: {e}", file=sys.stderr)
            sys.stdout.write(SHOW_CURSOR)
            sys.stdout.flush()
            conn.close()
            sys.exit(1)

        # Incremental FTS update (only changed rows, not full rebuild)
        # Full DELETE+INSERT holds exclusive lock 1-2s on 991 sessions.
        # Incremental: ~5ms per row, no global lock contention.
        updated_sids = [r.session_id for r in successful]
        if updated_sids:
            try:
                placeholders = ",".join("?" * len(updated_sids))
                conn.execute(
                    f"DELETE FROM sessions_fts WHERE session_id IN ({placeholders})",
                    updated_sids,
                )
                conn.execute(
                    f"INSERT INTO sessions_fts "
                    f"(session_id, summary, first_prompt, tags, keywords, project_name, "
                    f"context_text, assistant_text, files_changed, commands_run) "
                    f"SELECT session_id, summary, first_prompt, tags, keywords, project_name, "
                    f"context_text, assistant_text, files_changed, commands_run "
                    f"FROM sessions WHERE session_id IN ({placeholders})",
                    updated_sids,
                )
                conn.commit()
            except sqlite3.Error as e:
                log(f"FTS incremental update failed: {e}")
                # Non-fatal: tags are persisted, FTS will rebuild on next backfill

    conn.close()

    # ─── Restore cursor ───────────────────────────────────────────

    if IS_TTY and not args.quiet:
        sys.stdout.write(SHOW_CURSOR)
        sys.stdout.flush()

    # ─── Restore signal handlers ──────────────────────────────────

    signal.signal(signal.SIGINT, original_sigint)
    signal.signal(signal.SIGTERM, original_sigterm)

    # ─── Compute final stats ──────────────────────────────────────

    elapsed = time.monotonic() - start_time
    tagged = sum(1 for r in results if r.success)
    failed = sum(1 for r in results if not r.success)
    haiku_count = sum(1 for r in results if r.success and r.method == "haiku")
    regex_count = sum(1 for r in results if r.success and r.method == "regex")

    # ─── Print summary ────────────────────────────────────────────

    if not args.quiet:
        print_summary_box(
            elapsed,
            tagged,
            failed,
            effective_count,
            haiku_count,
            regex_count,
            summaries_added,
            error_counts,
        )

    # ─── Log ──────────────────────────────────────────────────────

    err_parts = " ".join(f"{k}={v}" for k, v in sorted(error_counts.items()))
    log(
        f"Tagging complete: {tagged} tagged, {failed} failed, "
        f"{summaries_added} summaries added ({elapsed:.1f}s) "
        f"[regex={regex_count} haiku={haiku_count}] "
        f"{'dry-run ' if args.dry_run else ''}"
        f"{f'errors: {err_parts}' if err_parts else ''}"
    )


if __name__ == "__main__":
    main()

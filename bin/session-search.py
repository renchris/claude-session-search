#!/usr/bin/env python3
"""
Claude Session Search Engine — Full-text search over session index.

Usage:
    session-search.py "query"                    # Search, show ranked results
    session-search.py --format=fzf "query"       # fzf-compatible output
    session-search.py --format=json "query"      # JSON output
    session-search.py --after 2026-03-01 "query"  # Date filter
    session-search.py --project "reso" "query"   # Project filter
    session-search.py --preview SESSION_ID       # Preview a session
    session-search.py --context-inject CWD       # SessionStart context line
    session-search.py --stats                    # Index statistics
    session-search.py --limit N "query"          # Limit results (default 10)
"""

import argparse
import json
import math
import os
import re
import sqlite3
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

DB_PATH = Path.home() / ".claude" / "session-index.db"
CACHE_PATH = Path.home() / ".claude" / ".last-search-results.json"

# ─── Temporal Extraction ──────────────────────────────────

TEMPORAL_PATTERNS = [
    (r"\byesterday\b", lambda: (datetime.now(timezone.utc) - timedelta(days=1), datetime.now(timezone.utc))),
    (r"\btoday\b", lambda: (datetime.now(timezone.utc).replace(hour=0, minute=0, second=0), datetime.now(timezone.utc))),
    (r"\blast\s+(\d+)\s+days?\b", lambda m: (datetime.now(timezone.utc) - timedelta(days=int(m.group(1))), datetime.now(timezone.utc))),
    (r"\blast\s+week\b", lambda: (datetime.now(timezone.utc) - timedelta(days=7), datetime.now(timezone.utc))),
    (r"\blast\s+(\d+)\s+weeks?\b", lambda m: (datetime.now(timezone.utc) - timedelta(weeks=int(m.group(1))), datetime.now(timezone.utc))),
    (r"\blast\s+month\b", lambda: (datetime.now(timezone.utc) - timedelta(days=30), datetime.now(timezone.utc))),
    (r"\blast\s+(\d+)\s+months?\b", lambda m: (datetime.now(timezone.utc) - timedelta(days=30 * int(m.group(1))), datetime.now(timezone.utc))),
    (r"\bthis\s+week\b", lambda: (datetime.now(timezone.utc) - timedelta(days=datetime.now(timezone.utc).weekday()), datetime.now(timezone.utc))),
]

MONTH_NAMES = {
    "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3,
    "apr": 4, "april": 4, "may": 5, "jun": 6, "june": 6,
    "jul": 7, "july": 7, "aug": 8, "august": 8, "sep": 9, "september": 9,
    "oct": 10, "october": 10, "nov": 11, "november": 11, "dec": 12, "december": 12,
}

def extract_temporal(text):
    """Extract date range from query, return (cleaned_text, date_range_or_None)."""
    for pattern, factory in TEMPORAL_PATTERNS:
        m = re.search(pattern, text, re.IGNORECASE)
        if m:
            cleaned = re.sub(pattern, "", text, flags=re.IGNORECASE).strip()
            try:
                if m.lastindex:
                    date_range = factory(m)
                else:
                    date_range = factory()
                return cleaned, date_range
            except Exception:
                pass

    # "march 1" or "mar 8" style
    m = re.search(r"\b(" + "|".join(MONTH_NAMES.keys()) + r")\s+(\d{1,2})\b", text, re.IGNORECASE)
    if m:
        month = MONTH_NAMES[m.group(1).lower()]
        day = int(m.group(2))
        year = datetime.now().year
        try:
            start = datetime(year, month, day, tzinfo=timezone.utc)
            end = start + timedelta(days=1)
            cleaned = text[:m.start()] + text[m.end():]
            return cleaned.strip(), (start, end)
        except ValueError:
            pass

    # ISO date: 2026-03-01
    m = re.search(r"\b(\d{4}-\d{2}-\d{2})\b", text)
    if m:
        try:
            start = datetime.fromisoformat(m.group(1)).replace(tzinfo=timezone.utc)
            end = start + timedelta(days=1)
            cleaned = text[:m.start()] + text[m.end():]
            return cleaned.strip(), (start, end)
        except ValueError:
            pass

    return text, None


# ─── Synonym Expansion ────────────────────────────────────

def load_synonyms(conn):
    """Load synonyms from DB into dict: term → [expansions]."""
    try:
        rows = conn.execute("SELECT term, expansion FROM synonyms").fetchall()
        syns = {}
        for term, expansion in rows:
            syns.setdefault(term.lower(), []).append(expansion.lower())
        return syns
    except Exception:
        return {}

def expand_synonyms(tokens, synonym_map):
    """Expand tokens using synonym map. Returns expanded token list."""
    expanded = []
    i = 0
    while i < len(tokens):
        # Try 2-token phrases first (e.g., "floor plan")
        if i + 1 < len(tokens):
            bigram = f"{tokens[i]} {tokens[i+1]}"
            if bigram in synonym_map:
                expanded.append(bigram)
                expanded.extend(synonym_map[bigram])
                i += 2
                continue
        # Single token
        token = tokens[i]
        expanded.append(token)
        if token in synonym_map:
            expanded.extend(synonym_map[token])
        i += 1
    return list(dict.fromkeys(expanded))  # dedupe, preserve order


# ─── Fuzzy Correction ────────────────────────────────────

def fuzzy_correct(tokens, known_terms):
    """Correct tokens using fuzzy matching. Graceful if rapidfuzz not installed."""
    try:
        from rapidfuzz import fuzz, process
    except ImportError:
        return tokens

    corrected = []
    for token in tokens:
        if token in known_terms or len(token) < 4:
            corrected.append(token)
            continue
        threshold = 75 if len(token) <= 8 else 65
        match = process.extractOne(token, known_terms, scorer=fuzz.ratio, score_cutoff=threshold)
        if match:
            corrected.append(match[0])
        else:
            corrected.append(token)
    return corrected


# ─── FTS5 Query Builder ──────────────────────────────────

def build_fts5_query(tokens):
    """Build FTS5 MATCH query from tokens."""
    if not tokens:
        return None
    # Escape FTS5 special chars
    safe = []
    for t in tokens:
        t = t.replace('"', '""')
        if " " in t:
            safe.append(f'"{t}"')
        else:
            safe.append(t)
    return " OR ".join(safe)


# ─── Recency Boost ───────────────────────────────────────

def recency_score(created_at_str):
    """Calculate recency multiplier: more recent = higher score."""
    try:
        created = datetime.fromisoformat(created_at_str.replace("Z", "+00:00"))
        days_old = max(0, (datetime.now(timezone.utc) - created).days)
        return 1 + math.exp(-0.05 * days_old)
    except Exception:
        return 1.0


# ─── Query Pipeline ──────────────────────────────────────

class QueryPipeline:
    def __init__(self, db_path=DB_PATH):
        self.db_path = db_path
        self.conn = None

    def _connect(self):
        if self.conn is None:
            self.conn = sqlite3.connect(str(self.db_path), timeout=5)
            self.conn.row_factory = sqlite3.Row
        return self.conn

    def search(self, raw_query, limit=10, project_filter=None, date_after=None, date_before=None, min_messages=0):
        conn = self._connect()
        synonyms = load_synonyms(conn)
        known_terms = set(synonyms.keys())
        # Add all expansion values too
        for exps in synonyms.values():
            known_terms.update(exps)

        # 1. Normalize
        normalized = raw_query.strip().lower()

        # 2. Temporal extraction
        text, auto_date_range = extract_temporal(normalized)

        # CLI date flags override auto-extracted
        if date_after:
            start = datetime.fromisoformat(date_after).replace(tzinfo=timezone.utc)
            end = datetime.now(timezone.utc)
            if date_before:
                end = datetime.fromisoformat(date_before).replace(tzinfo=timezone.utc)
            auto_date_range = (start, end)

        # 3. Tokenize
        # First extract compound terms (for synonym lookup), then split hyphens for FTS5
        # FTS5 unicode61 tokenizer treats hyphens as separators
        compound_tokens = re.findall(r'[a-z0-9][-a-z0-9_.]*[a-z0-9]|[a-z0-9]+', text)
        if not compound_tokens:
            compound_tokens = re.findall(r'\S+', text)

        # 4. Synonym expansion (uses compound tokens like "slide-out" for lookup)
        expanded = expand_synonyms(compound_tokens, synonyms)

        # Split hyphens for FTS5 compatibility (FTS5 unicode61 treats - as separator;
        # FTS5 query parser treats - as NOT operator). After synonym expansion is done.
        tokens = []
        for t in expanded:
            if "-" in t:
                # Split and add both parts + keep as quoted phrase for adjacency match
                parts = [p for p in t.split("-") if p]
                tokens.extend(parts)
            else:
                tokens.append(t)
        tokens = list(dict.fromkeys(tokens))  # dedupe, preserve order

        # 5. Fuzzy correction (only for unknown terms)
        corrected = fuzzy_correct(tokens, known_terms)

        # 6. Progressive search
        results = self._progressive_search(corrected, limit, project_filter, auto_date_range, min_messages)

        # 7. Apply recency boost + depth multiplier and sort
        for r in results:
            r["recency"] = recency_score(r["created_at"])
            msgs = max(r["message_count"], 1)
            r["depth"] = max(0.3, min(3.0, math.log2(msgs + 1) / math.log2(6)))
            r["final_score"] = r.get("bm25", 0) * r["recency"] * r["depth"]
        results.sort(key=lambda r: r["final_score"], reverse=True)

        return results[:limit]

    def _progressive_search(self, tokens, limit, project_filter, date_range, min_messages=0):
        """Try increasingly broad queries until we get results."""
        strategies = [
            # 1. Phrase match (AND)
            lambda t: " AND ".join(f'"{tok}"' if " " in tok else tok for tok in t),
            # 2. OR match
            lambda t: build_fts5_query(t),
            # 3. Core terms only (drop expansions, keep first N originals)
            lambda t: build_fts5_query(t[:max(2, len(t) // 2)]),
            # 4. Prefix match on each term
            lambda t: " OR ".join(f"{tok}*" for tok in t if " " not in tok),
        ]

        for strategy in strategies:
            fts_query = strategy(tokens)
            if not fts_query:
                continue
            results = self._execute_query(fts_query, limit * 2, project_filter, date_range, min_messages)
            if results:
                return results
        return []

    def _execute_query(self, fts_query, limit, project_filter, date_range, min_messages=0):
        conn = self._connect()
        # Standalone FTS5 table — join on session_id column
        # BM25 weights: session_id(0), summary(10), first_prompt(2), tags(5), keywords(3), project_name(1), context_text(1.5)
        sql = """
            SELECT s.session_id, s.project_path, s.project_name, s.summary,
                   s.first_prompt, s.git_branch, s.created_at, s.modified_at,
                   s.message_count, s.tags, s.keywords, s.source,
                   bm25(sessions_fts, 0.0, 10.0, 2.0, 5.0, 3.0, 1.0, 1.5) AS bm25_score
            FROM sessions_fts
            JOIN sessions s ON s.session_id = sessions_fts.session_id
            WHERE sessions_fts MATCH ?
        """
        params = [fts_query]

        if project_filter:
            sql += " AND s.project_name LIKE ?"
            params.append(f"%{project_filter}%")

        if date_range:
            start, end = date_range
            sql += " AND s.created_at >= ? AND s.created_at <= ?"
            params.append(start.strftime("%Y-%m-%dT%H:%M:%SZ"))
            params.append(end.strftime("%Y-%m-%dT%H:%M:%SZ"))

        if min_messages and min_messages > 0:
            sql += " AND s.message_count >= ?"
            params.append(min_messages)

        sql += " ORDER BY bm25_score LIMIT ?"
        params.append(limit)

        try:
            rows = conn.execute(sql, params).fetchall()
        except sqlite3.OperationalError:
            return []

        results = []
        for row in rows:
            results.append({
                "session_id": row["session_id"],
                "project_path": row["project_path"],
                "project_name": row["project_name"],
                "summary": row["summary"],
                "first_prompt": row["first_prompt"],
                "git_branch": row["git_branch"],
                "created_at": row["created_at"],
                "modified_at": row["modified_at"],
                "message_count": row["message_count"],
                "tags": row["tags"],
                "keywords": row["keywords"],
                "source": row["source"],
                "bm25": abs(row["bm25_score"]),  # BM25 returns negative scores
            })
        return results

    def preview(self, session_id):
        conn = self._connect()
        row = conn.execute(
            "SELECT * FROM sessions WHERE session_id = ?", (session_id,)
        ).fetchone()
        if not row:
            return None
        return dict(row)

    def stats(self):
        conn = self._connect()
        total = conn.execute("SELECT COUNT(*) FROM sessions").fetchone()[0]
        tagged = conn.execute("SELECT COUNT(*) FROM sessions WHERE tagged_at IS NOT NULL").fetchone()[0]
        projects = conn.execute("SELECT COUNT(DISTINCT project_name) FROM sessions").fetchone()[0]
        last = conn.execute("SELECT MAX(indexed_at) FROM sessions").fetchone()[0]
        by_source = conn.execute(
            "SELECT source, COUNT(*) as c FROM sessions GROUP BY source ORDER BY c DESC"
        ).fetchall()
        by_project = conn.execute(
            "SELECT project_name, COUNT(*) as c FROM sessions GROUP BY project_name ORDER BY c DESC LIMIT 10"
        ).fetchall()
        return {
            "total": total,
            "tagged": tagged,
            "projects": projects,
            "last_indexed": last,
            "by_source": [(r[0], r[1]) for r in by_source],
            "by_project": [(r[0], r[1]) for r in by_project],
        }

    def context_inject(self, cwd):
        """Generate compact context string for SessionStart hook."""
        conn = self._connect()
        total = conn.execute("SELECT COUNT(*) FROM sessions").fetchone()[0]
        if total == 0:
            return ""

        # Get project name from cwd
        project_name = os.path.basename(cwd) if cwd else ""

        # Recent sessions for this project
        rows = conn.execute("""
            SELECT summary, created_at, tags FROM sessions
            WHERE project_name LIKE ?
            ORDER BY modified_at DESC LIMIT 3
        """, (f"%{project_name}%" if project_name else "%",)).fetchall()

        if not rows:
            return f"Session index: {total} sessions. Search: claude-search \"query\""

        parts = []
        now = datetime.now(timezone.utc)
        for row in rows:
            summary = row[0][:60] if row[0] else "(no summary)"
            created = row[1]
            tags = row[2]

            # Relative time
            try:
                dt = datetime.fromisoformat(created.replace("Z", "+00:00"))
                delta = now - dt
                if delta.days == 0:
                    age = "today"
                elif delta.days == 1:
                    age = "1d"
                elif delta.days < 7:
                    age = f"{delta.days}d"
                elif delta.days < 30:
                    age = f"{delta.days // 7}w"
                else:
                    age = f"{delta.days // 30}mo"
            except Exception:
                age = "?"

            tag_str = f" (#{tags.split(',')[0].strip()})" if tags else ""
            parts.append(f"[{age}] {summary}{tag_str}")

        recent_str = " | ".join(parts)
        return f"Session index: {total} sessions. Recent: {recent_str}\nSearch: claude-search \"query\""

    def log_search(self, query, result_count, selected_id=None, selected_rank=None, pipeline_ms=None):
        conn = self._connect()
        conn.execute(
            "INSERT INTO search_log (query, result_count, selected_id, selected_rank, pipeline_ms) VALUES (?, ?, ?, ?, ?)",
            (query, result_count, selected_id, selected_rank, pipeline_ms)
        )
        conn.commit()

    def close(self):
        if self.conn:
            self.conn.close()
            self.conn = None


# ─── Output Formatters ───────────────────────────────────

def format_relative_time(created_at):
    try:
        dt = datetime.fromisoformat(created_at.replace("Z", "+00:00"))
        delta = datetime.now(timezone.utc) - dt
        if delta.days == 0:
            hours = delta.seconds // 3600
            if hours == 0:
                return f"{delta.seconds // 60}m ago"
            return f"{hours}h ago"
        elif delta.days == 1:
            return "yesterday"
        elif delta.days < 7:
            return f"{delta.days}d ago"
        elif delta.days < 30:
            return f"{delta.days // 7}w ago"
        else:
            return f"{delta.days // 30}mo ago"
    except Exception:
        return "?"


def _use_color():
    """Check if ANSI colors should be used. Always on unless explicitly disabled."""
    return not os.environ.get("NO_COLOR") and os.environ.get("TERM") != "dumb"


def _smart_truncate(text, max_len):
    """Truncate at word boundary with ellipsis."""
    if len(text) <= max_len:
        return text
    truncated = text[:max_len - 1].rsplit(" ", 1)[0]
    return truncated + "\u2026"


def _truncate_tags(tags_str, max_len):
    """Truncate tags at complete tag boundaries with +N overflow."""
    if not tags_str:
        return ""
    # Normalize: always use ", " separator
    tags_str = ", ".join(t.strip() for t in tags_str.split(","))
    if len(tags_str) <= max_len:
        return tags_str
    tags = [t.strip() for t in tags_str.split(",")]
    result = []
    length = 0
    for tag in tags:
        needed = len(tag) + (2 if result else 0)
        if length + needed > max_len - 4:
            remaining = len(tags) - len(result)
            if remaining > 0:
                result.append(f"+{remaining}")
            break
        result.append(tag)
        length += needed
    return ", ".join(result)


def format_table(results, elapsed_ms=0):
    if not results:
        print("No results found.")
        return

    color = _use_color()
    R = "\033[0m" if color else ""
    BOLD = "\033[1m" if color else ""
    DIM = "\033[2m" if color else ""
    GREEN = "\033[32m" if color else ""
    YELLOW = "\033[33m" if color else ""
    GRAY = "\033[90m" if color else ""
    CYAN = "\033[36m" if color else ""
    BLUE = "\033[38;5;33m" if color else ""
    BOLD_YELLOW = "\033[1;33m" if color else ""

    TL, TR, BL, BR, H, V = "╭", "╮", "╰", "╯", "─", "│"

    # Terminal width
    try:
        tw = os.get_terminal_size().columns
    except (AttributeError, ValueError, OSError):
        tw = 80
    tw = min(tw, 120)
    cw = tw - 4  # content width inside box

    def strip_ansi(text):
        import re
        return re.sub(r'\033\[[0-9;]*m', '', text)

    def box_top():
        return f"{DIM}{TL}{H * (cw + 2)}{TR}{R}"

    def box_bottom():
        return f"{DIM}{BL}{H * (cw + 2)}{BR}{R}"

    def box_row(content):
        visible = strip_ansi(content)
        pad = cw - len(visible)
        return f"{DIM}{V}{R} {content}{' ' * max(0, pad)} {DIM}{V}{R}"

    # ─── Header Card ───────────────────────────────────────
    print()
    print(box_top())
    title = f"{BOLD}Session Search{R}"
    meta = f"{DIM}{len(results)} results · {elapsed_ms}ms{R}"
    title_vis = "Session Search"
    meta_vis = f"{len(results)} results · {elapsed_ms}ms"
    spacing = cw - len(title_vis) - len(meta_vis)
    print(box_row(f"{title}{' ' * max(2, spacing)}{meta}"))
    print(box_bottom())

    # ─── Section Header ───────────────────────────────────
    COL_NUM = 4
    COL_AGE = 10
    COL_MSGS = 6
    summary_budget = cw - COL_NUM - COL_AGE - COL_MSGS
    indent = COL_NUM + COL_AGE + COL_MSGS

    print()
    print(f"  {BOLD}Results{R}  {DIM}{len(results)} sessions{R}")
    print(f"  {DIM}{H * cw}{R}")

    # ─── Result Rows (dense — no blank lines) ─────────────
    for i, r in enumerate(results, 1):
        age = format_relative_time(r["created_at"])
        msgs = r["message_count"]
        sid = r["session_id"]
        is_legacy = sid.startswith("legacy-")
        short_id = "*" if is_legacy else sid[:8]
        summary = _smart_truncate(r["summary"] or r["first_prompt"] or "(no summary)", summary_budget)
        tags_str = _truncate_tags(r.get("tags", ""), summary_budget - 12)

        # Message count styling
        if msgs >= 50:
            msg_styled = f"{BOLD_YELLOW}{msgs:<{COL_MSGS}}{R}"
        elif msgs >= 20:
            msg_styled = f"{BOLD}{msgs:<{COL_MSGS}}{R}"
        elif msgs <= 2:
            msg_styled = f"{DIM}{msgs:<{COL_MSGS}}{R}"
        else:
            msg_styled = f"{msgs:<{COL_MSGS}}"

        # Line 1: #  age  msgs  summary
        print(f"  {DIM}{i:<{COL_NUM}}{R}{YELLOW}{age:<{COL_AGE}}{R}{msg_styled}{summary}")

        # Line 2: tags (left) + short ID (right)
        line2_width = cw - indent
        if tags_str:
            gap = line2_width - len(tags_str) - len(short_id)
            print(f"  {' ' * indent}{CYAN}{tags_str}{R}{' ' * max(2, gap)}{GRAY}{short_id}{R}")
        else:
            print(f"  {' ' * indent}{' ' * (line2_width - len(short_id))}{GRAY}{short_id}{R}")

    # ─── Footer Card ──────────────────────────────────────
    print()
    print(box_top())
    print(box_row(f"{GREEN}●{R}  {DIM}--resume N{R} to open  {DIM}·{R}  {DIM}--fzf{R} for interactive"))
    print(box_bottom())
    print()


def format_fzf(results):
    """Tab-delimited output for fzf with ANSI colors."""
    for r in results:
        age = format_relative_time(r["created_at"])
        proj = r["project_name"][:20]
        summary = (r["summary"] or r["first_prompt"] or "(no summary)")[:70]
        branch = (r["git_branch"] or "")[:12]
        tags = r.get("tags", "")[:30]
        # session_id is last field (hidden, used for --preview)
        print(f"\033[33m{age:<8}\033[0m \033[35m{proj:<20}\033[0m {summary:<70} \033[32m{branch:<12}\033[0m {tags}\t{r['session_id']}")


def format_json(results):
    print(json.dumps(results, indent=2, default=str))


def format_preview(session):
    if not session:
        print("Session not found.")
        return
    print(f"\033[1;33mSession\033[0m: {session['session_id']}")
    print(f"\033[1;35mProject\033[0m: {session['project_name']} ({session['project_path']})")
    print(f"\033[1;32mBranch\033[0m:  {session.get('git_branch', '')}")
    print(f"\033[1mCreated\033[0m: {session['created_at']}  |  Modified: {session['modified_at']}")
    print(f"\033[1mMessages\033[0m: {session['message_count']}  |  Source: {session['source']}")
    if session.get("tags"):
        print(f"\033[1mTags\033[0m:    {session['tags']}")
    print()
    print(f"\033[1;33mSummary\033[0m:")
    print(session.get("summary") or "(none)")
    print()
    print(f"\033[1;35mFirst Prompt\033[0m:")
    prompt = session.get("first_prompt", "")
    # Show first 500 chars
    print(prompt[:500])
    if len(prompt) > 500:
        print(f"... ({len(prompt)} chars total)")


# ─── Result Caching ──────────────────────────────────────

def _cache_results(results):
    """Cache search results for --resume without repeating query."""
    try:
        CACHE_PATH.write_text(json.dumps(
            [{"session_id": r["session_id"], "summary": r.get("summary", ""),
              "first_prompt": r.get("first_prompt", ""), "message_count": r.get("message_count", 0)}
             for r in results],
            default=str
        ))
    except Exception:
        pass


def _load_cached_results():
    """Load cached results from last search."""
    try:
        if CACHE_PATH.exists():
            return json.loads(CACHE_PATH.read_text())
    except Exception:
        pass
    return []


# ─── CLI ──────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Claude Session Search")
    parser.add_argument("query", nargs="*", help="Search query")
    parser.add_argument("--format", choices=["table", "fzf", "json"], default="table")
    parser.add_argument("--limit", type=int, default=10)
    parser.add_argument("--project", help="Filter by project name")
    parser.add_argument("--after", help="Filter sessions after date (YYYY-MM-DD)")
    parser.add_argument("--before", help="Filter sessions before date (YYYY-MM-DD)")
    parser.add_argument("--min-msgs", type=int, default=0, help="Minimum message count filter")
    parser.add_argument("--resume-result", type=int, metavar="N", help="Resume result #N (from last search or with query)")
    parser.add_argument("--preview", metavar="SESSION_ID", help="Preview a session")
    parser.add_argument("--context-inject", metavar="CWD", help="Generate SessionStart context")
    parser.add_argument("--stats", action="store_true", help="Show index statistics")
    args = parser.parse_args()

    if not DB_PATH.exists():
        print("No index database found. Run session-index-backfill.sh first.", file=sys.stderr)
        sys.exit(1)

    pipeline = QueryPipeline()

    try:
        if args.stats:
            s = pipeline.stats()
            print(f"Total sessions: {s['total']}")
            print(f"Tagged:         {s['tagged']}")
            print(f"Projects:       {s['projects']}")
            print(f"Last indexed:   {s['last_indexed']}")
            print()
            print("By source:")
            for src, cnt in s["by_source"]:
                print(f"  {src:<20} {cnt}")
            print()
            print("Top projects:")
            for proj, cnt in s["by_project"]:
                print(f"  {proj:<35} {cnt}")
            return

        if args.context_inject:
            result = pipeline.context_inject(args.context_inject)
            print(result)
            return

        if args.preview:
            session = pipeline.preview(args.preview)
            format_preview(session)
            return

        query = " ".join(args.query)

        # --resume-result N: resume a result by number
        if args.resume_result is not None:
            n = args.resume_result
            if query:
                # Run search first, then resume result N
                results = pipeline.search(
                    query, limit=args.limit, project_filter=args.project,
                    date_after=args.after, date_before=args.before,
                    min_messages=args.min_msgs,
                )
                _cache_results(results)
            else:
                # Use cached results from last search
                results = _load_cached_results()

            if not results:
                print("No results. Run a search first.", file=sys.stderr)
                sys.exit(1)
            if n < 1 or n > len(results):
                print(f"Result #{n} out of range (1-{len(results)}).", file=sys.stderr)
                sys.exit(1)
            sid = results[n - 1]["session_id"]
            if sid.startswith("legacy-"):
                print(f"Result #{n} is a legacy session and cannot be resumed.", file=sys.stderr)
                sys.exit(1)
            # Output the session ID for the bash wrapper to exec
            print(sid)
            return

        if not query:
            parser.print_help()
            sys.exit(1)

        import time
        t0 = time.monotonic()
        results = pipeline.search(
            query,
            limit=args.limit,
            project_filter=args.project,
            date_after=args.after,
            date_before=args.before,
            min_messages=args.min_msgs,
        )
        elapsed_ms = int((time.monotonic() - t0) * 1000)

        pipeline.log_search(query, len(results), pipeline_ms=elapsed_ms)
        _cache_results(results)

        if args.format == "fzf":
            format_fzf(results)
        elif args.format == "json":
            format_json(results)
        else:
            format_table(results, elapsed_ms)

    finally:
        pipeline.close()


if __name__ == "__main__":
    main()

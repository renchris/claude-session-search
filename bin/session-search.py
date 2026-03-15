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
    session-search.py --explain "query"          # Show match explanation per result
    session-search.py --analytics                # Show search log statistics
    session-search.py --analytics --fails        # Show only zero-result queries
"""

import argparse
import json
import math
import os
import re
import shutil
import sqlite3
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

DB_PATH = Path.home() / ".claude" / "session-index.db"
CACHE_PATH = Path.home() / ".claude" / ".last-search-results.json"

# ─── Stopwords ───────────────────────────────────────────

STOP_WORDS = {
    "the", "a", "an", "is", "are", "was", "were", "and", "or", "but",
    "in", "on", "at", "to", "for", "of", "with", "by", "it", "its",
    "i", "we", "my", "our", "that", "this", "those", "these",
    "session", "claude", "where", "which", "how", "when", "what",
    "did", "do", "does", "have", "has", "had", "can", "could",
    "about", "just", "some", "any", "all", "also", "there", "here",
}
# Keep domain-relevant words even if commonly stop-word-like
KEEP_WORDS = {"not", "without", "no", "from", "after", "before", "during"}

# ─── Verb Expansions ─────────────────────────────────────

VERB_EXPANSIONS = {
    "debug": ["error", "fix", "trace", "bug"],
    "debugged": ["error", "fix", "trace", "bug"],
    "debugging": ["error", "fix", "trace", "bug"],
    "fix": ["bug", "error", "patch", "repair"],
    "fixed": ["bug", "error", "patch", "repair"],
    "upload": ["file", "import", "add", "create"],
    "uploaded": ["file", "import", "add", "create"],
    "implement": ["build", "create", "add", "feature"],
    "implemented": ["build", "create", "add", "feature"],
    "refactor": ["cleanup", "restructure", "reorganize"],
    "refactored": ["cleanup", "restructure", "reorganize"],
    "migrate": ["migration", "schema", "database", "drizzle"],
    "migrated": ["migration", "schema", "database", "drizzle"],
    "deploy": ["deployment", "amplify", "fly", "production"],
    "deployed": ["deployment", "amplify", "fly", "production"],
    "monitor": ["rum", "cloudwatch", "latency", "metrics"],
    "research": ["explore", "investigate", "analyze", "deep dive"],
    "researched": ["explore", "investigate", "analyze", "deep dive"],
    "review": ["audit", "check", "inspect", "examine"],
    "reviewed": ["audit", "check", "inspect", "examine"],
    "create": ["add", "new", "build", "implement"],
    "created": ["add", "new", "build", "implement"],
    "change": ["modify", "update", "edit", "alter"],
    "changed": ["modify", "update", "edit", "alter"],
}

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

    @staticmethod
    def _parse_inline_syntax(query):
        """Parse @project and #tag shortcuts from query."""
        project = None
        tags = []
        for match in re.finditer(r'@([\w-]+)', query):
            project = match.group(1)
        for match in re.finditer(r'#([\w-]+)', query):
            tags.append(match.group(1))
        clean = re.sub(r'[@#][\w-]+', '', query).strip()
        return clean, project, tags

    def search(self, raw_query, limit=10, project_filter=None, date_after=None, date_before=None, min_messages=0):
        conn = self._connect()
        synonyms = load_synonyms(conn)
        known_terms = set(synonyms.keys())
        # Add all expansion values too
        for exps in synonyms.values():
            known_terms.update(exps)

        # 0. Parse inline @project #tag syntax
        query_text, inline_project, inline_tags = self._parse_inline_syntax(raw_query)
        if inline_project and not project_filter:
            project_filter = inline_project

        # 1. Normalize
        normalized = query_text.strip().lower()

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

        # 3a. Stopword filtering (before synonym expansion)
        effective_stops = STOP_WORDS - KEEP_WORDS
        compound_tokens = [t for t in compound_tokens if t not in effective_stops]
        if not compound_tokens:
            # If all tokens were stopwords, use original (fallback)
            compound_tokens = re.findall(r'[a-z0-9][-a-z0-9_.]*[a-z0-9]|[a-z0-9]+', text)

        # 3b. Verb expansion (add search-relevant terms for action verbs)
        verb_expanded = []
        for t in compound_tokens:
            verb_expanded.append(t)
            if t in VERB_EXPANSIONS:
                verb_expanded.extend(VERB_EXPANSIONS[t])
        compound_tokens = list(dict.fromkeys(verb_expanded))

        # 3c. Inject inline #tags as search tokens
        if inline_tags:
            compound_tokens.extend(inline_tags)

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

        # Store original query tokens (pre-expansion) for NEAR matching
        self._original_tokens = [t for t in compound_tokens if t not in effective_stops][:6]

        # Store final tokens for --explain
        self._final_tokens = corrected

        # 6. Progressive search
        results = self._progressive_search(corrected, limit, project_filter, auto_date_range, min_messages)

        # 6a. LLM expansion fallback on sparse results
        if len(results) < 3:
            llm_results = self._llm_expand_query(raw_query, limit, project_filter, auto_date_range, min_messages)
            if llm_results:
                # Merge via RRF
                results = self._reciprocal_rank_fusion([results, llm_results])[:limit * 2]
                self._last_strategy = getattr(self, '_last_strategy', 'none') + " + LLM expansion"

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
        # Build NEAR strategy from original (pre-expansion) tokens
        orig = getattr(self, '_original_tokens', tokens[:4])

        strategy_names = [
            "NEAR proximity",
            "AND phrase",
            "OR match",
            "Core terms only",
            "Prefix match",
        ]

        strategies = [
            # 0. NEAR proximity match (original terms within 5 tokens of each other)
            lambda t: (f'NEAR({" ".join(orig)}, 5)' if len(orig) > 1 else None),
            # 1. Phrase match (AND)
            lambda t: " AND ".join(f'"{tok}"' if " " in tok else tok for tok in t),
            # 2. OR match
            lambda t: build_fts5_query(t),
            # 3. Core terms only (drop expansions, keep first N originals)
            lambda t: build_fts5_query(t[:max(2, len(t) // 2)]),
            # 4. Prefix match on each term
            lambda t: " OR ".join(f"{tok}*" for tok in t if " " not in tok),
        ]

        best_results = []
        best_strategy = None
        for i, strategy in enumerate(strategies):
            fts_query = strategy(tokens)
            if not fts_query:
                continue
            results = self._execute_query(fts_query, limit * 2, project_filter, date_range, min_messages)
            if results:
                if len(results) >= 3:
                    self._last_strategy = strategy_names[i]
                    return results  # Sufficient results, stop here
                # Sparse results — keep but try broader strategies
                if len(results) > len(best_results):
                    best_results = results
                    best_strategy = strategy_names[i]
        self._last_strategy = best_strategy or "none"
        return best_results

    def _execute_query(self, fts_query, limit, project_filter, date_range, min_messages=0):
        conn = self._connect()
        # Standalone FTS5 table — join on session_id column
        # BM25 weights (10 columns):
        #   session_id(0), summary(10), first_prompt(1.5), tags(5), keywords(3),
        #   project_name(0.5), context_text(2), assistant_text(3), files_changed(4), commands_run(2)
        sql = """
            SELECT s.session_id, s.project_path, s.project_name, s.summary,
                   s.first_prompt, s.context_text, s.git_branch, s.created_at,
                   s.modified_at, s.message_count, s.tags, s.keywords, s.source,
                   bm25(sessions_fts, 0.0, 10.0, 1.5, 5.0, 3.0, 0.5, 2.0, 3.0, 4.0, 2.0) AS bm25_score,
                   highlight(sessions_fts, 1, '\x02', '\x03') AS summary_hl,
                   highlight(sessions_fts, 7, '\x02', '\x03') AS assistant_hl
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
                "context_text": row["context_text"],
                "git_branch": row["git_branch"],
                "created_at": row["created_at"],
                "modified_at": row["modified_at"],
                "message_count": row["message_count"],
                "tags": row["tags"],
                "keywords": row["keywords"],
                "source": row["source"],
                "bm25": abs(row["bm25_score"]),  # BM25 returns negative scores
                "summary_hl": row["summary_hl"] if "summary_hl" in row.keys() else "",
                "assistant_hl": row["assistant_hl"] if "assistant_hl" in row.keys() else "",
            })
        return results

    def _llm_expand_query(self, raw_query, limit, project_filter, date_range, min_messages):
        """Fallback: ask Haiku to rewrite query into keyword variants."""
        if not os.environ.get("ANTHROPIC_API_KEY"):
            return []
        try:
            import anthropic
        except ImportError:
            return []
        try:
            client = anthropic.Anthropic()
            msg = client.messages.create(
                model="claude-haiku-4-5-20251001",
                max_tokens=150,
                messages=[{"role": "user", "content": (
                    "Rewrite this session search query as 4 lines of keywords (5-7 terms each).\n"
                    "Each line should capture a different interpretation. Terms only, no explanation.\n\n"
                    f"Query: {raw_query}"
                )}],
            )
            interpretations = msg.content[0].text.strip().split("\n")
            all_results = []
            for interp in interpretations[:4]:
                interp = interp.strip().lstrip("0123456789.-) ")
                if not interp:
                    continue
                itokens = re.findall(r'[a-z0-9][-a-z0-9_.]*[a-z0-9]|[a-z0-9]+', interp.lower())
                if not itokens:
                    continue
                fts_q = build_fts5_query(itokens)
                if fts_q:
                    results = self._execute_query(fts_q, limit, project_filter, date_range, min_messages)
                    all_results.append(results)
            if all_results:
                return self._reciprocal_rank_fusion(all_results)
        except Exception:
            pass
        return []

    @staticmethod
    def _reciprocal_rank_fusion(ranked_lists, k=60):
        """Merge multiple ranked lists via Reciprocal Rank Fusion."""
        scores = {}
        for ranking in ranked_lists:
            for rank, result in enumerate(ranking, 1):
                sid = result["session_id"]
                if sid not in scores:
                    scores[sid] = {"result": result, "rrf": 0}
                scores[sid]["rrf"] += 1.0 / (k + rank)
        fused = sorted(scores.values(), key=lambda x: x["rrf"], reverse=True)
        return [item["result"] for item in fused]

    def suggest_alternatives(self, raw_query, limit=4):
        """When search fails, suggest queries that might work."""
        tokens = re.findall(r'[a-z0-9][-a-z0-9_.]*[a-z0-9]|[a-z0-9]+', raw_query.lower())
        effective_stops = STOP_WORDS - KEEP_WORDS
        tokens = [t for t in tokens if t not in effective_stops]
        suggestions = []

        # Try each token individually
        for token in tokens:
            fts_q = build_fts5_query([token])
            if fts_q:
                results = self._execute_query(fts_q, 1, None, None)
                if results:
                    count = len(self._execute_query(fts_q, 50, None, None))
                    suggestions.append((token, count))

        # Try dropping one term at a time
        if len(tokens) > 2:
            for i in range(len(tokens)):
                subset = tokens[:i] + tokens[i + 1:]
                fts_q = build_fts5_query(subset)
                if fts_q:
                    results = self._execute_query(fts_q, 1, None, None)
                    if results:
                        count = len(self._execute_query(fts_q, 50, None, None))
                        suggestions.append((" ".join(subset), count))

        # Deduplicate and sort by match count
        seen = set()
        unique = []
        for term, count in sorted(suggestions, key=lambda x: -x[1]):
            if term not in seen:
                seen.add(term)
                unique.append((term, count))
        return unique[:limit]

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

    def _explain_match(self, result, tokens, raw_query):
        """Explain why a result matched the query. Returns list of lines (no prefix)."""
        color = _use_color()
        R = "\033[0m" if color else ""
        CYAN = "\033[36m" if color else ""
        YELLOW = "\033[33m" if color else ""
        DIM = "\033[2m" if color else ""

        explanations = []

        # Check which columns contain query terms — group by token
        columns = {
            'summary': result.get('summary', ''),
            'first_prompt': result.get('first_prompt', ''),
            'tags': result.get('tags', ''),
            'keywords': result.get('keywords', ''),
            'context_text': result.get('context_text', ''),
            'assistant_text': result.get('assistant_hl', ''),
            'files_changed': result.get('files_changed', ''),
            'commands_run': result.get('commands_run', ''),
        }

        for token in tokens:
            matching_cols = [col for col, text in columns.items() if text and token.lower() in text.lower()]
            if matching_cols:
                cols_str = f"{CYAN}{', '.join(matching_cols)}{R}"
                explanations.append(f"'{token}' \u2192 {cols_str}")

        # Combine BM25 + strategy on one line
        parts = []
        strategy = getattr(self, '_last_strategy', None)
        if strategy:
            parts.append(f"Strategy: {strategy}")
        if 'bm25' in result:
            parts.append(f"BM25: {YELLOW}{result['bm25']:.2f}{R}")
        if parts:
            joined = ' \u00b7 '.join(parts)
            explanations.append(f"{DIM}{joined}{R}")

        # Show synonym/verb expansions
        effective_stops = STOP_WORDS - KEEP_WORDS
        raw_tokens = re.findall(r'[a-z0-9][-a-z0-9_.]*[a-z0-9]|[a-z0-9]+', raw_query.lower())
        raw_tokens = [t for t in raw_tokens if t not in effective_stops]
        expanded_only = [t for t in tokens if t not in raw_tokens]
        if expanded_only:
            explanations.append(f"Expanded: {DIM}{', '.join(expanded_only[:10])}{R}")

        return '\n'.join(explanations)

    def reset_dedup(self):
        """Reset description deduplication tracking for a new search."""
        self._seen_descriptions = set()

    def build_deduped_description(self, r):
        """Build description with deduplication — if the same text was already
        shown for a previous result, try alternative sources."""
        if not hasattr(self, '_seen_descriptions'):
            self._seen_descriptions = set()

        desc = _build_description(r)
        desc_hash = hash(desc[:200])

        if desc_hash in self._seen_descriptions:
            # Try alternative sources in priority order
            alternatives = [
                (r.get('summary') or '').strip(),
                (r.get('assistant_hl') or '').strip()[:200],
                (r.get('first_prompt') or '').strip()[:200],
                (r.get('context_text') or '').strip()[:200],
            ]
            for alt in alternatives:
                if alt and len(alt) >= 8 and hash(alt[:200]) not in self._seen_descriptions:
                    desc = alt
                    desc_hash = hash(desc[:200])
                    break

        self._seen_descriptions.add(desc_hash)
        return desc

    def _show_analytics(self, fails_only=False):
        """Show search log statistics with box-drawing layout."""
        conn = self._connect()
        color = _use_color()
        R = "\033[0m" if color else ""
        BOLD = "\033[1m" if color else ""
        DIM = "\033[2m" if color else ""
        WHITE = "\033[38;5;255m" if color else ""
        CYAN = "\033[36m" if color else ""
        YELLOW = "\033[33m" if color else ""

        H = "\u2500"  # ─
        TL, TR, BL, BR = "\u256d", "\u256e", "\u2570", "\u256f"
        V = "\u2502"  # │
        ML, MR = "\u251c", "\u2524"  # ├ ┤

        tw = _get_term_width()
        bw = min(56, tw - 4)  # box width

        # Total searches
        total = conn.execute("SELECT COUNT(*) FROM search_log").fetchone()[0]

        if total == 0:
            print(f"\n  {DIM}No search history yet.{R}\n")
            return

        # Average latency
        avg_latency = conn.execute("SELECT AVG(pipeline_ms) FROM search_log").fetchone()[0]

        # Zero-result queries
        zero_results = conn.execute(
            "SELECT query, COUNT(*) as cnt FROM search_log WHERE result_count = 0 "
            "GROUP BY query ORDER BY cnt DESC LIMIT 20"
        ).fetchall()
        zero_count = conn.execute(
            "SELECT COUNT(*) FROM search_log WHERE result_count = 0"
        ).fetchone()[0]
        zero_pct = (zero_count / total * 100) if total else 0

        if fails_only:
            print()
            print(f"  {BOLD}{WHITE}Zero-Result Queries{R}  {DIM}({len(zero_results)} unique){R}")
            print(f"  {DIM}{H * bw}{R}")
            for row in zero_results:
                print(f"   {YELLOW}{row[1]:>3}\u00d7{R}  {row[0]}")
            print()
            return

        # Top queries
        top_queries = conn.execute(
            "SELECT query, COUNT(*) as cnt, AVG(result_count) as avg_results "
            "FROM search_log GROUP BY query ORDER BY cnt DESC LIMIT 15"
        ).fetchall()

        # Recent searches
        recent = conn.execute(
            "SELECT query, result_count, pipeline_ms, created_at "
            "FROM search_log ORDER BY created_at DESC LIMIT 10"
        ).fetchall()

        # ─── Summary Box ─────────────────────────────────
        title = "Search Analytics"
        total_str = f"{total} searches"
        inner = bw - 2
        spacing = inner - len(title) - len(total_str)
        print()
        print(f"  {DIM}{TL}{H * bw}{TR}{R}")
        print(f"  {DIM}{V}{R} {BOLD}{WHITE}{title}{R}{' ' * max(1, spacing)}{DIM}{total_str}{R} {DIM}{V}{R}")
        print(f"  {DIM}{ML}{H * bw}{MR}{R}")

        # Avg latency row
        latency_label = "Avg latency"
        latency_val = f"{avg_latency:.1f}ms"
        lat_space = inner - len(latency_label) - len(latency_val)
        print(f"  {DIM}{V}{R} {DIM}{latency_label}{R}{' ' * max(1, lat_space)}{CYAN}{latency_val}{R} {DIM}{V}{R}")

        # Zero-result row
        zr_label = "Zero-result"
        zr_val = f"{zero_pct:.1f}% ({zero_count}/{total})"
        zr_space = inner - len(zr_label) - len(zr_val)
        zr_color = YELLOW if zero_pct > 10 else DIM
        print(f"  {DIM}{V}{R} {DIM}{zr_label}{R}{' ' * max(1, zr_space)}{zr_color}{zr_val}{R} {DIM}{V}{R}")
        print(f"  {DIM}{BL}{H * bw}{BR}{R}")

        # ─── Top Queries ─────────────────────────────────
        print()
        print(f"  {BOLD}{WHITE}Top Queries{R}")
        print(f"  {DIM}{H * bw}{R}")
        for row in top_queries:
            count_str = f"{row[1]:>3}\u00d7"
            avg_str = f"avg {row[2]:>2.0f} results"
            query_w = bw - len(count_str) - len(avg_str) - 4
            query_display = row[0][:query_w].ljust(query_w)
            print(f"   {YELLOW}{count_str}{R}  {query_display}  {DIM}{avg_str}{R}")

        # ─── Failed Queries ──────────────────────────────
        if zero_results:
            print()
            print(f"  {BOLD}{WHITE}Failed Queries{R}  {DIM}(tuning targets){R}")
            print(f"  {DIM}{H * bw}{R}")
            for row in zero_results[:10]:
                print(f"   {YELLOW}{row[1]:>3}\u00d7{R}  {row[0]}")

        # ─── Recent Searches ─────────────────────────────
        print()
        print(f"  {BOLD}{WHITE}Recent Searches{R}")
        print(f"  {DIM}{H * bw}{R}")
        for row in recent:
            ts = row[3]
            # Show just date portion for compactness
            try:
                dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                ts_short = dt.strftime("%m/%d %H:%M")
            except Exception:
                ts_short = ts[:16]
            res_str = f"{row[1]:>2} res"
            ms_str = f"{row[2]:>.0f}ms"
            meta = f"{res_str}  {ms_str}"
            query_w = bw - len(ts_short) - len(meta) - 4
            query_display = row[0][:query_w].ljust(query_w)
            print(f"   {DIM}{ts_short}{R}  {query_display}{DIM}{meta}{R}")

        print()

    def close(self):
        if self.conn:
            self.conn.close()
            self.conn = None


# ─── Output Formatters ───────────────────────────────────

def format_relative_time(created_at, compact=False):
    try:
        dt = datetime.fromisoformat(created_at.replace("Z", "+00:00"))
        delta = datetime.now(timezone.utc) - dt
        if compact:
            if delta.days == 0:
                hours = delta.seconds // 3600
                return f"{hours}h" if hours else f"{delta.seconds // 60}m"
            elif delta.days < 7:
                return f"{delta.days}d"
            elif delta.days < 30:
                return f"{delta.days // 7}w"
            elif delta.days < 365:
                return f"{delta.days // 30}mo"
            else:
                return f"{delta.days // 365}y"
        else:
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
    """Check if ANSI colors should be used. Disabled for pipes or explicit NO_COLOR."""
    return (sys.stdout.isatty()
            and not os.environ.get("NO_COLOR")
            and os.environ.get("TERM") != "dumb")


def _smart_truncate(text, max_len):
    """Truncate at word boundary with ellipsis."""
    if len(text) <= max_len:
        return text
    truncated = text[:max_len - 1].rsplit(" ", 1)[0]
    return truncated + "\u2026"


def _wrap_lines(text, width, max_lines=3):
    """Word-wrap text into up to max_lines lines. Returns list of strings."""
    text = " ".join(text.replace("\n", " ").split()).strip()
    lines = []
    while text and len(lines) < max_lines:
        if len(text) <= width:
            lines.append(text)
            text = ""
            break
        break_at = text[:width].rfind(" ")
        if break_at <= 0:
            break_at = width
        lines.append(text[:break_at].rstrip())
        text = text[break_at:].strip()
    # If text remains after max_lines, truncate last line
    if text and lines:
        last = lines[-1]
        if len(last) + len(text) + 1 > width:
            lines[-1] = _smart_truncate(last + " " + text, width)
    return lines if lines else [""]


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


def _build_description(r):
    """Build the best available description from session data.

    Priority: summary > cleaned context_text > first_prompt.
    Returns a single cleaned string suitable for multi-line wrapping.
    """
    summary = (r.get("summary") or "").strip()
    context = (r.get("context_text") or "").strip()
    first_prompt = (r.get("first_prompt") or "").strip()

    # Prefixes that add no information
    noise_prefixes = [
        "Implement the following plan:",
        "Implement the following plan: ",
        "/compact",
        "[Pasted text #1",
        "Wrote 1 memory",
        "Wrote 2 memories",
        "Wrote 3 memories",
    ]
    # Noise fragments that can appear anywhere at the start
    noise_patterns = [
        r'^\(ctrl\+o to expand\)\s*',
        r'^⏺\s*',
        r'^\[Pasted text #\d+ \+\d+ lines\]\s*',
    ]

    def clean_text(text):
        """Strip noise prefixes, markdown formatting, and normalize whitespace."""
        for prefix in noise_prefixes:
            if text.startswith(prefix):
                text = text[len(prefix):].strip()
                # After stripping, if it starts with a markdown header or bullet, strip that too
                text = re.sub(r'^#+\s+', '', text)
                text = re.sub(r'^[-*]\s+', '', text)
        for pat in noise_patterns:
            text = re.sub(pat, '', text)
        # Strip markdown bold/italic markers
        text = re.sub(r'\*{1,2}([^*]+)\*{1,2}', r'\1', text)
        # Strip markdown backticks
        text = text.replace('`', '')
        # Collapse whitespace
        text = " ".join(text.split())
        return text

    def is_useful(text):
        """Check if text provides meaningful session identification."""
        if not text or len(text) < 8:
            return False
        # Single-word commands or dots are not useful
        if text in (".", "..", "yes", "no", "ok", "commit this", "push", "No prompt"):
            return False
        if text.startswith("[Pasted text"):
            return False
        return True

    # 1. Summary is best (Claude-generated session description)
    if is_useful(summary):
        return summary

    # 2. Context text (first user messages from transcript — rich but needs cleaning)
    if context and len(context) > 30:
        cleaned = clean_text(context)
        if is_useful(cleaned):
            return cleaned

    # 3. First prompt (often garbage but sometimes useful)
    if is_useful(first_prompt):
        cleaned = clean_text(first_prompt)
        if is_useful(cleaned):
            return cleaned

    # 4. Assistant text (Claude's responses — outcomes, explanations)
    assistant = (r.get("assistant_hl") or r.get("assistant_text") or "").strip()
    if assistant and len(assistant) > 30:
        cleaned = clean_text(assistant)
        if is_useful(cleaned):
            return cleaned[:300]

    return "(no description)"


def _visible_len(text):
    """Return visible length of text, stripping ANSI escape codes."""
    return len(re.sub(r'\033\[[0-9;]*m', '', text))


def _pad_visible(text, width, align='left'):
    """Pad text to fixed visible width, accounting for ANSI escape codes."""
    pad = width - _visible_len(text)
    if pad <= 0:
        return text
    if align == 'right':
        return ' ' * pad + text
    return text + ' ' * pad


def _render_highlights(text, bold_start="\033[1;4;33m", bold_end="\033[0m"):
    """Convert \\x02...\\x03 FTS5 highlight markers to ANSI bold+underline+yellow."""
    return text.replace("\x02", bold_start).replace("\x03", bold_end)


def _get_term_width():
    """Get terminal width, capped at 120. Fallback 80 for non-TTY."""
    try:
        tw = shutil.get_terminal_size().columns
    except (AttributeError, ValueError, OSError):
        tw = 80
    return min(tw, 120)


def _box_line(left, fill, right, width, dim="", reset=""):
    """Build a box-drawing line: left + fill*width + right."""
    return f"{dim}{left}{fill * width}{right}{reset}"


def format_table(results, elapsed_ms=0, pipeline=None, raw_query=None, explain=False, tokens=None):
    color = _use_color()
    R = "\033[0m" if color else ""
    BOLD = "\033[1m" if color else ""
    DIM = "\033[2m" if color else ""
    GREEN = "\033[32m" if color else ""
    CYAN = "\033[36m" if color else ""
    YELLOW = "\033[33m" if color else ""
    BLUE = "\033[38;5;33m" if color else ""
    MAGENTA = "\033[35m" if color else ""
    DIM_MAGENTA = "\033[2;35m" if color else ""
    WHITE = "\033[38;5;255m" if color else ""
    GRAY = "\033[90m" if color else ""
    BOLD_CYAN = "\033[1;36m" if color else ""

    H = "\u2500"  # horizontal: ─
    TL, TR, BL, BR = "\u256d", "\u256e", "\u2570", "\u256f"  # ╭╮╰╯
    V = "\u2502"  # │
    ML, MR = "\u251c", "\u2524"  # ├ ┤
    THIN_V = "\u250a"  # thin vertical: ┊

    tw = _get_term_width()
    cw = tw - 4  # content width (2 indent + 2 margin)

    if not results:
        # ─── Zero-Result Empty State ──────────────────────
        display_query = raw_query or "query"
        label = f'No results for "{display_query}"'
        box_inner = max(len(label) + 4, 48)
        print()
        print(f"  {DIM}{TL}{H * box_inner}{TR}{R}")
        print(f"  {DIM}{V}{R}  {YELLOW}{label}{R}{' ' * (box_inner - len(label) - 2)}{DIM}{V}{R}")
        print(f"  {DIM}{BL}{H * box_inner}{BR}{R}")

        if pipeline and raw_query:
            suggestions = pipeline.suggest_alternatives(raw_query)
            print()
            print(f"  {DIM}Suggestions:{R}")
            if suggestions:
                for term, count in suggestions:
                    print(f"    {GREEN}\u2192{R} Try: {BOLD}\"{term}\"{R}  {DIM}({count} results){R}")
            print(f"    {GREEN}\u2192{R} Use {CYAN}@project{R} to filter by project")
            print(f"    {GREEN}\u2192{R} Use {MAGENTA}#tag{R} to filter by tag")
        print()
        return

    # ─── Column Grid ──────────────────────────────────────
    # Fixed gutter: rank(2, right-aligned) + gap(2) = 4 chars
    # Content area: cw - 4 = description and metadata width
    GUTTER = 4        # rank + gap
    content = cw - GUTTER  # available for description/metadata

    # Metadata fixed columns (within content area, indented by GUTTER)
    COL_AGE  = 4      # "2d", "1w", "12mo" — right-aligned
    COL_MSGS = 9      # "  83 msgs", "2.4k msgs" — right-aligned number + " msgs"
    COL_SID  = 8      # "e6f2a0ee" — right-aligned at line end
    SEP_W    = 3      # " · " separator between columns (visible rhythm)
    # Tags fill remaining: content - age - sep - msgs - sep - sid
    # Session ID is right-aligned to terminal edge (no trailing separator)
    COL_TAGS = content - COL_AGE - SEP_W - COL_MSGS - SEP_W - COL_SID

    # ─── Header Card ──────────────────────────────────────
    title_text = "Session Search"
    meta_text = f"{len(results)} result{'s' if len(results) != 1 else ''} \u00b7 {elapsed_ms}ms"
    inner = cw - 2  # inside box padding
    spacing = inner - len(title_text) - len(meta_text)
    print()
    print(f"  {_box_line(TL, H, TR, cw, DIM, R)}")
    print(f"  {DIM}{V}{R} {BOLD}{WHITE}{title_text}{R}{' ' * max(1, spacing)}{DIM}{meta_text}{R} {DIM}{V}{R}")
    print(f"  {_box_line(BL, H, BR, cw, DIM, R)}")

    # ─── Result Rows ──────────────────────────────────────
    for i, r in enumerate(results, 1):
        age = format_relative_time(r["created_at"], compact=True)
        msgs = r["message_count"]
        sid = r["session_id"]
        is_legacy = sid.startswith("legacy-")
        short_id = "*" if is_legacy else sid[:8]
        tags_raw = r.get("tags", "")
        branch = (r.get("git_branch") or "").strip()

        # Build smart description with deduplication
        if pipeline:
            desc_raw = pipeline.build_deduped_description(r)
        else:
            desc_raw = _build_description(r)
        # Check if FTS5 highlight markers are available (keep raw \x02/\x03 for now)
        has_highlights = False
        if r.get("summary_hl") and "\x02" in r.get("summary_hl", ""):
            desc_raw = r["summary_hl"]
            has_highlights = True

        # Format message count (right-aligned number within COL_MSGS)
        if msgs >= 1000:
            msgs_num = f"{msgs / 1000:.1f}k"
        else:
            msgs_num = str(msgs)

        # Wrap description using raw markers (1 byte each, same visual width as nothing)
        # Strip markers for wrapping, then re-apply after
        desc_plain = desc_raw.replace("\x02", "").replace("\x03", "") if has_highlights else desc_raw
        desc_lines = _wrap_lines(desc_plain, content, max_lines=5)

        # Re-apply highlights to wrapped lines if present
        if has_highlights and color:
            HL_ON = "\033[1;4;33m"
            HL_OFF = R
            # Re-match highlight spans from original text onto wrapped lines
            # Simple approach: apply highlights per-line by finding matching terms
            highlighted_lines = []
            for line in desc_lines:
                # Find terms that were highlighted in summary_hl
                hl_text = r["summary_hl"]
                for m in re.finditer(r'\x02([^\x03]+)\x03', hl_text):
                    term = m.group(1)
                    # Case-insensitive replacement preserving case
                    pattern = re.compile(re.escape(term), re.IGNORECASE)
                    line = pattern.sub(f"{HL_ON}{term}{HL_OFF}", line)
                highlighted_lines.append(line)
            desc_lines = highlighted_lines

        # Rank gutter: right-aligned number in 2 chars + 2-space gap
        rank_str = f"{i:>2}"

        # Line 1: rank + first description line (bold white)
        print(f"  {BOLD}{CYAN}{rank_str}{R}  {BOLD}{WHITE}{desc_lines[0]}{R}")

        # Lines 2+: continuation (indented to content column, dim for hierarchy)
        for line in desc_lines[1:]:
            print(f"  {' ' * GUTTER}{DIM}{line}{R}")

        # ─── Metadata (fixed-width columns) ───────────────
        # Age column (right-aligned in fixed width, dim)
        age_col = _pad_visible(f"{DIM}{age}{R}", COL_AGE, 'right')

        # Msgs column (right-aligned number + " msgs", bold cyan if >= 100)
        if msgs >= 100:
            msgs_col = _pad_visible(
                f"{BOLD_CYAN}{msgs_num}{R}{DIM} msgs{R}", COL_MSGS, 'right'
            )
        else:
            msgs_col = _pad_visible(f"{DIM}{msgs_num} msgs{R}", COL_MSGS, 'right')

        # Tags column (left-aligned, truncated to fit, magenta for differentiation)
        if branch and branch not in ("main", "master"):
            tag_parts = branch
            if tags_raw:
                tag_parts += f", {tags_raw}"
        else:
            tag_parts = tags_raw
        tags_display = _truncate_tags(tag_parts, COL_TAGS) if tag_parts else ""

        # Session ID column (right-aligned to terminal edge, cyan for actionable)
        sid_col = _pad_visible(f"{CYAN}{short_id}{R}", COL_SID, 'right')

        # Build metadata line: age · msgs · tags (right-aligned sid at edge)
        sep = f" {DIM}\u00b7{R} "
        if tags_display:
            tags_col = f"{MAGENTA}{tags_display}{R}"
            # Calculate padding to right-align session ID to terminal edge
            meta_left = f"{age_col}{sep}{msgs_col}{sep}{tags_col}"
            meta_left_vis = _visible_len(meta_left)
            sid_pad = content - meta_left_vis - COL_SID
            print(f"  {' ' * GUTTER}{meta_left}{' ' * max(1, sid_pad)}{sid_col}")
        else:
            meta_left = f"{age_col}{sep}{msgs_col}"
            meta_left_vis = _visible_len(meta_left)
            sid_pad = content - meta_left_vis - COL_SID
            print(f"  {' ' * GUTTER}{meta_left}{' ' * max(1, sid_pad)}{sid_col}")

        # Explain match (if --explain flag is active)
        if explain and pipeline and raw_query and tokens:
            explanation = pipeline._explain_match(r, tokens, raw_query)
            if explanation:
                for exp_line in explanation.split('\n'):
                    print(f"  {' ' * GUTTER}{GRAY}{THIN_V}{R} {GRAY}{exp_line.strip()}{R}")

        # Separator (skip after last result)
        if i < len(results):
            print(f"  {DIM}{H * cw}{R}")

    # ─── Footer Card ──────────────────────────────────────
    print(f"  {_box_line(TL, H, TR, cw, DIM, R)}")
    footer_text = f"claude-search --resume N  \u00b7  --fzf for interactive"
    print(f"  {DIM}{V}{R} {GREEN}\u25cf{R}  {DIM}{footer_text}{R}{' ' * max(0, inner - len(footer_text) - 3)} {DIM}{V}{R}")
    print(f"  {_box_line(BL, H, BR, cw, DIM, R)}")
    print()


def format_fzf(results):
    """Tab-delimited output for fzf with ANSI colors."""
    for r in results:
        age = format_relative_time(r["created_at"])
        proj = r["project_name"][:20]
        desc = _build_description(r)[:70]
        branch = (r["git_branch"] or "")[:12]
        tags = r.get("tags", "")[:30]
        # session_id is last field (hidden, used for --preview)
        print(f"\033[33m{age:<8}\033[0m \033[35m{proj:<20}\033[0m {desc:<70} \033[32m{branch:<12}\033[0m {tags}\t{r['session_id']}")


def format_json(results):
    print(json.dumps(results, indent=2, default=str))


def _extract_last_messages(session_id, project_path, count=3):
    """Extract last N user messages from transcript JSONL file."""
    projects_dir = Path.home() / ".claude" / "projects"
    # Encode project path: /Users/foo/bar → -Users-foo-bar
    if project_path and project_path != "unknown":
        encoded = project_path.replace("/", "-")
        if not encoded.startswith("-"):
            encoded = "-" + encoded
        transcript = projects_dir / encoded / f"{session_id}.jsonl"
    else:
        transcript = None

    # Try encoded path, then scan all project dirs
    paths_to_try = []
    if transcript and transcript.exists():
        paths_to_try.append(transcript)
    else:
        for d in projects_dir.iterdir():
            candidate = d / f"{session_id}.jsonl"
            if candidate.exists():
                paths_to_try.append(candidate)
                break

    if not paths_to_try:
        return []

    msgs = []
    try:
        with open(paths_to_try[0]) as f:
            for line in f:
                try:
                    d = json.loads(line)
                    if d.get("type") != "user":
                        continue
                    content = d.get("message", {}).get("content", "")
                    if isinstance(content, list):
                        text = " ".join(
                            c.get("text", "") for c in content
                            if isinstance(c, dict) and c.get("type") == "text"
                        )
                    else:
                        text = str(content)
                    text = text.strip()
                    if not text or len(text) < 8:
                        continue
                    if text.startswith("<") or text.startswith("<!--"):
                        continue
                    msgs.append(text[:300])
                except Exception:
                    pass
    except Exception:
        pass

    return msgs[-count:] if msgs else []


def format_preview(session):
    if not session:
        print("Session not found.")
        return

    # ─── Compact metadata header ─────────────────────────
    age = format_relative_time(session['created_at'], compact=True)
    msgs = session['message_count']
    sid = session['session_id'][:8]
    branch = (session.get('git_branch') or '').strip()
    proj = session['project_name'][:30]

    print(f"\033[1;33m{proj}\033[0m  \033[2m{age} \u00b7 {msgs} msgs \u00b7 {sid}\033[0m")
    if branch and branch not in ("main", "master"):
        print(f"\033[2;32m{branch}\033[0m")
    if session.get("tags"):
        tags_display = ", ".join(t.strip() for t in session['tags'].split(',')[:5])
        print(f"\033[2;35m{tags_display}\033[0m")

    # ─── Description (no pre-wrapping — let fzf handle it) ─
    desc = _build_description(session)
    if desc and desc != "(no description)":
        print()
        print(f"\033[1;33mAbout\033[0m:")
        # Print full description up to 800 chars, fzf wraps to pane width
        print(f"  {desc[:800]}")

    # ─── Conversation Timeline (from transcript) ─────────
    last_msgs = _extract_last_messages(
        session["session_id"], session.get("project_path", ""), count=7
    )
    if last_msgs:
        print()
        print(f"\033[1;35mRecent Messages\033[0m:")
        for i, msg in enumerate(last_msgs, 1):
            clean = " ".join(msg.split())[:250]
            print(f"  \033[2m{i}.\033[0m {clean}")
    elif session.get("first_prompt"):
        fp = " ".join(session["first_prompt"].split())[:250]
        if len(fp) > 10:
            print()
            print(f"\033[1;35mFirst Message\033[0m:")
            print(f"  {fp}")


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
    parser.add_argument("--explain", action="store_true", help="Show match explanation for each result")
    parser.add_argument("--analytics", action="store_true", help="Show search log analytics")
    parser.add_argument("--fails", action="store_true", help="Show only zero-result queries (with --analytics)")
    args = parser.parse_args()

    if not DB_PATH.exists():
        print("No index database found. Run session-index-backfill.sh first.", file=sys.stderr)
        sys.exit(1)

    pipeline = QueryPipeline()

    try:
        if args.stats:
            s = pipeline.stats()
            color = _use_color()
            R = "\033[0m" if color else ""
            BOLD = "\033[1m" if color else ""
            DIM = "\033[2m" if color else ""
            WHITE = "\033[38;5;255m" if color else ""
            CYAN = "\033[36m" if color else ""

            _H = "\u2500"
            _TL, _TR, _BL, _BR = "\u256d", "\u256e", "\u2570", "\u256f"
            _V = "\u2502"
            _ML, _MR = "\u251c", "\u2524"

            bw = 52
            inner = bw - 2
            print()
            print(f"  {DIM}{_TL}{_H * bw}{_TR}{R}")
            title = "Session Index"
            total_str = f"{s['total']} sessions"
            sp = inner - len(title) - len(total_str)
            print(f"  {DIM}{_V}{R} {BOLD}{WHITE}{title}{R}{' ' * max(1, sp)}{CYAN}{total_str}{R} {DIM}{_V}{R}")
            print(f"  {DIM}{_ML}{_H * bw}{_MR}{R}")

            rows = [
                ("Tagged", str(s['tagged'])),
                ("Projects", str(s['projects'])),
                ("Last indexed", s['last_indexed'] or "never"),
            ]
            for label, val in rows:
                sp = inner - len(label) - len(val)
                print(f"  {DIM}{_V}{R} {DIM}{label}{R}{' ' * max(1, sp)}{val} {DIM}{_V}{R}")
            print(f"  {DIM}{_BL}{_H * bw}{_BR}{R}")

            print()
            print(f"  {BOLD}{WHITE}By Source{R}")
            print(f"  {DIM}{_H * bw}{R}")
            for src, cnt in s["by_source"]:
                print(f"   {src:<20} {DIM}{cnt}{R}")

            print()
            print(f"  {BOLD}{WHITE}Top Projects{R}")
            print(f"  {DIM}{_H * bw}{R}")
            for proj, cnt in s["by_project"]:
                print(f"   {proj:<35} {DIM}{cnt}{R}")
            print()
            return

        if args.analytics:
            pipeline._show_analytics(fails_only=args.fails)
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

        # Show spinner while searching (cosmetic — search is <5ms)
        is_tty = sys.stdout.isatty()
        if is_tty and args.format == "table":
            sys.stdout.write('  \033[2m\u280b Searching\u2026\033[0m')
            sys.stdout.flush()

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

        # Clear spinner
        if is_tty and args.format == "table":
            sys.stdout.write('\r\033[K')
            sys.stdout.flush()

        pipeline.log_search(query, len(results), pipeline_ms=elapsed_ms)
        _cache_results(results)

        # Reset dedup tracking before rendering
        pipeline.reset_dedup()

        if args.format == "fzf":
            format_fzf(results)
        elif args.format == "json":
            format_json(results)
        else:
            final_tokens = getattr(pipeline, '_final_tokens', [])
            format_table(results, elapsed_ms, pipeline=pipeline, raw_query=query,
                         explain=args.explain, tokens=final_tokens)

    finally:
        pipeline.close()


if __name__ == "__main__":
    main()

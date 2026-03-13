# claude-session-search

Full-text search for Claude Code sessions. Find past conversations instantly with keyword search, temporal queries, synonym expansion, and fzf interactive mode.

## Quick Start

```bash
git clone https://github.com/yourusername/claude-session-search.git
cd claude-session-search
./install.sh                          # Symlinks into ~/.claude/
./scripts/session-index-backfill.sh   # Index existing sessions
echo 'export PATH="$HOME/.claude/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

## Usage

```bash
claude-search "bottle menu"                # Keyword search
claude-search "monitoring last week"       # Temporal query
claude-search --fzf "migration"            # Interactive fzf picker
claude-search --after 2026-03-01 "rum"     # Date filter
claude-search --project reso "sync"        # Project filter
claude-search --json "floor plan"          # JSON output
claude-search --stats                      # Index statistics
```

### fzf Interactive Mode

`claude-search --fzf "query"` opens an interactive picker:
- **Enter**: Resume selected session with `claude --resume`
- **Ctrl-Y**: Copy session ID to clipboard
- **Ctrl-O**: Open project directory
- Type to re-search in real-time

## How It Works

### Indexing

Sessions are automatically indexed on `SessionEnd` via Claude Code hooks. The indexer reads from `sessions-index.json` (Claude's per-project session metadata) which contains summaries, message counts, git branches, and timestamps.

A one-time backfill script indexes all historical sessions from:
1. `sessions-index.json` (richest — has AI-generated summaries)
2. `history.jsonl` (gap fill — has user prompts)
3. Legacy entries without session IDs (synthetic grouping)

### Search Pipeline

```
Query → Normalize → Temporal extraction → Synonym expansion → Fuzzy correction
     → FTS5 MATCH (BM25 column weights) → Recency boost → Ranked results
```

- **Synonym expansion**: `db` → database/turso/sqlite, `bottle` → bottle service/menu/catalog
- **Temporal queries**: "last week", "yesterday", "march 1", "last 3 days"
- **Progressive relaxation**: AND → OR → core terms → prefix match
- **BM25 weights**: summary(10x), tags(8x), keywords(3x), first_prompt(2x), project(1x)
- **Recency boost**: `score * (1 + exp(-0.05 * days_old))`

### Enrichment (Optional)

Tag sessions with Claude Haiku for better search recall:

```bash
# Regex-only (free, ~40% accuracy)
./scripts/session-index-tag.sh --regex-only

# With Haiku API (~$0.09 for 650 sessions, ~95% accuracy)
ANTHROPIC_API_KEY=sk-... ./scripts/session-index-tag.sh
```

## Architecture

```
~/.claude/
├── session-index.db           # SQLite FTS5 database
├── hooks/
│   ├── session-index-end.sh   # SessionEnd hook (indexes on completion)
│   ├── session-index-start.sh # SessionStart hook (injects context)
│   └── lib/
│       └── session-index-helpers.sh  # Shared library
├── bin/
│   ├── claude-search          # Bash fzf wrapper
│   └── session-search.py      # Python search engine
```

All files are symlinks back to this repo. `git pull && ./install.sh` to update.

## Prerequisites

- `sqlite3` with FTS5 support (macOS default)
- `python3` (3.8+)
- `jq`
- `fzf` (optional, for interactive mode)
- `rapidfuzz` (optional, for fuzzy correction: `pip3 install rapidfuzz`)

## Customization

### Synonyms

Edit `synonyms/default.json` to add domain-specific terms:

```json
[
  {"term": "your-abbreviation", "expansions": ["full term", "alias"], "category": "custom"}
]
```

Re-run `./scripts/session-index-backfill.sh` to reload synonyms.

## Uninstall

```bash
./uninstall.sh  # Removes symlinks + hook entries, preserves DB
rm ~/.claude/session-index.db  # Optional: delete index
```

## License

MIT

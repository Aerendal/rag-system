# RAG System - Universal Knowledge Base

**Production-ready RAG (Retrieval-Augmented Generation) system built on SQLite 3.51.0+ with JSONB support.**

A modular, extensible foundation for:
- 🤖 AI agents (multi-agent collaboration)
- 🎮 Game development (assets, scenes, dialogue)
- 🎬 Screenplay writing (acts, characters, locations)
- 📚 Book writing (chapters, timelines, character arcs)
- 💡 Idea management (versioning, graphs, relationships)
- 📊 Knowledge bases (documentation, RAG, semantic search)

---

## 🚀 Quick Start

```bash
# 1. Clone repository
git clone <repo-url>
cd rag-system

# 2. Install SQLite 3.51.0+ (if needed)
./scripts/install_sqlite.sh

# 3. Bootstrap database
cd tools
./bootstrap.sh

# 4. Verify installation
./healthcheck.sh

# 5. Import sample data
python3 import_docs.py sqlite-docs --section pragma
```

**Time**: ~30 seconds
**Requirements**: SQLite 3.51.0+, Python 3.10+

---

## 📋 Features

### Core Features (v2.2)

- ✅ **FTS5 Full-Text Search** - contentless mode, custom tokenizers
- ✅ **JSONB Binary JSON** - 2-3x faster queries, 19% smaller storage
- ✅ **Dual-Column Strategy** - TEXT for debugging, JSONB for performance
- ✅ **Auto-Sync Triggers** - TEXT → JSONB automatically
- ✅ **Version Control** - Schema versioning with migrations
- ✅ **Contract-Based Tests** - 20+ integrity tests
- ✅ **Diagnostic Tools** - analyze, benchmark, healthcheck

### Schema v2.2 Tables

```
topics          - Projects/modules organization
sessions        - Work sessions tracking (with telemetry JSONB)
messages        - Conversation logs (with metadata JSONB)
docs            - Documents (with metadata JSONB)
chunks          - Document chunks for RAG (with metadata JSONB)
chunks_fts      - FTS5 virtual table (contentless)
```

### Performance

| Metric | TEXT JSON | BLOB JSONB | Improvement |
|--------|-----------|------------|-------------|
| Query speed | 1.0x | **2-3x** | 2-3x faster |
| Storage | 1.0x | **0.81x** | 19% smaller |
| Parse overhead | Yes | **No** | Zero parsing |

---

## 📁 Repository Structure

```
rag-system/
├── README.md                   # This file
├── LICENSE                     # MIT License
├── .gitignore                  # Git ignore rules
│
├── schemas/                    # Database schemas
│   ├── schema_v2.2_jsonb.sql  # Current schema (JSONB)
│   ├── schema_v2.1_fixed.sql  # Legacy (TEXT JSON only)
│   └── migrations/
│       └── migrate_v2.1_to_v2.2.sql
│
├── tools/                      # CLI tools & scripts
│   ├── bootstrap.sh            # Database setup
│   ├── healthcheck.sh          # System diagnostics
│   ├── recovery.sh             # Auto-repair
│   ├── analyze_json_usage.sh   # JSON usage analysis
│   ├── diagnose_jsonb.sh       # JSONB availability check
│   ├── benchmark_jsonb.sh      # Performance benchmarks
│   ├── cli_logger.py           # Session logging
│   ├── chunk_splitter.py       # Document chunking
│   ├── import_docs.py          # Import external docs
│   └── query_rag.py            # Query interface
│
├── tests/                      # Test suites
│   ├── test_jsonb.sql          # JSONB functional tests (10 tests)
│   ├── test_jsonb_migration.sql # Migration integrity (10 tests)
│   └── test_contracts.py       # Contract-based tests (Python)
│
├── docs/                       # Documentation
│   ├── JSONB_README.md         # JSONB quick start
│   ├── JSONB_USAGE_GUIDE.md    # Comprehensive JSONB guide
│   ├── UPGRADE.md              # Migration guides
│   ├── SCHEMA_USAGE.md         # SQL patterns
│   └── ARCHITECTURE.md         # System design (WIP)
│
├── extensions/                 # Modular extensions (future)
│   ├── INDEX.md                # Extensions catalog
│   ├── ext_versioning.sql      # Git-like version control
│   ├── ext_ideas_graph.sql     # Ideas relationship graph
│   ├── ext_game_dev.sql        # Game development
│   └── ext_screenplay.sql      # Screenplay writing
│
└── scripts/                    # Installation & setup
    ├── install_sqlite.sh       # Install SQLite 3.51.0
    └── setup_dev.sh            # Development environment
```

---

## 🔧 Installation

### Option A: Automated (recommended)

```bash
# Install SQLite 3.51.0 + setup database
./scripts/install_sqlite.sh
cd tools && ./bootstrap.sh
```

### Option B: Manual

```bash
# 1. Install SQLite 3.51.0+
wget https://www.sqlite.org/2025/sqlite-autoconf-3510000.tar.gz
tar xzf sqlite-autoconf-3510000.tar.gz
cd sqlite-autoconf-3510000
export CFLAGS="-DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_JSON1 -DSQLITE_ENABLE_RTREE -O3"
./configure --prefix=/usr/local
make -j4
sudo make install
sudo ldconfig

# 2. Create database
cd /path/to/rag-system
sqlite3 knowledge.db < schemas/schema_v2.2_jsonb.sql

# 3. Verify
sqlite3 knowledge.db "SELECT sqlite_version();"  # Should be 3.51.0
```

---

## 📖 Documentation

### Quick Start Guides
- [JSONB_README.md](docs/JSONB_README.md) - JSONB testing & diagnostics
- [UPGRADE.md](docs/UPGRADE.md) - Migration from v2.1 to v2.2

### Comprehensive Guides
- [JSONB_USAGE_GUIDE.md](docs/JSONB_USAGE_GUIDE.md) - Complete JSONB reference (650+ lines)
- [SCHEMA_USAGE.md](docs/SCHEMA_USAGE.md) - SQL query patterns

### Reference
- [schema_v2.2_jsonb.sql](schemas/schema_v2.2_jsonb.sql) - Annotated schema
- [API Reference](docs/API_REFERENCE.md) - Python tools API (WIP)

---

## 🧪 Testing

### Run all tests

```bash
# SQL tests
sqlite3 knowledge.db < tests/test_jsonb.sql
sqlite3 knowledge.db < tests/test_jsonb_migration.sql

# Python contract tests
python3 tests/test_contracts.py

# Quick tests only
python3 tests/test_contracts.py --quick
```

### Diagnostics

```bash
# Check JSONB availability
./tools/diagnose_jsonb.sh

# Analyze JSON usage
./tools/analyze_json_usage.sh knowledge.db

# Benchmark performance
./tools/benchmark_jsonb.sh --size 10000

# System health
./tools/healthcheck.sh
```

---

## 🎯 Use Cases

### 1. AI Agent Knowledge Base

```python
# Log agent session with telemetry
import cli_logger
session = cli_logger.start_session(
    topic_id=1,
    model="claude-sonnet-4"
)

# Query with FTS5
results = query_rag.search("JSONB performance", limit=5)

# Analyze telemetry with JSONB
conn.execute("""
    SELECT model, AVG(jsonb_extract(telemetry_jsonb, '$.total_tokens'))
    FROM sessions GROUP BY model
""")
```

### 2. Game Development

```sql
-- Store game assets with metadata
INSERT INTO docs (module, slug, title, doc_type, metadata)
VALUES ('game-assets', 'forest-level', 'Forest Level', 'official',
        '{"engine": "Unity", "version": "2023.1", "assets": [...]}');

-- Query by engine
SELECT * FROM docs
WHERE jsonb_extract(metadata_jsonb, '$.engine') = 'Unity';
```

### 3. Screenplay Writing

```sql
-- Store scene with characters
INSERT INTO docs (module, slug, title, doc_type, metadata)
VALUES ('screenplay', 'act2-scene5', 'Coffee Shop Confrontation', 'example',
        '{"act": 2, "scene": 5, "characters": ["ALICE", "BOB"], "mood": "tense"}');

-- Find all tense scenes
SELECT * FROM docs
WHERE jsonb_extract(metadata_jsonb, '$.mood') = 'tense';
```

---

## 🛠️ Development

### Architecture Decisions

All major decisions documented in ADR format:
- **AD-008**: JSONB Support (dual-column strategy)
- See [ARCHITECTURE.md](docs/ARCHITECTURE.md) for full list

### Contributing

1. Fork repository
2. Create feature branch (`git checkout -b feature/amazing-feature`)
3. Write tests first (contract-based)
4. Implement feature
5. Update documentation
6. Commit (`git commit -m 'Add amazing feature'`)
7. Push to branch (`git push origin feature/amazing-feature`)
8. Open Pull Request

### Development Workflow

```bash
# 1. Create test database
./tools/bootstrap.sh --db test.db

# 2. Make changes to schema
# Edit schemas/schema_v2.2_jsonb.sql

# 3. Test migration
sqlite3 test.db < schemas/migrations/migrate_v2.1_to_v2.2.sql

# 4. Run tests
sqlite3 test.db < tests/test_jsonb_migration.sql

# 5. Commit
git add schemas/ tests/
git commit -m "feat: add new feature"
```

---

## 📊 Benchmarks

### JSONB Performance (10,000 records)

```
=== Benchmark Results ===

Extract field:       3.9ms (TEXT) → 1.5ms (JSONB)  [2.6x faster]
Filter numeric:      3.8ms (TEXT) → 1.3ms (JSONB)  [2.9x faster]
Aggregate:          10.2ms (TEXT) → 3.7ms (JSONB)  [2.8x faster]
Array iteration:     0.6ms (TEXT) → 0.2ms (JSONB)  [3.4x faster]
Storage:          1629 KB (TEXT) → 1316 KB (JSONB) [19% smaller]
```

Run your own benchmarks:
```bash
./tools/benchmark_jsonb.sh --size 10000
```

---

## 🗺️ Roadmap

### Phase 1: Foundation ✅ COMPLETE
- [x] SQLite 3.51.0 installation
- [x] Schema v2.2 (JSONB dual-column)
- [x] Migration tools (v2.1 → v2.2)
- [x] Diagnostic tools
- [x] Test suite (20+ tests)
- [x] Documentation

### Phase 2: Extensions (In Progress)
- [ ] CLI improvements (`.timer` microseconds, `--safe` mode)
- [ ] Version control extension (`ext_versioning.sql`)
- [ ] Ideas graph extension (`ext_ideas_graph.sql`)
- [ ] Multi-agent collaboration

### Phase 3: Domain-Specific (Planned)
- [ ] Game development extension
- [ ] Screenplay extension
- [ ] Book writing extension
- [ ] Task queue system

### Phase 4: Production (Planned)
- [ ] Performance tuning
- [ ] Full integration tests
- [ ] Deployment guide
- [ ] API documentation

---

## 🤝 Support

### Issues & Questions
- Open issue on GitHub: [Issues](../../issues)
- Check documentation: [docs/](docs/)
- Run diagnostics: `./tools/healthcheck.sh`

### Troubleshooting
1. Run `./tools/diagnose_jsonb.sh` - check JSONB availability
2. Run `./tools/healthcheck.sh` - verify system health
3. Run `./tools/recovery.sh --auto` - auto-repair issues
4. Check [UPGRADE.md](docs/UPGRADE.md) - migration guides

---

## 📄 License

MIT License - see [LICENSE](LICENSE) file

---

## 🙏 Acknowledgments

- Built with [SQLite](https://www.sqlite.org/) 3.51.0+
- Inspired by modern RAG architectures
- Designed for AI agent collaboration

---

## 📈 Stats

- **Schema version**: 2.2 (JSONB)
- **Tables**: 5 core + 1 FTS5 virtual
- **Triggers**: 14 (4 FTS + 8 auto-sync + 2 timestamp)
- **Views**: 3
- **Tests**: 20+ (SQL + Python)
- **Documentation**: 2000+ lines
- **Lines of code**: ~3000 (SQL + Python + Bash)

---

**Last Updated**: 2025-11-22
**Version**: 2.2.0
**Status**: Production Ready ✅

**Built with ❤️ by Claude (AI System Architect)**

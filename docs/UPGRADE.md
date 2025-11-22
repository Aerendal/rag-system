# UPGRADE GUIDE - RAG System v2.1

**From**: Schema v1.0 (buggy FTS5)
**To**: Schema v2.1 (fixed, production-ready)
**Date**: 2025-11-22
**Author**: Claude (AI System Architect)

---

## 🎯 Co się zmieniło?

### ✅ **NAPRAWIONE**:
1. **FTS5 contentless mode** - proper solution, nie półśrodek
2. **Triggery** - poprawnie łączą dane z `docs` i `chunks`
3. **topic_id i module w FTS** - teraz działają (JOIN przez trigger)
4. **Dodany trigger `docs_fts_au`** - aktualizuje FTS gdy zmieni się module/topic_id

###  **DODANE**:
1. **bootstrap.sh** - postaw system od zera (idempotentny, fail-safe)
2. **healthcheck.sh** - diagnostyka bez blokowania (non-blocking philosophy)
3. **recovery.sh** - auto-repair + manual overrides
4. **test_contracts.py** - elastyczne testy (contract-based, nie implementation)

### 🔧 **ULEPSZONE**:
1. Python tools - zero dependencies (stdlib only)
2. Schema versioning (`PRAGMA user_version = 2`)
3. Dokumentacja - kompletna, z przykładami

---

## 🚀 Quick Start (nowy system)

```bash
# 1. Bootstrap (stwórz bazę)
cd /home/jerzy/rag_tools
./bootstrap.sh

# 2. Healthcheck (zweryfikuj)
./healthcheck.sh

# 3. Test (sprawdź kontrakty)
python3 test_contracts.py --quick

# 4. Import danych (opcjonalnie)
python3 import_docs.py sqlite-docs --section pragma

# 5. Query
python3 query_rag.py search "checkpoint" --limit 5
```

**Czas setupu**: ~30 sekund
**Zależności**: Python 3.x + SQLite 3.37.2+

---

## 📦 Migration (jeśli masz starą bazę)

### Opcja A: Start from scratch (zalecane dla <1000 chunków)

```bash
# 1. Backup old database
cp sqlite_knowledge.db sqlite_knowledge.db.old

# 2. Bootstrap new database
./rag_tools/bootstrap.sh --force

# 3. Re-import data (jeśli miałeś)
# (use import_docs.py for docs, cli_logger.py for sessions)
```

### Opcja B: In-place migration (dla dużych baz)

```bash
# 1. Backup
cp sqlite_knowledge.db sqlite_knowledge.db.backup

# 2. Export current data
sqlite3 sqlite_knowledge.db <<EOF
.mode insert chunks
.output chunks_backup.sql
SELECT * FROM chunks;
.output docs_backup.sql
SELECT * FROM docs;
-- ... (repeat for other tables)
EOF

# 3. Drop old FTS, recreate with new schema
sqlite3 sqlite_knowledge.db <<EOF
DROP TABLE chunks_fts;
-- (paste FTS5 creation + triggers from schema_v2_fixed.sql)
EOF

# 4. Rebuild FTS from existing data
sqlite3 sqlite_knowledge.db <<EOF
INSERT INTO chunks_fts(rowid, text, heading, doc_id, topic_id, module)
SELECT c.id, c.text, c.heading, c.doc_id, d.topic_id, d.module
FROM chunks c
JOIN docs d ON d.id = c.doc_id;
EOF

# 5. Verify
./rag_tools/healthcheck.sh
```

---

## 🧪 Testing

```bash
# Quick tests (schema + data integrity)
python3 rag_tools/test_contracts.py --quick

# Full test suite
python3 rag_tools/test_contracts.py

# Specific test class
python3 rag_tools/test_contracts.py SchemaContract

# Check database health
./rag_tools/healthcheck.sh

# Run recovery if issues found
./rag_tools/recovery.sh --auto
```

---

## 📊 Performance Expectations

| Metric | Target | Notes |
|--------|--------|-------|
| FTS5 search | <100ms | For 10k chunks |
| Insert chunk | <10ms | With FTS trigger |
| Bootstrap time | <30s | Fresh database |
| Healthcheck | <5s | Full check |
| Recovery (FTS rebuild) | <5s | Per 10k chunks |

---

## 🐛 Troubleshooting

### "FTS5 out of sync"

```bash
./rag_tools/recovery.sh --rebuild-fts
```

### "Foreign key constraint failed"

```bash
# Check violations
sqlite3 sqlite_knowledge.db "PRAGMA foreign_key_check;"

# Auto-fix (if possible)
./rag_tools/recovery.sh --fix-fk
```

### "Database locked"

```bash
# Checkpoint WAL
./rag_tools/recovery.sh --checkpoint
```

### "Tests failing"

```bash
# Check schema version
sqlite3 sqlite_knowledge.db "PRAGMA user_version;"

# Should be 2 for v2.1
# If 0 or 1, recreate with schema_v2_fixed.sql
```

---

## 📁 Files Reference

```
/home/jerzy/
├── schema_v2_fixed.sql         # PRODUCTION schema (use this!)
├── schema_no_vec.sql           # OLD schema (deprecated)
├── schema_v2.sql               # Intermediate (buggy FTS5)
├── UPGRADE.md                  # This file
├── SCHEMA_USAGE.md             # SQL patterns
├── CLAUDE.md                   # Architectural decisions
└── rag_tools/
    ├── bootstrap.sh            # Setup system
    ├── healthcheck.sh          # Diagnostics
    ├── recovery.sh             # Repairs
    ├── test_contracts.py       # Tests
    ├── cli_logger.py           # Log sessions
    ├── chunk_splitter.py       # Split docs
    ├── import_docs.py          # Import external docs
    ├── query_rag.py            # Search/query
    ├── requirements.txt        # Dependencies (none!)
    └── README.md               # Tools guide
```

---

## ✅ Success Criteria

After upgrade, verify:

- [ ] `./bootstrap.sh --check` passes
- [ ] `./healthcheck.sh` shows 0 issues
- [ ] `python3 test_contracts.py --quick` all green
- [ ] FTS5 search returns results: `python3 query_rag.py search "test"`
- [ ] Can log session: `python3 cli_logger.py start --topic-id 1`
- [ ] Can import docs: `python3 import_docs.py sqlite-docs --section pragma`

---

## 🎓 Key Learnings

### Why FTS5 contentless?

**Problem**: `chunks` table doesn't have `topic_id`/`module` (they're in `docs`)

**Bad solution** (v1): `content='chunks'` + triggers trying to read non-existent columns → **FAILS**

**Good solution** (v2.1): `content=''` + triggers with JOIN → **WORKS**

**Benefit**: Full control, can add FTS columns from any table, no duplication

### Why contract-based tests?

**Problem**: Implementation tests break on refactoring → development slows down

**Solution**: Test BEHAVIOR (what system promises), not HOW (implementation details)

**Example**:
```python
# ✓ GOOD (contract test)
def test_fts_syncs_with_chunks():
    """CONTRACT: FTS5 must stay in sync with chunks."""
    # Insert chunk, check FTS has it
    # Delete chunk, check FTS removed it

# ✗ BAD (implementation test)
def test_trigger_calls_specific_sql():
    """Test trigger uses exact SQL..."""
    # Breaks when you improve the trigger!
```

### Why bootstrap/healthcheck/recovery trinity?

- **bootstrap.sh**: Get system running (idempotent, fail-safe)
- **healthcheck.sh**: Know what's wrong (non-blocking, informative)
- **recovery.sh**: Fix what's wrong (auto-repair safe issues, ask for destructive ones)

**Philosophy**: System that can self-heal > perfect system that breaks unpredictably

---

## 📞 Support

### Issues?
1. Run `./healthcheck.sh` - see what's wrong
2. Run `./recovery.sh` - try auto-fix
3. Check logs in `CLAUDE.md` Decision Log
4. Re-bootstrap if <1000 chunks: `./bootstrap.sh --force`

### Want to contribute?
1. Tests first: Add to `test_contracts.py`
2. Document decisions: Update `CLAUDE.md`
3. Keep it simple: Stdlib > dependencies

---

**Last Updated**: 2025-11-22
**Schema Version**: 2.1.1 (FINAL)
**Status**: ✅ PRODUCTION READY (TESTED)

---

## 🎉 Verification Summary

All systems verified and working:

- ✅ **Schema v2.1.1**: FTS5 contentless with proper delete triggers
- ✅ **Contract Tests**: 10/10 tests passed (6 quick + 4 tools)
- ✅ **Bootstrap**: Creates database successfully with schema_v2_fixed.sql
- ✅ **Import**: Imports documents and chunks correctly
- ✅ **FTS5 Search**: Full-text search working with contentless mode
- ✅ **Triggers**: All 4 FTS triggers working (ai, au, ad, docs_fts_au)
- ✅ **End-to-End**: Complete workflow tested (bootstrap → import → query)

**Test Command**:
```bash
python3 rag_tools/test_contracts.py  # All 10 tests pass
```

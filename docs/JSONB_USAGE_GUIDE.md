# JSONB Usage Guide - RAG System

**Complete guide to using JSONB (Binary JSON) in the RAG system**

SQLite 3.51.0 introduced JSONB - a binary JSON format that's 2-3x faster for queries and ~19% smaller than TEXT JSON.

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [Dual-Column Strategy](#dual-column-strategy)
3. [JSONB Functions Reference](#jsonb-functions-reference)
4. [Common Query Patterns](#common-query-patterns)
5. [Performance Best Practices](#performance-best-practices)
6. [Migration Workflow](#migration-workflow)
7. [Troubleshooting](#troubleshooting)

---

## Quick Start

### Check if JSONB is available

```bash
cd /home/jerzy/rag_tools
./diagnose_jsonb.sh
```

**Output** (if SQLite 3.51.0+):
```
✓ JSONB is available (SQLite 3.51.0)
✓ All JSONB functions working
```

### Create new database with JSONB

```bash
cd /home/jerzy/rag_tools
./bootstrap.sh --force
```

Bootstrap auto-detects SQLite 3.51.0+ and uses schema v2.2 (JSONB dual-column).

### Migrate existing database

```bash
cd /home/jerzy
sqlite3 sqlite_knowledge.db < rag_tools/migrate_v2.1_to_v2.2.sql
```

---

## Dual-Column Strategy

Schema v2.2 uses **dual-column approach** for all metadata:

```sql
CREATE TABLE docs (
    id INTEGER PRIMARY KEY,
    module TEXT NOT NULL,

    -- Dual-column: TEXT for debugging, JSONB for performance
    metadata        TEXT,  -- Human-readable, for debugging
    metadata_jsonb  BLOB   -- Binary, for fast queries
);
```

### How it works

1. **Write to TEXT column** (human writes JSON string)
2. **Auto-sync trigger** converts TEXT → JSONB automatically
3. **Read from JSONB column** for fast queries
4. **Debug with TEXT column** when needed

### Example

```sql
-- Insert document with TEXT JSON
INSERT INTO docs (module, slug, title, doc_type, metadata)
VALUES ('ai-core', 'rag-intro', 'RAG Introduction', 'official',
        '{"author": "claude", "version": "1.0", "tags": ["rag", "sqlite"]}');

-- Auto-sync trigger fires → metadata_jsonb is created automatically

-- Query with JSONB (fast)
SELECT
    id,
    module,
    jsonb_extract(metadata_jsonb, '$.author') AS author,
    jsonb_extract(metadata_jsonb, '$.version') AS version
FROM docs
WHERE metadata_jsonb IS NOT NULL;

-- Debug with TEXT (human-readable)
SELECT
    id,
    module,
    metadata  -- Shows: {"author": "claude", "version": "1.0", ...}
FROM docs;
```

---

## JSONB Functions Reference

### 1. `jsonb(text)` - Convert TEXT → JSONB

```sql
-- Manual conversion (usually done by triggers)
UPDATE docs
SET metadata_jsonb = jsonb(metadata)
WHERE metadata IS NOT NULL;
```

### 2. `json(blob)` - Convert JSONB → TEXT

```sql
-- Convert JSONB back to TEXT for debugging
SELECT
    id,
    json(metadata_jsonb) AS readable_json
FROM docs
WHERE metadata_jsonb IS NOT NULL;
```

### 3. `jsonb_extract(blob, path)` - Extract field

**Most common function** - like `json_extract()` but for JSONB.

```sql
-- Extract single field
SELECT
    id,
    jsonb_extract(metadata_jsonb, '$.author') AS author,
    jsonb_extract(metadata_jsonb, '$.version') AS version,
    jsonb_extract(metadata_jsonb, '$.tags[0]') AS first_tag
FROM docs
WHERE metadata_jsonb IS NOT NULL;
```

**Path syntax**:
- `$.field` - top-level field
- `$.nested.field` - nested object
- `$.array[0]` - array element by index
- `$.array[#]` - all array elements (use with `jsonb_each()`)

### 4. `jsonb_each(blob)` - Iterate over object/array

```sql
-- Iterate over JSON object keys
SELECT
    d.id,
    d.module,
    key.key AS field_name,
    key.value AS field_value
FROM docs d,
     jsonb_each(d.metadata_jsonb) key
WHERE d.metadata_jsonb IS NOT NULL;

-- Iterate over JSON array
SELECT
    d.id,
    d.module,
    tag.value AS tag
FROM docs d,
     jsonb_each(jsonb_extract(d.metadata_jsonb, '$.tags')) tag
WHERE d.metadata_jsonb IS NOT NULL;
```

**Output columns**:
- `key` - object key or array index
- `value` - value (as JSON)
- `type` - value type (text, integer, object, array, null)
- `atom` - atomic value (for primitives)
- `id` - unique identifier
- `parent` - parent node ID
- `fullkey` - full path to this element
- `path` - JSONPath to this element

### 5. `jsonb_tree(blob)` - Hierarchical traversal

**Use when**: Deep traversal of nested JSON structures.

```sql
-- Traverse entire JSON tree
SELECT
    d.id,
    d.module,
    tree.key,
    tree.value,
    tree.type,
    tree.path
FROM docs d,
     jsonb_tree(d.metadata_jsonb) tree
WHERE d.metadata_jsonb IS NOT NULL
  AND tree.type = 'text'  -- Only text values
ORDER BY d.id, tree.path;
```

**Example output**:
```
id  | module   | key    | value      | type    | path
----|----------|--------|------------|---------|---------------
1   | ai-core  |        | {...}      | object  | $
1   | ai-core  | author | claude     | text    | $.author
1   | ai-core  | version| 1.0        | text    | $.version
1   | ai-core  | tags   | [...]      | array   | $.tags
1   | ai-core  | 0      | rag        | text    | $.tags[0]
1   | ai-core  | 1      | sqlite     | text    | $.tags[1]
```

**Use cases**:
- Search all fields containing specific value
- Validate schema (check required fields exist)
- Build search indexes from nested data
- Extract all leaf values

### 6. `jsonb_set(blob, path, value)` - Modify JSONB

```sql
-- Update specific field in JSONB
UPDATE docs
SET metadata_jsonb = jsonb_set(metadata_jsonb, '$.version', '"2.0"')
WHERE id = 1;

-- Note: value must be valid JSON string
```

---

## Common Query Patterns

### Pattern 1: Filter by JSON field

```sql
-- Find all docs by specific author
SELECT id, module, title
FROM docs
WHERE jsonb_extract(metadata_jsonb, '$.author') = 'claude';

-- Find sessions with high token usage
SELECT id, model, started_at
FROM sessions
WHERE jsonb_extract(telemetry_jsonb, '$.total_tokens') > 10000
ORDER BY jsonb_extract(telemetry_jsonb, '$.total_tokens') DESC;
```

### Pattern 2: Aggregate by JSON field

```sql
-- Average tokens by model
SELECT
    model,
    COUNT(*) AS session_count,
    AVG(jsonb_extract(telemetry_jsonb, '$.total_tokens')) AS avg_tokens,
    MAX(jsonb_extract(telemetry_jsonb, '$.total_tokens')) AS max_tokens
FROM sessions
WHERE telemetry_jsonb IS NOT NULL
GROUP BY model
ORDER BY avg_tokens DESC;
```

### Pattern 3: Extract array elements

```sql
-- Get all tools used across sessions
SELECT DISTINCT
    tool.value AS tool_name,
    COUNT(*) AS usage_count
FROM sessions s,
     jsonb_each(jsonb_extract(s.telemetry_jsonb, '$.tool_calls')) tool
WHERE s.telemetry_jsonb IS NOT NULL
GROUP BY tool.value
ORDER BY usage_count DESC;
```

### Pattern 4: Complex nested extraction

```sql
-- Extract nested metadata from docs
SELECT
    d.id,
    d.module,
    jsonb_extract(d.metadata_jsonb, '$.embedding.model') AS embedding_model,
    jsonb_extract(d.metadata_jsonb, '$.embedding.dimensions') AS dimensions,
    jsonb_extract(d.metadata_jsonb, '$.chunk_strategy') AS strategy
FROM docs d
WHERE d.metadata_jsonb IS NOT NULL
  AND jsonb_extract(d.metadata_jsonb, '$.embedding') IS NOT NULL;
```

### Pattern 5: Search in nested structures (jsonb_tree)

```sql
-- Find all docs mentioning "gpt-4" anywhere in metadata
SELECT DISTINCT
    d.id,
    d.module,
    d.title,
    tree.path AS found_at,
    tree.value AS value
FROM docs d,
     jsonb_tree(d.metadata_jsonb) tree
WHERE tree.value LIKE '%gpt-4%'
ORDER BY d.id;
```

### Pattern 6: Conditional updates based on JSON

```sql
-- Update priority for sessions with errors
UPDATE sessions
SET notes = 'High priority - has errors'
WHERE jsonb_extract(telemetry_jsonb, '$.errors') != '[]'
  AND notes IS NULL;
```

---

## Performance Best Practices

### 1. Always prefer JSONB for queries

```sql
-- ✗ SLOW (parses TEXT JSON every time)
SELECT * FROM docs
WHERE json_extract(metadata, '$.author') = 'claude';

-- ✓ FAST (binary JSONB, no parsing)
SELECT * FROM docs
WHERE jsonb_extract(metadata_jsonb, '$.author') = 'claude';
```

**Performance gain**: 2-3x faster queries.

### 2. Index frequently queried JSON paths

While SQLite doesn't directly index JSONB columns, you can create computed columns:

```sql
-- Create computed column for frequently queried field
ALTER TABLE docs ADD COLUMN author_computed TEXT
    GENERATED ALWAYS AS (jsonb_extract(metadata_jsonb, '$.author')) STORED;

-- Index the computed column
CREATE INDEX idx_docs_author ON docs(author_computed);

-- Query using indexed column
SELECT * FROM docs
WHERE author_computed = 'claude';
```

### 3. Batch JSONB conversions

```sql
-- ✗ SLOW (row-by-row)
-- (Auto-sync triggers do this, but for manual migration use batches)

-- ✓ FAST (bulk update)
UPDATE docs
SET metadata_jsonb = jsonb(metadata)
WHERE metadata IS NOT NULL
  AND metadata_jsonb IS NULL;
```

### 4. Use jsonb_each vs jsonb_tree

- **`jsonb_each()`**: One level (object keys or array elements)
- **`jsonb_tree()`**: Full tree traversal (slower, but comprehensive)

```sql
-- ✓ Use jsonb_each() for simple cases
SELECT tool.value
FROM sessions s,
     jsonb_each(jsonb_extract(s.telemetry_jsonb, '$.tool_calls')) tool;

-- ✓ Use jsonb_tree() only when you need full traversal
SELECT tree.path, tree.value
FROM docs d,
     jsonb_tree(d.metadata_jsonb) tree
WHERE tree.value LIKE '%keyword%';
```

### 5. Keep TEXT JSON for debugging only

```sql
-- ✓ Use JSONB for application queries
SELECT id, jsonb_extract(metadata_jsonb, '$.author') FROM docs;

-- ✓ Use TEXT JSON for manual inspection
SELECT id, metadata FROM docs LIMIT 5;
```

---

## Migration Workflow

### Step 1: Diagnose current database

```bash
./rag_tools/analyze_json_usage.sh sqlite_knowledge.db > analysis_report.txt
```

**Review**:
- How much JSON data you have
- Estimated migration time
- Projected storage savings

### Step 2: Backup database

```bash
cp sqlite_knowledge.db sqlite_knowledge.db.backup_$(date +%Y%m%d)
```

### Step 3: Run migration

```bash
sqlite3 sqlite_knowledge.db < rag_tools/migrate_v2.1_to_v2.2.sql
```

**Migration features**:
- Non-destructive (adds columns, doesn't drop)
- Auto-sync triggers installed
- Batch processing for large databases
- Reversible (TEXT JSON preserved)

### Step 4: Verify migration

```bash
sqlite3 sqlite_knowledge.db < rag_tools/test_jsonb_migration.sql
```

**Expected output**:
```
✓ Test 1: Schema version v2.2
✓ Test 2: JSONB columns exist
✓ Test 3: Auto-sync triggers installed
...
All migration integrity tests passed!
```

### Step 5: Update application code (optional)

Replace `json_extract()` with `jsonb_extract()`:

```python
# Before (v2.1)
cursor.execute("""
    SELECT id, json_extract(metadata, '$.author')
    FROM docs WHERE id = ?
""", (doc_id,))

# After (v2.2)
cursor.execute("""
    SELECT id, jsonb_extract(metadata_jsonb, '$.author')
    FROM docs WHERE id = ?
""", (doc_id,))
```

**Note**: Not required if using dual-column strategy - TEXT JSON still works!

---

## Troubleshooting

### Issue: "no such function: jsonb"

**Cause**: SQLite < 3.51.0

**Solution**:
```bash
sqlite3 --version  # Check version
# If < 3.51.0, upgrade SQLite (see UPGRADE.md)
```

### Issue: "metadata_jsonb is NULL"

**Cause**: Auto-sync trigger didn't fire, or TEXT JSON is NULL

**Solution**:
```sql
-- Check if TEXT JSON exists
SELECT id, metadata IS NOT NULL, metadata_jsonb IS NOT NULL
FROM docs LIMIT 5;

-- Manual sync if needed
UPDATE docs
SET metadata_jsonb = jsonb(metadata)
WHERE metadata IS NOT NULL AND metadata_jsonb IS NULL;
```

### Issue: "TEXT ↔ JSONB mismatch"

**Cause**: TEXT JSON was modified without updating JSONB

**Solution**:
```sql
-- Re-sync TEXT → JSONB
UPDATE docs
SET metadata_jsonb = jsonb(metadata)
WHERE metadata IS NOT NULL;

-- Verify sync
SELECT id, metadata = json(metadata_jsonb) AS is_synced
FROM docs
WHERE metadata IS NOT NULL;
```

### Issue: "JSONB queries slow"

**Possible causes**:
1. Using TEXT JSON instead of JSONB
2. No indexes on frequently queried paths
3. Large JSON documents

**Solutions**:
```sql
-- 1. Verify using JSONB (not TEXT)
EXPLAIN QUERY PLAN
SELECT * FROM docs
WHERE jsonb_extract(metadata_jsonb, '$.author') = 'claude';

-- 2. Create computed column + index
ALTER TABLE docs ADD COLUMN author_idx TEXT
    GENERATED ALWAYS AS (jsonb_extract(metadata_jsonb, '$.author')) STORED;
CREATE INDEX idx_docs_author_jsonb ON docs(author_idx);

-- 3. Check JSON document sizes
SELECT
    AVG(LENGTH(metadata_jsonb)) AS avg_size_bytes,
    MAX(LENGTH(metadata_jsonb)) AS max_size_bytes
FROM docs;
```

---

## Advanced Use Cases

### Use Case 1: Session Telemetry Analysis

```sql
-- Find sessions with errors and high token usage
SELECT
    s.id,
    s.model,
    s.started_at,
    jsonb_extract(s.telemetry_jsonb, '$.total_tokens') AS tokens,
    json(jsonb_extract(s.telemetry_jsonb, '$.errors')) AS errors,
    json(jsonb_extract(s.telemetry_jsonb, '$.tool_calls')) AS tools
FROM sessions s
WHERE jsonb_extract(s.telemetry_jsonb, '$.total_tokens') > 10000
  AND jsonb_extract(s.telemetry_jsonb, '$.errors') != '[]'
ORDER BY tokens DESC;
```

### Use Case 2: Document Provenance Tracking

```sql
-- Track document lineage through metadata
WITH RECURSIVE doc_lineage AS (
    -- Base case: starting document
    SELECT
        id,
        module,
        title,
        jsonb_extract(metadata_jsonb, '$.source_doc_id') AS parent_id,
        0 AS depth
    FROM docs
    WHERE id = 42

    UNION ALL

    -- Recursive case: parent documents
    SELECT
        d.id,
        d.module,
        d.title,
        jsonb_extract(d.metadata_jsonb, '$.source_doc_id') AS parent_id,
        l.depth + 1 AS depth
    FROM docs d
    JOIN doc_lineage l ON d.id = l.parent_id
    WHERE l.depth < 10  -- Prevent infinite loops
)
SELECT * FROM doc_lineage ORDER BY depth;
```

### Use Case 3: AI Tool Usage Patterns

```sql
-- Analyze tool usage patterns by model
SELECT
    s.model,
    tool.value AS tool_name,
    COUNT(*) AS usage_count,
    AVG(jsonb_extract(s.telemetry_jsonb, '$.total_tokens')) AS avg_tokens_when_used
FROM sessions s,
     jsonb_each(jsonb_extract(s.telemetry_jsonb, '$.tool_calls')) tool
WHERE s.telemetry_jsonb IS NOT NULL
GROUP BY s.model, tool.value
ORDER BY s.model, usage_count DESC;
```

---

## See Also

- **JSONB_README.md** - Testing and diagnostics
- **schema_v2.2_jsonb.sql** - Full schema with comments
- **migrate_v2.1_to_v2.2.sql** - Migration script
- **test_jsonb_migration.sql** - Integrity tests
- **SQLite JSONB docs**: https://sqlite.org/jsonb.html

---

**Author**: Claude (AI System Architect)
**Date**: 2025-11-22
**Version**: 1.0.0
**Status**: Production Ready ✅

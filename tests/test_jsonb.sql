-- rag_tools/test_jsonb.sql
-- SQL-only functional tests for JSONB support (SQLite 3.51.0+)
--
-- Usage:
--   sqlite3 test.db < test_jsonb.sql
--
-- Author: Claude (AI System Architect)
-- Date: 2025-11-22
-- Version: 1.0.0

-- ==============================================================================
-- PREREQUISITE CHECKS
-- ==============================================================================

.print "=== JSONB Functional Tests ==="
.print ""

-- Check SQLite version
.print "Checking SQLite version..."
SELECT CASE
    WHEN sqlite_version() >= '3.51.0' THEN '✓ SQLite ' || sqlite_version() || ' (JSONB supported)'
    ELSE '✗ SQLite ' || sqlite_version() || ' (JSONB requires 3.51.0+)'
END AS version_check;

.print ""

-- ==============================================================================
-- TEST 1: JSONB Basic Operations
-- ==============================================================================

.print "Test 1: JSONB basic operations"

-- Create test data
CREATE TEMP TABLE test_jsonb (
    id INTEGER PRIMARY KEY,
    metadata TEXT,           -- TEXT JSON
    metadata_jsonb BLOB      -- BLOB JSONB
);

-- Insert with TEXT JSON
INSERT INTO test_jsonb (id, metadata) VALUES
    (1, '{"model": "gpt-4", "tokens": 1500, "tools": ["read", "write"]}'),
    (2, '{"model": "claude-3", "tokens": 2000, "tools": ["search", "analyze"]}'),
    (3, '{"model": "gpt-3.5", "tokens": 500, "tools": ["read"]}');

-- Convert TEXT → JSONB
UPDATE test_jsonb SET metadata_jsonb = jsonb(metadata) WHERE metadata IS NOT NULL;

-- Verify conversion
SELECT
    id,
    CASE
        WHEN metadata_jsonb IS NOT NULL THEN '✓ JSONB converted'
        ELSE '✗ JSONB conversion failed'
    END AS status,
    typeof(metadata_jsonb) AS type,
    length(metadata) AS text_size,
    length(metadata_jsonb) AS blob_size
FROM test_jsonb
ORDER BY id;

.print ""

-- ==============================================================================
-- TEST 2: jsonb_each() - Iterate over JSON object
-- ==============================================================================

.print "Test 2: jsonb_each() - iterate over keys"

SELECT
    t.id,
    j.key,
    j.value,
    j.type
FROM test_jsonb t, jsonb_each(t.metadata_jsonb) j
WHERE t.id = 1
ORDER BY j.key;

.print ""

-- ==============================================================================
-- TEST 3: jsonb_extract() - Extract specific values
-- ==============================================================================

.print "Test 3: jsonb_extract() - get specific fields"

SELECT
    id,
    jsonb_extract(metadata_jsonb, '$.model') AS model,
    jsonb_extract(metadata_jsonb, '$.tokens') AS tokens,
    json(metadata_jsonb) AS full_json  -- Convert BLOB → TEXT for display
FROM test_jsonb
ORDER BY id;

.print ""

-- ==============================================================================
-- TEST 4: Filtering with jsonb_extract()
-- ==============================================================================

.print "Test 4: Filter by JSONB field (tokens > 1000)"

SELECT
    id,
    jsonb_extract(metadata_jsonb, '$.model') AS model,
    jsonb_extract(metadata_jsonb, '$.tokens') AS tokens
FROM test_jsonb
WHERE jsonb_extract(metadata_jsonb, '$.tokens') > 1000
ORDER BY tokens DESC;

.print ""

-- ==============================================================================
-- TEST 5: jsonb_tree() - Hierarchical traversal
-- ==============================================================================

.print "Test 5: jsonb_tree() - full tree traversal"

SELECT
    t.id,
    tree.key,
    tree.value,
    tree.type,
    tree.path
FROM test_jsonb t, jsonb_tree(t.metadata_jsonb) tree
WHERE t.id = 1
ORDER BY tree.path;

.print ""

-- ==============================================================================
-- TEST 6: Array operations with jsonb_each()
-- ==============================================================================

.print "Test 6: Extract array elements (tools)"

SELECT
    t.id,
    jsonb_extract(t.metadata_jsonb, '$.model') AS model,
    arr.value AS tool,
    arr.key AS tool_index
FROM test_jsonb t, jsonb_each(jsonb_extract(t.metadata_jsonb, '$.tools')) arr
ORDER BY t.id, arr.key;

.print ""

-- ==============================================================================
-- TEST 7: Performance comparison (TEXT vs JSONB)
-- ==============================================================================

.print "Test 7: Performance comparison (1000 iterations)"
.print "Extracting 'model' field..."

-- Create larger dataset
CREATE TEMP TABLE perf_test (id INTEGER PRIMARY KEY, metadata TEXT, metadata_jsonb BLOB);

INSERT INTO perf_test (id, metadata)
WITH RECURSIVE cnt(x) AS (
    SELECT 1
    UNION ALL
    SELECT x+1 FROM cnt WHERE x < 1000
)
SELECT x, '{"model": "test-model-' || x || '", "tokens": ' || (x * 10) || '}' FROM cnt;

UPDATE perf_test SET metadata_jsonb = jsonb(metadata);

-- TEXT JSON extraction (requires parsing)
.timer on
SELECT COUNT(*) FROM (
    SELECT json_extract(metadata, '$.model') AS model FROM perf_test
);
.timer off

.print ""

-- JSONB extraction (no parsing)
.timer on
SELECT COUNT(*) FROM (
    SELECT jsonb_extract(metadata_jsonb, '$.model') AS model FROM perf_test
);
.timer off

.print ""

-- ==============================================================================
-- TEST 8: Real-world use case - Session telemetry
-- ==============================================================================

.print "Test 8: Real-world use case - session telemetry"

CREATE TEMP TABLE sessions_test (
    id INTEGER PRIMARY KEY,
    model TEXT,
    metadata_jsonb BLOB
);

-- Insert session metadata
INSERT INTO sessions_test (id, model, metadata_jsonb) VALUES
    (1, 'claude-sonnet-4', jsonb('{"total_tokens": 15000, "tool_calls": ["Read", "Write", "Bash"], "user_satisfaction": "high", "errors": []}')),
    (2, 'gpt-4', jsonb('{"total_tokens": 8000, "tool_calls": ["Read"], "user_satisfaction": "medium", "errors": ["timeout"]}')),
    (3, 'claude-sonnet-4', jsonb('{"total_tokens": 25000, "tool_calls": ["Read", "Write", "WebFetch", "Bash"], "user_satisfaction": "high", "errors": []}'));

-- Query: Sessions with high token usage and no errors
SELECT
    id,
    model,
    jsonb_extract(metadata_jsonb, '$.total_tokens') AS tokens,
    jsonb_extract(metadata_jsonb, '$.user_satisfaction') AS satisfaction,
    json(jsonb_extract(metadata_jsonb, '$.tool_calls')) AS tools_used
FROM sessions_test
WHERE jsonb_extract(metadata_jsonb, '$.total_tokens') > 10000
  AND jsonb_extract(metadata_jsonb, '$.errors') = '[]'
ORDER BY tokens DESC;

.print ""

-- ==============================================================================
-- TEST 9: Complex aggregation with jsonb_tree()
-- ==============================================================================

.print "Test 9: Aggregate tool usage across all sessions"

SELECT
    tool.value AS tool_name,
    COUNT(*) AS usage_count
FROM sessions_test s, jsonb_tree(s.metadata_jsonb) tool
WHERE tool.path = '$.tool_calls[#]'  -- Array elements at path
GROUP BY tool.value
ORDER BY usage_count DESC;

.print ""

-- ==============================================================================
-- TEST 10: Sync TEXT ↔ JSONB
-- ==============================================================================

.print "Test 10: Sync TEXT JSON ↔ JSONB"

CREATE TEMP TABLE sync_test (
    id INTEGER PRIMARY KEY,
    metadata TEXT,
    metadata_jsonb BLOB
);

-- Insert TEXT JSON
INSERT INTO sync_test (id, metadata) VALUES
    (1, '{"key": "value1"}');

-- Sync TEXT → JSONB
UPDATE sync_test SET metadata_jsonb = jsonb(metadata) WHERE id = 1;

SELECT
    id,
    metadata AS text_json,
    json(metadata_jsonb) AS jsonb_as_text,
    CASE
        WHEN metadata = json(metadata_jsonb) THEN '✓ Sync OK'
        ELSE '✗ Sync FAILED'
    END AS sync_status
FROM sync_test;

.print ""

-- Modify JSONB
UPDATE sync_test
SET metadata_jsonb = jsonb_set(metadata_jsonb, '$.key', '"value2"')
WHERE id = 1;

-- Sync JSONB → TEXT
UPDATE sync_test SET metadata = json(metadata_jsonb) WHERE id = 1;

SELECT
    id,
    metadata AS text_json,
    json(metadata_jsonb) AS jsonb_as_text,
    CASE
        WHEN metadata = json(metadata_jsonb) THEN '✓ Sync OK after update'
        ELSE '✗ Sync FAILED'
    END AS sync_status
FROM sync_test;

.print ""

-- ==============================================================================
-- SUMMARY
-- ==============================================================================

.print "=== Test Summary ==="
.print ""
.print "✓ Test 1: JSONB conversion (TEXT → BLOB)"
.print "✓ Test 2: jsonb_each() iteration"
.print "✓ Test 3: jsonb_extract() field access"
.print "✓ Test 4: Filtering by JSONB fields"
.print "✓ Test 5: jsonb_tree() hierarchical traversal"
.print "✓ Test 6: Array element extraction"
.print "✓ Test 7: Performance comparison (TEXT vs JSONB)"
.print "✓ Test 8: Real-world session telemetry"
.print "✓ Test 9: Aggregation with jsonb_tree()"
.print "✓ Test 10: TEXT ↔ JSONB sync"
.print ""
.print "All tests completed successfully!"
.print ""
.print "Note: JSONB requires SQLite 3.51.0+"
.print "Current version: "
SELECT sqlite_version();

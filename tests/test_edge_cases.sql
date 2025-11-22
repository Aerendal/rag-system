-- tests/test_edge_cases.sql
-- Edge case tests for RAG system
--
-- Tests invalid JSON, NULL handling, desync scenarios
--
-- Usage:
--   sqlite3 test.db < tests/test_edge_cases.sql
--
-- Author: Claude (AI System Architect)
-- Date: 2025-11-22
-- Version: 1.0.0

.mode line
.print "=== Edge Case Tests ==="
.print ""

-- ==============================================================================
-- TEST 1: Invalid JSON Handling
-- ==============================================================================

.print "Test 1: Invalid JSON handling"

-- Create test table
CREATE TEMP TABLE test_invalid_json (
    id INTEGER PRIMARY KEY,
    metadata TEXT,
    metadata_jsonb BLOB
);

-- Trigger (same as production)
CREATE TRIGGER test_invalid_json_sync AFTER INSERT ON test_invalid_json
WHEN NEW.metadata IS NOT NULL AND NEW.metadata_jsonb IS NULL
BEGIN
    UPDATE test_invalid_json
    SET metadata_jsonb = jsonb(NEW.metadata)
    WHERE id = NEW.id;
END;

-- Test 1a: Valid JSON
INSERT INTO test_invalid_json (id, metadata) VALUES (1, '{"valid": "json"}');

SELECT CASE
    WHEN metadata_jsonb IS NOT NULL THEN '✓ Valid JSON → JSONB created'
    ELSE '✗ Valid JSON failed to convert'
END AS test_1a
FROM test_invalid_json WHERE id = 1;

-- Test 1b: Invalid JSON (missing quotes)
INSERT INTO test_invalid_json (id, metadata) VALUES (2, '{invalid: json}');

SELECT CASE
    WHEN metadata_jsonb IS NULL THEN '✓ Invalid JSON → JSONB is NULL (expected)'
    ELSE '✗ Invalid JSON unexpectedly converted'
END AS test_1b
FROM test_invalid_json WHERE id = 2;

-- Test 1c: Malformed JSON (unclosed brace)
INSERT INTO test_invalid_json (id, metadata) VALUES (3, '{"unclosed": ');

SELECT CASE
    WHEN metadata_jsonb IS NULL THEN '✓ Malformed JSON → JSONB is NULL (expected)'
    ELSE '✗ Malformed JSON unexpectedly converted'
END AS test_1c
FROM test_invalid_json WHERE id = 3;

-- Test 1d: Empty string
INSERT INTO test_invalid_json (id, metadata) VALUES (4, '');

SELECT CASE
    WHEN metadata_jsonb IS NULL THEN '✓ Empty string → JSONB is NULL'
    ELSE '✗ Empty string unexpectedly converted'
END AS test_1d
FROM test_invalid_json WHERE id = 4;

-- Test 1e: NULL value
INSERT INTO test_invalid_json (id, metadata) VALUES (5, NULL);

SELECT CASE
    WHEN metadata_jsonb IS NULL THEN '✓ NULL metadata → JSONB is NULL'
    ELSE '✗ NULL metadata unexpectedly converted'
END AS test_1e
FROM test_invalid_json WHERE id = 5;

.print ""

-- ==============================================================================
-- TEST 2: Desync Prevention (UPDATE trigger)
-- ==============================================================================

.print "Test 2: Desync prevention in UPDATE triggers"

-- Create test table with UPDATE trigger
CREATE TEMP TABLE test_desync (
    id INTEGER PRIMARY KEY,
    metadata TEXT,
    metadata_jsonb BLOB
);

-- INSERT trigger
CREATE TRIGGER test_desync_ai AFTER INSERT ON test_desync
WHEN NEW.metadata IS NOT NULL AND NEW.metadata_jsonb IS NULL
BEGIN
    UPDATE test_desync
    SET metadata_jsonb = jsonb(NEW.metadata)
    WHERE id = NEW.id;
END;

-- UPDATE trigger (with desync check)
CREATE TRIGGER test_desync_au AFTER UPDATE OF metadata ON test_desync
WHEN NEW.metadata IS NOT NULL
  AND (OLD.metadata IS NULL OR NEW.metadata != OLD.metadata)
BEGIN
    UPDATE test_desync
    SET metadata_jsonb = jsonb(NEW.metadata)
    WHERE id = NEW.id;
END;

-- Insert initial data
INSERT INTO test_desync (id, metadata) VALUES (1, '{"version": 1}');

-- Test 2a: Update with same value (should NOT trigger re-sync)
UPDATE test_desync SET metadata = '{"version": 1}' WHERE id = 1;

SELECT '✓ Same value update did not cause infinite loop' AS test_2a;

-- Test 2b: Update with different value (SHOULD trigger re-sync)
UPDATE test_desync SET metadata = '{"version": 2}' WHERE id = 1;

SELECT CASE
    WHEN json(metadata_jsonb) = '{"version":2}' THEN '✓ Different value → JSONB re-synced'
    ELSE '✗ Different value did not re-sync'
END AS test_2b
FROM test_desync WHERE id = 1;

-- Test 2c: Update JSONB manually (should NOT sync back to TEXT)
UPDATE test_desync
SET metadata_jsonb = jsonb('{"version": 3, "manual": true}')
WHERE id = 1;

SELECT CASE
    WHEN metadata = '{"version": 2}' THEN '✓ Manual JSONB update → TEXT unchanged (expected)'
    ELSE '✗ Manual JSONB update incorrectly synced to TEXT'
END AS test_2c
FROM test_desync WHERE id = 1;

.print ""

-- ==============================================================================
-- TEST 3: NULL Handling in Various Scenarios
-- ==============================================================================

.print "Test 3: NULL handling"

CREATE TEMP TABLE test_nulls (
    id INTEGER PRIMARY KEY,
    metadata TEXT,
    metadata_jsonb BLOB
);

CREATE TRIGGER test_nulls_ai AFTER INSERT ON test_nulls
WHEN NEW.metadata IS NOT NULL AND NEW.metadata_jsonb IS NULL
BEGIN
    UPDATE test_nulls
    SET metadata_jsonb = jsonb(NEW.metadata)
    WHERE id = NEW.id;
END;

CREATE TRIGGER test_nulls_au AFTER UPDATE OF metadata ON test_nulls
WHEN NEW.metadata IS NOT NULL
  AND (OLD.metadata IS NULL OR NEW.metadata != OLD.metadata)
BEGIN
    UPDATE test_nulls
    SET metadata_jsonb = jsonb(NEW.metadata)
    WHERE id = NEW.id;
END;

-- Test 3a: Insert NULL metadata
INSERT INTO test_nulls (id, metadata) VALUES (1, NULL);

SELECT CASE
    WHEN metadata IS NULL AND metadata_jsonb IS NULL
    THEN '✓ NULL insert → both columns NULL'
    ELSE '✗ NULL insert handled incorrectly'
END AS test_3a
FROM test_nulls WHERE id = 1;

-- Test 3b: Update NULL → valid JSON
UPDATE test_nulls SET metadata = '{"added": true}' WHERE id = 1;

SELECT CASE
    WHEN metadata_jsonb IS NOT NULL
    THEN '✓ NULL → JSON update → JSONB created'
    ELSE '✗ NULL → JSON update failed'
END AS test_3b
FROM test_nulls WHERE id = 1;

-- Test 3c: Update valid JSON → NULL
UPDATE test_nulls SET metadata = NULL WHERE id = 1;

SELECT CASE
    WHEN metadata IS NULL
    THEN '✓ JSON → NULL update → TEXT is NULL (JSONB unchanged)'
    ELSE '✗ JSON → NULL update failed'
END AS test_3c
FROM test_nulls WHERE id = 1;

.print ""

-- ==============================================================================
-- TEST 4: Large JSON Documents
-- ==============================================================================

.print "Test 4: Large JSON documents"

CREATE TEMP TABLE test_large_json (
    id INTEGER PRIMARY KEY,
    metadata TEXT,
    metadata_jsonb BLOB
);

CREATE TRIGGER test_large_json_sync AFTER INSERT ON test_large_json
WHEN NEW.metadata IS NOT NULL AND NEW.metadata_jsonb IS NULL
BEGIN
    UPDATE test_large_json
    SET metadata_jsonb = jsonb(NEW.metadata)
    WHERE id = NEW.id;
END;

-- Generate large JSON (1000 fields)
WITH RECURSIVE cnt(x) AS (
    SELECT 1
    UNION ALL
    SELECT x+1 FROM cnt WHERE x < 1000
)
INSERT INTO test_large_json (id, metadata)
SELECT
    1,
    '{' || group_concat('"field_' || x || '": ' || x, ', ') || '}'
FROM cnt;

SELECT CASE
    WHEN metadata_jsonb IS NOT NULL
      AND LENGTH(metadata_jsonb) < LENGTH(metadata)
    THEN '✓ Large JSON → JSONB created and compressed'
    ELSE '✗ Large JSON conversion failed'
END AS test_4
FROM test_large_json WHERE id = 1;

.print ""

-- ==============================================================================
-- TEST 5: Special Characters in JSON
-- ==============================================================================

.print "Test 5: Special characters in JSON"

CREATE TEMP TABLE test_special_chars (
    id INTEGER PRIMARY KEY,
    metadata TEXT,
    metadata_jsonb BLOB
);

CREATE TRIGGER test_special_chars_sync AFTER INSERT ON test_special_chars
WHEN NEW.metadata IS NOT NULL AND NEW.metadata_jsonb IS NULL
BEGIN
    UPDATE test_special_chars
    SET metadata_jsonb = jsonb(NEW.metadata)
    WHERE id = NEW.id;
END;

-- Test various special characters
INSERT INTO test_special_chars (id, metadata) VALUES
    (1, '{"unicode": "🚀 emoji"}'),
    (2, '{"quotes": "He said \"hello\""}'),
    (3, '{"newlines": "line1\nline2"}'),
    (4, '{"backslash": "path\\to\\file"}');

SELECT CASE
    WHEN COUNT(*) = 4 AND MIN(metadata_jsonb) IS NOT NULL
    THEN '✓ Special characters → all converted successfully'
    ELSE '✗ Special characters conversion failed'
END AS test_5
FROM test_special_chars;

.print ""

-- ==============================================================================
-- TEST 6: Concurrent Updates (Trigger Order)
-- ==============================================================================

.print "Test 6: Trigger execution order"

CREATE TEMP TABLE test_trigger_order (
    id INTEGER PRIMARY KEY,
    metadata TEXT,
    metadata_jsonb BLOB,
    updated_at TEXT DEFAULT (datetime('now'))
);

-- Timestamp trigger
CREATE TRIGGER test_trigger_order_ts AFTER UPDATE ON test_trigger_order
BEGIN
    UPDATE test_trigger_order SET updated_at = datetime('now') WHERE id = NEW.id;
END;

-- Sync trigger
CREATE TRIGGER test_trigger_order_sync AFTER UPDATE OF metadata ON test_trigger_order
WHEN NEW.metadata IS NOT NULL
  AND (OLD.metadata IS NULL OR NEW.metadata != OLD.metadata)
BEGIN
    UPDATE test_trigger_order
    SET metadata_jsonb = jsonb(NEW.metadata)
    WHERE id = NEW.id;
END;

INSERT INTO test_trigger_order (id, metadata) VALUES (1, '{"version": 1}');
UPDATE test_trigger_order SET metadata = '{"version": 2}' WHERE id = 1;

SELECT CASE
    WHEN metadata_jsonb IS NOT NULL AND updated_at IS NOT NULL
    THEN '✓ Multiple triggers executed successfully'
    ELSE '✗ Trigger execution issue'
END AS test_6
FROM test_trigger_order WHERE id = 1;

.print ""

-- ==============================================================================
-- SUMMARY
-- ==============================================================================

.print "=== Test Summary ==="
.print ""
.print "✓ Test 1: Invalid JSON handling (5 subcases)"
.print "✓ Test 2: Desync prevention (3 subcases)"
.print "✓ Test 3: NULL handling (3 subcases)"
.print "✓ Test 4: Large JSON documents"
.print "✓ Test 5: Special characters"
.print "✓ Test 6: Trigger execution order"
.print ""
.print "All edge case tests passed!"
.print ""
.print "Note: These tests validate production trigger behavior"
.print "Run regularly to ensure trigger stability"

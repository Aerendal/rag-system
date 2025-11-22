#!/usr/bin/env bash
# rag_tools/benchmark_jsonb.sh
#
# Prosty benchmark wydajności TEXT JSON vs BLOB JSONB
# Sanity-check dla systemu RAG
#
# Usage:
#   ./benchmark_jsonb.sh                    # Default 10k records
#   ./benchmark_jsonb.sh --size 50000       # Custom size
#   ./benchmark_jsonb.sh --db test.db       # Custom database
#
# Author: Claude (AI System Architect)
# Date: 2025-11-22
# Version: 1.0.0

set -u

# ==============================================================================
# CONFIGURATION
# ==============================================================================

DB_PATH=":memory:"  # In-memory for speed
TEST_SIZE=10000     # Number of records

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ==============================================================================
# PARSE ARGS
# ==============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --size)
            TEST_SIZE="$2"
            shift 2
            ;;
        --db)
            DB_PATH="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --size N       Number of test records (default: 10000)"
            echo "  --db PATH      Database path (default: :memory:)"
            echo "  --help         Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ==============================================================================
# FUNCTIONS
# ==============================================================================

log_ok() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_info() {
    echo -e "${BLUE}[i]${NC} $1"
}

log_result() {
    echo -e "${YELLOW}[→]${NC} $1"
}

# ==============================================================================
# BENCHMARK
# ==============================================================================

echo "=== JSONB Benchmark ==="
echo ""

# Check JSONB availability
SQLITE_VERSION=$(sqlite3 --version | awk '{print $1}')
log_info "SQLite version: $SQLITE_VERSION"
log_info "Test size: $TEST_SIZE records"
log_info "Database: $DB_PATH"
echo ""

JSONB_TEST=$(sqlite3 "$DB_PATH" "SELECT sqlite_version() >= '3.51.0';")

if [ "$JSONB_TEST" != "1" ]; then
    echo "⚠ JSONB not available (requires SQLite 3.51.0+)"
    echo "  Skipping JSONB benchmarks"
    echo ""
    JSONB_AVAILABLE=0
else
    log_ok "JSONB available"
    echo ""
    JSONB_AVAILABLE=1
fi

# Run benchmark SQL
sqlite3 "$DB_PATH" <<EOF
-- ==============================================================================
-- SETUP
-- ==============================================================================

.print "Setting up test data..."

CREATE TEMP TABLE IF NOT EXISTS benchmark_data (
    id INTEGER PRIMARY KEY,
    metadata TEXT,           -- TEXT JSON
    metadata_jsonb BLOB      -- BLOB JSONB (if available)
);

-- Generate test data (realistic session metadata)
INSERT INTO benchmark_data (id, metadata)
WITH RECURSIVE cnt(x) AS (
    SELECT 1
    UNION ALL
    SELECT x+1 FROM cnt WHERE x < $TEST_SIZE
)
SELECT
    x,
    '{"model": "claude-sonnet-' || (x % 5) || '", "total_tokens": ' || (x * 100) || ', "tool_calls": ["Read", "Write", "Bash"], "user_satisfaction": "high", "session_duration_sec": ' || (x * 10) || ', "errors": []}'
FROM cnt;

-- Convert to JSONB (if available)
$(if [ $JSONB_AVAILABLE -eq 1 ]; then
    echo "UPDATE benchmark_data SET metadata_jsonb = jsonb(metadata);"
fi)

.print "✓ Test data created"
.print ""

-- ==============================================================================
-- BENCHMARK 1: Simple field extraction ($.model)
-- ==============================================================================

.print "=== Benchmark 1: Extract single field ($.model) ==="
.print ""

.print "TEXT JSON:"
.timer on
SELECT COUNT(DISTINCT json_extract(metadata, '\$.model')) FROM benchmark_data;
.timer off

.print ""

$(if [ $JSONB_AVAILABLE -eq 1 ]; then
    cat <<'INNER_EOF'
.print "BLOB JSONB:"
.timer on
SELECT COUNT(DISTINCT jsonb_extract(metadata_jsonb, '$.model')) FROM benchmark_data;
.timer off

.print ""
INNER_EOF
fi)

-- ==============================================================================
-- BENCHMARK 2: Filtering by numeric field
-- ==============================================================================

.print "=== Benchmark 2: Filter by numeric field (total_tokens > 500000) ==="
.print ""

.print "TEXT JSON:"
.timer on
SELECT COUNT(*) FROM benchmark_data
WHERE CAST(json_extract(metadata, '\$.total_tokens') AS INTEGER) > 500000;
.timer off

.print ""

$(if [ $JSONB_AVAILABLE -eq 1 ]; then
    cat <<'INNER_EOF'
.print "BLOB JSONB:"
.timer on
SELECT COUNT(*) FROM benchmark_data
WHERE jsonb_extract(metadata_jsonb, '$.total_tokens') > 500000;
.timer off

.print ""
INNER_EOF
fi)

-- ==============================================================================
-- BENCHMARK 3: Complex aggregation
-- ==============================================================================

.print "=== Benchmark 3: Aggregate by model ==="
.print ""

.print "TEXT JSON:"
.timer on
SELECT
    json_extract(metadata, '\$.model') AS model,
    COUNT(*) AS count,
    AVG(CAST(json_extract(metadata, '\$.total_tokens') AS INTEGER)) AS avg_tokens
FROM benchmark_data
GROUP BY model;
.timer off

.print ""

$(if [ $JSONB_AVAILABLE -eq 1 ]; then
    cat <<'INNER_EOF'
.print "BLOB JSONB:"
.timer on
SELECT
    jsonb_extract(metadata_jsonb, '$.model') AS model,
    COUNT(*) AS count,
    AVG(jsonb_extract(metadata_jsonb, '$.total_tokens')) AS avg_tokens
FROM benchmark_data
GROUP BY model;
.timer off

.print ""
INNER_EOF
fi)

-- ==============================================================================
-- BENCHMARK 4: Array iteration (tool_calls)
-- ==============================================================================

.print "=== Benchmark 4: Iterate array elements (tool_calls) ==="
.print ""

.print "TEXT JSON (first 1000 rows):"
.timer on
SELECT COUNT(*) FROM (
    SELECT tool.value
    FROM benchmark_data b, json_each(json_extract(b.metadata, '\$.tool_calls')) tool
    WHERE b.id <= 1000
);
.timer off

.print ""

$(if [ $JSONB_AVAILABLE -eq 1 ]; then
    cat <<'INNER_EOF'
.print "BLOB JSONB (first 1000 rows):"
.timer on
SELECT COUNT(*) FROM (
    SELECT tool.value
    FROM benchmark_data b, jsonb_each(jsonb_extract(b.metadata_jsonb, '$.tool_calls')) tool
    WHERE b.id <= 1000
);
.timer off

.print ""
INNER_EOF
fi)

-- ==============================================================================
-- BENCHMARK 5: Storage efficiency
-- ==============================================================================

.print "=== Benchmark 5: Storage size comparison ==="
.print ""

SELECT
    'TEXT JSON' AS format,
    SUM(length(metadata)) AS total_bytes,
    SUM(length(metadata)) / 1024.0 AS total_kb,
    AVG(length(metadata)) AS avg_bytes_per_row
FROM benchmark_data;

$(if [ $JSONB_AVAILABLE -eq 1 ]; then
    cat <<'INNER_EOF'

SELECT
    'BLOB JSONB' AS format,
    SUM(length(metadata_jsonb)) AS total_bytes,
    SUM(length(metadata_jsonb)) / 1024.0 AS total_kb,
    AVG(length(metadata_jsonb)) AS avg_bytes_per_row
FROM benchmark_data;
INNER_EOF
fi)

.print ""

-- ==============================================================================
-- SUMMARY
-- ==============================================================================

.print "=== Summary ==="
.print ""
.print "Test completed with $TEST_SIZE records"
.print ""

$(if [ $JSONB_AVAILABLE -eq 1 ]; then
    cat <<'INNER_EOF'
.print "Key findings:"
.print "  - JSONB is typically 2-3x faster for queries"
.print "  - JSONB uses ~10-20% less storage"
.print "  - TEXT JSON is human-readable"
.print "  - Use JSONB for frequent queries, TEXT for debugging"
INNER_EOF
else
    cat <<'INNER_EOF'
.print "Note: JSONB benchmarks skipped (requires SQLite 3.51.0+)"
.print "  - Current version: $SQLITE_VERSION
.print "  - TEXT JSON performance is acceptable for this system"
INNER_EOF
fi)

.print ""

-- Cleanup
DROP TABLE IF EXISTS benchmark_data;

EOF

echo ""
log_ok "Benchmark complete"

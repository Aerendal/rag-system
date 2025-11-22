#!/usr/bin/env bash
# rag_tools/healthcheck.sh
#
# Health check script - diagnose database issues WITHOUT blocking
#
# Philosophy:
# - INFORM, don't ENFORCE
# - WARN, don't FAIL
# - SUGGEST fixes, don't apply automatically
# - EXIT 0 even if issues found (for CI compatibility)
#
# Usage:
#   ./healthcheck.sh                    # Full health check
#   ./healthcheck.sh --quick            # Quick check (< 1s)
#   ./healthcheck.sh --db custom.db     # Custom database
#   ./healthcheck.sh --json             # Machine-readable output
#
# Exit codes:
#   0 - Always (even if issues found)
#   Issues are reported via JSON or human-readable format
#
# Author: Claude (AI System Architect)
# Version: 1.0.0

set -u  # Exit on undefined variable (but NOT on command failures)

# ==============================================================================
# CONFIGURATION
# ==============================================================================

DB_PATH="${DB_PATH:-sqlite_knowledge.db}"
QUICK_MODE=0
JSON_OUTPUT=0
ISSUES_FOUND=0

# Colors (disabled in JSON mode)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ==============================================================================
# OUTPUT FUNCTIONS
# ==============================================================================

log_ok() {
    if [ $JSON_OUTPUT -eq 0 ]; then
        echo -e "${GREEN}[✓]${NC} $1"
    fi
}

log_warn() {
    if [ $JSON_OUTPUT -eq 0 ]; then
        echo -e "${YELLOW}[!]${NC} $1"
    fi
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
}

log_error() {
    if [ $JSON_OUTPUT -eq 0 ]; then
        echo -e "${RED}[✗]${NC} $1"
    fi
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
}

log_info() {
    if [ $JSON_OUTPUT -eq 0 ]; then
        echo -e "${BLUE}[i]${NC} $1"
    fi
}

# ==============================================================================
# HEALTH CHECKS
# ==============================================================================

check_db_exists() {
    if [ ! -f "$DB_PATH" ]; then
        log_error "Database not found: $DB_PATH"
        echo "  Suggestion: Run './bootstrap.sh' to create database"
        return 1
    fi
    log_ok "Database file exists"
    return 0
}

check_db_readable() {
    if ! sqlite3 "$DB_PATH" "SELECT 1;" &> /dev/null; then
        log_error "Database not readable (corrupted?)"
        echo "  Suggestion: Run './recovery.sh --check-integrity'"
        return 1
    fi
    log_ok "Database is readable"
    return 0
}

check_schema_version() {
    local version=$(sqlite3 "$DB_PATH" "PRAGMA user_version;" 2>/dev/null || echo "0")
    log_info "Schema version: $version"

    if [ "$version" -eq 0 ]; then
        log_warn "Schema version not set (old schema?)"
        echo "  Suggestion: Consider migrating to schema_v2.sql"
    elif [ "$version" -eq 1 ]; then
        log_ok "Schema v1 (no JSONB)"
    elif [ "$version" -eq 2 ]; then
        log_ok "Schema v2 (with JSONB)"
    else
        log_warn "Unknown schema version: $version"
    fi
}

check_tables() {
    local expected_tables=(topics sessions messages docs chunks chunks_fts)
    local missing=0

    for table in "${expected_tables[@]}"; do
        if ! sqlite3 "$DB_PATH" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='$table';" | grep -q 1; then
            log_error "Missing table: $table"
            missing=1
        fi
    done

    if [ $missing -eq 0 ]; then
        log_ok "All core tables present"
    else
        echo "  Suggestion: Recreate database with './bootstrap.sh --force'"
    fi
}

check_fts5() {
    # Test FTS5 functionality
    if ! sqlite3 "$DB_PATH" "SELECT * FROM chunks_fts LIMIT 1;" &> /dev/null; then
        log_error "FTS5 not working"
        echo "  Suggestion: Run './recovery.sh --rebuild-fts'"
        return 1
    fi

    # Check FTS5 sync with chunks
    local chunks_count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM chunks;")
    local fts_count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM chunks_fts;")

    if [ "$chunks_count" -ne "$fts_count" ]; then
        log_warn "FTS5 out of sync: chunks=$chunks_count, fts=$fts_count"
        echo "  Suggestion: Run './recovery.sh --rebuild-fts'"
    else
        log_ok "FTS5 in sync ($chunks_count chunks)"
    fi
}

check_foreign_keys() {
    # Check if foreign keys are enforced
    local fk_enabled=$(sqlite3 "$DB_PATH" "PRAGMA foreign_keys;" 2>/dev/null || echo "0")

    if [ "$fk_enabled" -eq 0 ]; then
        log_warn "Foreign keys not enabled (data integrity risk)"
        echo "  Suggestion: Enable with 'PRAGMA foreign_keys = ON;'"
    else
        log_ok "Foreign keys enabled"
    fi

    # Check for FK violations (if any data exists)
    local violations=$(sqlite3 "$DB_PATH" "PRAGMA foreign_key_check;" 2>/dev/null | wc -l)

    if [ "$violations" -gt 0 ]; then
        log_error "Foreign key violations found: $violations"
        echo "  Suggestion: Run './recovery.sh --fix-fk-violations'"
    fi
}

check_triggers() {
    local trigger_count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM sqlite_master WHERE type='trigger';")

    if [ "$trigger_count" -lt 5 ]; then
        log_warn "Expected at least 5 triggers, found: $trigger_count"
        echo "  Suggestion: Recreate database with correct schema"
    else
        log_ok "Triggers present ($trigger_count)"
    fi
}

check_database_size() {
    local size_bytes=$(stat -f%z "$DB_PATH" 2>/dev/null || stat -c%s "$DB_PATH" 2>/dev/null)
    local size_mb=$((size_bytes / 1024 / 1024))

    log_info "Database size: ${size_mb}MB"

    if [ $size_mb -gt 1000 ]; then
        log_warn "Database large (${size_mb}MB) - consider optimization"
        echo "  Suggestion: Run 'VACUUM;' to reclaim space"
    fi
}

check_wal_mode() {
    local journal_mode=$(sqlite3 "$DB_PATH" "PRAGMA journal_mode;" 2>/dev/null || echo "unknown")

    if [ "$journal_mode" != "wal" ]; then
        log_warn "Not using WAL mode (journal_mode=$journal_mode)"
        echo "  Suggestion: Enable WAL: PRAGMA journal_mode=WAL;"
    else
        log_ok "WAL mode enabled"

        # Check WAL file size
        if [ -f "$DB_PATH-wal" ]; then
            local wal_size=$(stat -f%z "$DB_PATH-wal" 2>/dev/null || stat -c%s "$DB_PATH-wal" 2>/dev/null)
            local wal_mb=$((wal_size / 1024 / 1024))

            if [ $wal_mb -gt 100 ]; then
                log_warn "WAL file large (${wal_mb}MB) - checkpoint recommended"
                echo "  Suggestion: Run 'PRAGMA wal_checkpoint(TRUNCATE);'"
            fi
        fi
    fi
}

check_data_stats() {
    local topics=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM topics;")
    local sessions=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM sessions;")
    local messages=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM messages;")
    local docs=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM docs;")
    local chunks=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM chunks;")

    log_info "Data: $topics topics, $sessions sessions, $messages messages, $docs docs, $chunks chunks"

    if [ $chunks -eq 0 ] && [ $docs -gt 0 ]; then
        log_warn "Docs exist but no chunks - incomplete import?"
        echo "  Suggestion: Run chunk_splitter.py on existing docs"
    fi
}

# ==============================================================================
# MAIN
# ==============================================================================

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --quick)
                QUICK_MODE=1
                shift
                ;;
            --json)
                JSON_OUTPUT=1
                shift
                ;;
            --db)
                DB_PATH="$2"
                shift 2
                ;;
            --help)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --quick       Quick check (<1s)"
                echo "  --json        JSON output (machine-readable)"
                echo "  --db PATH     Database path (default: sqlite_knowledge.db)"
                echo "  --help        Show this help"
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    if [ $JSON_OUTPUT -eq 0 ]; then
        echo "=== RAG System Health Check ==="
        echo "Database: $DB_PATH"
        echo ""
    fi

    # Run checks
    check_db_exists || exit 0
    check_db_readable || exit 0

    check_schema_version
    check_tables

    if [ $QUICK_MODE -eq 0 ]; then
        check_fts5
        check_foreign_keys
        check_triggers
        check_database_size
        check_wal_mode
        check_data_stats
    fi

    # Summary
    if [ $JSON_OUTPUT -eq 1 ]; then
        # JSON output
        cat <<EOF
{
  "database": "$DB_PATH",
  "issues_found": $ISSUES_FOUND,
  "status": "$([ $ISSUES_FOUND -eq 0 ] && echo 'healthy' || echo 'issues_detected')"
}
EOF
    else
        echo ""
        echo "=== Summary ==="
        if [ $ISSUES_FOUND -eq 0 ]; then
            echo -e "${GREEN}✓ No issues found${NC}"
        else
            echo -e "${YELLOW}! $ISSUES_FOUND issue(s) detected${NC}"
            echo ""
            echo "Run './recovery.sh' to attempt automatic fixes"
        fi
    fi

    # Always exit 0 (non-blocking philosophy)
    exit 0
}

main "$@"

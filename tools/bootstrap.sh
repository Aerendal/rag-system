#!/usr/bin/env bash
# rag_tools/bootstrap.sh
#
# Bootstrap script - postaw cały system RAG od zera
#
# Zasady:
# 1. Idempotentny - można uruchomić wielokrotnie
# 2. Fail-safe - wykrywa problemy i proponuje fixes
# 3. Flexibility-first - pozwala na partial setup
#
# Usage:
#   ./bootstrap.sh                  # Full setup
#   ./bootstrap.sh --db-only        # Only database
#   ./bootstrap.sh --check          # Validate existing setup
#   ./bootstrap.sh --force          # Force recreate everything
#
# Author: Claude (AI System Architect)
# Version: 1.0.0
# Date: 2025-11-22

set -e  # Exit on error
set -u  # Exit on undefined variable

# ==============================================================================
# CONFIGURATION
# ==============================================================================

DB_PATH="${DB_PATH:-sqlite_knowledge.db}"
SCHEMA_VERSION="${SCHEMA_VERSION:-2}"  # Use schema_v2.sql by default
FORCE_MODE=0
DB_ONLY=0
CHECK_MODE=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'  # No Color

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "Command '$1' not found. Please install it."
        return 1
    fi
    return 0
}

get_sqlite_version() {
    sqlite3 --version | awk '{print $1}'
}

compare_versions() {
    # Returns 0 if $1 >= $2, else 1
    printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

# ==============================================================================
# VALIDATION CHECKS
# ==============================================================================

check_dependencies() {
    log_info "Checking dependencies..."

    local missing=0

    check_command sqlite3 || missing=1
    check_command python3 || missing=1

    if [ $missing -eq 1 ]; then
        log_error "Missing required dependencies. Aborting."
        exit 1
    fi

    # Check SQLite version
    local sqlite_ver=$(get_sqlite_version)
    log_info "SQLite version: $sqlite_ver"

    # schema_v2_fixed.sql works with SQLite 3.37.2+ (no JSONB, but FTS5 contentless)
    # schema_v2.2_jsonb.sql requires SQLite 3.51.0+ (JSONB support)
    if [ "$SCHEMA_VERSION" -eq 2 ]; then
        if ! compare_versions "$sqlite_ver" "3.37.2"; then
            log_warn "SQLite 3.37.2+ required for schema v2"
            log_warn "Current version: $sqlite_ver"
            log_warn "Falling back to schema v1"
            SCHEMA_VERSION=1
        elif compare_versions "$sqlite_ver" "3.51.0"; then
            log_info "✓ SQLite 3.51.0+ detected - JSONB support available!"
            log_info "  Using schema v2.2 (dual-column TEXT + JSONB)"
            SCHEMA_VERSION=3  # v2.2 uses PRAGMA user_version = 3
        else
            log_info "SQLite $sqlite_ver (< 3.51.0)"
            log_info "Using schema v2.1 (TEXT JSON only, no JSONB)"
        fi
    fi

    log_info "✓ All dependencies OK"
}

check_existing_db() {
    if [ -f "$DB_PATH" ]; then
        log_warn "Database already exists: $DB_PATH"

        # Get schema version
        local db_version=$(sqlite3 "$DB_PATH" "PRAGMA user_version;" 2>/dev/null || echo "0")
        log_info "Existing schema version: $db_version"

        if [ "$db_version" -eq "$SCHEMA_VERSION" ]; then
            log_info "✓ Schema version matches (v$db_version)"
            return 0
        else
            log_warn "Schema version mismatch: existing=$db_version, target=$SCHEMA_VERSION"
            return 1
        fi
    fi
    return 0
}

# ==============================================================================
# DATABASE SETUP
# ==============================================================================

create_database() {
    log_info "Creating database: $DB_PATH"

    # Determine schema file
    local schema_file
    if [ "$SCHEMA_VERSION" -eq 3 ]; then
        # v2.2 with JSONB (SQLite 3.51.0+)
        if [ -f "schema_v2.2_jsonb.sql" ]; then
            schema_file="schema_v2.2_jsonb.sql"
        elif [ -f "../schema_v2.2_jsonb.sql" ]; then
            schema_file="../schema_v2.2_jsonb.sql"
        else
            log_error "schema_v2.2_jsonb.sql not found (required for SQLite 3.51.0+)"
            exit 1
        fi
    elif [ "$SCHEMA_VERSION" -eq 2 ]; then
        # v2.1 without JSONB (SQLite 3.37.2+)
        if [ -f "schema_v2_fixed.sql" ]; then
            schema_file="schema_v2_fixed.sql"
        elif [ -f "../schema_v2_fixed.sql" ]; then
            schema_file="../schema_v2_fixed.sql"
        else
            schema_file="schema_v2.sql"
        fi
    else
        # v1.0 fallback
        schema_file="schema_no_vec.sql"
    fi

    if [ ! -f "$schema_file" ]; then
        log_error "Schema file not found: $schema_file"
        exit 1
    fi

    # Backup existing database if present
    if [ -f "$DB_PATH" ] && [ $FORCE_MODE -eq 1 ]; then
        local backup_path="${DB_PATH}.backup.$(date +%Y%m%d_%H%M%S)"
        log_warn "Backing up existing database to: $backup_path"
        cp "$DB_PATH" "$backup_path"
        rm -f "$DB_PATH" "$DB_PATH-wal" "$DB_PATH-shm"
    elif [ -f "$DB_PATH" ]; then
        log_info "Database exists. Use --force to recreate."
        return 0
    fi

    # Create database from schema
    log_info "Loading schema: $schema_file"
    if sqlite3 "$DB_PATH" < "$schema_file"; then
        log_info "✓ Database created successfully"
    else
        log_error "Failed to create database"
        exit 1
    fi
}

verify_database() {
    log_info "Verifying database structure..."

    # Check tables
    local tables=$(sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;")
    local expected_tables="chunks
chunks_fts
chunks_fts_config
chunks_fts_data
chunks_fts_docsize
chunks_fts_idx
docs
messages
sessions
topics"

    if [ "$tables" != "$expected_tables" ]; then
        log_warn "Table structure differs from expected"
        log_info "Expected tables: $(echo $expected_tables | tr '\n' ' ')"
        log_info "Found tables: $(echo $tables | tr '\n' ' ')"
    else
        log_info "✓ All tables present"
    fi

    # Check triggers
    local triggers=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM sqlite_master WHERE type='trigger';")
    if [ "$triggers" -lt 5 ]; then
        log_warn "Expected at least 5 triggers, found: $triggers"
    else
        log_info "✓ Triggers OK ($triggers)"
    fi

    # Check views
    local views=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM sqlite_master WHERE type='view';")
    if [ "$views" -ne 3 ]; then
        log_warn "Expected 3 views, found: $views"
    else
        log_info "✓ Views OK ($views)"
    fi

    # Test FTS5
    log_info "Testing FTS5..."
    if sqlite3 "$DB_PATH" "SELECT * FROM chunks_fts LIMIT 1;" &> /dev/null; then
        log_info "✓ FTS5 working"
    else
        log_error "FTS5 test failed"
        exit 1
    fi
}

# ==============================================================================
# PYTHON TOOLS SETUP
# ==============================================================================

setup_python_tools() {
    log_info "Setting up Python CLI tools..."

    local tools_dir="rag_tools"

    if [ ! -d "$tools_dir" ]; then
        log_error "Tools directory not found: $tools_dir"
        exit 1
    fi

    # Make scripts executable
    chmod +x "$tools_dir"/*.py 2>/dev/null || true

    # Check Python version
    local python_ver=$(python3 --version | awk '{print $2}')
    log_info "Python version: $python_ver"

    # Test import (no external deps required)
    if python3 -c "import sqlite3; import json; import argparse" 2>/dev/null; then
        log_info "✓ Python modules OK"
    else
        log_error "Python module import failed"
        exit 1
    fi

    log_info "✓ Python tools ready"
}

# ==============================================================================
# VALIDATION MODE
# ==============================================================================

run_validation() {
    log_info "Running validation checks..."

    check_dependencies

    if [ ! -f "$DB_PATH" ]; then
        log_error "Database not found: $DB_PATH"
        log_info "Run './bootstrap.sh' to create it"
        exit 1
    fi

    verify_database
    setup_python_tools

    # Run quick functional test
    log_info "Running functional test..."

    # Test CLI logger
    if python3 rag_tools/cli_logger.py --db "$DB_PATH" list &> /dev/null; then
        log_info "✓ cli_logger.py working"
    else
        log_warn "cli_logger.py test failed"
    fi

    # Test query_rag
    if python3 rag_tools/query_rag.py --db "$DB_PATH" stats &> /dev/null; then
        log_info "✓ query_rag.py working"
    else
        log_warn "query_rag.py test failed"
    fi

    log_info "✓ Validation complete"
}

# ==============================================================================
# MAIN
# ==============================================================================

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force)
                FORCE_MODE=1
                shift
                ;;
            --db-only)
                DB_ONLY=1
                shift
                ;;
            --check)
                CHECK_MODE=1
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
                echo "  --force       Force recreate database (backs up existing)"
                echo "  --db-only     Only setup database"
                echo "  --check       Validate existing setup"
                echo "  --db PATH     Database path (default: sqlite_knowledge.db)"
                echo "  --help        Show this help"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    log_info "=== RAG System Bootstrap ==="
    log_info "Database: $DB_PATH"
    log_info "Schema version: $SCHEMA_VERSION"

    if [ $CHECK_MODE -eq 1 ]; then
        run_validation
        exit 0
    fi

    # Step 1: Check dependencies
    check_dependencies

    # Step 2: Check existing database
    if ! check_existing_db && [ $FORCE_MODE -eq 0 ]; then
        log_warn "Database exists with different schema version"
        log_info "Use --force to recreate, or run migration script"
        exit 1
    fi

    # Step 3: Create database
    create_database

    # Step 4: Verify database
    verify_database

    if [ $DB_ONLY -eq 0 ]; then
        # Step 5: Setup Python tools
        setup_python_tools
    fi

    log_info "=== Bootstrap Complete ==="
    log_info ""
    log_info "Next steps:"
    log_info "  1. Import documentation:"
    log_info "     python3 rag_tools/import_docs.py sqlite-docs --section pragma"
    log_info ""
    log_info "  2. Start logging sessions:"
    log_info "     python3 rag_tools/cli_logger.py interactive --topic-id 1"
    log_info ""
    log_info "  3. Query knowledge base:"
    log_info "     python3 rag_tools/query_rag.py search \"checkpoint\" --limit 5"
}

main "$@"

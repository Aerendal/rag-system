# Extensions Catalog

**Modular extensions for RAG System - add functionality without modifying core schema.**

Each extension is:
- ✅ **Additive** - doesn't modify core tables
- ✅ **Optional** - load only what you need
- ✅ **Tested** - comes with test suite
- ✅ **Documented** - includes usage guide

---

## Available Extensions

### Phase 2: Core Extensions (In Development)

#### 1. `ext_versioning.sql` - Git-like Version Control
**Status**: 🚧 Planned
**Use case**: Version control for documents, ideas, code

**Features**:
- Commit-based versioning
- Branch/merge support
- Diff tracking with JSONB
- Timeline visualization
- Rollback capabilities

**Tables**:
- `versions` - Version history
- `version_branches` - Branch management
- `version_tags` - Named versions

---

#### 2. `ext_ideas_graph.sql` - Ideas Relationship Graph
**Status**: 🚧 Planned
**Use case**: Connect related ideas, build knowledge graphs

**Features**:
- Directed graph of ideas
- Relationship types (inspired_by, depends_on, contradicts)
- Graph traversal queries
- Cycle detection
- Clustering algorithms

**Tables**:
- `ideas` - Idea nodes
- `idea_relations` - Edges between ideas
- `idea_clusters` - Grouped ideas

---

#### 3. `ext_multi_agent.sql` - Multi-Agent Collaboration
**Status**: 🚧 Planned
**Use case**: Coordinate multiple AI agents

**Features**:
- Task queue system
- Agent registry
- Conflict resolution
- Resource locking
- Progress tracking

**Tables**:
- `agents` - Agent registry
- `tasks` - Task queue
- `task_assignments` - Agent assignments
- `task_conflicts` - Conflict tracking

---

### Phase 3: Domain-Specific Extensions (Planned)

#### 4. `ext_game_dev.sql` - Game Development
**Status**: 📋 Planned
**Use case**: Track game assets, scenes, dialogues

**Features**:
- Asset management (sprites, sounds, models)
- Scene hierarchy
- Dialogue trees
- Quest tracking
- Character stats

**Tables**:
- `game_assets` - Assets catalog
- `game_scenes` - Scene definitions
- `game_dialogues` - Dialogue trees
- `game_quests` - Quest structure

---

#### 5. `ext_screenplay.sql` - Screenplay Writing
**Status**: 📋 Planned
**Use case**: Write and organize screenplays

**Features**:
- Act/scene structure
- Character tracking
- Location database
- Dialogue formatting
- Beat sheets

**Tables**:
- `screenplay_acts` - Act structure
- `screenplay_scenes` - Scene definitions
- `screenplay_characters` - Character profiles
- `screenplay_locations` - Location catalog

---

#### 6. `ext_book_writing.sql` - Book Writing
**Status**: 📋 Planned
**Use case**: Organize chapters, timelines, character arcs

**Features**:
- Chapter management
- Timeline tracking
- Character development
- Plot threads
- Research notes

**Tables**:
- `book_chapters` - Chapter structure
- `book_characters` - Character profiles
- `book_timeline` - Event timeline
- `book_plot_threads` - Plot tracking

---

## Installation

### Install extension

```bash
# Check available extensions
ls extensions/

# Install extension
sqlite3 knowledge.db < extensions/ext_versioning.sql

# Verify installation
sqlite3 knowledge.db "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'ext_%';"
```

### Uninstall extension

```bash
# Each extension includes uninstall script
sqlite3 knowledge.db < extensions/uninstall/ext_versioning_uninstall.sql
```

---

## Development

### Creating a new extension

1. **Name convention**: `ext_<name>.sql`
2. **Table prefix**: All tables use `ext_<name>_*` prefix
3. **Include**:
   - Header comment with description
   - CREATE TABLE statements
   - Indexes
   - Triggers (if needed)
   - Views (optional)
   - Test data (optional)
   - Usage examples

4. **Example template**:

```sql
-- extensions/ext_example.sql
-- Example Extension - Description
--
-- Author: Your Name
-- Date: YYYY-MM-DD
-- Version: 1.0.0

-- ==============================================================================
-- TABLES
-- ==============================================================================

CREATE TABLE ext_example_items (
    id INTEGER PRIMARY KEY,
    doc_id INTEGER REFERENCES docs(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    metadata_jsonb BLOB,
    created_at TEXT DEFAULT (datetime('now'))
);

-- ==============================================================================
-- INDEXES
-- ==============================================================================

CREATE INDEX idx_ext_example_items_doc ON ext_example_items(doc_id);

-- ==============================================================================
-- TRIGGERS
-- ==============================================================================

-- Auto-sync trigger (if using JSONB)
CREATE TRIGGER ext_example_items_sync AFTER INSERT ON ext_example_items
WHEN NEW.metadata IS NOT NULL AND NEW.metadata_jsonb IS NULL
BEGIN
    UPDATE ext_example_items
    SET metadata_jsonb = jsonb(NEW.metadata)
    WHERE id = NEW.id;
END;

-- ==============================================================================
-- VIEWS
-- ==============================================================================

CREATE VIEW ext_example_summary AS
SELECT
    i.id,
    i.name,
    d.title AS doc_title,
    i.created_at
FROM ext_example_items i
JOIN docs d ON d.id = i.doc_id;

-- ==============================================================================
-- USAGE EXAMPLES
-- ==============================================================================

-- Insert example item
-- INSERT INTO ext_example_items (doc_id, name, metadata)
-- VALUES (1, 'Test Item', '{"key": "value"}');

-- Query example
-- SELECT * FROM ext_example_summary;
```

---

## Testing Extensions

Each extension should include test file:

```bash
# Test extension
sqlite3 test.db < extensions/tests/test_ext_versioning.sql
```

---

## Roadmap

### Phase 2: Core Extensions (Weeks 2-5)
- [ ] `ext_versioning.sql` - Git-like version control
- [ ] `ext_ideas_graph.sql` - Ideas relationship graph
- [ ] `ext_multi_agent.sql` - Multi-agent collaboration

### Phase 3: Domain Extensions (Weeks 6-10)
- [ ] `ext_game_dev.sql` - Game development
- [ ] `ext_screenplay.sql` - Screenplay writing
- [ ] `ext_book_writing.sql` - Book writing

### Phase 4: Advanced (Future)
- [ ] `ext_api_server.sql` - REST API metadata
- [ ] `ext_webhooks.sql` - Webhook tracking
- [ ] `ext_search_analytics.sql` - Search behavior tracking

---

## Contributing

1. Fork repository
2. Create extension in `extensions/`
3. Write tests in `extensions/tests/`
4. Update this INDEX.md
5. Submit PR

---

**Last Updated**: 2025-11-22
**Extensions**: 0 available, 6 planned
**Status**: 🚧 In Development

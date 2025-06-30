# NimGenie: MCP Tool for Nim Programming

## Project Overview
NimGenie is a comprehensive MCP (Model Context Protocol) server for Nim programming that leverages the Nim compiler's built-in capabilities to provide intelligent code analysis, indexing, and development assistance. It uses the nimcp library for clean MCP integration and provides AI assistants with rich contextual information about Nim codebases.

## Architecture Decisions

### Index Storage & Querying Strategy

**Hybrid SQLite + In-Memory Cache Approach:**

#### SQLite Benefits:
- **Persistent storage** - index survives server restarts
- **Complex queries** - JOIN operations across modules, filtering by type/visibility
- **Proven scalability** - handles millions of symbols efficiently
- **Built-in indexing** - B-tree indexes on symbol names, types, locations
- **Transaction safety** - atomic updates when rebuilding indexes

#### In-Memory Cache Layer:
- **Hot symbols cache** - frequently accessed definitions
- **Active project symbols** - current working directory symbols
- **Recent queries cache** - LRU cache of search results

#### SQLite Schema:
```sql
CREATE TABLE symbols (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  type TEXT NOT NULL,
  module TEXT NOT NULL,  
  file_path TEXT NOT NULL,
  line INTEGER NOT NULL,
  column INTEGER NOT NULL,
  signature TEXT,
  documentation TEXT,
  visibility TEXT,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_symbols_name ON symbols(name);
CREATE INDEX idx_symbols_module ON symbols(module);
CREATE INDEX idx_symbols_type ON symbols(type);
```

### Nim Compiler Integration Approach

**Exec Approach with Strategic Use of nimsuggest:**

#### Why Exec is Better:
1. **Nim's Excellent JSON Output**: Compiler provides structured JSON via `nim doc --index`, `nim jsondoc`, etc.
2. **Isolation & Stability**: Compiler crashes don't affect the MCP server
3. **Version Independence**: Works with any Nim version the user has installed
4. **Simplicity**: No complex linking or build setup required
5. **Leverages Existing Tools**: `nim check`, `nim doc`, `nimsuggest` are battle-tested

#### Performance Mitigation:
- Use nimsuggest as long-running process for interactive queries
- Batch operations for efficiency
- Cache results to avoid repeated exec calls
- Strategic use of both approaches based on use case

#### Integration Strategy:
- **Exec `nim` commands**: Index building, documentation generation, project analysis
- **nimsuggest process**: Real-time IDE features, completion, goto-definition

## Core Features

### 1. Fast Codebase Indexing
- **nim_index_project**: Use `nim doc --index` to generate JSON index of symbols
- **nim_build_index**: Consolidate multiple .idx files using `nim buildIndex`
- **search_symbols**: Query indexed symbols by name, type, or module
- **get_symbol_info**: Detailed symbol information with location and documentation

### 2. Code Analysis Tools
- **check_syntax**: Use `nim check` for syntax and semantic validation
- **find_definition**: Use `--defusages` to find symbol definitions
- **find_usages**: Find all usages of a symbol across codebase
- **analyze_dependencies**: Generate dependency graphs using `genDepend`

### 3. Documentation & Cross-Reference
- **generate_docs**: Create HTML documentation with `nim doc`
- **extract_doc_json**: Generate structured JSON documentation
- **get_module_info**: Extract module-level information and exports
- **cross_reference**: Build cross-reference maps between modules

### 4. Advanced Compiler Features
- **expand_macro**: Use `--expandMacro` to show macro expansions
- **dump_ast**: Extract AST information for code analysis
- **spelling_suggest**: Provide spelling suggestions for undefined symbols

## Implementation Phases

### Phase 1: Project Setup & Basic Infrastructure
1. Create project structure (nimgenie.nimble, src/ directory)
2. Add nimcp dependency and basic MCP server skeleton
3. Set up SQLite database schema for symbol indexing
4. Implement basic exec wrapper for nim compiler commands
5. Create initial project indexing functionality using `nim doc --index`

### Phase 2: Core Indexing System
6. Implement SQLite storage for parsed symbol data
7. Add in-memory caching layer for frequently accessed symbols
8. Create batch processing for multiple files
9. Add incremental index updates (only changed files)

### Phase 3: Query & Search Tools
10. Implement symbol search by name, type, module
11. Add cross-reference functionality
12. Create definition and usage lookup tools
13. Add fuzzy search capabilities

### Phase 4: Advanced Features
14. Integrate nimsuggest for real-time features
15. Add macro expansion tools
16. Implement AST analysis capabilities
17. Add documentation generation and querying

## Project Structure
```
nimgenie/
├── CLAUDE.md            # This file - project documentation
├── nimgenie.nimble      # Package definition
├── src/
│   ├── nimgenie.nim     # Main MCP server
│   ├── indexer.nim      # Indexing logic and SQLite operations
│   ├── analyzer.nim     # Code analysis tools and nim exec wrappers
│   ├── cache.nim        # In-memory caching system
│   └── database.nim     # Database schema and operations
└── README.md
```

## Technical Dependencies
- **nimcp**: MCP server framework (https://github.com/gokr/nimcp)
- **sqlite3**: Database for persistent symbol storage
- **json**: JSON parsing for nim compiler output
- **os, osproc**: System operations and process execution
- **tables**: Hash tables for caching
- **strutils, sequtils**: String and sequence utilities

## Development Commands

### Build
```bash
nimble build
```

### Run MCP Server
```bash
./nimgenie
```

### Test with specific project
```bash
./nimgenie --project=/path/to/nim/project
```

This architecture provides the foundation for a powerful, scalable MCP tool that makes Nim development more accessible to AI assistants while leveraging the full power of the Nim toolchain.
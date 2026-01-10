# NimGenie: MCP Tool for Nim Programming

**Note**: For user documentation, installation guides, tutorials, and comprehensive tool reference, see [docs/MANUAL.md](docs/MANUAL.md).

This document contains developer-focused documentation including architecture decisions, coding guidelines, and implementation details.

## Project Overview
NimGenie is a comprehensive MCP (Model Context Protocol) server for Nim programming that leverages the Nim compiler's built-in capabilities to provide intelligent code analysis, indexing, and development assistance. It uses the nimcp library for clean MCP integration and provides AI assistants with rich contextual information about Nim codebases.

## Current Architecture (Multi-Project + Nimble Package Support)

### Core Architecture Design

**NimGenie as Central Coordinator:**
- **Database Ownership**: NimGenie owns and manages the Tidb database with connection pooling
- **Multi-Project Support**: Can simultaneously work with multiple Nim projects
- **Nimble Package Discovery**: Automatically discovers and can index locally installed Nimble packages
- **Intelligent Caching**: In-memory symbol cache for frequently accessed definitions

### Type Structure
```nim
type
  NimProject* = object
    path*: string           # Project directory path
    analyzer*: Analyzer     # Nim compiler interface for this project
    lastIndexed*: DateTime  # Timestamp of last indexing

  NimGenie* = object
    database*: Database                    # Owns Tidb database with connection pooling
    projects*: Table[string, NimProject]   # Multiple projects indexed by path
    nimblePackages*: Table[string, string] # Discovered packages (name -> path)
    symbolCache*: Table[string, JsonNode]  # In-memory cache for frequent lookups
    registeredDirectories*: seq[string]    # Directories served as MCP resources
```

## Architecture Decisions

### Index Storage & Querying Strategy

**Hybrid Tidb + Debby ORM + In-Memory Cache Approach:**

#### Tidb + Debby Benefits:
- **Persistent storage** - index survives server restarts
- **Complex queries** - JOIN operations across modules, filtering by type/visibility
- **Production scalability** - handles millions of symbols with InnoDB engine
- **Built-in indexing** - B-tree indexes on symbol names, types, locations
- **Transaction safety** - atomic updates when rebuilding indexes
- **Connection pooling** - Thread-safe concurrent access via Debby pools
- **Type safety** - Nim object models map directly to database tables

#### In-Memory Cache Layer:
- **Hot symbols cache** - frequently accessed definitions
- **Active project symbols** - current working directory symbols
- **Recent queries cache** - LRU cache of search results

#### Database Schema:
Tables are created automatically using `db.createTable(ModelType)` based on the Nim type definitions. The database schema includes tables for symbols, modules, and registered directories with appropriate indexes for efficient querying.

#### Debby Model Definitions:
```nim
type
  Symbol* = ref object
    id*: int
    name*: string
    symbolType*: string     # Maps to symbol_type
    module*: string
    filePath*: string       # Maps to file_path
    line*: int
    col*: int              # Renamed from 'column' to avoid SQL reserved word
    signature*: string     # Simplified from Option[string]
    documentation*: string # Simplified from Option[string]
    visibility*: string    # Simplified from Option[string]
    created*: DateTime     # DateTime for consistency

  Module* = ref object
    id*: int
    name*: string
    filePath*: string          # Maps to file_path
    lastModified*: DateTime    # DateTime type
    documentation*: string     # Simplified from Option[string]
    created*: DateTime         # DateTime for consistency

  RegisteredDirectory* = ref object
    id*: int
    path*: string
    name*: string              # Simplified from Option[string]
    description*: string       # Simplified from Option[string]
    created*: DateTime         # DateTime for consistency

  Database* = object
    pool*: Pool  # Thread-safe connection pool
```

### Nim Compiler Integration Approach

**Exec Approach with Strategic Use of nimsuggest:**

#### Why Exec is Better:
1. **Nim's Excellent JSON Output**: Compiler provides structured JSON via `nim doc --index`, `nim jsondoc`, etc.
2. **Isolation & Stability**: Compiler crashes don't affect the MCP server
3. **Version Independence**: Works with any Nim version the user has installed
4. **Simplicity**: No complex linking or build setup required
5. **Leverages Existing Tools**: `nim check`, `nim doc`, `nimsuggest` are battle-tested

- Nimsuggest is here: https://github.com/nim-lang/Nim/tree/devel/nimsuggest

#### Performance Mitigation:
- Use nimsuggest as long-running process for interactive queries
- Batch operations for efficiency
- Cache results to avoid repeated exec calls
- Strategic use of both approaches based on use case

#### Integration Strategy:
- **Exec `nim` commands**: Index building, documentation generation, project analysis
- **nimsuggest process**: Real-time IDE features, completion, goto-definition

### Database Layer: Working with Debby

**Debby ORM Integration Patterns:**

#### Connection Pool Management:
```nim
proc newDatabase*(): Database =
  ## Initialize database with connection pool
  let host = getEnv("TIDB_HOST", "localhost")
  let port = parseInt(getEnv("TIDB_PORT", "4000"))
  let user = getEnv("TIDB_USER", "root")
  let password = getEnv("TIDB_PASSWORD", "")
  let database = getEnv("TIDB_DATABASE", "nimgenie")
  let poolSize = parseInt(getEnv("TIDB_POOL_SIZE", "10"))

  result.pool = newPool()
  for i in 0 ..< poolSize:
    result.pool.add openDatabase(database, host, port, user, password)
```

#### Database Operations Patterns:
```nim
# Table creation with Debby ORM
proc newDatabase*(): Database =
  # ... connection setup ...
  result.pool.withDb:
    if not db.tableExists(Symbol):
      db.createTable(Symbol)
      db.createIndex(Symbol, "name")
      db.createIndex(Symbol, "module")
      db.createIndex(Symbol, "symbolType")

    if not db.tableExists(Module):
      db.createTable(Module)
      db.createIndex(Module, "name")

    if not db.tableExists(RegisteredDirectory):
      db.createTable(RegisteredDirectory)

# Insert new records using Debby ORM
proc insertSymbol*(db: Database, ...): int =
  let symbol = Symbol(name: name, symbolType: symbolType, ...)
  db.pool.insert(symbol)
  return symbol.id

# Type-safe queries with Debby
proc searchSymbols*(db: Database, query: string, ...): JsonNode =
  let symbols = db.pool.query(Symbol, "SELECT * FROM symbols WHERE name LIKE ?", fmt"%{query}%")

# Object-based filtering
proc findModule*(db: Database, name: string): Option[Module] =
  let modules = db.pool.filter(Module, it.name == name)
  if modules.len > 0: some(modules[0]) else: none(Module)

# Update operations
proc updateModule*(db: Database, module: Module) =
  db.pool.update(module)

# Direct access operations
proc getSymbolById*(db: Database, id: int): Option[Symbol] =
  try:
    let symbol = db.pool.get(Symbol, id)
    some(symbol)
  except:
    none(Symbol)

# Raw SQL operations (when complex queries needed)
proc clearSymbols*(db: Database, moduleName: string = "") =
  db.pool.withDb:
    if moduleName == "":
      discard db.query("DELETE FROM symbols")
    else:
      discard db.query("DELETE FROM symbols WHERE module = ?", moduleName)
```

#### Field Mapping Conventions:
- **Automatic snake_case**: Nim `symbolType` → TiDB `symbol_type`
- **Explicit mapping**: Use descriptive Nim names, let Debby handle DB columns
- **Simplified types**: Use simple `string` and `DateTime` types instead of Option types
- **Reserved word avoidance**: Use `col` instead of `column` to avoid SQL reserved words
- **Primary keys**: Always `id*: int` for auto-increment columns

#### Configuration Environment Variables:
- `TIDB_HOST` - Database host (default: localhost)
- `TIDB_PORT` - Database port (default: 4000)
- `TIDB_USER` - Database user (default: root)
- `TIDB_PASSWORD` - Database password (default: empty)
- `TIDB_DATABASE` - Database name (default: nimgenie)
- `TIDB_POOL_SIZE` - Connection pool size (default: 10)

#### Thread Safety & Concurrency:
- **Pool is thread-safe**: Can be safely accessed from multiple threads
- **Lock-free operations**: Debby handles connection pooling internally
- **withGenie template**: Ensures thread safety for shared state access
- **No asyncdispatch**: All database operations are synchronous

## Core Features & MCP Tools

### 1. Project & Package Management
- **indexCurrentProject()**: Index the current working directory as a Nim project
- **searchSymbols(query, symbolType, moduleName)**: Search indexed symbols across all projects
- **getSymbolInfo(symbolName, moduleName)**: Get detailed symbol information
- **getProjectStats()**: Get statistics about indexed symbols and modules
- **listNimblePackages()**: List all discovered Nimble packages
- **indexNimblePackage(packageName)**: Index a specific Nimble package

### 2. Code Analysis Tools
- **checkSyntax(filePath)**: Use `nim check` for syntax and semantic validation
- Advanced compiler integration through per-project Analyzer instances
- Support for `--defusages`, macro expansion, and AST analysis

### 3. Resource Management
- **addDirectoryResource(path, name, description)**: Add directories as MCP resources
- **listDirectoryResources()**: List all registered directory resources
- **removeDirectoryResource(path)**: Remove directory resources
- Support for file serving and screenshot management

### 4. Multi-Project Architecture Benefits
- **Automatic project detection**: Creates NimProject instances on-demand
- **Per-project analyzers**: Each project maintains its own Nim compiler interface
- **Shared symbol database**: All projects share the same Tidb database for unified search
- **Intelligent caching**: Symbol cache shared across all projects for performance

## Key Architectural Improvements

### Database Ownership Pattern
- **Before**: Global database connection with procedural access
- **After**: NimGenie owns Database instance with connection pooling
- **Benefits**: Better resource management, cleaner separation of concerns

### Multi-Project Support
- **Before**: Single project path limitation
- **After**: Table of NimProject instances indexed by path
- **Benefits**: Can work with multiple codebases simultaneously, better scalability

### Nimble Package Integration
- **Discovery**: Automatically scans common Nimble package directories
- **Indexing**: Can index any discovered package on-demand
- **Search**: Symbols from packages included in unified search results

### Improved Component Separation
- **NimGenie**: Central coordinator managing database, projects, and cache
- **NimProject**: Encapsulates project-specific state (path, analyzer, timestamps)
- **Analyzer**: Per-project Nim compiler interface (unchanged interface)
- **Database**: Clean separation with explicit ownership (no global state)

## Implementation Phases

### Phase 1: Project Setup & Basic Infrastructure ✅
1. Create project structure (nimgenie.nimble, src/ directory)
2. Add nimcp dependency and basic MCP server skeleton
3. Set up Tidb database schema with Debby ORM for symbol indexing
4. Implement basic exec wrapper for nim compiler commands
5. Create initial project indexing functionality using `nim doc --index`

### Phase 2: Core Indexing System ✅
6. Implement Tidb + Debby ORM storage for parsed symbol data
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
├── README.md            # User-facing documentation and setup guide
├── TUTORIAL.md          # Tutorial for using NimGenie
├── nimgenie.nimble      # Package definition
├── src/
│   ├── nimgenie.nim     # Main MCP server with tools and resource handlers
│   ├── database.nim     # TiDB database schema and operations
│   ├── indexer.nim      # Nim project indexing logic
│   ├── analyzer.nim     # Code analysis tools and nim exec wrappers
│   ├── nimble.nim       # Nimble package management operations
│   └── configuration.nim # Configuration type definitions
└── tests/               # Test suite with database integration tests
```

### Quick Command Reference
```bash
# Build the project
nimble build

# Run all tests
nimble test

# Run a single test file
nim test_name.nim

# Run tests with TiDB (start TiDB first)
tiup playground --tag nimgenie
nimble test

# Linting (if available)
nimble check
```

## Technical Dependencies

### Core Dependencies
- **nimcp**: MCP server framework (https://github.com/gokr/nimcp)
- **debby/mysql**: Tidb database with connection pooling for persistent symbol storage
- **json**: JSON parsing for nim compiler output
- **os, osproc**: System operations and process execution
- **tables**: Hash tables for multi-project management and caching
- **times**: DateTime handling for project timestamps
- **strutils, sequtils**: String and sequence utilities

### Database Requirements
- **Primary Database**: TiDB (MySQL-compatible distributed database)
  - Easy setup via TiUP: `tiup playground`
  - No complex installation or configuration required
  - Automatic schema creation via Debby ORM models
  - Handles table creation, indexing, and migrations automatically

### Why TiDB?
- **Zero Configuration**: Single command startup with `tiup playground`
- **MySQL Compatible**: Works with existing MySQL ecosystem and tools
- **Development Speed**: No need to install and configure MySQL locally
- **Testing Isolation**: Easy to create/destroy test databases
- **Production Scalable**: Distributed architecture scales horizontally
- **Modern Architecture**: Cloud-native, ACID compliant, supports both OLTP and OLAP

## Nim coding Guidelines
- We do not use "_" in naming (snake case), we prefer instead camel case
- Do not shadow the local `result` variable (Nim built-in)
- Doc comments: `##` below proc signature
- Prefer generics or object variants over methods and type inheritance
- Use `return expression` for early exits
- Prefer direct field access over getters/setters
- **NO `asyncdispatch`** - we use threads for concurrency
- Remove old code during refactoring
- Import full modules, not selected symbols
- Use `*` to export fields that should be publicly accessible
- If something is not exported, export it instead of doing workarounds
- Do not be afraid to break backwards compatibility
- Do not add comments talking about how good something is, it is just noise. Be brief.
- Do not add comments that reflect what has changed, we use git for change tracking, only describe current code
- Do not add unnecessary commentary or explain code that is self-explanatory
- **DO NOT USE `asyncdispatch`** - This project explicitly avoids asyncdispatch for concurrency
- Generally try to avoid Option[T] if possible, it is not a style I like that much
- **Single-line functions**: Use direct expression without `result =` assignment or `return` statement
- **Multi-line functions**: Use `result =` assignment and `return` statement for clarity
- **Early exits**: Use `return value` instead of `result = value; return`
- **JSON Object Construction**: Prefer the `%*{}` syntax for clean, readable JSON creation
- **Content Serialization**: Use dedicated procs or templates for consistent formatting

## MCP Tool Documentation Standards

When creating or updating MCP tools using the `mcpTool` macro, follow these documentation patterns for consistency and AI assistant usability:

### Documentation Pattern
```nim
mcpTool:
  proc toolName(param1: Type1, param2: Type2 = "default"): string {.gcsafe.} =
    ## Main tool description that explains what the tool does, when to use it,
    ## and what problem it solves. Should be comprehensive but concise, targeting
    ## AI assistants that need to understand the tool's purpose and context.
    ## - param1: Description of first parameter including its purpose and expected format
    ## - param2: Description of second parameter with default value explanation
```

### Documentation Requirements

#### Main Description (`##`)
- **Purpose**: Clearly explain what the tool does and what it accomplishes
- **When to use**: Describe scenarios where this tool should be used
- **Context**: Explain how it fits into typical workflows
- **AI-friendly**: Write for AI assistants who need to understand when and how to use the tool
- **Length**: 2-4 sentences providing comprehensive but concise information

#### Parameter Documentation (`## - paramName:`)
- **Format**: Use `## - paramName: Description` format for each parameter
- **Required vs Optional**: Clearly indicate optional parameters and their defaults
- **Expected Values**: Describe what values are valid or expected
- **Examples**: Include format examples when helpful (e.g., version constraints, file paths)

#### Section Organization
- **Group related tools**: Use clear section headers with `# ============` borders
- **Logical ordering**: Place core functionality first, followed by specialized tools
- **Consistent naming**: Use descriptive section names that explain the tool category

### Example Sections
```nim
# ============================================================================
# CORE PROJECT ANALYSIS TOOLS
# Tools for indexing, searching, and analyzing Nim projects and their code
# ============================================================================
```

This documentation pattern ensures that AI assistants can easily understand:
1. What each tool does and why it exists
2. When to use each tool in typical workflows
3. What parameters are required and what values are expected
4. How tools relate to each other within functional groups

## Development Best Practices
- Always end todolists by running all the tests at the end to verify everything compiles and works

### Refactoring and Code Cleanup
- **Remove old unused code during refactoring** - We prioritize clean, maintainable code over backwards compatibility
- When implementing new architecture patterns, completely remove the old implementation patterns
- Delete deprecated methods, unused types, and obsolete code paths immediately
- Keep the codebase lean and focused on the current architectural approach
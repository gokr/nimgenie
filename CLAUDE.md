# NimGenie: MCP Tool for Nim Programming

## Project Overview
NimGenie is a comprehensive MCP (Model Context Protocol) server for Nim programming that leverages the Nim compiler's built-in capabilities to provide intelligent code analysis, indexing, and development assistance. It uses the nimcp library for clean MCP integration and provides AI assistants with rich contextual information about Nim codebases.

## Current Architecture (Multi-Project + Nimble Package Support)

### Core Architecture Design

**NimGenie as Central Coordinator:**
- **Database Ownership**: NimGenie owns and manages the MySQL database with connection pooling
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
    database*: Database                    # Owns MySQL database with connection pooling
    projects*: Table[string, NimProject]   # Multiple projects indexed by path
    nimblePackages*: Table[string, string] # Discovered packages (name -> path)
    symbolCache*: Table[string, JsonNode]  # In-memory cache for frequent lookups
    registeredDirectories*: seq[string]    # Directories served as MCP resources
```

## Architecture Decisions

### Index Storage & Querying Strategy

**Hybrid MySQL + Debby ORM + In-Memory Cache Approach:**

#### MySQL + Debby Benefits:
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

#### MySQL Schema (via Debby Models):
```sql
CREATE TABLE symbols (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  symbol_type VARCHAR(100) NOT NULL,
  module VARCHAR(255) NOT NULL,  
  file_path TEXT NOT NULL,
  line INT NOT NULL,
  column INT NOT NULL,
  signature TEXT,
  documentation TEXT,
  visibility VARCHAR(50),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_symbols_name (name),
  INDEX idx_symbols_module (module),
  INDEX idx_symbols_type (symbol_type),
  INDEX idx_symbols_file (file_path(255))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

#### Debby Model Definitions:
```nim
type
  Symbol* = ref object
    id*: int
    name*: string
    symbolType*: string  # Maps to symbol_type via snake_case conversion
    module*: string
    filePath*: string    # Maps to file_path
    line*: int
    column*: int
    signature*: Option[string]
    documentation*: Option[string]
    visibility*: Option[string]
    createdAt*: string   # Maps to created_at
  
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

**Debby ORM Integration Patterns Following tankfeudserver:**

#### Connection Pool Management:
```nim
proc newDatabase*(): Database =
  ## Initialize database with connection pool
  let host = getEnv("MYSQL_HOST", "localhost")
  let port = parseInt(getEnv("MYSQL_PORT", "3306"))
  let user = getEnv("MYSQL_USER", "root")
  let password = getEnv("MYSQL_PASSWORD", "")
  let database = getEnv("MYSQL_DATABASE", "nimgenie")
  let poolSize = parseInt(getEnv("MYSQL_POOL_SIZE", "10"))
  
  result.pool = newPool()
  for i in 0 ..< poolSize:
    result.pool.add openDatabase(database, host, port, user, password)
```

#### Database Operations Patterns:
```nim
# Insert new records
proc insertSymbol*(db: Database, ...): int =
  let symbol = Symbol(name: name, symbolType: symbolType, ...)
  db.pool.insert(symbol)
  return symbol.id

# Query with conditions  
proc searchSymbols*(db: Database, query: string, ...): JsonNode =
  let symbols = db.pool.query(Symbol, "SELECT * FROM symbols WHERE name LIKE ?", fmt"%{query}%")
  
# Filter with object conditions
proc findModule*(db: Database, name: string): Option[Module] =
  let modules = db.pool.filter(Module, it.name == name)
  if modules.len > 0: some(modules[0]) else: none(Module)

# Raw SQL operations
proc clearSymbols*(db: Database, moduleName: string = "") =
  db.pool.withDb:
    if moduleName == "":
      discard db.query("DELETE FROM symbols")
    else:
      discard db.query("DELETE FROM symbols WHERE module = ?", moduleName)
```

#### Field Mapping Conventions:
- **Automatic snake_case**: Nim `symbolType` → MySQL `symbol_type`
- **Explicit mapping**: Use descriptive Nim names, let Debby handle DB columns
- **Optional fields**: Use `Option[T]` for nullable database columns
- **Primary keys**: Always `id*: int` for auto-increment columns

#### Configuration Environment Variables:
- `MYSQL_HOST` - Database host (default: localhost)
- `MYSQL_PORT` - Database port (default: 3306)  
- `MYSQL_USER` - Database user (default: root)
- `MYSQL_PASSWORD` - Database password (default: empty)
- `MYSQL_DATABASE` - Database name (default: nimgenie)
- `MYSQL_POOL_SIZE` - Connection pool size (default: 10)

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
- **Shared symbol database**: All projects share the same MySQL database for unified search
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
3. Set up MySQL database schema with Debby ORM for symbol indexing
4. Implement basic exec wrapper for nim compiler commands
5. Create initial project indexing functionality using `nim doc --index`

### Phase 2: Core Indexing System ✅
6. Implement MySQL + Debby ORM storage for parsed symbol data
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
- **debby/mysql**: MySQL database with connection pooling for persistent symbol storage
- **json**: JSON parsing for nim compiler output
- **os, osproc**: System operations and process execution
- **tables**: Hash tables for multi-project management and caching
- **times**: DateTime handling for project timestamps
- **strutils, sequtils**: String and sequence utilities

## Development Commands

### MySQL Configuration
Set up your MySQL database connection via environment variables:
```bash
export MYSQL_HOST=localhost
export MYSQL_PORT=3306
export MYSQL_USER=nimgenie_user
export MYSQL_PASSWORD=your_password
export MYSQL_DATABASE=nimgenie
export MYSQL_POOL_SIZE=10
```

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


## Coding Guidelines

### Variable Naming
- Do not introduce a local variable called "result" since Nim has such a variable already defined that represents the return value
- Always use doc comment with double "##" right below the signature for Nim procs, not above

### Result Variable and Return Statement Style
Follow these patterns for idiomatic Nim code:

**Single-line functions**: Use direct expression without `result =` assignment
```nim
proc getTimeout*(server: McpServer): int =
  server.requestTimeout

proc `%`*(id: JsonRpcId): JsonNode =
  case id.kind
  of jridString: %id.str
  of jridNumber: %id.num
```

**Multi-line functions with return at end**: Use `return expression` for clarity
```nim
proc handleInitialize(server: McpServer, params: JsonNode): JsonNode =
  server.initialized = true
  return createInitializeResponseJson(server.serverInfo, server.capabilities)
```

**Early exits**: Use `return value` instead of `result = value; return`
```nim
proc validateInput(value: string): bool =
  if value.len == 0:
    return false
  # ... more validation
  true
```

**Exception handlers**: Use `return expression` for error cases
```nim
proc processRequest(): McpToolResult =
  try:
    # ... processing
    McpToolResult(content: @[result])
  except ValueError:
    return McpToolResult(content: @[createTextContent("Error: Invalid input")])
```

**Avoid**: The verbose pattern of `result = value; return` for early exits

### Field Access Guidelines

**Direct Field Access**: Prefer direct field access over trivial getter/setter procedures
```nim
# Preferred: Direct field access for simple get/set operations
server.requestTimeout = 5000        # Direct assignment
let timeout = server.requestTimeout # Direct access
composed.mainServer                 # Direct access to public fields
mountPoint.server                   # Direct access to public fields

# Avoid: Trivial getter/setter procedures
proc getRequestTimeout*(server: McpServer): int = server.requestTimeout
proc setRequestTimeout*(server: McpServer, timeout: int) = server.requestTimeout = timeout
```

**When to Use Procedures**: Reserve procedures for complex operations with logic
```nim
# Appropriate: Complex logic, validation, or side effects
proc setLogLevel*(server: McpServer, level: LogLevel) =
  server.logger.setMinLevel(level)  # Calls method on nested object

proc getServerStats*(server: McpServer): Table[string, JsonNode] =
  # Complex computation combining multiple fields
  result = initTable[string, JsonNode]()
  result["serverName"] = %server.serverInfo.name
  result["toolCount"] = %server.getRegisteredToolNames().len
```

**Public Field Declaration**: Use `*` to export fields that should be directly accessible
```nim
type
  McpServer* = ref object
    serverInfo*: McpServerInfo      # Public - direct access allowed
    requestTimeout*: int            # Public - direct access allowed
    initialized*: bool              # Public - direct access allowed
    internalState: SomePrivateType  # Private - no direct access
```

### JSON Handling Style Guidelines

**JSON Object Construction**: Prefer the `%*{}` syntax for clean, readable JSON creation
```nim
# Preferred: Clean and readable
let response = %*{
  "content": contentsToJsonArray(contents),
  "isError": false
}

# Avoid: Manual construction when %*{} is sufficient
let response = newJObject()
response["content"] = contentsToJsonArray(contents)
response["isError"] = %false
```

**Field Access**: Use consolidated utility functions for consistent error handling
```nim
# Preferred: Type-safe field access with clear error messages
let toolName = requireStringField(params, "name")
let optionalArg = getStringField(params, "argument", "default")

# Avoid: Direct access without proper error handling
let toolName = params["name"].getStr()  # Can throw exceptions
```

**Content Serialization**: Use centralized utilities for consistent formatting
```nim
# Preferred: Consolidated utilities
let jsonContent = contentToJsonNode(content)
let jsonArray = contentsToJsonArray(contents)

# Avoid: Manual serialization patterns
let jsonContent = %*{
  "type": content.`type`,
  "text": content.text  # Missing proper variant handling
}
```

**Error Response Creation**: Use standardized error utilities across all transport layers
```nim
# Preferred: Consistent error responses
let errorResponse = createParseError(details = e.msg)
let invalidResponse = createInvalidRequest(id, "Missing required field")

# Avoid: Manual error construction
let errorResponse = JsonRpcResponse(
  jsonrpc: "2.0",
  id: id,
  error: some(JsonRpcError(code: -32700, message: "Parse error"))
)
```

**Field Validation**: Combine validation with field access for cleaner code
```nim
# Preferred: Validation integrated with access
proc handleToolCall(params: JsonNode): JsonNode =
  let toolName = requireStringField(params, "name")  # Validates and extracts
  let arguments = params.getOrDefault("arguments", newJObject())

# Avoid: Separate validation and access steps
proc handleToolCall(params: JsonNode): JsonNode =
  if not params.hasKey("name"):
    raise newException(ValueError, "Missing name field")
  let toolName = params["name"].getStr()
```

## Development Best Practices
- Always end todolists by running all the tests at the end to verify everything compiles and works

### Async and Concurrency Guidelines
- **DO NOT USE `asyncdispatch`** - This project explicitly avoids asyncdispatch for concurrency
- Use **`taskpools`** for concurrent processing and background tasks
- Use **synchronous I/O** with taskpools rather than async/await patterns
- For HTTP/WebSocket transports, use Mummy's built-in async capabilities but avoid introducing asyncdispatch dependencies
- All concurrent operations should be implemented using taskpools and synchronous patterns for stdio transport
- Real-time capabilities are provided via WebSocket transport using Mummy's built-in WebSocket support

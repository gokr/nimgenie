# AGENTS.md - Coding Guidelines for NimGenie

## Build/Lint/Test Commands

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

## Code Style Guidelines

### Naming Conventions
- Use camelCase, not snake_case
- Use `*` to export fields that should be publicly accessible
- Do not shadow the local `result` variable

### Imports
- Import full modules, not selected symbols
- If something is not exported, export it instead of doing workarounds

### Functions
- Single-line functions: Use direct expression without `result =` assignment
- Multi-line functions: Use `result =` assignment and `return` statement
- Early exits: Use `return value` instead of `result = value; return`

### Documentation
- Doc comments: `##` below proc signature
- MCP tools: Follow the pattern in CLAUDE.md with comprehensive descriptions

### Types & Error Handling
- Prefer generics or object variants over methods and type inheritance
- Generally avoid Option[T] if possible
- Prefer direct field access over getters/setters

### Concurrency
- NO `asyncdispatch` - we use threads for concurrency
- DO NOT USE `asyncdispatch` - explicitly avoided for concurrency

### JSON & Formatting
- JSON Object Construction: Prefer the `%*{}` syntax
- Content Serialization: Use dedicated procs or templates

### Refactoring
- Remove old unused code during refactoring
- Do not be afraid to break backwards compatibility
- Delete deprecated methods, unused types, and obsolete code paths immediately

### Comments
- Do not add comments talking about how good something is
- Do not add comments that reflect what has changed (use git)
- Do not add unnecessary commentary or explain self-explanatory code
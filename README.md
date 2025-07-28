# NimGenie

**MCP Server for AI assisted Nim Programming**

NimGenie is a Model Context Protocol (MCP) server that provides AI assistants with deep understanding of Nim codebases through intelligent code analysis, symbol indexing, and development assistance.

## What is NimGenie?

NimGenie bridges the gap between AI assistants and Nim development by providing MCP tools for the LLM to use to:

- **Intelligent Symbol Search**: Find functions, types, and variables across your entire codebase and dependencies
- **Real-time Code Analysis**: Perform syntax checking and semantic validation using the Nim compiler
- **Dependency Management**: Automatic discovery and indexing of Nimble packages
- **Multi-Project Support**: Work with multiple Nim projects simultaneously
- **Persistent Storage**: TiDB-backed symbol database that survives server restarts

## Key Features

### 🔍 **Code Indexing**
- Search symbols by name, type, or module across your entire codebase
- Automatic indexing of project dependencies and Nimble packages
- Cross-reference functionality to understand code relationships
- Dependency-based incremental indexing that only re-indexes changed files and their dependents

### 🛠️ **Development Tasks**
- Syntax and semantic checking with detailed error reporting
- Project statistics and codebase metrics
- Nimble package management (install, search, upgrade)
- Project creation and build automation
- Dependency-based incremental indexing for efficient re-indexing

### 📁 **Resource Management**
- Serve project files and assets as MCP resources
- Screenshot workflow support for game development
- Directory-based resource organization


## Quick Start

### 1. Prerequisites

- **Nim 2.2.4+**: Install from [nim-lang.org](https://nim-lang.org)
- **TiDB**: For persistent storage (see setup below)
- **Ollama**: For running a local LLM to perform embeddings

### 2. TiDB Setup

NimGenie uses TiDB for persistent storage. The easiest way to get started running Tidb locally is with TiUP:

```bash
# Install TiUP (TiDB cluster management tool)
curl --proto '=https' --tlsv1.2 -sSf https://tiup-mirrors.pingcap.com/install.sh | sh

# Start a persistent TiDB playground for Nimgenie (includes TiDB, TiKV, PD)
tiup playground --tag nimgenie
```

This starts TiDB on `localhost:4000` with default settings (user: `root`, password: empty).

### 3. Install NimGenie

```bash
# Clone the repository
git clone https://github.com/gokr/nimgenie
cd nimgenie

# Build the MCP server
nimble build

# Run NimGenie
./nimgenie

# Install globally
nimble install
```

### 4. Configuration

NimGenie can be configured via environment variables or command-line options.

| Variable | Description | Default |
|----------|-------------|---------|
| `TIDB_HOST` | Database host | localhost |
| `TIDB_PORT` | Database port | 4000 |
| `TIDB_USER` | Database user | root |
| `TIDB_PASSWORD` | Database password | (empty) |
| `TIDB_DATABASE` | Database name | nimgenie |
| `TIDB_POOL_SIZE` | Connection pool size | 10 |

Command-line options:

```
Usage: nimgenie [OPTIONS]

Options:
  -h, --help              Show help message
  -v, --version           Show version information
  -p, --port <number>     MCP server port (default: 8080)
      --host <address>    Host address (default: localhost)
      --project <path>    Project directory (default: current directory)
      --verbose           Enable verbose logging
      --database-host     TiDB host (default: localhost)
      --database-port     TiDB port (default: 4000)
      --no-discovery      Disable Nimble package discovery
```


### 5. Tutorial

For some feeling how to use Nimgenie, see the [tutorial](TUTORIAL.md).


## Architecture

NimGenie is built with Nimcp, a library that makes it easy to build MCP servers. We mostly call out to Nim tools like nimble and the Nim compiler etc to perform indexing and other tasks. The database used is Tidb because it is MySQL compatible, fully Open Source, can run locally or is also available in the cloud and supports vector based searching and more. Embeddings are calculated via Ollama with an embeddings LLM running, typically locally.

### Dependency Tracking

NimGenie uses the Nim compiler's built-in dependency analysis (`nim genDepend`) to track file dependencies efficiently. This enables:

- **Incremental indexing**: Only re-index files that have changed and their dependents
- **Accurate dependency tracking**: Leverages the compiler's understanding of imports and modules
- **Efficient updates**: Avoids full re-indexing on every change
- **Cascade changes**: Automatically identifies all files affected by a dependency change

The dependency information is stored in the TiDB database with tables for:
- `file_dependency`: Tracks source → target file dependencies
- `file_modification`: Stores file modification times, sizes, and hashes

This approach is more reliable than manual file hash/modification tracking as it uses the compiler's own dependency analysis, handling complex import scenarios correctly.

## Contributing

We welcome contributions! Please see our development documentation in `CLAUDE.md` for detailed information about the codebase architecture and development guidelines.

## License

MIT License - see LICENSE file for details.

## Links

- **Nimcp**: [github.com/gokr/nimcp](https://github.com/gokr/nimcp)
- **MCP Protocol**: [modelcontextprotocol.io](https://modelcontextprotocol.io)
- **Nim Language**: [nim-lang.org](https://nim-lang.org)
- **TiDB Database**: [pingcap.com](https://pingcap.com)
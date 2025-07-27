# NimGenie

**MCP Server for Intelligent Nim Programming**

NimGenie is a comprehensive Model Context Protocol (MCP) server that provides AI assistants with deep understanding of Nim codebases through intelligent code analysis, symbol indexing, and development assistance.

## What is NimGenie?

NimGenie bridges the gap between AI assistants and Nim development by providing:

- **Intelligent Symbol Search**: Find functions, types, and variables across your entire codebase and dependencies
- **Real-time Code Analysis**: Syntax checking and semantic validation using the Nim compiler
- **Dependency Management**: Automatic discovery and indexing of Nimble packages
- **Multi-Project Support**: Work with multiple Nim projects simultaneously
- **Persistent Storage**: TiDB-backed symbol database that survives server restarts

## Key Features

### 🔍 **Smart Code Discovery**
- Search symbols by name, type, or module across your entire codebase
- Automatic indexing of project dependencies and Nimble packages
- Cross-reference functionality to understand code relationships

### 🛠️ **Development Tools**
- Syntax and semantic checking with detailed error reporting
- Project statistics and codebase metrics
- Nimble package management (install, search, upgrade)
- Project creation and build automation

### 📁 **Resource Management**
- Serve project files and assets as MCP resources
- Screenshot workflow support for game development
- Directory-based resource organization

### 🏗️ **Scalable Architecture**
- TiDB database for high-performance symbol storage
- Connection pooling for concurrent access
- In-memory caching for frequently accessed symbols

## Quick Start

### 1. Prerequisites

- **Nim 2.2.4+**: Install from [nim-lang.org](https://nim-lang.org)
- **TiDB**: For symbol storage (see setup below)
- **Nimble**: For package management (included with Nim)

### 2. TiDB Setup

NimGenie uses TiDB for persistent symbol storage. The easiest way to get started is with TiUP:

```bash
# Install TiUP (TiDB cluster management tool)
curl --proto '=https' --tlsv1.2 -sSf https://tiup-mirrors.pingcap.com/install.sh | sh

# Start TiDB playground (includes TiDB, TiKV, PD)
tiup playground
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
```

### 4. Configuration

NimGenie can be configured via environment variables or command-line options:

```bash
# Environment variables
export TIDB_HOST=localhost
export TIDB_PORT=4000
export TIDB_USER=root
export TIDB_PASSWORD=your_password
export TIDB_DATABASE=nimgenie

# Command-line options
./nimgenie --port 8080 --host localhost --project /path/to/nim/project
```

## Usage Examples

### Basic Workflow

1. **Index your project**:
   ```
   AI: Use indexCurrentProject() to analyze the codebase
   ```

2. **Search for symbols**:
   ```
   AI: Use searchSymbols("HttpServer", "type") to find HTTP server types
   ```

3. **Get detailed information**:
   ```
   AI: Use getSymbolInfo("newHttpServer") for usage details
   ```

4. **Check syntax**:
   ```
   AI: Use checkSyntax("src/main.nim") to validate code
   ```

### Package Management

```bash
# Install a package
AI: Use nimbleInstallPackage("jester", ">= 0.5.0")

# Index the package for search
AI: Use indexNimblePackage("jester")

# Search package symbols
AI: Use searchSymbols("get", "proc", "jester")
```

### Project Development

```bash
# Create a new project
AI: Use nimbleInitProject("myapp", "bin")

# Build the project
AI: Use nimbleBuildProject()

# Run tests
AI: Use nimbleTestProject()
```

## MCP Integration

NimGenie implements the Model Context Protocol, making it easy to integrate with AI development tools:

### Supported MCP Tools

- **Project Analysis**: `indexCurrentProject`, `getProjectStats`, `checkSyntax`
- **Symbol Search**: `searchSymbols`, `getSymbolInfo`
- **Package Management**: `nimbleInstallPackage`, `nimbleSearchPackages`, `listNimblePackages`
- **Development**: `nimbleBuildProject`, `nimbleTestProject`, `nimbleRunProject`
- **Resources**: `addDirectoryResource`, `listDirectoryResources`

### Resource Templates

- `/files/{dirIndex}/{relativePath}`: Access files from registered directories
- `/screenshots/{filepath}`: Access screenshot files for game development

## Configuration Options

### Command Line Options

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

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `TIDB_HOST` | Database host | localhost |
| `TIDB_PORT` | Database port | 4000 |
| `TIDB_USER` | Database user | root |
| `TIDB_PASSWORD` | Database password | (empty) |
| `TIDB_DATABASE` | Database name | nimgenie |
| `TIDB_POOL_SIZE` | Connection pool size | 10 |

## Architecture

NimGenie uses a multi-layered architecture for scalable Nim code analysis:

- **MCP Layer**: Handles AI assistant communication and tool registration
- **Analysis Layer**: Nim compiler integration for syntax checking and symbol extraction
- **Storage Layer**: TiDB database with Debby ORM for persistent symbol storage
- **Cache Layer**: In-memory caching for frequently accessed symbols
- **Resource Layer**: File serving and screenshot management

## Contributing

We welcome contributions! Please see our development documentation in `CLAUDE.md` for detailed information about the codebase architecture and development guidelines.

## License

MIT License - see LICENSE file for details.

## Links

- **GitHub**: [github.com/gokr/nimgenie](https://github.com/gokr/nimgenie)
- **MCP Protocol**: [modelcontextprotocol.io](https://modelcontextprotocol.io)
- **Nim Language**: [nim-lang.org](https://nim-lang.org)
- **TiDB Database**: [pingcap.com](https://pingcap.com)
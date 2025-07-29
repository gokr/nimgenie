# External Database Integration

## Overview

NimGenie now provides comprehensive support for connecting to and querying external databases through a set of MCP tools. This feature enables AI assistants to interact with MySQL, TiDB, and PostgreSQL databases directly through the NimGenie MCP server.

## Architecture

### Multi-Database Support

The implementation supports three database types:
- **MySQL** - Standard MySQL databases (port 3306, user: root)
- **TiDB** - MySQL-compatible distributed database (port 3306, user: root)  
- **PostgreSQL** - PostgreSQL databases (port 5432, user: postgres) *[Framework ready]*

### Core Components

1. **`src/external_database.nim`** - Core database module with connection management
2. **`src/configuration.nim`** - Extended with external database configuration
3. **MCP Tools in `src/nimgenie.nim`** - 12 database interaction tools
4. **Environment Variables** - Configuration through DB_* environment variables

### Connection Architecture

- **Thread-Safe Connection Pooling** - Uses Debby ORM with connection pools
- **Persistent Connections** - Connections maintained across multiple queries
- **Automatic Driver Selection** - MySQL driver for MySQL/TiDB, PostgreSQL driver for PostgreSQL
- **Configuration-Driven** - Smart defaults with environment variable overrides

## Configuration

### Environment Variables

Configure database connections using these environment variables:

```bash
# Database connection configuration
export DB_TYPE="mysql"              # mysql, tidb, postgresql
export DB_HOST="localhost"          # Database server hostname
export DB_PORT="3306"              # Database port (3306 for MySQL/TiDB, 5432 for PostgreSQL)
export DB_USER="root"              # Database username
export DB_PASSWORD=""              # Database password
export DB_DATABASE="mysql"         # Database name to connect to
export DB_POOL_SIZE="5"            # Connection pool size
```

### Smart Defaults

The system automatically applies appropriate defaults based on database type:

| Database | Default Port | Default User | Default Database |
|----------|--------------|--------------|------------------|
| MySQL    | 3306         | root         | mysql            |
| TiDB     | 3306         | root         | test             |
| PostgreSQL| 5432        | postgres     | postgres         |

## MCP Tools

### Connection Management

#### `dbConnect(dbType, host, port, user, password, database)`
Connect to an external database and establish a persistent connection pool.

**Parameters:**
- `dbType`: Database type ("mysql", "tidb", "postgresql")
- `host`: Database server hostname (optional, default: localhost)
- `port`: Database port (optional, uses type-specific defaults)
- `user`: Database username (optional, uses type-specific defaults)
- `password`: Database password (optional, default: empty)
- `database`: Database name (optional, uses type-specific defaults)

**Example:**
```
dbConnect("mysql", "localhost", 3306, "root", "", "testdb")
```

#### `dbDisconnect()`
Close the database connection and free resources.

#### `dbStatus()`
Get current connection status and database information.

### Query Execution

#### `dbQuery(sql, params)`
Execute SELECT queries with optional parameterized values.

**Parameters:**
- `sql`: SQL SELECT statement (supports ? placeholders)
- `params`: Comma-separated parameter values (optional)

**Example:**
```
dbQuery("SELECT * FROM users WHERE age > ?", "25")
```

#### `dbExecute(sql, params)`
Execute INSERT, UPDATE, or DELETE statements.

**Example:**
```
dbExecute("INSERT INTO users (name, email) VALUES (?, ?)", "John,john@example.com")
```

#### `dbTransaction(sqlStatements)`
Execute multiple statements in a transaction with automatic rollback on error.

**Parameters:**
- `sqlStatements`: Semicolon-separated SQL statements

**Example:**
```
dbTransaction("UPDATE accounts SET balance = balance - 100 WHERE id = 1; UPDATE accounts SET balance = balance + 100 WHERE id = 2")
```

### Database Introspection

#### `dbListDatabases()`
List all databases available on the server.

#### `dbListTables(database)`
List all tables in the specified or current database.

#### `dbDescribeTable(tableName)`
Get detailed table schema including columns, types, and constraints.

#### `dbShowIndexes(tableName)`
Display all indexes defined on a table.

#### `dbExplainQuery(sql)`
Get query execution plan for performance analysis.

## JSON Response Format

All database operations return consistent JSON responses:

```json
{
  "success": true,
  "database_type": "mysql",
  "rows": [
    ["John", "john@example.com", 25],
    ["Jane", "jane@example.com", 30]
  ],
  "affected_rows": 0,
  "execution_time_ms": 15,
  "columns": ["name", "email", "age"],
  "row_count": 2,
  "error": null,
  "query_metadata": {
    "database_type": "mysql",
    "database": "testdb",
    "query_type": "SELECT"
  }
}
```

## Security Features

### SQL Injection Prevention
- **Parameterized Queries** - All user input is safely parameterized
- **Parameter Binding** - Automatic type conversion and escaping
- **Query Validation** - Input validation before execution

### Connection Security
- **Connection Pooling** - Secure connection reuse
- **Error Handling** - Sanitized error messages
- **Timeout Protection** - Query execution timeouts

## Usage Examples

### Basic Database Connection and Query
```nim
# Connect to MySQL database
dbConnect("mysql", "localhost", 3306, "root", "password", "mydb")

# Check connection status
dbStatus()

# List all tables
dbListTables()

# Query data
dbQuery("SELECT * FROM products WHERE price > ?", "100")

# Insert new record
dbExecute("INSERT INTO products (name, price) VALUES (?, ?)", "Widget,25.99")

# Disconnect
dbDisconnect()
```

### Database Schema Exploration
```nim
# Connect to database
dbConnect("mysql")

# List all databases
dbListDatabases()

# List tables in current database
dbListTables()

# Get table structure
dbDescribeTable("users")

# Check table indexes
dbShowIndexes("users")

# Analyze query performance
dbExplainQuery("SELECT * FROM users WHERE email = 'test@example.com'")
```

### Transaction Processing
```nim
# Connect and execute transaction
dbConnect("mysql")

dbTransaction("""
  UPDATE inventory SET quantity = quantity - 1 WHERE product_id = 123;
  INSERT INTO orders (product_id, customer_id, quantity) VALUES (123, 456, 1);
  INSERT INTO order_history (order_id, status) VALUES (LAST_INSERT_ID(), 'pending')
""")
```

## Database-Specific Features

### MySQL/TiDB
- Uses `SHOW` statements for introspection
- Supports `START TRANSACTION` syntax
- Backtick identifiers (`` `table` ``)
- `EXPLAIN` for query analysis

### PostgreSQL *(Framework Ready)*
- Uses `information_schema` for introspection
- Supports `BEGIN/COMMIT` transaction syntax
- Double-quote identifiers (`"table"`)
- `EXPLAIN ANALYZE` for detailed query analysis

## Error Handling

The system provides comprehensive error handling:

- **Connection Errors** - Database unavailable, authentication failures
- **SQL Errors** - Syntax errors, constraint violations
- **Transaction Errors** - Automatic rollback on failure
- **Timeout Errors** - Long-running query protection

All errors are returned in the standard JSON format with descriptive messages.

## Performance Considerations

### Connection Pooling
- **Pool Size** - Configurable via `DB_POOL_SIZE` (default: 5)
- **Connection Reuse** - Persistent connections across queries
- **Thread Safety** - Safe concurrent access with locking

### Query Optimization
- **Prepared Statements** - Automatic parameter binding
- **Result Caching** - Framework supports caching layers
- **Execution Timing** - Built-in performance monitoring

## Integration with NimGenie

The database tools integrate seamlessly with NimGenie's existing features:

- **Unified MCP Interface** - Same server handles both Nim analysis and database queries
- **Configuration System** - Uses NimGenie's existing configuration framework
- **Thread Safety** - Compatible with NimGenie's threading model
- **Error Reporting** - Consistent error handling across all features

## Future Enhancements

Planned improvements include:

1. **Full PostgreSQL Support** - Complete PostgreSQL driver integration
2. **Query Builder** - High-level query construction helpers
3. **Schema Migration Tools** - Database schema management
4. **Connection Monitoring** - Health checks and connection diagnostics
5. **Advanced Security** - SSL/TLS connection support

## Implementation Status

- ✅ **Core Architecture** - Multi-database connection framework
- ✅ **MySQL/TiDB Support** - Full implementation with all tools
- ✅ **Configuration System** - Environment variables and smart defaults  
- ✅ **MCP Tools** - Complete set of 12 database interaction tools
- ✅ **Security Features** - Parameterized queries and connection pooling
- ✅ **Documentation** - Comprehensive tool documentation and examples
- 🔧 **PostgreSQL Support** - Framework ready, driver integration pending
- 🔧 **Testing** - Comprehensive test suite implemented

This database integration transforms NimGenie from a Nim-specific tool into a comprehensive development assistant capable of both code analysis and database operations, making it invaluable for full-stack development workflows.
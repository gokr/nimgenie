import std/[json, strutils, strformat, os, times, locks]
import debby/pools, debby/common, debby/mysql
import configuration

# Note: For now, we'll focus on MySQL/TiDB support using the mysql driver
# PostgreSQL support can be added later with a more sophisticated driver selection system

type
  DatabaseType* = enum
    MySQL = "mysql"
    TiDB = "tidb"      # Uses MySQL driver but different defaults
    PostgreSQL = "postgresql"

  ExternalDbConfig* = object
    dbType*: DatabaseType
    host*: string
    port*: int
    user*: string
    password*: string
    database*: string
    poolSize*: int

  ExternalDatabase* = object
    config*: ExternalDbConfig
    pool*: Pool
    connected*: bool

  QueryResult* = object
    success*: bool
    rows*: seq[Row]
    affectedRows*: int
    executionTimeMs*: int
    columns*: seq[string] 
    rowCount*: int
    error*: string
    queryMetadata*: JsonNode

var externalDb: ExternalDatabase
var externalDbLock: Lock

proc initExternalDbLock*() =
  ## Initialize the external database lock
  initLock(externalDbLock)

template withExternalDb(body: untyped): untyped =
  ## Execute code block with external database access lock
  {.cast(gcsafe).}:
    acquire(externalDbLock)
    try:
      body
    finally:
      release(externalDbLock)

proc parseDbType*(dbTypeStr: string): DatabaseType =
  ## Parse database type from string
  case dbTypeStr.toLowerAscii():
  of "mysql":
    MySQL
  of "tidb":
    TiDB
  of "postgresql", "postgres":
    PostgreSQL
  else:
    raise newException(ValueError, fmt"Unsupported database type: {dbTypeStr}")

proc getDefaultPort*(dbType: DatabaseType): int =
  ## Get default port for database type
  case dbType:
  of MySQL, TiDB:
    3306
  of PostgreSQL:
    5432

proc getDefaultUser*(dbType: DatabaseType): string =
  ## Get default user for database type
  case dbType:
  of MySQL, TiDB:
    "root"
  of PostgreSQL:
    "postgres"

proc getDefaultDatabase*(dbType: DatabaseType): string =
  ## Get default database name for database type
  case dbType:
  of MySQL:
    "mysql"
  of TiDB:
    "test"
  of PostgreSQL:
    "postgres"

proc createExternalDbConfig*(config: Config): ExternalDbConfig =
  ## Create external database configuration with environment variable support
  let dbType = parseDbType(getEnv("DB_TYPE", config.externalDbType))
  
  result = ExternalDbConfig(
    dbType: dbType,
    host: getEnv("DB_HOST", if config.externalDbHost != "": config.externalDbHost else: "localhost"),
    port: parseInt(getEnv("DB_PORT", $getDefaultPort(dbType))),
    user: getEnv("DB_USER", if config.externalDbUser != "": config.externalDbUser else: getDefaultUser(dbType)),
    password: getEnv("DB_PASSWORD", config.externalDbPassword),
    database: getEnv("DB_DATABASE", if config.externalDbDatabase != "": config.externalDbDatabase else: getDefaultDatabase(dbType)),
    poolSize: parseInt(getEnv("DB_POOL_SIZE", $config.externalDbPoolSize))
  )

proc connectToExternalDatabase*(config: ExternalDbConfig): Pool =
  ## Connect to external database with appropriate driver
  result = newPool()
  
  case config.dbType:
  of MySQL, TiDB:
    # Use debby/mysql driver for both MySQL and TiDB
    for i in 0 ..< config.poolSize:
      let db = openDatabase(config.database, config.host, config.port, 
                           config.user, config.password)
      result.add(db)
  of PostgreSQL:
    # PostgreSQL support to be implemented later
    raise newException(ValueError, "PostgreSQL support not yet implemented")

proc isConnected*(): bool =
  ## Check if external database is connected
  withExternalDb:
    return externalDb.connected

proc connectExternalDb*(config: Config): bool =
  ## Connect to external database using configuration
  try:
    withExternalDb:
      if externalDb.connected:
        return true
      
      let dbConfig = createExternalDbConfig(config)
      externalDb.config = dbConfig
      externalDb.pool = connectToExternalDatabase(dbConfig)
      externalDb.connected = true
      
    return true
  except Exception as e:
    echo fmt"Failed to connect to external database: {e.msg}"
    return false

proc disconnectExternalDb*() =
  ## Disconnect from external database
  withExternalDb:
    if externalDb.connected and externalDb.pool != nil:
      # The pool's close template handles closing individual connections
      externalDb.pool.close()
      externalDb.connected = false

proc adaptQueryForDatabase*(sql: string, dbType: DatabaseType): string =
  ## Adapt SQL query syntax for specific database type
  case dbType:
  of MySQL, TiDB:
    # MySQL/TiDB syntax (backticks for identifiers, different LIMIT syntax)
    result = sql
    # Convert PostgreSQL-style identifiers to MySQL-style
    result = result.replace("\"", "`")
  of PostgreSQL:
    # PostgreSQL syntax (double quotes for identifiers, standard LIMIT/OFFSET)
    result = sql
    # Convert MySQL-style identifiers to PostgreSQL-style
    result = result.replace("`", "\"")

proc getDatabaseIntrospectionQuery*(queryType: string, dbType: DatabaseType): string =
  ## Get database-specific introspection queries
  case dbType:
  of MySQL, TiDB:
    case queryType:
    of "list_databases":
      "SHOW DATABASES"
    of "list_tables":
      "SHOW TABLES"
    of "describe_table":
      "DESCRIBE `{table}`"
    of "show_indexes":
      "SHOW INDEXES FROM `{table}`"
    else:
      raise newException(ValueError, fmt"Unknown query type: {queryType}")
      
  of PostgreSQL:
    case queryType:
    of "list_databases":
      "SELECT datname FROM pg_database WHERE datistemplate = false"
    of "list_tables":
      "SELECT tablename FROM pg_tables WHERE schemaname = 'public'"
    of "describe_table":
      """SELECT column_name, data_type, is_nullable, column_default 
         FROM information_schema.columns 
         WHERE table_name = '{table}' 
         ORDER BY ordinal_position"""
    of "show_indexes":
      """SELECT indexname, tablename, attname, schemaname
         FROM pg_indexes 
         JOIN pg_index ON pg_indexes.indexname = pg_class.relname
         JOIN pg_attribute ON pg_attribute.attrelid = pg_index.indrelid
         WHERE tablename = '{table}'"""
    else:
      raise newException(ValueError, fmt"Unknown query type: {queryType}")

proc executeExternalQuery*(sql: string, params: seq[string] = @[]): QueryResult =
  ## Execute query on external database and return formatted result
  result = QueryResult(success: false, executionTimeMs: 0, error: "")
  
  if not isConnected():
    result.error = "Not connected to external database"
    return result
  
  let startTime = cpuTime()
  
  try:
    withExternalDb:
      let adaptedSql = adaptQueryForDatabase(sql, externalDb.config.dbType)
      
      externalDb.pool.withDb:
        let rows = if params.len > 0:
          # Convert seq[string] to varargs for debby
          case params.len:
          of 1: db.query(adaptedSql, params[0])
          of 2: db.query(adaptedSql, params[0], params[1])  
          of 3: db.query(adaptedSql, params[0], params[1], params[2])
          of 4: db.query(adaptedSql, params[0], params[1], params[2], params[3])
          else:
            # For more parameters, we'll need to handle differently
            db.query(adaptedSql)
        else:
          db.query(adaptedSql)
        
        result.rows = rows
        result.rowCount = rows.len
        result.success = true
        
        # Extract column information if available
        if rows.len > 0:
          for i in 0 ..< rows[0].len:
            result.columns.add(fmt"col_{i}")
      
    result.executionTimeMs = int((cpuTime() - startTime) * 1000)
    result.queryMetadata = %*{
      "database_type": $externalDb.config.dbType,
      "database": externalDb.config.database,
      "query_type": if sql.toLowerAscii().startsWith("select"): "SELECT" else: "OTHER"
    }
    
  except Exception as e:
    result.error = e.msg
    result.executionTimeMs = int((cpuTime() - startTime) * 1000)

proc executeExternalTransaction*(sqlStatements: seq[string]): QueryResult =
  ## Execute multiple statements in a transaction
  result = QueryResult(success: false, executionTimeMs: 0, error: "")
  
  if not isConnected():
    result.error = "Not connected to external database"
    return result
  
  let startTime = cpuTime()
  
  try:
    withExternalDb:
      externalDb.pool.withDb:
        # Use the database-specific transaction syntax
        case externalDb.config.dbType:
        of MySQL, TiDB:
          discard db.query("START TRANSACTION")
        of PostgreSQL:
          discard db.query("BEGIN")
        
        try:
          var totalAffectedRows = 0
          for sql in sqlStatements:
            let adaptedSql = adaptQueryForDatabase(sql, externalDb.config.dbType)
            let queryRows = db.query(adaptedSql)
            totalAffectedRows += queryRows.len
          
          # Commit transaction
          discard db.query("COMMIT")
          result.success = true
          result.affectedRows = totalAffectedRows
          
        except Exception as txnError:
          # Rollback on error
          discard db.query("ROLLBACK")
          raise txnError
    
    result.executionTimeMs = int((cpuTime() - startTime) * 1000)
    result.queryMetadata = %*{
      "database_type": $externalDb.config.dbType,
      "database": externalDb.config.database,
      "query_type": "TRANSACTION",
      "statement_count": sqlStatements.len
    }
    
  except Exception as e:
    result.error = e.msg
    result.executionTimeMs = int((cpuTime() - startTime) * 1000)

proc getConnectionStatus*(): JsonNode =
  ## Get connection status and information
  withExternalDb:
    if not externalDb.connected:
      return %*{
        "connected": false,
        "error": "Not connected to external database"
      }
    
    return %*{
      "connected": true,
      "database_type": $externalDb.config.dbType,
      "host": externalDb.config.host,
      "port": externalDb.config.port,
      "database": externalDb.config.database,
      "user": externalDb.config.user,
      "pool_size": externalDb.config.poolSize
    }

proc formatQueryResult*(queryResult: QueryResult): JsonNode =
  ## Format query result as JSON
  result = newJObject()
  result["success"] = %queryResult.success
  result["database_type"] = if queryResult.queryMetadata != nil and queryResult.queryMetadata.hasKey("database_type"): 
    queryResult.queryMetadata["database_type"] 
  else: 
    %"unknown"
  result["rows"] = %queryResult.rows
  result["affected_rows"] = %queryResult.affectedRows
  result["execution_time_ms"] = %queryResult.executionTimeMs
  result["columns"] = %queryResult.columns
  result["row_count"] = %queryResult.rowCount
  result["error"] = if queryResult.error == "": newJNull() else: %queryResult.error
  result["query_metadata"] = if queryResult.queryMetadata != nil: queryResult.queryMetadata else: newJNull()
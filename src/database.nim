import std/[json, strutils, strformat, os, options]
import debby/pools, debby/mysql

type
  Symbol* = ref object
    id*: int
    name*: string  
    symbolType*: string  # Maps to symbol_type
    module*: string
    filePath*: string    # Maps to file_path  
    line*: int
    column*: int
    signature*: Option[string]
    documentation*: Option[string]
    visibility*: Option[string]
    createdAt*: string   # Maps to created_at
  
  Module* = ref object
    id*: int
    name*: string
    filePath*: string          # Maps to file_path
    lastModified*: Option[string]  # Maps to last_modified
    documentation*: Option[string]
    createdAt*: string         # Maps to created_at
  
  RegisteredDirectory* = ref object
    id*: int
    path*: string
    name*: Option[string]
    description*: Option[string]
    createdAt*: string  # Maps to created_at

  Database* = object
    pool*: Pool

proc newDatabase*(): Database =
  ## Create a new database instance with connection pool
  let host = getEnv("MYSQL_HOST", "localhost")
  let port = parseInt(getEnv("MYSQL_PORT", "3306"))
  let user = getEnv("MYSQL_USER", "root")
  let password = getEnv("MYSQL_PASSWORD", "")
  let database = getEnv("MYSQL_DATABASE", "nimgenie")
  let poolSize = parseInt(getEnv("MYSQL_POOL_SIZE", "10"))
  
  result.pool = newPool()
  for i in 0 ..< poolSize:
    result.pool.add openDatabase(database, host, port, user, password)
  
  # Create tables if they don't exist
  result.pool.withDb:
    discard db.query("""
      CREATE TABLE IF NOT EXISTS symbols (
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
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    """)
    
    discard db.query("""
      CREATE TABLE IF NOT EXISTS modules (
        id INT AUTO_INCREMENT PRIMARY KEY,
        name VARCHAR(255) UNIQUE NOT NULL,
        file_path TEXT NOT NULL,
        last_modified TIMESTAMP NULL,
        documentation TEXT,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        INDEX idx_modules_name (name),
        INDEX idx_modules_path (file_path(255))
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    """)
    
    discard db.query("""
      CREATE TABLE IF NOT EXISTS registered_directories (
        id INT AUTO_INCREMENT PRIMARY KEY,
        path TEXT UNIQUE NOT NULL,
        name VARCHAR(255),
        description TEXT,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        INDEX idx_registered_dirs_path (path(255))
      ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    """)

proc closeDatabase*(db: Database) =
  ## Close the database connection pool
  if db.pool != nil:
    db.pool.close()

proc insertSymbol*(db: Database, name, symbolType, module, filePath: string,
                  line, column: int, signature = "", documentation = "", 
                  visibility = ""): int =
  ## Insert a symbol into the database and return its ID
  try:
    let symbol = Symbol(
      name: name,
      symbolType: symbolType,
      module: module,
      filePath: filePath,
      line: line,
      column: column,
      signature: if signature == "": none(string) else: some(signature),
      documentation: if documentation == "": none(string) else: some(documentation),
      visibility: if visibility == "": none(string) else: some(visibility)
    )
    db.pool.insert(symbol)
    return symbol.id
  except Exception as e:
    echo "Database error inserting symbol: ", e.msg
    return -1

proc insertModule*(db: Database, name, filePath: string, lastModified: string = "", 
                  documentation: string = ""): int =
  ## Insert or update a module in the database
  try:
    # Try to find existing module first
    let existing = db.pool.filter(Module, it.name == name)
    if existing.len > 0:
      # Update existing module
      let module = existing[0]
      module.filePath = filePath
      module.lastModified = if lastModified == "": none(string) else: some(lastModified)
      module.documentation = if documentation == "": none(string) else: some(documentation)
      db.pool.update(module)
      return module.id
    else:
      # Insert new module
      let module = Module(
        name: name,
        filePath: filePath,
        lastModified: if lastModified == "": none(string) else: some(lastModified),
        documentation: if documentation == "": none(string) else: some(documentation)
      )
      db.pool.insert(module)
      return module.id
  except Exception as e:
    echo "Database error inserting module: ", e.msg
    return -1

proc searchSymbols*(db: Database, query: string, symbolType: string = "", 
                   moduleName: string = ""): JsonNode =
  ## Search for symbols matching the query
  result = newJArray()
  
  try:
    # Build SQL query for LIKE search with conditional filters
    var sqlQuery = "SELECT * FROM symbols WHERE name LIKE ?"
    var params: seq[string] = @[fmt"%{query}%"]
    
    if symbolType != "":
      sqlQuery.add(" AND symbol_type = ?")
      params.add(symbolType)
      
    if moduleName != "":
      sqlQuery.add(" AND module = ?")
      params.add(moduleName)
    
    sqlQuery.add(" ORDER BY name LIMIT 100")
    
    let symbols = db.pool.query(Symbol, sqlQuery, params)
    
    for symbol in symbols:
      let symbolObj = %*{
        "name": symbol.name,
        "type": symbol.symbolType, 
        "module": symbol.module,
        "file_path": symbol.filePath,
        "line": symbol.line,
        "column": symbol.column,
        "signature": if symbol.signature.isSome: symbol.signature.get else: "",
        "documentation": if symbol.documentation.isSome: symbol.documentation.get else: "",
        "visibility": if symbol.visibility.isSome: symbol.visibility.get else: ""
      }
      result.add(symbolObj)
      
  except Exception as e:
    echo "Database error searching symbols: ", e.msg
    result = %*{"error": e.msg}

proc getSymbolInfo*(db: Database, symbolName: string, moduleName: string = ""): JsonNode =
  ## Get detailed information about a specific symbol
  try:
    var sqlQuery = "SELECT * FROM symbols WHERE name = ?"
    var params: seq[string] = @[symbolName]
    
    if moduleName != "":
      sqlQuery.add(" AND module = ?")
      params.add(moduleName)
    
    sqlQuery.add(" ORDER BY module")
    
    let symbols = db.pool.query(Symbol, sqlQuery, params)
    
    if symbols.len == 0:
      return %*{"error": fmt"Symbol '{symbolName}' not found"}
    
    if symbols.len == 1:
      let symbol = symbols[0]
      return %*{
        "name": symbol.name,
        "type": symbol.symbolType,
        "module": symbol.module, 
        "file_path": symbol.filePath,
        "line": symbol.line,
        "column": symbol.column,
        "signature": if symbol.signature.isSome: symbol.signature.get else: "",
        "documentation": if symbol.documentation.isSome: symbol.documentation.get else: "",
        "visibility": if symbol.visibility.isSome: symbol.visibility.get else: ""
      }
    else:
      # Multiple matches, return all
      result = newJArray()
      for symbol in symbols:
        let symbolObj = %*{
          "name": symbol.name,
          "type": symbol.symbolType,
          "module": symbol.module,
          "file_path": symbol.filePath, 
          "line": symbol.line,
          "column": symbol.column,
          "signature": if symbol.signature.isSome: symbol.signature.get else: "",
          "documentation": if symbol.documentation.isSome: symbol.documentation.get else: "",
          "visibility": if symbol.visibility.isSome: symbol.visibility.get else: ""
        }
        result.add(symbolObj)
        
  except Exception as e:
    echo "Database error getting symbol info: ", e.msg
    result = %*{"error": e.msg}

proc clearSymbols*(db: Database, moduleName: string = "") =
  ## Clear symbols, optionally for just one module
  try:
    if moduleName == "":
      db.pool.withDb:
        discard db.query("DELETE FROM symbols")
    else:
      db.pool.withDb:
        discard db.query("DELETE FROM symbols WHERE module = ?", moduleName)
  except Exception as e:
    echo "Database error clearing symbols: ", e.msg

proc getProjectStats*(db: Database): JsonNode =
  ## Get statistics about the indexed project
  try:
    db.pool.withDb:
      let symbolCountRows = db.query("SELECT COUNT(*) FROM symbols")
      let moduleCountRows = db.query("SELECT COUNT(*) FROM modules")
      let typeStatsRows = db.query("""
        SELECT symbol_type, COUNT(*) as count 
        FROM symbols 
        GROUP BY symbol_type 
        ORDER BY count DESC
      """)
      
      let symbolCount = if symbolCountRows.len > 0: parseInt(symbolCountRows[0][0]) else: 0
      let moduleCount = if moduleCountRows.len > 0: parseInt(moduleCountRows[0][0]) else: 0
      
      var typeStatsJson = newJArray()
      for row in typeStatsRows:
        typeStatsJson.add(%*{
          "type": row[0],
          "count": parseInt(row[1])
        })
      
      return %*{
        "total_symbols": symbolCount,
        "total_modules": moduleCount,
        "symbol_types": typeStatsJson
      }
    
  except Exception as e:
    echo "Database error getting stats: ", e.msg
    return %*{"error": e.msg}

proc addRegisteredDirectory*(db: Database, path: string, name: string = "", description: string = ""): bool =
  ## Add a directory to the registered directories table
  try:
    let displayName = if name == "": path.extractFilename() else: name
    
    # Try to find existing directory first
    let existing = db.pool.filter(RegisteredDirectory, it.path == path)
    if existing.len > 0:
      # Update existing directory
      let directory = existing[0]
      directory.name = if displayName == "": none(string) else: some(displayName)
      directory.description = if description == "": none(string) else: some(description)
      db.pool.update(directory)
    else:
      # Insert new directory
      let directory = RegisteredDirectory(
        path: path,
        name: if displayName == "": none(string) else: some(displayName),
        description: if description == "": none(string) else: some(description)
      )
      db.pool.insert(directory)
    
    return true
  except Exception as e:
    echo "Database error adding registered directory: ", e.msg
    return false

proc removeRegisteredDirectory*(db: Database, path: string): bool =
  ## Remove a directory from the registered directories table
  try:
    let existing = db.pool.filter(RegisteredDirectory, it.path == path)
    if existing.len > 0:
      db.pool.delete(existing[0])
    return true
  except Exception as e:
    echo "Database error removing registered directory: ", e.msg
    return false

proc getRegisteredDirectories*(db: Database): JsonNode =
  ## Get all registered directories
  result = newJArray()
  try:
    let directories = db.pool.filter(RegisteredDirectory, "1=1 ORDER BY created_at DESC")
    
    for directory in directories:
      let dirObj = %*{
        "path": directory.path,
        "name": if directory.name.isSome: directory.name.get else: "",
        "description": if directory.description.isSome: directory.description.get else: "",
        "created_at": directory.createdAt
      }
      result.add(dirObj)
      
  except Exception as e:
    echo "Database error getting registered directories: ", e.msg
    result = %*{"error": e.msg}
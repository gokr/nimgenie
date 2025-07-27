import std/[json, strutils, strformat, os, options, times]
import debby/pools, debby/mysql, debby/common

type
  Symbol* = ref object
    id*: int
    name*: string  
    symbolType*: string  # Maps to symbol_type
    module*: string
    filePath*: string    # Maps to file_path  
    line*: int
    col*: int           # Renamed from 'column' to avoid SQL reserved word
    signature*: string  # Simplified from Option[string]
    documentation*: string  # Simplified from Option[string]
    visibility*: string  # Simplified from Option[string]
    created*: DateTime   # Use DateTime like tankfeudserver
  
  Module* = ref object
    id*: int
    name*: string
    filePath*: string          # Maps to file_path
    lastModified*: DateTime    # Simplified to DateTime
    documentation*: string     # Simplified from Option[string]
    created*: DateTime         # Use DateTime like tankfeudserver
  
  RegisteredDirectory* = ref object
    id*: int
    path*: string
    name*: string              # Simplified from Option[string]
    description*: string       # Simplified from Option[string]
    created*: DateTime         # Use DateTime like tankfeudserver

  Database* = object
    pool*: Pool

proc newDatabase*(): Database =
  ## Create a new database instance with connection pool
  let host = getEnv("TIDB_HOST", "localhost")
  let port = parseInt(getEnv("TIDB_PORT", "4000"))
  let user = getEnv("TIDB_USER", "root")
  let password = getEnv("TIDB_PASSWORD", "")
  let database = getEnv("TIDB_DATABASE", "nimgenie")
  let poolSize = parseInt(getEnv("TIDB_POOL_SIZE", "10"))
  
  result.pool = newPool()
  for i in 0 ..< poolSize:
    result.pool.add openDatabase(database, host, port, user, password)
  # Create tables first, then indexes (following tankfeudserver patterns)
  result.pool.withDb:    
    # Create tables first
    if not db.tableExists(Symbol):
      db.createTable(Symbol)    
    if not db.tableExists(Module):
      db.createTable(Module)
    if not db.tableExists(RegisteredDirectory):
      db.createTable(RegisteredDirectory)
  
  # Create indexes in separate transaction (following tankfeudserver patterns)
  result.pool.withDb:
    # Create indexes for Symbol table
    if db.tableExists(Symbol):
      # Use raw SQL for TEXT/VARCHAR columns to specify key length
      db.query("CREATE INDEX IF NOT EXISTS idx_symbols_name ON symbol (name(255))")
      db.query("CREATE INDEX IF NOT EXISTS idx_symbols_module ON symbol (module(255))")
      db.query("CREATE INDEX IF NOT EXISTS idx_symbols_symbol_type ON symbol (symbol_type(255))")
      # Use Debby createIndex() for non-TEXT fields (integers)
      try:
        db.createIndex(Symbol, "line")
      except DbError:
        discard
    
    # Create indexes for Module table  
    if db.tableExists(Module):
      db.query("CREATE INDEX IF NOT EXISTS idx_modules_name ON module (name(255))")    
    # Create indexes for RegisteredDirectory table
    if db.tableExists(RegisteredDirectory):
      db.query("CREATE INDEX IF NOT EXISTS idx_registered_dirs_path ON registered_directory (path(255))")

proc closeDatabase*(db: Database) =
  ## Close the database connection pool
  if db.pool != nil:
    db.pool.close()

proc insertSymbol*(db: Database, name, symbolType, module, filePath: string,
                  line, col: int, signature = "", documentation = "", 
                  visibility = ""): int =
  ## Insert a symbol into the database and return its ID
  try:
    let symbol = Symbol(
      name: name,
      symbolType: symbolType,
      module: module,
      filePath: filePath,
      line: line,
      col: col,
      signature: signature,
      documentation: documentation,
      visibility: visibility,
      created: now()
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
      module.lastModified = now()
      module.documentation = documentation
      db.pool.update(module)
      return module.id
    else:
      # Insert new module
      let module = Module(
        name: name,
        filePath: filePath,
        lastModified: now(),
        documentation: documentation,
        created: now()
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
    db.pool.withDb:
      # Build SQL query for LIKE search with conditional filters using string formatting for now
      var sqlQuery = "SELECT * FROM symbol WHERE 1=1"
      
      if query != "":
        sqlQuery.add(fmt" AND name LIKE '%{query}%'")
      
      if symbolType != "":
        sqlQuery.add(fmt" AND symbol_type = '{symbolType}'")
        
      if moduleName != "":
        sqlQuery.add(fmt" AND module = '{moduleName}'")
      
      sqlQuery.add(" ORDER BY name LIMIT 100")
      
      let rows = db.query(sqlQuery)
      
      for row in rows:
        let symbolObj = %*{
          "name": row[1],        # name field
          "type": row[2],        # symbol_type field  
          "module": row[3],      # module field
          "file_path": row[4],   # file_path field
          "line": parseInt(row[5]),     # line field
          "column": parseInt(row[6]),   # col field
          "signature": row[7],   # signature field
          "documentation": row[8], # documentation field
          "visibility": row[9]   # visibility field
        }
        result.add(symbolObj)
      
  except Exception as e:
    echo "Database error searching symbols: ", e.msg
    result = %*{"error": e.msg}

proc getSymbolInfo*(db: Database, symbolName: string, moduleName: string = ""): JsonNode =
  ## Get detailed information about a specific symbol
  try:
    db.pool.withDb:
      var sqlQuery = fmt"SELECT * FROM symbol WHERE name = '{symbolName}'"
      
      if moduleName != "":
        sqlQuery.add(fmt" AND module = '{moduleName}'")
      
      sqlQuery.add(" ORDER BY module")
      
      let rows = db.query(sqlQuery)
      
      if rows.len == 0:
        return %*{"error": fmt"Symbol '{symbolName}' not found"}
      
      if rows.len == 1:
        let row = rows[0]
        return %*{
          "name": row[1],
          "type": row[2],
          "module": row[3], 
          "file_path": row[4],
          "line": parseInt(row[5]),
          "column": parseInt(row[6]),
          "signature": row[7],
          "documentation": row[8],
          "visibility": row[9]
        }
      else:
        # Multiple matches, return all
        result = newJArray()
        for row in rows:
          let symbolObj = %*{
            "name": row[1],
            "type": row[2],
            "module": row[3],
            "file_path": row[4], 
            "line": parseInt(row[5]),
            "column": parseInt(row[6]),
            "signature": row[7],
            "documentation": row[8],
            "visibility": row[9]
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
        discard db.query("DELETE FROM symbol")
    else:
      db.pool.withDb:
        discard db.query("DELETE FROM symbol WHERE module = ?", moduleName)
  except Exception as e:
    echo "Database error clearing symbols: ", e.msg

proc getProjectStats*(db: Database): JsonNode =
  ## Get statistics about the indexed project
  try:
    db.pool.withDb:
      let symbolCountRows = db.query("SELECT COUNT(*) FROM symbol")
      let moduleCountRows = db.query("SELECT COUNT(*) FROM module")
      let typeStatsRows = db.query("""
        SELECT symbol_type, COUNT(*) as count 
        FROM symbol 
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
      directory.name = displayName
      directory.description = description
      db.pool.update(directory)
    else:
      # Insert new directory
      let directory = RegisteredDirectory(
        path: path,
        name: displayName,
        description: description,
        created: now()
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
        "name": directory.name,
        "description": directory.description,
        "created_at": $directory.created
      }
      result.add(dirObj)
      
  except Exception as e:
    echo "Database error getting registered directories: ", e.msg
    result = %*{"error": e.msg}

proc getSymbolById*(db: Database, id: int): Option[Symbol] =
  ## Get a symbol by its ID
  try:
    let symbol = db.pool.get(Symbol, id)
    return some(symbol)
  except Exception:
    return none(Symbol)

proc getModules*(db: Database): JsonNode =
  ## Get all modules
  result = newJArray()
  try:
    let modules = db.pool.filter(Module, "1=1 ORDER BY name")
    
    for module in modules:
      let moduleObj = %*{
        "name": module.name,
        "file_path": module.filePath,
        "last_modified": $module.lastModified,
        "documentation": module.documentation,
        "created_at": $module.created
      }
      result.add(moduleObj)
      
  except Exception as e:
    echo "Database error getting modules: ", e.msg
    result = %*{"error": e.msg}

proc findModule*(db: Database, name: string): Option[Module] =
  ## Find a module by name
  try:
    let modules = db.pool.filter(Module, it.name == name)
    if modules.len > 0:
      return some(modules[0])
    else:
      return none(Module)
  except Exception:
    return none(Module)
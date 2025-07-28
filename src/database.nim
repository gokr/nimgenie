import std/[json, strutils, strformat, os, osproc, options, times]
import debby/pools, debby/mysql, debby/common
import configuration

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
    created*: DateTime
    documentationEmbedding*: string    # Native VECTOR(1024) column
    signatureEmbedding*: string        # Native VECTOR(1024) column
    nameEmbedding*: string             # Native VECTOR(1024) column
    combinedEmbedding*: string         # Native VECTOR(1024) column
    embeddingModel*: string            # Model used to generate embeddings
    embeddingVersion*: string          # Version of embeddings for tracking
  
  Module* = ref object
    id*: int
    name*: string
    filePath*: string          # Maps to file_path
    lastModified*: DateTime    # Simplified to DateTime
    documentation*: string     # Simplified from Option[string]
    created*: DateTime 
  
  RegisteredDirectory* = ref object
    id*: int
    path*: string
    name*: string              # Simplified from Option[string]
    description*: string       # Simplified from Option[string]
    created*: DateTime

  EmbeddingMetadata* = ref object
    id*: int
    modelName*: string          # e.g., "nomic-embed-text:latest" or "nomic-embed-text:latest"
    modelVersion*: string       # Version of the embedding model
    dimensions*: int            # Vector dimensions (e.g., 1024)
    embeddingType*: string      # "documentation", "signature", "name", "combined"
    totalSymbols*: int          # Number of symbols with embeddings
    lastUpdated*: DateTime      # When embeddings were last generated
    created*: DateTime

  FileDependency* = ref object
    id*: int
    sourceFile*: string        # Path to the source file
    targetFile*: string        # Path to the file being imported/required
    created*: DateTime         # When this dependency was recorded
    updated*: DateTime         # When this dependency was last updated

  FileModification* = ref object
    id*: int
    filePath*: string          # Path to the file
    modificationTime*: DateTime # Last modification time
    fileSize*: int             # Size of the file in bytes
    hash*: string              # Hash of the file content
    created*: DateTime         # When this record was created
    updated*: DateTime         # When this record was last updated

  Database* = object
    pool*: Pool

proc ensureDatabaseExists(config: Config) =
  ## Create the database first using mysql command
  let createDbResult = execCmd(fmt"mysql -h{config.databaseHost} -P{config.databasePort} -u{config.databaseUser} -e 'CREATE DATABASE IF NOT EXISTS `{config.database}`;' --silent")
  if createDbResult != 0:
    echo fmt"Warning: Could not create database {config.database}."

proc newDatabase*(config: Config): Database =
  ## Create a new database instance with connection pool
  ensureDatabaseExists(config)
  result.pool = newPool()
  for i in 0 ..< config.databasePoolSize:
    result.pool.add openDatabase(config.database, config.databaseHost, config.databasePort, config.databaseUser, config.databasePassword)
  # Create tables with custom SQL to support TiDB vector columns
  result.pool.withDb:
    # Create Symbol table with TiDB vector columns only if it doesn't exist
    try:
      let symbolTableExists = db.query("SHOW TABLES LIKE 'symbol'")
      if symbolTableExists.len == 0:
        # Create new table with vector columns
        db.query("""
          CREATE TABLE symbol (
            id INT AUTO_INCREMENT PRIMARY KEY,
            name VARCHAR(255) NOT NULL,
            symbol_type VARCHAR(100) NOT NULL,
            module VARCHAR(255) NOT NULL,
            file_path TEXT NOT NULL,
            line INT NOT NULL,  
            col INT NOT NULL,
            signature TEXT,
            documentation TEXT,
            visibility VARCHAR(50),  
            created DATETIME NOT NULL,
            documentation_embedding VECTOR(768) NULL,
            signature_embedding VECTOR(768) NULL,
            name_embedding VECTOR(768) NULL,
            combined_embedding VECTOR(768) NULL,
            embedding_model VARCHAR(100),
            embedding_version VARCHAR(50)
          )
        """)
        db.query("ALTER TABLE symbol SET TIFLASH REPLICA 1")
        echo "Created symbol table with TiDB vector columns and TiFlash"
        
        # Vector indexes need to be created separately with special syntax
        # For now, we'll skip vector indexing and rely on TiDB's vector search capabilities
        # Use raw SQL for TEXT/VARCHAR columns to specify key length
        db.query("CREATE INDEX IF NOT EXISTS idx_symbols_name ON symbol (name(255))")
        db.query("CREATE INDEX IF NOT EXISTS idx_symbols_module ON symbol (module(255))")
        db.query("CREATE INDEX IF NOT EXISTS idx_symbols_symbol_type ON symbol (symbol_type(255))")
        # Create index on integer column
        db.query("CREATE INDEX IF NOT EXISTS idx_symbols_line ON symbol (line)")       
    except Exception as e:
      echo fmt"Warning: Could not create symbol table with vectors: {e.msg}"
    
    # Create other tables normally, only if they don't exist
    if not db.tableExists(Module):
      db.createTable(Module)
      echo "Created Module table"
      db.query("CREATE INDEX IF NOT EXISTS idx_modules_name ON module (name(255))")
    
    if not db.tableExists(RegisteredDirectory):
      db.createTable(RegisteredDirectory)
      db.query("CREATE INDEX IF NOT EXISTS idx_registered_dirs_path ON registered_directory (path(255))")
      echo "Created RegisteredDirectory table"

    if not db.tableExists(EmbeddingMetadata):
      db.createTable(EmbeddingMetadata)
      echo "Created EmbeddingMetadata table"
    
    # Create FileDependency table only if it doesn't exist
    if not db.tableExists(FileDependency):
      db.createTable(FileDependency)
      db.query("CREATE INDEX IF NOT EXISTS idx_file_dependency_source ON file_dependency (source_file(255))")
      db.query("CREATE INDEX IF NOT EXISTS idx_file_dependency_target ON file_dependency (target_file(255))")
      echo "Created FileDependency table"
    
    # Create FileModification table only if it doesn't exist
    if not db.tableExists(FileModification):
      db.createTable(FileModification)
      db.query("CREATE INDEX IF NOT EXISTS idx_file_modification_path ON file_modification (file_path(255))")
      db.query("CREATE INDEX IF NOT EXISTS idx_file_modification_time ON file_modification (modification_time)")
      echo "Created FileModification table"
    
proc closeDatabase*(db: Database) =
  ## Close the database connection pool
  if db.pool != nil:
    db.pool.close()

proc insertSymbol*(db: Database, name, symbolType, module, filePath: string,
                  line, col: int, signature = "", documentation = "", 
                  visibility = "", documentationEmbedding = "", signatureEmbedding = "",
                  nameEmbedding = "", combinedEmbedding = "", embeddingModel = "",
                  embeddingVersion = ""): int =
  ## Insert a symbol with native vector embeddings into the database
  ## Empty string vector embeddings are treated as NULL to avoid TiDB "Invalid vector text" errors
  try:
    # Use raw SQL to properly handle NULL values for empty vector strings
    db.pool.withDb:
      let createdTime = now().format("yyyy-MM-dd HH:mm:ss")
      
      # Helper to convert empty string to NULL for SQL
      proc toSqlValue(value: string): string =
        if value == "": "NULL" else: "'" & value & "'"
      
      let sql = fmt"""
        INSERT INTO symbol (
          name, symbol_type, module, file_path, line, col,
          signature, documentation, visibility, created,
          documentation_embedding, signature_embedding, 
          name_embedding, combined_embedding, 
          embedding_model, embedding_version
        ) VALUES (
          '{name}', '{symbolType}', '{module}', '{filePath}', {line}, {col},
          '{signature}', '{documentation}', '{visibility}', '{createdTime}',
          {toSqlValue(documentationEmbedding)}, {toSqlValue(signatureEmbedding)},
          {toSqlValue(nameEmbedding)}, {toSqlValue(combinedEmbedding)},
          '{embeddingModel}', '{embeddingVersion}'
        )
      """
      
      discard db.query(sql)
      
      # Get the inserted ID
      let idResult = db.query("SELECT LAST_INSERT_ID()")
      if idResult.len > 0:
        return parseInt(idResult[0][0])
      else:
        return -1
        
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
                   moduleName: string = "", limit: int = 100): JsonNode =
  ## Search for symbols matching the query
  result = newJArray()
  
  try:
    db.pool.withDb:
      # Build SQL query for LIKE search with conditional filters using string formatting for now
      var sqlQuery = "SELECT * FROM symbol WHERE 1=1"
      
      if query != "":
        sqlQuery.add(fmt" AND LOWER(name) LIKE LOWER('%{query}%')")
      
      if symbolType != "":
        sqlQuery.add(fmt" AND symbol_type = '{symbolType}'")
        
      if moduleName != "":
        sqlQuery.add(fmt" AND module = '{moduleName}'")
      
      sqlQuery.add(fmt" ORDER BY name LIMIT {limit}")
      
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

proc vectorToTiDBString*(vec: seq[float32]): string =
  ## Convert vector to TiDB VECTOR string format: "[0.1, 0.2, 0.3]"
  return ($vec)[1 .. ^1]

# ============================================================================
# VECTOR SEARCH AND EMBEDDING MANAGEMENT FUNCTIONS
# ============================================================================

proc updateSymbolEmbeddings*(db: Database, symbolId: int,
                           docEmb, sigEmb, nameEmb, combinedEmb: string,
                           embeddingModel: string, embeddingVersion: string): bool =
  ## Update native vector embeddings for a specific symbol
  try:
    let symbolOpt = db.getSymbolById(symbolId)
    if symbolOpt.isSome:
      let symbol = symbolOpt.get()
      symbol.documentationEmbedding = docEmb
      symbol.signatureEmbedding = sigEmb
      symbol.nameEmbedding = nameEmb
      symbol.combinedEmbedding = combinedEmb
      symbol.embeddingModel = embeddingModel
      symbol.embeddingVersion = embeddingVersion
        
      db.pool.update(symbol)
      return true
    else:
      return false
  except Exception as e:
    echo "Database error updating symbol embeddings: ", e.msg
    return false

proc semanticSearchSymbols*(db: Database, queryEmbedding: string,
                          symbolType: string = "", moduleName: string = "",
                          limit: int = 10): JsonNode =
  ## Search symbols using vector similarity with TiDB native vector support
  ## Uses VEC_COSINE_DISTANCE to calculate actual similarity scores
  result = newJArray()
  
  # Debug: Log the query embedding details
  echo fmt"semanticSearchSymbols called with embedding length: {queryEmbedding.len}"
  let embeddingPreview = if queryEmbedding.len > 30: queryEmbedding[0..30] & "..." else: queryEmbedding
  echo fmt"Query embedding starts with: {embeddingPreview}"
  
  try:
    db.pool.withDb:
      # Use VEC_COSINE_DISTANCE to calculate similarity between query embedding and stored embeddings
      # Order by similarity (ascending distance) and limit results
      var sqlQuery = fmt"""
        SELECT
          id, name, symbol_type, module, file_path, line, col,
          signature, documentation, visibility,
          VEC_COSINE_DISTANCE(combined_embedding, '{queryEmbedding}') as distance
        FROM symbol
        WHERE combined_embedding IS NOT NULL
      """
      
      if symbolType != "":
        sqlQuery.add(fmt" AND symbol_type = '{symbolType}'")
        
      if moduleName != "":
        sqlQuery.add(fmt" AND module = '{moduleName}'")
      
      # Order by distance (similarity) - smaller distance means higher similarity
      sqlQuery.add(fmt" ORDER BY distance ASC LIMIT {limit}")
      
      let rows = db.query(sqlQuery)
      
      for row in rows:
        # Convert distance to similarity score (1 - distance)
        # Distance ranges from 0 (identical) to 2 (opposite), so we normalize
        let distance = parseFloat(row[10])
        let similarityScore = 1.0 - (distance / 2.0)
        
        let symbolObj = %*{
          "name": row[1],
          "type": row[2],
          "module": row[3],
          "file_path": row[4],
          "line": parseInt(row[5]),
          "column": parseInt(row[6]),
          "signature": row[7],
          "documentation": row[8],
          "visibility": row[9],
          "similarity_score": similarityScore,
          "distance": distance
        }
        result.add(symbolObj)
      
  except Exception as e:
    echo "Database error in semantic search: ", e.msg
    result = %*{"error": e.msg}

proc findSimilarByEmbedding*(db: Database, embedding: string,
                           excludeId: int = -1, limit: int = 10): JsonNode =
  ## Find symbols similar to a given embedding using TiDB native vector support
  ## Uses VEC_COSINE_DISTANCE to calculate actual similarity scores
  result = newJArray()
  
  try:
    db.pool.withDb:
      # Use VEC_COSINE_DISTANCE to calculate similarity between query embedding and stored embeddings
      # Order by similarity (ascending distance) and limit results
      var sqlQuery = fmt"""
        SELECT
          id, name, symbol_type, module, file_path, line, col,
          signature, documentation, visibility,
          VEC_COSINE_DISTANCE(combined_embedding, '{embedding}') as distance
        FROM symbol
        WHERE combined_embedding IS NOT NULL
      """
      
      if excludeId != -1:
        sqlQuery.add(fmt" AND id != {excludeId}")
      
      # Order by distance (similarity) - smaller distance means higher similarity
      sqlQuery.add(fmt" ORDER BY distance ASC LIMIT {limit}")
      
      let rows = db.query(sqlQuery)
      
      for row in rows:
        # Convert distance to similarity score (1 - distance)
        # Distance ranges from 0 (identical) to 2 (opposite), so we normalize
        let distance = parseFloat(row[10])
        let similarityScore = 1.0 - (distance / 2.0)
        
        let symbolObj = %*{
          "name": row[1],
          "type": row[2],
          "module": row[3],
          "file_path": row[4],
          "line": parseInt(row[5]),
          "column": parseInt(row[6]),
          "signature": row[7],
          "documentation": row[8],
          "visibility": row[9],
          "similarity_score": similarityScore,
          "distance": distance
        }
        result.add(symbolObj)
      
  except Exception as e:
    echo "Database error finding similar symbols: ", e.msg
    result = %*{"error": e.msg}

proc insertEmbeddingMetadata*(db: Database, modelName: string, modelVersion: string,
                            dimensions: int, embeddingType: string, totalSymbols: int): int =
  ## Insert embedding metadata tracking information
  try:
    let metadata = EmbeddingMetadata(
      modelName: modelName,
      modelVersion: modelVersion,
      dimensions: dimensions,
      embeddingType: embeddingType,
      totalSymbols: totalSymbols,
      lastUpdated: now(),
      created: now()
    )
    db.pool.insert(metadata)
    return metadata.id
  except Exception as e:
    echo "Database error inserting embedding metadata: ", e.msg
    return -1

proc getEmbeddingStats*(db: Database): JsonNode =
  ## Get statistics about embedding coverage and models
  try:
    db.pool.withDb:
      # Get count of symbols with embeddings
      let embeddedCountRows = db.query("SELECT COUNT(*) FROM symbol WHERE combined_embedding != NULL")
      let totalCountRows = db.query("SELECT COUNT(*) FROM symbol")
      
      let embeddedCount = if embeddedCountRows.len > 0: parseInt(embeddedCountRows[0][0]) else: 0
      let totalCount = if totalCountRows.len > 0: parseInt(totalCountRows[0][0]) else: 0
      
      # Get embedding metadata
      let metadataRows = db.query("""
        SELECT model_name, model_version, dimensions, embedding_type, total_symbols, last_updated
        FROM embedding_metadata 
        ORDER BY created_at DESC
      """)
      
      var metadataJson = newJArray()
      for row in metadataRows:
        metadataJson.add(%*{
          "model_name": row[0],
          "model_version": row[1],
          "dimensions": parseInt(row[2]),
          "embedding_type": row[3],
          "total_symbols": parseInt(row[4]),
          "last_updated": row[5]
        })
      
      return %*{
        "embedded_symbols": embeddedCount,
        "total_symbols": totalCount,
        "coverage_percentage": if totalCount > 0: (embeddedCount.float / totalCount.float * 100.0) else: 0.0,
        "embedding_metadata": metadataJson
      }
    
  except Exception as e:
    echo "Database error getting embedding stats: ", e.msg
    return %*{"error": e.msg}

proc insertFileDependency*(db: Database, sourceFile, targetFile: string): bool =
  ## Insert a file dependency relationship
  try:
    # Check if this dependency already exists
    let existing = db.pool.filter(FileDependency, it.sourceFile == sourceFile and it.targetFile == targetFile)
    if existing.len > 0:
      # Update the existing record
      let dep = existing[0]
      dep.updated = now()
      db.pool.update(dep)
    else:
      # Insert new dependency
      let dep = FileDependency(
        sourceFile: sourceFile,
        targetFile: targetFile,
        created: now(),
        updated: now()
      )
      db.pool.insert(dep)
    return true
  except Exception as e:
    echo "Database error inserting file dependency: ", e.msg
    return false

proc getFileDependencies*(db: Database, sourceFile: string = "", targetFile: string = ""): seq[FileDependency] =
  ## Get file dependencies, optionally filtered by source or target file
  try:
    var sqlQuery = "SELECT * FROM file_dependency WHERE 1=1"
    var params: seq[string] = @[]
    
    if sourceFile != "":
      sqlQuery.add(" AND source_file = ?")
      params.add(sourceFile)
    
    if targetFile != "":
      sqlQuery.add(" AND target_file = ?")
      params.add(targetFile)
    
    let rows = db.pool.withDb:
      if params.len > 0:
        db.query(sqlQuery, params)
      else:
        db.query(sqlQuery)
    
    for row in rows:
      let dep = FileDependency(
        id: parseInt(row[0]),
        sourceFile: row[1],
        targetFile: row[2],
        created: parse(row[3], "yyyy-MM-dd HH:mm:ss"),
        updated: parse(row[4], "yyyy-MM-dd HH:mm:ss")
      )
      result.add(dep)

  except Exception as e:
    echo "Database error getting file dependencies: ", e.msg
    return @[]

proc clearFileDependencies*(db: Database, sourceFile: string = "") =
  ## Clear file dependencies, optionally for a specific source file
  try:
    if sourceFile == "":
      db.pool.withDb:
        discard db.query("DELETE FROM file_dependency")
    else:
      db.pool.withDb:
        discard db.query("DELETE FROM file_dependency WHERE sourceFile = ?", sourceFile)
  except Exception as e:
    echo "Database error clearing file dependencies: ", e.msg

proc insertFileModification*(db: Database, filePath: string, modificationTime: DateTime, fileSize: int, hash: string): bool =
  ## Insert or update file modification tracking
  try:
    # Try to find existing record
    let existing = db.pool.filter(FileModification, it.filePath == filePath)
    if existing.len > 0:
      # Update existing record
      let fileMod = existing[0]
      fileMod.modificationTime = modificationTime
      fileMod.fileSize = fileSize
      fileMod.hash = hash
      fileMod.updated = now()
      db.pool.update(fileMod)
    else:
      # Insert new record
      let fileMod = FileModification(
        filePath: filePath,
        modificationTime: modificationTime,
        fileSize: fileSize,
        hash: hash,
        created: now(),
        updated: now()
      )
      db.pool.insert(fileMod)
    return true
  except Exception as e:
    echo "Database error inserting file modification: ", e.msg
    return false

proc getFileModification*(db: Database, filePath: string): Option[FileModification] =
  ## Get file modification info for a specific file
  try:
    let mods = db.pool.filter(FileModification, it.filePath == filePath)
    if mods.len > 0:
      return some(mods[0])
    else:
      return none(FileModification)
  except Exception as e:
    echo "Database error getting file modification: ", e.msg
    return none(FileModification)

proc getModifiedFiles*(db: Database, since: DateTime): seq[string] =
  ## Get files that have been modified since the given time
  try:
    let fileMods = db.pool.filter(FileModification, it.modificationTime > since)
    result = @[]
    for fileMod in fileMods:
      result.add(fileMod.filePath)
    return result
  except Exception as e:
    echo "Database error getting modified files: ", e.msg
    return @[]


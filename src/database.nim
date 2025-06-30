import std/[json, strutils, os, tables]
import db_connector/db_sqlite

type
  Database* = object
    conn: DbConn
    
const SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS symbols (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  type TEXT NOT NULL,
  module TEXT NOT NULL,
  file_path TEXT NOT NULL,
  line INTEGER NOT NULL,
  column INTEGER NOT NULL,
  signature TEXT,
  documentation TEXT,
  visibility TEXT,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_symbols_name ON symbols(name);
CREATE INDEX IF NOT EXISTS idx_symbols_module ON symbols(module);  
CREATE INDEX IF NOT EXISTS idx_symbols_type ON symbols(type);
CREATE INDEX IF NOT EXISTS idx_symbols_file ON symbols(file_path);

CREATE TABLE IF NOT EXISTS modules (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT UNIQUE NOT NULL,
  file_path TEXT NOT NULL,
  last_modified TIMESTAMP,
  documentation TEXT,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_modules_name ON modules(name);
CREATE INDEX IF NOT EXISTS idx_modules_path ON modules(file_path);
"""

proc initDatabase*(dbPath: string = ":memory:"): Database =
  ## Initialize the SQLite database with schema
  result.conn = open(dbPath, "", "", "")
  
  # Execute schema creation
  for statement in SCHEMA_SQL.split(';'):
    let trimmed = statement.strip()
    if trimmed.len > 0:
      result.conn.exec(sql(trimmed))

proc close*(db: Database) =
  ## Close the database connection
  db.conn.close()

proc insertSymbol*(db: Database, name, symbolType, module, filePath: string,
                  line, column: int, signature = "", documentation = "", 
                  visibility = ""): int64 =
  ## Insert a symbol into the database and return its ID
  try:
    result = db.conn.insertID(sql"""
      INSERT INTO symbols (name, type, module, file_path, line, column, signature, documentation, visibility)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, name, symbolType, module, filePath, line, column, signature, documentation, visibility)
  except DbError as e:
    echo "Database error inserting symbol: ", e.msg
    result = -1

proc insertModule*(db: Database, name, filePath: string, lastModified: string = "", 
                  documentation: string = ""): int64 =
  ## Insert or update a module in the database
  try:
    # Try to update first
    let updated = db.conn.tryExec(sql"""
      UPDATE modules SET file_path = ?, last_modified = ?, documentation = ?
      WHERE name = ?
    """, filePath, lastModified, documentation, name)
    
    if not updated:
      # Insert new module
      result = db.conn.insertID(sql"""
        INSERT INTO modules (name, file_path, last_modified, documentation)
        VALUES (?, ?, ?, ?)
      """, name, filePath, lastModified, documentation)
    else:
      # Get existing module ID
      let row = db.conn.getRow(sql"SELECT id FROM modules WHERE name = ?", name)
      if row[0] != "":
        result = parseInt(row[0])
      else:
        result = -1
  except DbError as e:
    echo "Database error inserting module: ", e.msg
    result = -1

proc searchSymbols*(db: Database, query: string, symbolType: string = "", 
                   moduleName: string = ""): JsonNode =
  ## Search for symbols matching the query
  result = newJArray()
  
  try:
    var whereClause = "WHERE name LIKE ?"
    var params = @[fmt"%{query}%"]
    
    if symbolType != "":
      whereClause.add(" AND type = ?")
      params.add(symbolType)
      
    if moduleName != "":
      whereClause.add(" AND module = ?")
      params.add(moduleName)
    
    let sqlQuery = fmt"""
      SELECT name, type, module, file_path, line, column, signature, documentation, visibility
      FROM symbols {whereClause}
      ORDER BY name
      LIMIT 100
    """
    
    for row in db.conn.fastRows(sql(sqlQuery), params):
      let symbolObj = %*{
        "name": row[0],
        "type": row[1], 
        "module": row[2],
        "file_path": row[3],
        "line": parseInt(row[4]),
        "column": parseInt(row[5]),
        "signature": row[6],
        "documentation": row[7],
        "visibility": row[8]
      }
      result.add(symbolObj)
      
  except DbError as e:
    echo "Database error searching symbols: ", e.msg
    result = %*{"error": e.msg}

proc getSymbolInfo*(db: Database, symbolName: string, moduleName: string = ""): JsonNode =
  ## Get detailed information about a specific symbol
  try:
    var whereClause = "WHERE name = ?"
    var params = @[symbolName]
    
    if moduleName != "":
      whereClause.add(" AND module = ?")
      params.add(moduleName)
    
    let sqlQuery = fmt"""
      SELECT name, type, module, file_path, line, column, signature, documentation, visibility
      FROM symbols {whereClause}
      ORDER BY module
    """
    
    let rows = db.conn.getAllRows(sql(sqlQuery), params)
    
    if rows.len == 0:
      return %*{"error": fmt"Symbol '{symbolName}' not found"}
    
    if rows.len == 1:
      let row = rows[0]
      return %*{
        "name": row[0],
        "type": row[1],
        "module": row[2], 
        "file_path": row[3],
        "line": parseInt(row[4]),
        "column": parseInt(row[5]),
        "signature": row[6],
        "documentation": row[7],
        "visibility": row[8]
      }
    else:
      # Multiple matches, return all
      result = newJArray()
      for row in rows:
        let symbolObj = %*{
          "name": row[0],
          "type": row[1],
          "module": row[2],
          "file_path": row[3], 
          "line": parseInt(row[4]),
          "column": parseInt(row[5]),
          "signature": row[6],
          "documentation": row[7],
          "visibility": row[8]
        }
        result.add(symbolObj)
        
  except DbError as e:
    echo "Database error getting symbol info: ", e.msg
    result = %*{"error": e.msg}

proc clearSymbols*(db: Database, moduleName: string = "") =
  ## Clear symbols, optionally for just one module
  try:
    if moduleName == "":
      db.conn.exec(sql"DELETE FROM symbols")
    else:
      db.conn.exec(sql"DELETE FROM symbols WHERE module = ?", moduleName)
  except DbError as e:
    echo "Database error clearing symbols: ", e.msg

proc getProjectStats*(db: Database): JsonNode =
  ## Get statistics about the indexed project
  try:
    let symbolCount = db.conn.getValue(sql"SELECT COUNT(*) FROM symbols")
    let moduleCount = db.conn.getValue(sql"SELECT COUNT(*) FROM modules")
    let typeStats = db.conn.getAllRows(sql"""
      SELECT type, COUNT(*) as count 
      FROM symbols 
      GROUP BY type 
      ORDER BY count DESC
    """)
    
    var typeStatsJson = newJArray()
    for row in typeStats:
      typeStatsJson.add(%*{
        "type": row[0],
        "count": parseInt(row[1])
      })
    
    return %*{
      "total_symbols": parseInt(symbolCount),
      "total_modules": parseInt(moduleCount),
      "symbol_types": typeStatsJson
    }
    
  except DbError as e:
    echo "Database error getting stats: ", e.msg
    return %*{"error": e.msg}
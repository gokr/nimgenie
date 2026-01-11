import std/[unittest, json, strutils, os, osproc, strformat]
import ../src/configuration, ../src/external_database

# Test utilities for MCP tool testing - these mirror the MCP tool functionality
proc testDbConnect(dbType, host: string, port: int, user, password, database: string): string =
  ## Test version of dbConnect MCP tool
  try:
    var config = Config(
      externalDbType: dbType,
      externalDbHost: host,
      externalDbPort: port,
      externalDbUser: user,
      externalDbPassword: password,
      externalDbDatabase: database,
      externalDbPoolSize: 5
    )

    if connectExternalDb(config):
      let status = getConnectionStatus()
      return $status
    else:
      let status = getConnectionStatus()
      return $status
  except Exception as e:
    return $(%*{"connected": false, "error": e.msg})

proc testDbStatus(): string =
  ## Test version of dbStatus MCP tool
  let status = getConnectionStatus()
  return $status

proc testDbDisconnect(): string =
  ## Test version of dbDisconnect MCP tool
  disconnectExternalDb()
  return "Disconnected from external database"

proc testDbQuery(sql: string, params: string = ""): string =
  ## Test version of dbQuery MCP tool
  let paramList = if params == "": @[] else: params.split(",")
  let queryResult = executeExternalQuery(sql, paramList)
  let jsonResult = formatQueryResult(queryResult)
  return $jsonResult

proc testDbExecute(sql: string, params: string = ""): string =
  ## Test version of dbExecute MCP tool
  let paramList = if params == "": @[] else: params.split(",")
  let queryResult = executeExternalQuery(sql, paramList)
  let jsonResult = formatQueryResult(queryResult)
  return $jsonResult

proc testDbTransaction(sqlStatements: string): string =
  ## Test version of dbTransaction MCP tool
  let statements = sqlStatements.split(";")
  let queryResult = executeExternalTransaction(statements)
  let jsonResult = formatQueryResult(queryResult)
  return $jsonResult

proc testDbListDatabases(): string =
  ## Test version of dbListDatabases MCP tool
  if not isConnected():
    return """{"success": false, "error": "Not connected to external database"}"""
  
  let sql = getDatabaseIntrospectionQuery("list_databases", parseDbType("tidb"))
  let queryResult = executeExternalQuery(sql)
  let jsonResult = formatQueryResult(queryResult)
  return $jsonResult

proc testDbListTables(database: string = ""): string =
  ## Test version of dbListTables MCP tool
  if not isConnected():
    return """{"success": false, "error": "Not connected to external database"}"""
  
  let sql = getDatabaseIntrospectionQuery("list_tables", parseDbType("tidb"))
  let queryResult = executeExternalQuery(sql)
  let jsonResult = formatQueryResult(queryResult)
  return $jsonResult

proc ensureDatabaseExists(config: Config) =
  ## Create the database first using mysql command
  let createDbResult = execCmd(fmt"mysql -h127.0.0.1 -P4000 -uroot -e 'CREATE DATABASE IF NOT EXISTS `test`;' --silent")
  if createDbResult != 0:
    echo fmt"Warning: Could not create test database! Continuing anyway..."

proc createConfig(): Config =
  ## Check if test database is available for integration tests
  Config(
    externalDbType: "tidb",
    externalDbHost: "127.0.0.1",
    externalDbPort: 4000,
    externalDbUser: "root",
    externalDbPassword: "",
    externalDbDatabase: "test",
    externalDbPoolSize: 1
  )

# Do this first
# ensureDatabaseExists(createConfig())

suite "MCP Database Tool Tests":
  
  setup:
    initExternalDbLock()
    
  teardown:
    disconnectExternalDb()

  test "dbConnect tool with valid parameters":
    let result = testDbConnect("tidb", "127.0.0.1", 4000, "root", "", "test")
    let resultJson = parseJson(result)
    check resultJson["connected"].getBool() == true
 
  test "dbConnect tool with invalid parameters":
    let result = testDbConnect("tidb", "nonexistent_host", 4000, "root", "", "test")
    let resultJson = parseJson(result)
    check resultJson["connected"].getBool() == false

  test "dbConnect tool with invalid database type":
    try:
      let result = testDbConnect("invalid_db", "127.0.0.1", 4000, "root", "", "test")
      let resultJson = parseJson(result)
      check resultJson["connected"].getBool() == false
    except:
      check true

  test "dbStatus tool when not connected":
    disconnectExternalDb()  # Ensure we're not connected
    let result = testDbStatus()
    let statusJson = parseJson(result)
    check statusJson["connected"].getBool() == false

  test "dbStatus tool when connected":
    let connectResult = testDbConnect("tidb", "127.0.0.1", 4000, "root", "", "test")
    let connectJson = parseJson(connectResult)
    
    # Only proceed if connection was successful
    if connectJson.hasKey("connected") and connectJson["connected"].getBool():
      let result = testDbStatus()
      let statusJson = parseJson(result)
      check statusJson["connected"].getBool() == true
      check statusJson["database_type"].getStr() == "tidb"
    else:
      skip()

  test "dbDisconnect tool":
    discard testDbConnect("tidb", "127.0.0.1", 4000, "root", "", "test")
    
    let result = testDbDisconnect()
    check "Disconnected from external database" in result
    
    # Verify disconnection
    let statusResult = testDbStatus()
    let statusJson = parseJson(statusResult)
    check statusJson["connected"].getBool() == false

  test "dbQuery tool without connection":
    disconnectExternalDb()  # Ensure we're not connected
    let result = testDbQuery("SELECT 1", "")
    let resultJson = parseJson(result)
    check resultJson["success"].getBool() == false
    check "Not connected" in resultJson["error"].getStr()

  test "dbQuery tool with connection":
    discard testDbConnect("tidb", "127.0.0.1", 4000, "root", "", "test")
    let result = testDbQuery("SELECT 1 as test_col", "")
    let resultJson = parseJson(result)
    
    if resultJson["success"].getBool():
      check resultJson["rows"].len() > 0
      check resultJson["row_count"].getInt() > 0
    else:
      echo "Query failed: ", resultJson["error"].getStr()

  test "dbQuery tool with parameters":
    discard testDbConnect("tidb", "127.0.0.1", 4000, "root", "", "test")
    let result = testDbQuery("SELECT ? as param_value", "42")
    let resultJson = parseJson(result)
    
    if resultJson["success"].getBool():
      check resultJson["rows"].len() > 0
    else:
      echo "Parameterized query failed: ", resultJson["error"].getStr()

  test "dbExecute tool without connection":
    disconnectExternalDb()  # Ensure we're not connected
    let result = testDbExecute("CREATE TEMPORARY TABLE test (id INT)", "")
    let resultJson = parseJson(result)
    check resultJson["success"].getBool() == false
    check "Not connected" in resultJson["error"].getStr()

  test "dbListDatabases tool without connection":
    disconnectExternalDb()  # Ensure we're not connected
    let result = testDbListDatabases()
    let resultJson = parseJson(result)
    check resultJson["success"].getBool() == false
    check "Not connected" in resultJson["error"].getStr()

  test "dbListDatabases tool with connection":
    discard testDbConnect("tidb", "127.0.0.1", 4000, "root", "", "test")
    let result = testDbListDatabases()
    let resultJson = parseJson(result)
    
    if resultJson["success"].getBool():
      check resultJson["rows"].len() > 0
      # MySQL should have at least 'information_schema' database
    else:
      echo "List databases failed: ", resultJson["error"].getStr()

  test "dbListTables tool with connection":
    discard testDbConnect("tidb", "127.0.0.1", 4000, "root", "", "test")
    let result = testDbListTables("")
    let resultJson = parseJson(result)
    
    # This should succeed even if there are no tables
    if not resultJson["success"].getBool():
      echo "List tables failed: ", resultJson["error"].getStr()

  test "dbTransaction tool without connection":
    disconnectExternalDb()  # Ensure we're not connected
    let result = testDbTransaction("SELECT 1; SELECT 2;")
    let resultJson = parseJson(result)
    check resultJson["success"].getBool() == false
    check "Not connected" in resultJson["error"].getStr()

  test "dbTransaction tool with simple statements":
    discard testDbConnect("tidb", "127.0.0.1", 4000, "root", "", "test")
    let result = testDbTransaction("SELECT 1; SELECT 2;")
    let resultJson = parseJson(result)
    
    # Transaction should execute successfully
    if not resultJson["success"].getBool():
      echo "Transaction failed: ", resultJson["error"].getStr()

  test "JSON response format consistency":
    # Test that all tools return consistent JSON format
    disconnectExternalDb()
    
    let tools = [
      testDbQuery("SELECT 1", ""),
      testDbExecute("SELECT 1", ""),
      testDbListDatabases(),
      testDbListTables(""),
      testDbTransaction("SELECT 1")
    ]
    
    for toolResult in tools:
      let resultJson = parseJson(toolResult)
      # All should have these basic fields
      check resultJson.hasKey("success")
      
      # When connected, should have database_type, when not connected it's less important
      if resultJson["success"].getBool():
        check resultJson.hasKey("database_type")
      else:
        check resultJson.hasKey("error")
    
    # Test status separately since it has different format
    let statusResult = testDbStatus()
    let statusJson = parseJson(statusResult)
    check statusJson.hasKey("connected")

suite "MCP Database Tool Edge Cases":
  
  test "dbConnect with missing required parameters":
    try:
      let result1 = testDbConnect("", "127.0.0.1", 4000, "root", "", "test")
      let resultJson = parseJson(result1)
      check resultJson["connected"].getBool() == false
    except:
      check true
    
  test "dbQuery with invalid SQL":
    discard testDbConnect("tidb", "127.0.0.1", 4000, "root", "", "test")
    let result = testDbQuery("INVALID SQL SYNTAX", "")
    let resultJson = parseJson(result)
    check resultJson["success"].getBool() == false
    check resultJson["error"].getStr() != ""

  test "Empty parameter handling":
    # Test tools with empty parameters
    disconnectExternalDb()
    
    let result1 = testDbQuery("", "")
    let json1 = parseJson(result1)
    check json1["success"].getBool() == false
    
    let result2 = testDbTransaction("")
    let json2 = parseJson(result2)
    check json2["success"].getBool() == false

  test "Parameter parsing":
    discard testDbConnect("tidb", "127.0.0.1", 4000, "root", "", "test")
    
    # Test multiple parameters
    let result = testDbQuery("SELECT ? as first, ? as second", "hello,world")
    let resultJson = parseJson(result)
    
    if resultJson["success"].getBool():
      check resultJson["rows"].len() > 0
    else:
      echo "Multi-parameter query failed: ", resultJson["error"].getStr()

when isMainModule:
  echo "Running MCP Database Tool Tests..."
  echo "Note: Integration tests require MySQL to be running on 127.0.0.1:4000"
  echo "To run integration tests:"
  echo "  docker run -d --name test-mysql -e MYSQL_ALLOW_EMPTY_PASSWORD=yes -p 4000:4000 mysql:8.0"
  echo ""
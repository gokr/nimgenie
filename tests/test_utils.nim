## Test utilities for NimGenie tests
## Provides common setup for TiDB connections and test databases

import os, strutils, strformat, times
import ../src/database
import debby/pools, debby/mysql

const
  # TiDB default settings for `tiup playground`
  TEST_DB_HOST = "127.0.0.1"
  TEST_DB_PORT = 4000
  TEST_DB_USER = "root"
  TEST_DB_PASSWORD = ""

proc createTestDatabase*(): Database =
  ## Create a test database instance connected to TiDB
  ## Requires TiDB to be running via `tiup playground`
  
  # Generate unique database name for this test run
  let timestamp = $getTime().toUnix()
  let testDbName = fmt"nimgenie_test_{timestamp}"
  
  # Set environment variables for test database
  putEnv("TIDB_HOST", TEST_DB_HOST)
  putEnv("TIDB_PORT", $TEST_DB_PORT)
  putEnv("TIDB_USER", TEST_DB_USER)
  putEnv("TIDB_PASSWORD", TEST_DB_PASSWORD)
  putEnv("TIDB_DATABASE", testDbName)
  putEnv("TIDB_POOL_SIZE", "5")  # Smaller pool for tests
  
  # Create the database first by connecting to default database
  putEnv("TIDB_DATABASE", "test")
  let setupDb = newDatabase()
  setupDb.pool.withDb:
    discard db.query(fmt"CREATE DATABASE IF NOT EXISTS {testDbName}")
  setupDb.closeDatabase()
  
  # Now connect to our test database
  putEnv("TIDB_DATABASE", testDbName)
  result = newDatabase()

proc cleanupTestDatabase*(db: Database) =
  ## Clean up test database by dropping it
  let dbName = getEnv("TIDB_DATABASE")
  if dbName.startsWith("nimgenie_test_"):
    # Drop the test database
    putEnv("TIDB_DATABASE", "test")
    let cleanupDb = newDatabase()
    cleanupDb.pool.withDb:
      discard db.query(fmt"DROP DATABASE IF EXISTS {dbName}")
    cleanupDb.closeDatabase()
  
  # Close the test database connection
  db.closeDatabase()

proc checkTiDBAvailable*(): bool =
  ## Check if TiDB is available for testing
  try:
    putEnv("TIDB_HOST", TEST_DB_HOST)
    putEnv("TIDB_PORT", $TEST_DB_PORT)
    putEnv("TIDB_USER", TEST_DB_USER)
    putEnv("TIDB_PASSWORD", TEST_DB_PASSWORD)
    putEnv("TIDB_DATABASE", "test")
    echo "newDatabase"
    let testDb = newDatabase()
    testDb.pool.withDb:
      echo "Trying query"
      discard db.query("SELECT 1")
      echo "Query done"
    testDb.closeDatabase()
    return true
  except Exception as e:
    echo fmt"Check for Tidb failed: {e.msg}"
    return false

template requireTiDB*(body: untyped): untyped =
  ## Template that skips tests if TiDB is not available
  echo "Checking tidb"
  if not checkTiDBAvailable():
    skip()
  else:
    body
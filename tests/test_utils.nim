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
  putEnv("MYSQL_HOST", TEST_DB_HOST)
  putEnv("MYSQL_PORT", $TEST_DB_PORT)
  putEnv("MYSQL_USER", TEST_DB_USER)
  putEnv("MYSQL_PASSWORD", TEST_DB_PASSWORD)
  putEnv("MYSQL_DATABASE", testDbName)
  putEnv("MYSQL_POOL_SIZE", "5")  # Smaller pool for tests
  
  # Create the database first by connecting to default database
  putEnv("MYSQL_DATABASE", "test")
  let setupDb = newDatabase()
  setupDb.pool.withDb:
    discard db.query(fmt"CREATE DATABASE IF NOT EXISTS {testDbName}")
  setupDb.closeDatabase()
  
  # Now connect to our test database
  putEnv("MYSQL_DATABASE", testDbName)
  result = newDatabase()

proc cleanupTestDatabase*(db: Database) =
  ## Clean up test database by dropping it
  let dbName = getEnv("MYSQL_DATABASE")
  if dbName.startsWith("nimgenie_test_"):
    # Drop the test database
    putEnv("MYSQL_DATABASE", "test")
    let cleanupDb = newDatabase()
    cleanupDb.pool.withDb:
      discard db.query(fmt"DROP DATABASE IF EXISTS {dbName}")
    cleanupDb.closeDatabase()
  
  # Close the test database connection
  db.closeDatabase()

proc checkTiDBAvailable*(): bool =
  ## Check if TiDB is available for testing
  try:
    putEnv("MYSQL_HOST", TEST_DB_HOST)
    putEnv("MYSQL_PORT", $TEST_DB_PORT)
    putEnv("MYSQL_USER", TEST_DB_USER)
    putEnv("MYSQL_PASSWORD", TEST_DB_PASSWORD)
    putEnv("MYSQL_DATABASE", "test")
    
    let testDb = newDatabase()
    testDb.pool.withDb:
      discard db.query("SELECT 1")
    testDb.closeDatabase()
    return true
  except:
    return false

template requireTiDB*(body: untyped): untyped =
  ## Template that skips tests if TiDB is not available
  if not checkTiDBAvailable():
    skip()
  else:
    body
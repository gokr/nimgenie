## Test utilities for NimGenie tests
## Provides common setup for TiDB connections and test databases

import os, strutils
import ../src/database
import ../src/configuration
import debby/pools, debby/mysql

const
  # TiDB default settings for `tiup playground`
  TEST_DB_HOST = "127.0.0.1"
  TEST_DB_PORT = 4000
  TEST_DB_USER = "root"
  TEST_DB_PASSWORD = ""

proc cleanTestTables*(db: Database) =
  ## Clean all tables in the test database to ensure fresh state
  try:
    db.pool.withDb:
      # Delete all data from tables in reverse dependency order
      discard db.query("DELETE FROM symbol")
      discard db.query("DELETE FROM module")
      discard db.query("DELETE FROM registered_directory")
  except Exception as e:
    echo "Warning: Could not clean test tables: ", e.msg

proc getTestConfig*(dbName: string): Config =
  ## Create a configuration for test database
  result = Config(
    port: 0,
    host: "localhost",
    projectPath: "",
    verbose: false,
    showHelp: false,
    showVersion: false,
    database: dbName,
    databaseHost: TEST_DB_HOST,
    databasePort: TEST_DB_PORT,
    databaseUser: TEST_DB_USER,
    databasePassword: TEST_DB_PASSWORD,
    databasePoolSize: 5,
    noDiscovery: true
  )

proc createTestDatabase*(): Database =
  ## Create a test database instance connected to TiDB
  ## Requires TiDB to be running via `tiup playground`
  ## Reuses the same test database and cleans tables for each test
  let testDbName = "nimgenie_test"
  let testConfig = getTestConfig(testDbName)
  result = newDatabase(testConfig)
  # Clean all tables to ensure fresh state
  cleanTestTables(result)

proc cleanupTestDatabase*(db: Database) =
  ## Clean up test database - just close connections since we reuse the database
  # Close the test database connection
  closeDatabase(db)

# Common test utility functions
import base64

proc detectMimeType*(filename: string): string =
  ## MIME type detection for testing
  let ext = filename.splitFile().ext.toLowerAscii()
  case ext
  of ".png": "image/png"
  of ".jpg", ".jpeg": "image/jpeg"
  of ".gif": "image/gif"
  of ".svg": "image/svg+xml"
  of ".webp": "image/webp"
  of ".txt": "text/plain"
  of ".html": "text/html"
  of ".css": "text/css"
  of ".js": "application/javascript"
  of ".json": "application/json"
  of ".zip": "application/zip"
  of ".tar": "application/x-tar"
  of ".gz": "application/gzip"
  else: "application/octet-stream"

proc isImageFile*(filename: string): bool =
  ## Image file detection for testing
  let mimeType = detectMimeType(filename)
  mimeType.startsWith("image/")

proc encodeFileAsBase64*(filePath: string): string =
  ## Base64 file encoding for testing
  let content = readFile(filePath)
  encode(content)

proc listDirectoryFiles*(dirPath: string): seq[string] =
  ## Directory file listing for testing
  result = @[]
  for entry in walkDirRec(dirPath):
    let relativePath = entry.relativePath(dirPath)
    result.add(relativePath)

proc createMockPngFile*(filePath: string) =
  ## Create a small valid PNG file for testing
  let pngData = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde\x00\x00\x00\tpHYs\x00\x00\x0b\x13\x00\x00\x0b\x13\x01\x00\x9a\x9c\x18\x00\x00\x00\nIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\r\n-\xdb\x00\x00\x00\x00IEND\xaeB`\x82"
  writeFile(filePath, pngData)

proc createMockScreenshot*(screenshotDir: string, filename: string): string =
  ## Simulate taking a screenshot by creating a mock PNG file
  let fullPath = screenshotDir / filename
  createMockPngFile(fullPath)
  return fullPath
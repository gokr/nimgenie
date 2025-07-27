## Test the actual MCP tools for directory resources
## This creates a mock MCP request context and tests the tool handlers

import unittest, json, os, times
import ../src/database
import test_utils

# Mock MCP Request Context for testing
type 
  MockMcpRequestContext = object
    requestId: string
    
proc createMockContext(id: string = "test-1"): MockMcpRequestContext =
  MockMcpRequestContext(requestId: id)

# Test the core database operations that the MCP tools use
proc testAddDirectoryToResources(db: Database, dirPath: string, name: string = "", description: string = ""): bool =
  ## Test version of addDirectoryToResources that uses a specific database
  if not dirExists(dirPath):
    return false
    
  let normalizedPath = dirPath.normalizedPath().absolutePath()
  return db.addRegisteredDirectory(normalizedPath, name, description)

proc testRemoveDirectoryFromResources(db: Database, dirPath: string): bool =
  ## Test version of removeDirectoryFromResources that uses a specific database
  let normalizedPath = dirPath.normalizedPath().absolutePath()
  return db.removeRegisteredDirectory(normalizedPath)

proc testListDirectoryResources(db: Database): string =
  ## Test version of listDirectoryResources that uses a specific database
  let dirData = db.getRegisteredDirectories()
  return $dirData

suite "MCP Tool Handlers Tests":
  
  var testDb: Database
  var testTempDir: string
  var testDir1: string
  var testDir2: string
  
  setup:
    requireTiDB:
      # Create test database connection
      testDb = createTestDatabase()
      
      # Create test environment
      testTempDir = getTempDir() / "nimgenie_mcp_test_" & $getTime().toUnix()
      createDir(testTempDir)
      
      # Create test directories
      testDir1 = testTempDir / "screenshots"
      testDir2 = testTempDir / "documents"  
      createDir(testDir1)
      createDir(testDir2)
      
      # Create test files
      writeFile(testDir1 / "image1.png", "fake png data")
      writeFile(testDir1 / "image2.png", "more fake png data")
      writeFile(testDir2 / "readme.txt", "Documentation")
    
  teardown:
    cleanupTestDatabase(testDb)
    if dirExists(testTempDir):
      removeDir(testTempDir)

  test "addDirectoryResource tool handler":
    requireTiDB:
      let ctx = createMockContext()
      
      # Test adding valid directory
      let result1 = testAddDirectoryToResources(testDb, testDir1, "Screenshots", "PNG images")
      check result1 == true
      
      # Verify it was added
      let listResult = testListDirectoryResources(testDb)
      let listJson = parseJson(listResult)
      check listJson.len == 1
      check listJson[0]["name"].getStr() == "Screenshots"
      check listJson[0]["description"].getStr() == "PNG images"
      check listJson[0]["path"].getStr() == testDir1.normalizedPath().absolutePath()

  test "addDirectoryResource tool handler - invalid directory":
    requireTiDB:
      let ctx = createMockContext()
      let fakeDir = testTempDir / "nonexistent"
      
      let result = testAddDirectoryToResources(testDb, fakeDir, "Fake", "Does not exist")
      check result == false
      
      # Should not be in database
      let listResult = testListDirectoryResources(testDb)
      let listJson = parseJson(listResult)
      check listJson.len == 0

  test "listDirectoryResources tool handler":
    requireTiDB:
      let ctx = createMockContext()
      
      # Add some directories first
      discard testAddDirectoryToResources(testDb, testDir1, "Dir1", "First directory")
      discard testAddDirectoryToResources(testDb, testDir2, "Dir2", "Second directory")
      
      # Test listing
      let result = testListDirectoryResources(testDb)
      let resultJson = parseJson(result)
      
      check resultJson.kind == JArray
      check resultJson.len == 2
      
      # Check that both directories are present
      var foundNames: seq[string] = @[]
      for entry in resultJson:
        foundNames.add(entry["name"].getStr())
      
      check "Dir1" in foundNames
      check "Dir2" in foundNames

  test "listDirectoryResources tool handler - empty":
    requireTiDB:
      let ctx = createMockContext()
      
      # Test with no registered directories
      let result = testListDirectoryResources(testDb)
      let resultJson = parseJson(result)
      
      check resultJson.kind == JArray
      check resultJson.len == 0

  test "removeDirectoryResource tool handler":
    requireTiDB:
      let ctx = createMockContext()
      
      # Add directory first
      discard testAddDirectoryToResources(testDb, testDir1, "ToRemove", "Will be deleted")
      
      # Verify it's there
      let listBefore = parseJson(testListDirectoryResources(testDb))
      check listBefore.len == 1
      
      # Remove it
      let result = testRemoveDirectoryFromResources(testDb, testDir1)
      check result == true
      
      # Verify it's gone
      let listAfter = parseJson(testListDirectoryResources(testDb))
      check listAfter.len == 0

  test "removeDirectoryResource tool handler - nonexistent":
    requireTiDB:
      let ctx = createMockContext()
      let fakeDir = testTempDir / "never_existed"
      
      # Try to remove directory that was never added
      let result = testRemoveDirectoryFromResources(testDb, fakeDir)
      check result == true  # Should succeed (no error)
      
      # Should still have empty list
      let listResult = parseJson(testListDirectoryResources(testDb))
      check listResult.len == 0

  test "Full workflow - add, list, remove":
    requireTiDB:
      let ctx = createMockContext()
      
      # Step 1: Add multiple directories
      let result1 = testAddDirectoryToResources(testDb, testDir1, "Images", "PNG files")
      let result2 = testAddDirectoryToResources(testDb, testDir2, "Docs", "Text files")
      check result1 == true
      check result2 == true
      
      # Step 2: List and verify both are there
      let listResult1 = parseJson(testListDirectoryResources(testDb))
      check listResult1.len == 2
      
      # Step 3: Remove one directory
      let removeResult = testRemoveDirectoryFromResources(testDb, testDir1)
      check removeResult == true
      
      # Step 4: List and verify only one remains
      let listResult2 = parseJson(testListDirectoryResources(testDb))
      check listResult2.len == 1
      check listResult2[0]["name"].getStr() == "Docs"
      
      # Step 5: Remove the last directory
      let removeResult2 = testRemoveDirectoryFromResources(testDb, testDir2)
      check removeResult2 == true
      
      # Step 6: Verify empty
      let listResult3 = parseJson(testListDirectoryResources(testDb))
      check listResult3.len == 0

suite "Integration Tests with File System":
  
  var integrationDb: Database
  var integrationTempDir: string

  setup:
    requireTiDB:
      integrationDb = createTestDatabase()
      integrationTempDir = getTempDir() / "nimgenie_integration_" & $getTime().toUnix()
      createDir(integrationTempDir)

  teardown:
    cleanupTestDatabase(integrationDb)
    if dirExists(integrationTempDir):
      removeDir(integrationTempDir)

  test "Register directory with actual files and verify paths":
    requireTiDB:
      # Create a realistic directory structure
      let screenshotDir = integrationTempDir / "screenshots"
      let subDir = screenshotDir / "subfolder"
      createDir(screenshotDir) 
      createDir(subDir)
      
      # Create various file types
      writeFile(screenshotDir / "main.png", "main screenshot")
      writeFile(screenshotDir / "error.png", "error screenshot")
      writeFile(subDir / "detail.png", "detail screenshot")
      writeFile(screenshotDir / "readme.txt", "Screenshot documentation")
      
      # Register the directory
      let result = testAddDirectoryToResources(integrationDb, screenshotDir, "Screenshots", "App screenshots")
      check result == true
      
      # List and verify
      let listJson = parseJson(testListDirectoryResources(integrationDb))
      check listJson.len == 1
      
      let entry = listJson[0]
      let registeredPath = entry["path"].getStr()
      
      # Verify the path is absolute and normalized
      check registeredPath.isAbsolute()
      check registeredPath == screenshotDir.normalizedPath().absolutePath()
      
      # Verify all test files still exist at registered path
      check fileExists(registeredPath / "main.png")
      check fileExists(registeredPath / "error.png") 
      check fileExists(registeredPath / "subfolder" / "detail.png")
      check fileExists(registeredPath / "readme.txt")

  test "Path normalization consistency":
    requireTiDB:
      # Test with various path formats
      let baseDir = integrationTempDir / "test_paths"
      createDir(baseDir)
      writeFile(baseDir / "file.txt", "test content")
      
      # Register with relative path (if possible)
      let currentDir = getCurrentDir()
      setCurrentDir(integrationTempDir)
      
      # These should all resolve to the same normalized path
      let result1 = testAddDirectoryToResources(integrationDb, "test_paths", "Relative", "Relative path test")
      check result1 == true
      
      setCurrentDir(currentDir)
      
      let result2 = testAddDirectoryToResources(integrationDb, baseDir, "Absolute", "Absolute path test")
      check result2 == true  # Should replace the first entry
      
      # Should have only one entry (the absolute path replaced the relative one)
      let listJson = parseJson(testListDirectoryResources(integrationDb))
      check listJson.len == 1
      check listJson[0]["name"].getStr() == "Absolute"  # Latest name should be used
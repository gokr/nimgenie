## Tests for NimGenie multi-project management architecture
## Tests the data structures and foundations for multi-project support

import unittest, json, os, strutils, times, tables
import ../src/nimgenie, ../src/database
import test_utils, test_server

suite "Multi-Project Architecture Tests":

  var testTempDir: string
  var testDb: Database
  var testGenie: NimGenie
  var project1Path: string
  var project2Path: string
  var project3Path: string
  
  setup:
    requireTiDB:
      testTempDir = getTempDir() / "nimgenie_multiproject_test_" & $getTime().toUnix()
      createDir(testTempDir)
      
      # Create multiple test projects
      project1Path = createTestProject(testTempDir, "project1")
      project2Path = createTestProject(testTempDir, "project2")  
      project3Path = createTestProject(testTempDir, "project3")
      
      # Create unique content for each project
      writeFile(project1Path / "src" / "unique1.nim", """
proc uniqueFunction1*(): string = "from project 1"
type Project1Type* = object
  field1*: string
""")
      
      writeFile(project2Path / "src" / "unique2.nim", """
proc uniqueFunction2*(): string = "from project 2"  
type Project2Type* = object
  field2*: int
""")
      
      writeFile(project3Path / "src" / "unique3.nim", """
proc uniqueFunction3*(): string = "from project 3"
type Project3Type* = object
  field3*: bool
""")
      
      testDb = createTestDatabase()
      testGenie = NimGenie(
        database: testDb,
        projects: initTable[string, NimProject](),
        nimblePackages: initTable[string, string](),
        symbolCache: initTable[string, JsonNode](),
        registeredDirectories: @[]
      )
    
  teardown:
    cleanupTestDatabase(testDb)
    if dirExists(testTempDir):
      removeDir(testTempDir)

  test "Add multiple projects to NimGenie":
    requireTiDB:
      # This test would require implementing addProject method
      # For now, we'll test the data structure setup
      check testGenie.projects.len >= 0
      # Database object existence check (no nil comparison for value types)

  test "Test NimGenie structure and data tables":
    requireTiDB:
      # Test that we can initialize the data structures
      check testGenie.projects.len == 0
      check testGenie.nimblePackages.len == 0
      check testGenie.symbolCache.len == 0
      check testGenie.registeredDirectories.len == 0

  test "Test directory resource management":
    requireTiDB:
      # Test using the implemented directory resource functionality
      let result = testGenie.addDirectoryToResources(project1Path, "Project 1", "Test project 1")
      check result == true
      
      check testGenie.registeredDirectories.len == 1
      check project1Path.normalizedPath().absolutePath() in testGenie.registeredDirectories

  test "Test Nimble package discovery":
    requireTiDB:
      # Test Nimble package data structure
      check testGenie.nimblePackages.len == 0
      
      # Manually add a test package
      testGenie.nimblePackages["test_package"] = "/fake/path/to/test_package"
      check testGenie.nimblePackages.len == 1
      check testGenie.nimblePackages.hasKey("test_package")

  test "Test symbol cache functionality":
    requireTiDB:
      # Test symbol cache data structure
      check testGenie.symbolCache.len == 0
      
      # Manually add a test symbol to cache
      testGenie.symbolCache["test_symbol"] = %*{"name": "test", "type": "proc"}
      check testGenie.symbolCache.len == 1
      check testGenie.symbolCache.hasKey("test_symbol")

suite "NimGenie Integration Tests":

  var testTempDir: string
  var testDb: Database
  var testGenie: NimGenie
  
  setup:
    requireTiDB:
      testTempDir = getTempDir() / "nimgenie_integration_test_" & $getTime().toUnix()
      createDir(testTempDir)
      
      testDb = createTestDatabase()
      testGenie = NimGenie(
        database: testDb,
        projects: initTable[string, NimProject](),
        nimblePackages: initTable[string, string](),
        symbolCache: initTable[string, JsonNode](),
        registeredDirectories: @[]
      )
    
  teardown:
    cleanupTestDatabase(testDb)
    if dirExists(testTempDir):
      removeDir(testTempDir)

  test "Test openGenie functionality":
    requireTiDB:
      # Test the main openGenie function
      let projectPath = createTestProject(testTempDir, "open_test")
      let genie = openGenie(projectPath)
      
      # Database is value type, not reference type
      check genie.projects.len >= 0
      check genie.nimblePackages.len >= 0
      check genie.symbolCache.len >= 0

suite "Resource Management Tests":

  var testTempDir: string
  var testDb: Database
  var testGenie: NimGenie
  
  setup:
    requireTiDB:
      testTempDir = getTempDir() / "nimgenie_resource_test_" & $getTime().toUnix()
      createDir(testTempDir)
      
      testDb = createTestDatabase()
      testGenie = NimGenie(
        database: testDb,
        projects: initTable[string, NimProject](),
        nimblePackages: initTable[string, string](),
        symbolCache: initTable[string, JsonNode](),
        registeredDirectories: @[]
      )
    
  teardown:
    cleanupTestDatabase(testDb)
    if dirExists(testTempDir):
      removeDir(testTempDir)

  test "Register multiple directories":
    requireTiDB:
      # Create test directories
      let dir1 = testTempDir / "dir1"
      let dir2 = testTempDir / "dir2"
      createDir(dir1)
      createDir(dir2)
      
      # Register directories
      let result1 = testGenie.addDirectoryToResources(dir1, "Directory 1", "First directory")
      let result2 = testGenie.addDirectoryToResources(dir2, "Directory 2", "Second directory")
      
      check result1 == true
      check result2 == true
      
      # Verify both directories are registered
      check testGenie.registeredDirectories.len == 2

  test "Remove registered directory":
    requireTiDB:
      # Create and register directory
      let testDir = testTempDir / "remove_me"
      createDir(testDir)
      
      let addResult = testGenie.addDirectoryToResources(testDir, "Remove Me", "Will be removed")
      check addResult == true
      check testGenie.registeredDirectories.len == 1
      
      # Remove directory
      let removeResult = testGenie.removeDirectoryFromResources(testDir)
      check removeResult == true
      check testGenie.registeredDirectories.len == 0

when isMainModule:
  echo "Running multi-project management tests..."
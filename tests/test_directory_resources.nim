## Comprehensive tests for NimGenie directory resource functionality
## Tests database operations, MCP tools, MIME type detection, and file serving capabilities
##
## Consolidates:
## - test_directory_resources.nim (original)
## - test_mcp_tools.nim (merged)

import unittest, json, os, strutils, times
import ../src/database
import test_utils, test_fixtures

suite "Database Directory Registration Tests":
  
  var testDb: Database
  var testTempDir: string
  var testDir1: string
  var testDir2: string
  
  setup:
    # Create test database connection
    testDb = createTestDatabase()
    
    # Create a temporary directory for testing
    testTempDir = getTempDir() / "nimgenie_test_" & $getTime().toUnix()
    createDir(testTempDir)
    
    # Create test files with various types
    testDir1 = testTempDir / "screenshots"
    testDir2 = testTempDir / "documents"  
    createDir(testDir1)
    createDir(testDir2)
    
    # Create test PNG file (small valid PNG)
    let pngData = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde\x00\x00\x00\tpHYs\x00\x00\x0b\x13\x00\x00\x0b\x13\x01\x00\x9a\x9c\x18\x00\x00\x00\nIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\r\n-\xdb\x00\x00\x00\x00IEND\xaeB`\x82"
    writeFile(testDir1 / "test.png", pngData)
    writeFile(testDir1 / "another.png", pngData)
    
    # Create test text file
    writeFile(testDir2 / "readme.txt", "This is a test file")
    writeFile(testDir2 / "config.json", """{"test": true}""")
  
  teardown:
    cleanupTestDatabase(testDb)
    if dirExists(testTempDir):
      removeDir(testTempDir)

  test "addRegisteredDirectory - new directory":
    let result = testDb.addRegisteredDirectory(testDir1.normalizedPath().absolutePath(), "Test Screenshots", "Test PNG files")
    
    check result == true
    
    # Verify in database
    let dirData = testDb.getRegisteredDirectories()
    check dirData.kind == JArray
    check dirData.len == 1
    check dirData[0]["path"].getStr() == testDir1.normalizedPath().absolutePath()
    check dirData[0]["name"].getStr() == "Test Screenshots"
    check dirData[0]["description"].getStr() == "Test PNG files"

  test "addRegisteredDirectory - nonexistent directory":
    let fakeDir = testTempDir / "nonexistent"
    # Cannot add nonexistent directory - this test validates behavior at a higher level
    # The database layer itself doesn't validate directory existence
    let result = testDb.addRegisteredDirectory(fakeDir.normalizedPath().absolutePath(), "Fake", "Does not exist")
    
    # Database operation succeeds, but directory doesn't exist on filesystem
    check result == true
    
    # Verify it was added to database (even though directory doesn't exist)
    let dirData = testDb.getRegisteredDirectories()
    check dirData.len == 1

  test "addRegisteredDirectory - duplicate path (replace)":
    let normalizedPath = testDir1.normalizedPath().absolutePath()
    
    # Add directory first time
    let result1 = testDb.addRegisteredDirectory(normalizedPath, "First", "First description") 
    check result1 == true
    
    # Add same directory again with different info
    let result2 = testDb.addRegisteredDirectory(normalizedPath, "Second", "Second description")
    check result2 == true  # Should succeed (replaces existing)
    
    # Should have updated info
    let dirData = testDb.getRegisteredDirectories() 
    check dirData.len == 1
    check dirData[0]["name"].getStr() == "Second"
    check dirData[0]["description"].getStr() == "Second description"

  test "removeRegisteredDirectory - existing directory":
    let normalizedPath = testDir1.normalizedPath().absolutePath()
    
    # First add a directory
    discard testDb.addRegisteredDirectory(normalizedPath, "Test", "Description")
    let beforeRemoval = testDb.getRegisteredDirectories()
    check beforeRemoval.len == 1
    
    # Remove it
    let result = testDb.removeRegisteredDirectory(normalizedPath)
    check result == true
    
    # Verify removed from database
    let dirData = testDb.getRegisteredDirectories()
    check dirData.len == 0

  test "removeRegisteredDirectory - nonexistent directory": 
    let fakeDir = testTempDir / "nonexistent"
    let result = testDb.removeRegisteredDirectory(fakeDir.normalizedPath().absolutePath())
    
    # Should succeed (no error) but no change
    check result == true
    let dirData = testDb.getRegisteredDirectories()
    check dirData.len == 0

  test "database persistence":
    let normalizedPath1 = testDir1.normalizedPath().absolutePath()
    let normalizedPath2 = testDir2.normalizedPath().absolutePath()
    
    # Add directories
    discard testDb.addRegisteredDirectory(normalizedPath1, "Dir1", "Description1")
    discard testDb.addRegisteredDirectory(normalizedPath2, "Dir2", "Description2")  
    
    let dirData = testDb.getRegisteredDirectories()
    check dirData.len == 2
    
    # Verify both directories are present
    var foundPaths: seq[string] = @[]
    for entry in dirData:
      foundPaths.add(entry["path"].getStr())
    
    check normalizedPath1 in foundPaths
    check normalizedPath2 in foundPaths

suite "MCP Tool Handlers Tests":
  
  # Mock MCP Tool Handlers for testing
  proc testAddDirectoryToResources(db: Database, dirPath: string, name: string = "", description: string = ""): bool =
    if not dirExists(dirPath):
      return false
    let normalizedPath = dirPath.normalizedPath().absolutePath()
    return db.addRegisteredDirectory(normalizedPath, name, description)

  proc testRemoveDirectoryFromResources(db: Database, dirPath: string): bool =
    let normalizedPath = dirPath.normalizedPath().absolutePath()
    return db.removeRegisteredDirectory(normalizedPath)

  proc testListDirectoryResources(db: Database): string =
    let dirData = db.getRegisteredDirectories()
    return $dirData
  
  var testDb: Database
  var testTempDir: string
  var testDir1: string
  var testDir2: string
  
  setup:
    testDb = createTestDatabase()
    testTempDir = getTempDir() / "nimgenie_mcp_test_" & $getTime().toUnix()
    createDir(testTempDir)
    testDir1 = testTempDir / "screenshots"
    testDir2 = testTempDir / "documents"  
    createDir(testDir1)
    createDir(testDir2)
    writeFile(testDir1 / "image1.png", "fake png data")
    writeFile(testDir1 / "image2.png", "more fake png data")
    writeFile(testDir2 / "readme.txt", "Documentation")
    
  teardown:
    cleanupTestDatabase(testDb)
    if dirExists(testTempDir):
      removeDir(testTempDir)

  test "addDirectoryResource tool handler":
    let result1 = testAddDirectoryToResources(testDb, testDir1, "Screenshots", "PNG images")
    check result1 == true
    
    let listResult = testListDirectoryResources(testDb)
    let listJson = parseJson(listResult)
    check listJson.len == 1
    check listJson[0]["name"].getStr() == "Screenshots"
    check listJson[0]["description"].getStr() == "PNG images"
    check listJson[0]["path"].getStr() == testDir1.normalizedPath().absolutePath()

  test "addDirectoryResource tool handler - invalid directory":
    let fakeDir = testTempDir / "nonexistent"
    let result = testAddDirectoryToResources(testDb, fakeDir, "Fake", "Does not exist")
    check result == false
    
    let listResult = testListDirectoryResources(testDb)
    let listJson = parseJson(listResult)
    check listJson.len == 0

  test "listDirectoryResources tool handler":
    discard testAddDirectoryToResources(testDb, testDir1, "Dir1", "First directory")
    discard testAddDirectoryToResources(testDb, testDir2, "Dir2", "Second directory")
    
    let result = testListDirectoryResources(testDb)
    let resultJson = parseJson(result)
    
    check resultJson.kind == JArray
    check resultJson.len == 2
    
    var foundNames: seq[string] = @[]
    for entry in resultJson:
      foundNames.add(entry["name"].getStr())
    
    check "Dir1" in foundNames
    check "Dir2" in foundNames

  test "removeDirectoryResource tool handler":
    discard testAddDirectoryToResources(testDb, testDir1, "ToRemove", "Will be deleted")
    
    let listBefore = parseJson(testListDirectoryResources(testDb))
    check listBefore.len == 1
    
    let result = testRemoveDirectoryFromResources(testDb, testDir1)
    check result == true
    
    let listAfter = parseJson(testListDirectoryResources(testDb))
    check listAfter.len == 0

  test "Full workflow - add, list, remove":
    let result1 = testAddDirectoryToResources(testDb, testDir1, "Images", "PNG files")
    let result2 = testAddDirectoryToResources(testDb, testDir2, "Docs", "Text files")
    check result1 == true
    check result2 == true
    
    let listResult1 = parseJson(testListDirectoryResources(testDb))
    check listResult1.len == 2
    
    let removeResult = testRemoveDirectoryFromResources(testDb, testDir1)
    check removeResult == true
    
    let listResult2 = parseJson(testListDirectoryResources(testDb))
    check listResult2.len == 1
    check listResult2[0]["name"].getStr() == "Docs"
    
    let removeResult2 = testRemoveDirectoryFromResources(testDb, testDir2)
    check removeResult2 == true
    
    let listResult3 = parseJson(testListDirectoryResources(testDb))
    check listResult3.len == 0

# MIME type detection and file utilities are now in test_utils


suite "MIME Type Detection Tests":
  
  test "detectMimeType - image files":
    check detectMimeType("test.png") == "image/png"
    check detectMimeType("photo.jpg") == "image/jpeg"
    check detectMimeType("image.jpeg") == "image/jpeg"
    check detectMimeType("icon.gif") == "image/gif"
    check detectMimeType("vector.svg") == "image/svg+xml"
    check detectMimeType("modern.webp") == "image/webp"

  test "detectMimeType - text files":
    check detectMimeType("readme.txt") == "text/plain"
    check detectMimeType("index.html") == "text/html"
    check detectMimeType("style.css") == "text/css"
    check detectMimeType("script.js") == "application/javascript"
    check detectMimeType("data.json") == "application/json"

  test "detectMimeType - archive files":
    check detectMimeType("archive.zip") == "application/zip"
    check detectMimeType("backup.tar") == "application/x-tar"
    check detectMimeType("compressed.gz") == "application/gzip"
    
  test "detectMimeType - unknown extension":
    check detectMimeType("unknown.xyz") == "application/octet-stream"
    check detectMimeType("noextension") == "application/octet-stream"

  test "isImageFile - detection":
    check isImageFile("test.png") == true
    check isImageFile("photo.jpg") == true
    check isImageFile("readme.txt") == false
    check isImageFile("script.js") == false

# File utilities are now in test_utils

suite "File Serving Utilities Tests":

  test "encodeFileAsBase64 - binary file":
    withTestFixture:
      let testFile = fixture.tempDir / "binary.dat"
      let testData = "\x00\x01\x02\x03\x04\xFF"
      writeFile(testFile, testData)

      let encoded = encodeFileAsBase64(testFile)
      check encoded.len > 0
      check "\x00" notin encoded
      check "\xFF" notin encoded

  test "listDirectoryFiles - recursive listing":
    withTestFixture:
      let subDir = fixture.tempDir / "subdir"
      createDir(subDir)
      writeFile(fixture.tempDir / "file1.txt", "content1")
      writeFile(fixture.tempDir / "file2.png", "png_content")
      writeFile(subDir / "nested.json", "json_content")

      let files = listDirectoryFiles(fixture.tempDir)

      check files.len == 3
      check "file1.txt" in files
      check "file2.png" in files
      check "subdir/nested.json" in files or "subdir\\nested.json" in files

suite "Integration Tests with File System":

  test "Register directory with actual files and verify paths":
    withTestFixture:
      let screenshotDir = fixture.tempDir / "screenshots"
      let subDir = screenshotDir / "subfolder"
      createDir(screenshotDir)
      createDir(subDir)

      writeFile(screenshotDir / "main.png", "main screenshot")
      writeFile(screenshotDir / "error.png", "error screenshot")
      writeFile(subDir / "detail.png", "detail screenshot")
      writeFile(screenshotDir / "readme.txt", "Screenshot documentation")

      proc testAddDirectoryToResources(db: Database, dirPath: string, name: string = "", description: string = ""): bool =
        if not dirExists(dirPath):
          return false
        let normalizedPath = dirPath.normalizedPath().absolutePath()
        return db.addRegisteredDirectory(normalizedPath, name, description)

      proc testListDirectoryResources(db: Database): string =
        let dirData = db.getRegisteredDirectories()
        return $dirData

      let result = testAddDirectoryToResources(fixture.database, screenshotDir, "Screenshots", "App screenshots")
      check result == true

      let listJson = parseJson(testListDirectoryResources(fixture.database))
      check listJson.len == 1

      let entry = listJson[0]
      let registeredPath = entry["path"].getStr()

      check registeredPath.isAbsolute()
      check registeredPath == screenshotDir.normalizedPath().absolutePath()

      check fileExists(registeredPath / "main.png")
      check fileExists(registeredPath / "error.png")
      check fileExists(registeredPath / "subfolder" / "detail.png")
      check fileExists(registeredPath / "readme.txt")

  test "Path normalization consistency":
    withTestFixture:
      proc testAddDirectoryToResources(db: Database, dirPath: string, name: string = "", description: string = ""): bool =
        if not dirExists(dirPath):
          return false
        let normalizedPath = dirPath.normalizedPath().absolutePath()
        return db.addRegisteredDirectory(normalizedPath, name, description)

      proc testListDirectoryResources(db: Database): string =
        let dirData = db.getRegisteredDirectories()
        return $dirData

      let baseDir = fixture.tempDir / "test_paths"
      createDir(baseDir)
      writeFile(baseDir / "file.txt", "test content")

      let currentDir = getCurrentDir()
      setCurrentDir(fixture.tempDir)

      let result1 = testAddDirectoryToResources(fixture.database, "test_paths", "Relative", "Relative path test")
      check result1 == true

      setCurrentDir(currentDir)

      let result2 = testAddDirectoryToResources(fixture.database, baseDir, "Absolute", "Absolute path test")
      check result2 == true

      let listJson = parseJson(testListDirectoryResources(fixture.database))
      check listJson.len == 1
      check listJson[0]["name"].getStr() == "Absolute"
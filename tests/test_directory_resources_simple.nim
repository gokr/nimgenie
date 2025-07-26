## Simplified tests for NimGenie directory resource functionality
## Tests core functionality without MCP server dependencies

import unittest, json, options, os, strutils, times, tables
import ../src/database
import test_utils

# Test just the database and utility functions without importing the full nimgenie module
proc detectMimeTyp*(filePath: string): string =
  ## Simple MIME type detection for testing
  let ext = filePath.splitFile().ext.toLowerAscii()
  case ext
  of ".png": "image/png"
  of ".jpg", ".jpeg": "image/jpeg"
  of ".gif": "image/gif"
  of ".txt": "text/plain"
  of ".json": "application/json"
  else: "application/octet-stream"

proc isImageFil*(filePath: string): bool =
  ## Simple image file detection for testing
  let mimeType = detectMimeTyp(filePath)
  return mimeType.startsWith("image/")

suite "Database Directory Registration Tests":
  
  var testDb: Database
  var testTempDir: string
  
  setup:
    requireTiDB:
      # Create test database connection
      testDb = createTestDatabase()
      
      # Create a temporary directory for testing
      testTempDir = getTempDir() / "nimgenie_db_test_" & $getTime().toUnix()
      createDir(testTempDir)
    
  teardown:
    cleanupTestDatabase(testDb)
    if dirExists(testTempDir):
      removeDir(testTempDir)

  test "addRegisteredDirectory - new directory":
    requireTiDB:
      let testDir = testTempDir / "test_dir"
      createDir(testDir)
      let normalizedPath = testDir.normalizedPath().absolutePath()
      
      let result = testDb.addRegisteredDirectory(normalizedPath, "Test Dir", "A test directory")
      check result == true
      
      # Verify in database
      let dirData = testDb.getRegisteredDirectories()
      check dirData.kind == JArray
      check dirData.len == 1
      check dirData[0]["path"].getStr() == normalizedPath
      check dirData[0]["name"].getStr() == "Test Dir"
      check dirData[0]["description"].getStr() == "A test directory"

  test "addRegisteredDirectory - duplicate path (replace)":
    requireTiDB:
      let testDir = testTempDir / "duplicate_dir"
      createDir(testDir)
      let normalizedPath = testDir.normalizedPath().absolutePath()
      
      # Add first time
      let result1 = testDb.addRegisteredDirectory(normalizedPath, "First", "First description")
      check result1 == true
      
      # Add again with different info
      let result2 = testDb.addRegisteredDirectory(normalizedPath, "Second", "Second description")
      check result2 == true
      
      # Should have only one entry with updated info
      let dirData = testDb.getRegisteredDirectories()
      check dirData.len == 1
      check dirData[0]["name"].getStr() == "Second"
      check dirData[0]["description"].getStr() == "Second description"

  test "removeRegisteredDirectory - existing directory":
    requireTiDB:
      let testDir = testTempDir / "remove_test"
      createDir(testDir)
      let normalizedPath = testDir.normalizedPath().absolutePath()
      
      # Add directory first
      discard testDb.addRegisteredDirectory(normalizedPath, "Remove Test", "Will be removed")
      let dirDataBefore = testDb.getRegisteredDirectories()
      check dirDataBefore.len == 1
      
      # Remove it
      let result = testDb.removeRegisteredDirectory(normalizedPath)
      check result == true
      
      # Verify removed
      let dirDataAfter = testDb.getRegisteredDirectories()
      check dirDataAfter.len == 0

  test "removeRegisteredDirectory - nonexistent directory":
    requireTiDB:
      let fakeDir = testTempDir / "nonexistent"
      let normalizedPath = fakeDir.normalizedPath().absolutePath()
      
      let result = testDb.removeRegisteredDirectory(normalizedPath)
      check result == true  # Should succeed (no error)
      
      # Should still have empty result
      let dirData = testDb.getRegisteredDirectories()
      check dirData.len == 0

  test "getRegisteredDirectories - multiple entries":
    requireTiDB:
      let dir1 = testTempDir / "dir1"
      let dir2 = testTempDir / "dir2"
      createDir(dir1)
      createDir(dir2)
      let normalizedPath1 = dir1.normalizedPath().absolutePath()
      let normalizedPath2 = dir2.normalizedPath().absolutePath()
      
      discard testDb.addRegisteredDirectory(normalizedPath1, "Directory 1", "First directory")
      discard testDb.addRegisteredDirectory(normalizedPath2, "Directory 2", "Second directory")
      
      let dirData = testDb.getRegisteredDirectories()
      check dirData.len == 2
      
      # Check that both directories are present (order may vary)
      var foundPaths: seq[string] = @[]
      for entry in dirData:
        foundPaths.add(entry["path"].getStr())
      
      check normalizedPath1 in foundPaths
      check normalizedPath2 in foundPaths

suite "MIME Type Detection Tests":
  
  test "detectMimeType - image files":
    check detectMimeTyp("test.png") == "image/png"
    check detectMimeTyp("photo.jpg") == "image/jpeg"
    check detectMimeTyp("image.jpeg") == "image/jpeg"
    check detectMimeTyp("icon.gif") == "image/gif"

  test "detectMimeType - text files":
    check detectMimeTyp("readme.txt") == "text/plain"
    check detectMimeTyp("data.json") == "application/json"
    
  test "detectMimeType - unknown extension":
    check detectMimeTyp("unknown.xyz") == "application/octet-stream"
    check detectMimeTyp("noextension") == "application/octet-stream"

  test "isImageFile - detection":
    check isImageFil("test.png") == true
    check isImageFil("photo.jpg") == true
    check isImageFil("readme.txt") == false
    check isImageFil("script.js") == false

suite "File Operations Tests":

  setup:
    let testTempDir = getTempDir() / "nimgenie_file_test_" & $getTime().toUnix()
    createDir(testTempDir)
    
  teardown:
    if dirExists(testTempDir):
      removeDir(testTempDir)

  test "File creation and detection":
    # Create test files
    let pngFile = testTempDir / "test.png"
    let txtFile = testTempDir / "readme.txt"
    let jsonFile = testTempDir / "config.json"
    
    writeFile(pngFile, "fake png data")
    writeFile(txtFile, "This is a text file")
    writeFile(jsonFile, """{"test": true}""")
    
    # Test file existence
    check fileExists(pngFile)
    check fileExists(txtFile) 
    check fileExists(jsonFile)
    
    # Test MIME type detection
    check detectMimeTyp(pngFile) == "image/png"
    check detectMimeTyp(txtFile) == "text/plain"
    check detectMimeTyp(jsonFile) == "application/json"
    
    # Test content reading
    check readFile(txtFile) == "This is a text file"
    check readFile(jsonFile) == """{"test": true}"""
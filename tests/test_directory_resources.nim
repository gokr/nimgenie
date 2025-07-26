## Tests for NimGenie directory resource functionality
## Tests the three MCP tools: addDirectoryResource, listDirectoryResources, removeDirectoryResource
## Also tests MIME type detection and file serving capabilities

import unittest, json, options, os, strutils, times, tables
import ../src/database
import test_utils

suite "NimGenie Directory Resource Tests":
  
  var testDb: Database
  var testTempDir: string
  var testDir1: string
  var testDir2: string
  
  setup:
    requireTiDB:
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

  test "addDirectoryToResources - valid directory":
    requireTiDB:
      let result = testDb.addRegisteredDirectory(testDir1.normalizedPath().absolutePath(), "Test Screenshots", "Test PNG files")
      
      check result == true
      
      # Verify in database
      let dirData = testDb.getRegisteredDirectories()
      check dirData.kind == JArray
      check dirData.len == 1
      check dirData[0]["path"].getStr() == testDir1.normalizedPath().absolutePath()
      check dirData[0]["name"].getStr() == "Test Screenshots"
      check dirData[0]["description"].getStr() == "Test PNG files"

  test "addDirectoryToResources - nonexistent directory":
    requireTiDB:
      let fakeDir = testTempDir / "nonexistent"
      # Cannot add nonexistent directory - this test validates behavior at a higher level
      # The database layer itself doesn't validate directory existence
      let result = testDb.addRegisteredDirectory(fakeDir.normalizedPath().absolutePath(), "Fake", "Does not exist")
      
      # Database operation succeeds, but directory doesn't exist on filesystem
      check result == true
      
      # Verify it was added to database (even though directory doesn't exist)
      let dirData = testDb.getRegisteredDirectories()
      check dirData.len == 1

  test "addDirectoryToResources - duplicate directory":
    requireTiDB:
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

  test "removeDirectoryFromResources - existing directory":
    requireTiDB:
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

  test "removeDirectoryFromResources - nonexistent directory": 
    requireTiDB:
      let fakeDir = testTempDir / "nonexistent"
      let result = testDb.removeRegisteredDirectory(fakeDir.normalizedPath().absolutePath())
      
      # Should succeed (no error) but no change
      check result == true
      let dirData = testDb.getRegisteredDirectories()
      check dirData.len == 0

  test "database persistence":
    requireTiDB:
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

proc detectMimeType(filename: string): string =
  ## Test implementation of MIME type detection
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

proc isImageFile(filename: string): bool =
  ## Test implementation of image file detection
  let mimeType = detectMimeType(filename)
  mimeType.startsWith("image/")

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

import base64

proc encodeFileAsBase64(filePath: string): string =
  ## Test implementation of base64 file encoding
  let content = readFile(filePath)
  encode(content)

proc listDirectoryFiles(dirPath: string): seq[string] =
  ## Test implementation of directory file listing
  result = @[]
  for entry in walkDirRec(dirPath):
    let relativePath = entry.relativePath(dirPath)
    result.add(relativePath)

suite "File Serving Utilities Tests":

  var testTempDir: string

  setup:
    testTempDir = getTempDir() / "nimgenie_serve_test_" & $getTime().toUnix()
    createDir(testTempDir)
    
  teardown:
    if dirExists(testTempDir):
      removeDir(testTempDir)

  test "encodeFileAsBase64 - binary file":
    let testFile = testTempDir / "binary.dat"
    let testData = "\x00\x01\x02\x03\x04\xFF"
    writeFile(testFile, testData)
    
    let encoded = encodeFileAsBase64(testFile)
    check encoded.len > 0
    # Base64 encoding should not contain raw binary data
    check "\x00" notin encoded
    check "\xFF" notin encoded
    
  test "listDirectoryFiles - recursive listing":
    # Create nested structure
    let subDir = testTempDir / "subdir"
    createDir(subDir)
    writeFile(testTempDir / "file1.txt", "content1")
    writeFile(testTempDir / "file2.png", "png_content")
    writeFile(subDir / "nested.json", "json_content")
    
    let files = listDirectoryFiles(testTempDir)
    
    check files.len == 3
    check "file1.txt" in files
    check "file2.png" in files
    check "subdir/nested.json" in files or "subdir\\nested.json" in files  # Handle Windows paths
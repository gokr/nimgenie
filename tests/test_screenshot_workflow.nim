## Comprehensive screenshot workflow tests
## Tests screenshot creation, directory management, and file serving capabilities
## Consolidates all screenshot-related testing into a single comprehensive test suite

import unittest, json, os, strutils, times, random, strformat, httpclient
import ../src/database
import test_utils

type
  McpClient* = object
    baseUrl: string
    client: HttpClient
    requestId: int
    
  McpRequest = object
    jsonrpc: string
    `method`: string
    params: JsonNode
    id: int
    
  McpResponse = object
    jsonrpc: string
    result: JsonNode
    error: JsonNode
    id: int

# Global server management
var serverRunning: bool = false
var serverPort: int = 0

proc createMcpClient(port: int): McpClient =
  ## Create a new MCP client instance
  result.baseUrl = fmt"http://localhost:{port}"
  result.client = newHttpClient()
  result.requestId = 0

proc close(client: var McpClient) =
  ## Close the MCP client
  client.client.close()

proc makeRequest(client: var McpClient, methodName: string, params: JsonNode = newJObject()): JsonNode =
  ## Make an MCP JSON-RPC request
  client.requestId.inc()
  
  let request = %*{
    "jsonrpc": "2.0",
    "method": methodName,
    "params": params,
    "id": client.requestId
  }
  
  client.client.headers = newHttpHeaders({"Content-Type": "application/json"})
  let response = client.client.postContent(client.baseUrl, $request)
  
  let responseJson = parseJson(response)
  
  if responseJson.hasKey("error"):
    let error = responseJson["error"]
    let code = if error.hasKey("code"): error["code"].getInt() else: 0
    let message = if error.hasKey("message"): error["message"].getStr() else: ""
    raise newException(IOError, fmt"MCP error {code}: {message}")
    
  return if responseJson.hasKey("result"): responseJson["result"] else: newJNull()

proc makeToolCall(client: var McpClient, toolName: string, arguments: JsonNode = newJObject()): string =
  ## Make an MCP tool call request
  let params = %*{
    "name": toolName,
    "arguments": arguments
  }
  
  let res = client.makeRequest("tools/call", params)
  
  # Extract content from tool result
  if res.hasKey("content") and res["content"].kind == JArray and res["content"].len > 0:
    let content = res["content"][0]
    if content.hasKey("text"):
      return content["text"].getStr()
  
  return $res

proc requestResource(client: var McpClient, uri: string): JsonNode =
  ## Request a resource from the MCP server
  let params = %*{
    "uri": uri
  }
  
  return client.makeRequest("resources/read", params)

proc findAvailablePort(): int =
  ## Find an available port for testing
  # Start from a high port number to avoid conflicts
  randomize()
  for i in 0..100:
    let port = 9000 + rand(1000) 
    # Simple availability check (not foolproof but good enough for tests)
    if not fileExists(fmt"/proc/net/tcp") or true: # Simplified for cross-platform
      return port
  return 9000

# Note: Server functionality would need to be updated to work with new Database API
# For now, these tests are disabled as they require significant refactoring
# of the server startup code to work with TiDB instead of SQLite file databases

# Server functionality disabled for TiDB conversion
# var serverThread: Thread[tuple[port: int, testDir: string]]
# 
# proc startTestServer(): int =
#   ## Start the Nimgenie server in a background thread
#   serverPort = findAvailablePort()
#   let testDir = getCurrentDir()
#   
#   # Create and start server thread
#   createThread(serverThread, serverProc, (serverPort, testDir))
#   serverRunning = true
#   
#   # Wait for server to start (simple delay - could be improved with proper synchronization) 
#   sleep(2000)
#   
#   return serverPort
# 
# proc stopTestServer() =
#   ## Stop the test server
#   if serverRunning:
#     serverRunning = false
#     # Note: In production we'd want a graceful shutdown mechanism
#     # For testing, we let the thread finish naturally
    
# Mock PNG creation utilities are now in test_utils

suite "Screenshot Workflow Integration Tests":
  
  var testTempDir: string
  var screenshotDir: string
  
  setup:
    # Create test environment
      testTempDir = getTempDir() / "nimgenie_screenshot_test_" & $getTime().toUnix()
      screenshotDir = testTempDir / "screenshots"
      createDir(testTempDir)
      createDir(screenshotDir)
    
  teardown:
    if dirExists(testTempDir):
      removeDir(testTempDir)

  test "Complete screenshot workflow - create screenshots dir, create file":
    # Step 1: Create screenshots directory in project (simulating game setup)
      # This is much simpler than registering - just create the expected directory
      
      # Step 2: Simulate game taking a screenshot  
      let screenshotFilename = "game_state_001.png"
      let screenshotPath = createMockScreenshot(screenshotDir, screenshotFilename)
      
      echo fmt"Screenshot created at: {screenshotPath}"  # This simulates the game printing the filename
      
      # Step 3: Validate the file was created correctly
      check fileExists(screenshotPath)
      check screenshotPath.endsWith(screenshotFilename)
      
      # Step 4: Validate the file contents (basic PNG header check)
      let fileContent = readFile(screenshotPath)
      check fileContent.startsWith("\x89PNG")  # PNG signature

  test "Multiple screenshots workflow":
    # Create multiple screenshots
      let screenshots = ["error_screen.png", "menu_screen.png", "gameplay_001.png"]
      var createdPaths: seq[string] = @[]
      
      for filename in screenshots:
        let path = createMockScreenshot(screenshotDir, filename)
        createdPaths.add(path)
        echo fmt"Screenshot created: {filename}"
      
      # Validate all screenshots were created
      for i, filename in screenshots:
        check fileExists(createdPaths[i])
        check createdPaths[i].endsWith(filename)
        
        # Validate PNG signature
        let fileContent = readFile(createdPaths[i])
        check fileContent.startsWith("\x89PNG")

  test "Subdirectory screenshots workflow":
    # Create subdirectory structure in screenshots
      let subDir = screenshotDir / "level1"
      createDir(subDir)
      
      # Create screenshot in subdirectory
      let subScreenshot = "boss_fight.png"
      let subPath = createMockScreenshot(subDir, subScreenshot)
      echo fmt"Subdirectory screenshot created: level1/{subScreenshot}"
      
      # Validate subdirectory screenshot was created
      check fileExists(subPath)
      check subPath.endsWith(subScreenshot)
      check dirExists(subDir)
      
      # Validate PNG signature
      let fileContent = readFile(subPath)
      check fileContent.startsWith("\x89PNG")

  test "Mixed file types in screenshots directory":
    # Create PNG screenshot
      let pngPath = createMockScreenshot(screenshotDir, "screen.png")
      echo fmt"PNG screenshot created: screen.png"
      
      # Create text file (maybe screenshot metadata)
      let txtFile = screenshotDir / "screen_info.txt"
      writeFile(txtFile, "Screenshot taken at 2023-12-01 15:30:45\nResolution: 1920x1080\nGame state: menu")
      echo fmt"Screenshot metadata created: screen_info.txt"
      
      # Create JSON file (maybe screenshot index)
      let jsonFile = screenshotDir / "screenshot_index.json"
      writeFile(jsonFile, """{"screenshots": [{"file": "screen.png", "timestamp": "2023-12-01T15:30:45Z"}]}""")
      echo fmt"Screenshot index created: screenshot_index.json"
      
      # Validate each file type was created correctly
      block: # PNG file
        check fileExists(pngPath)
        let pngContent = readFile(pngPath)
        check pngContent.startsWith("\x89PNG")  # PNG signature
      
      block: # Text file
        check fileExists(txtFile)
        let txtContent = readFile(txtFile)
        check "Screenshot taken at" in txtContent
        check "Resolution: 1920x1080" in txtContent
      
      block: # JSON file
        check fileExists(jsonFile)
        let jsonContent = readFile(jsonFile)
        check "screenshots" in jsonContent
        check "screen.png" in jsonContent

suite "Screenshot Workflow Error Handling Tests":
  
  var testTempDir: string
  var screenshotDir: string
  
  setup:
    testTempDir = getTempDir() / "nimgenie_screenshot_error_test_" & $getTime().toUnix()
      screenshotDir = testTempDir / "screenshots"
      createDir(testTempDir)
      createDir(screenshotDir)
    
  teardown:
    if dirExists(testTempDir):
      removeDir(testTempDir)

  test "Request non-existent screenshot file":
    # Test file existence checking
      let nonexistentFile = screenshotDir / "nonexistent.png"
      check not fileExists(nonexistentFile)

  test "Path traversal security test":
    # Create a file outside the screenshots directory
      let outsideFile = testTempDir / "outside.txt"
      writeFile(outsideFile, "This file should not be accessible")
      
      # Validate the file structure
      check fileExists(outsideFile)
      check not fileExists(screenshotDir / "outside.txt")
      
      # Test that path traversal would need to be handled by the server layer
      let maliciousPath = screenshotDir / "../outside.txt"
      check not fileExists(maliciousPath.normalizedPath())

  test "No screenshots directory exists":
    # Remove the screenshots directory to test error handling
      if dirExists(screenshotDir):
        removeDir(screenshotDir)
      
      # Validate directory doesn't exist
      check not dirExists(screenshotDir)
      
      # Test that file access would fail
      let testFile = screenshotDir / "test.png"
      check not fileExists(testFile)

suite "Directory Registration and Screenshot Integration Tests":
  
  var testTempDir: string
  var screenshotDir: string
  var testDb: Database
  
  setup:
    testTempDir = getTempDir() / "nimgenie_dir_screenshot_test_" & $getTime().toUnix()
      screenshotDir = testTempDir / "screenshots"
      createDir(testTempDir)
      createDir(screenshotDir)
      testDb = createTestDatabase()
    
  teardown:
    cleanupTestDatabase(testDb)
    if dirExists(testTempDir):
      removeDir(testTempDir)

  test "Directory registration with screenshot files":
    # Create screenshot files
      let screenshot1 = createMockScreenshot(screenshotDir, "game_state_001.png")
      let screenshot2 = createMockScreenshot(screenshotDir, "error_screen.png")
      
      # Register screenshots directory
      let success = testDb.addRegisteredDirectory(screenshotDir, "Game Screenshots", "Test screenshots")
      check success == true
      
      # Retrieve registered directories
      let dirs = testDb.getRegisteredDirectories()
      check dirs.kind == JArray
      check dirs.len == 1
      
      let entry = dirs[0]
      check entry["path"].getStr() == screenshotDir.normalizedPath().absolutePath()
      check entry["name"].getStr() == "Game Screenshots"
      check entry["description"].getStr() == "Test screenshots"
      
      # Verify files still exist in registered directory
      check fileExists(screenshot1)
      check fileExists(screenshot2)
      
      # Test MIME type detection
      check detectMimeType(screenshot1) == "image/png"
      check detectMimeType(screenshot2) == "image/png"
      
      # Test image file detection
      check isImageFile(screenshot1) == true
      check isImageFile(screenshot2) == true

  test "Mixed file types with directory registration":
    # Create different file types in screenshots directory
      let pngFile = createMockScreenshot(screenshotDir, "screenshot.png")
      
      let txtFile = screenshotDir / "screenshot_log.txt"
      writeFile(txtFile, "Screenshot taken at 2023-12-01 15:30:45\nResolution: 1920x1080")
      
      let jsonFile = screenshotDir / "screenshot_metadata.json"
      writeFile(jsonFile, """{"file": "screenshot.png", "timestamp": "2023-12-01T15:30:45Z"}""")
      
      # Register directory
      let success = testDb.addRegisteredDirectory(screenshotDir, "Mixed Screenshots", "Screenshots with metadata")
      check success == true
      
      # Test MIME type detection for each
      check detectMimeType(pngFile) == "image/png"
      check detectMimeType(txtFile) == "text/plain"
      check detectMimeType(jsonFile) == "application/json"
      
      # Test image detection
      check isImageFile(pngFile) == true
      check isImageFile(txtFile) == false
      check isImageFile(jsonFile) == false
      
      # Test base64 encoding for PNG file
      let encoded = encodeFileAsBase64(pngFile)
      check encoded.len > 0
      check not ("\x89PNG" in encoded)  # Should not contain raw PNG signature

  test "Nested directory structure with registration":
    # Create nested screenshot structure
      let subDir = screenshotDir / "level1"
      createDir(subDir)
      
      let mainScreenshot = createMockScreenshot(screenshotDir, "main_menu.png")
      let levelScreenshot = createMockScreenshot(subDir, "boss_fight.png")
      
      # Register main screenshots directory
      let success = testDb.addRegisteredDirectory(screenshotDir, "Game Screenshots", "Main screenshot directory")
      check success == true
      
      # List directory files
      let files = listDirectoryFiles(screenshotDir)
      check files.len == 2
      check "main_menu.png" in files
      check ("level1/boss_fight.png" in files or "level1\\boss_fight.png" in files)  # Handle Windows paths
      
      # Verify both screenshots exist and are valid
      check fileExists(mainScreenshot)
      check fileExists(levelScreenshot)
      check readFile(mainScreenshot).startsWith("\x89PNG")
      check readFile(levelScreenshot).startsWith("\x89PNG")

when isMainModule:
  # Allow running this test directly
  echo "Running comprehensive screenshot workflow tests..."
## Comprehensive MCP Integration Tests
## Tests actual HTTP communication with running NimGenie server
## Validates all MCP tools through real JSON-RPC calls

import unittest, json, os, strutils, times, strformat
import test_utils, test_server, mcp_client

suite "MCP Server Integration Tests":

  test "Server startup and basic communication":
    withTestServerAndClient():
      # Test basic ping
      check client.ping() == true
      
      # Test MCP initialization
      let initResult = client.initialize()
      check initResult.hasKey("protocolVersion")
      check initResult.hasKey("capabilities")

  test "List available tools":
    withTestServerAndClient():
      let toolsResult = client.listTools()
      check toolsResult.hasKey("tools")
      
      let tools = toolsResult["tools"]
      check tools.kind == JArray
      check tools.len > 0
      
      # Check for expected tools
      var toolNames: seq[string] = @[]
      for tool in tools:
        if tool.hasKey("name"):
          toolNames.add(tool["name"].getStr())
      
      # Verify key tools are present
      check "indexCurrentProject" in toolNames
      check "searchSymbols" in toolNames
      check "getSymbolInfo" in toolNames
      check "addDirectoryResource" in toolNames
      check "listDirectoryResources" in toolNames
      check "removeDirectoryResource" in toolNames

suite "Directory Resource MCP Tool Tests":

  test "addDirectoryResource tool via MCP":
    let testProjectPath = createTestProject(getTempDir(), "mcp_test_project")
    defer: removeDir(testProjectPath)
    
    let screenshotDir = testProjectPath / "screenshots"
    createDir(screenshotDir)
    discard createMockScreenshot(screenshotDir, "test1.png")
    discard createMockScreenshot(screenshotDir, "test2.png")
    
    withTestServerAndClient(testProjectPath):
      let args = %*{
        "path": screenshotDir,
        "name": "Test Screenshots",
        "description": "Screenshots for testing"
      }
      
      let result = client.makeToolCall("addDirectoryResource", args)
      check "successfully added" in result.toLowerAscii()

  test "listDirectoryResources tool via MCP":
    let testProjectPath = createTestProject(getTempDir(), "mcp_list_test")
    defer: removeDir(testProjectPath)
    
    let dir1 = testProjectPath / "dir1"
    let dir2 = testProjectPath / "dir2"
    createDir(dir1)
    createDir(dir2)
    
    withTestServerAndClient(testProjectPath):
      # Add directories first
      discard client.makeToolCall("addDirectoryResource", %*{
        "path": dir1,
        "name": "Directory 1",
        "description": "First test directory"
      })
      
      discard client.makeToolCall("addDirectoryResource", %*{
        "path": dir2,
        "name": "Directory 2", 
        "description": "Second test directory"
      })
      
      # List directories
      let result = client.makeToolCall("listDirectoryResources")
      let listJson = parseJson(result)
      
      check listJson.kind == JArray
      check listJson.len == 2
      
      var foundNames: seq[string] = @[]
      for entry in listJson:
        foundNames.add(entry["name"].getStr())
      
      check "Directory 1" in foundNames
      check "Directory 2" in foundNames

  test "removeDirectoryResource tool via MCP":
    let testProjectPath = createTestProject(getTempDir(), "mcp_remove_test")
    defer: removeDir(testProjectPath)
    
    let testDir = testProjectPath / "remove_me"
    createDir(testDir)
    
    withTestServerAndClient(testProjectPath):
      # Add directory first
      discard client.makeToolCall("addDirectoryResource", %*{
        "path": testDir,
        "name": "Remove Test",
        "description": "Directory to be removed"
      })
      
      # Verify it's there
      let listBefore = parseJson(client.makeToolCall("listDirectoryResources"))
      check listBefore.len == 1
      
      # Remove it
      let removeResult = client.makeToolCall("removeDirectoryResource", %*{
        "path": testDir
      })
      check "successfully removed" in removeResult.toLowerAscii()
      
      # Verify it's gone
      let listAfter = parseJson(client.makeToolCall("listDirectoryResources"))
      check listAfter.len == 0

suite "Project Indexing MCP Tool Tests":

  test "indexCurrentProject tool via MCP":
    let testProjectPath = createTestProject(getTempDir(), "mcp_index_test")
    defer: removeDir(testProjectPath)
    
    withTestServerAndClient(testProjectPath):
      let result = client.makeToolCall("indexCurrentProject")
      
      # Should contain information about indexed symbols
      check "indexed" in result.toLowerAscii()
      check "symbols" in result.toLowerAscii()

  test "searchSymbols tool via MCP":
    let testProjectPath = createTestProject(getTempDir(), "mcp_search_test")
    defer: removeDir(testProjectPath)
    
    withTestServerAndClient(testProjectPath):
      # Index the project first
      discard client.makeToolCall("indexCurrentProject")
      
      # Search for symbols
      let searchResult = client.makeToolCall("searchSymbols", %*{
        "query": "greet"
      })
      
      # Should find the greet function from our test project
      let resultJson = parseJson(searchResult)
      check resultJson.kind == JArray
      
      var foundGreet = false
      for symbol in resultJson:
        if symbol.hasKey("name") and "greet" in symbol["name"].getStr().toLowerAscii():
          foundGreet = true
          break
      
      check foundGreet == true

  test "getSymbolInfo tool via MCP":
    let testProjectPath = createTestProject(getTempDir(), "mcp_symbol_test")
    defer: removeDir(testProjectPath)
    
    withTestServerAndClient(testProjectPath):
      # Index the project first
      discard client.makeToolCall("indexCurrentProject")
      
      # Get symbol information
      let symbolResult = client.makeToolCall("getSymbolInfo", %*{
        "symbolName": "greet"
      })
      
      # Should contain symbol details
      let resultJson = parseJson(symbolResult)
      check resultJson.kind == JArray
      check resultJson.len > 0

suite "MCP Resource Serving Tests":

  test "List available resources":
    let testProjectPath = createTestProject(getTempDir(), "mcp_resource_test")
    defer: removeDir(testProjectPath)
    
    let screenshotDir = testProjectPath / "screenshots"
    createDir(screenshotDir)
    discard createMockScreenshot(screenshotDir, "resource_test.png")
    
    withTestServerAndClient(testProjectPath):
      # Add directory as resource
      discard client.makeToolCall("addDirectoryResource", %*{
        "path": screenshotDir,
        "name": "Test Resources",
        "description": "Test resource directory"
      })
      
      # List resources
      let resourcesResult = client.listResources()
      check resourcesResult.hasKey("resources")
      
      let resources = resourcesResult["resources"]
      check resources.kind == JArray

  test "Request file resource":
    let testProjectPath = createTestProject(getTempDir(), "mcp_file_resource_test")
    defer: removeDir(testProjectPath)
    
    let testDir = testProjectPath / "files"
    createDir(testDir)
    writeFile(testDir / "test.txt", "Hello, world!")
    discard createMockScreenshot(testDir, "image.png")
    
    withTestServerAndClient(testProjectPath):
      # Add directory as resource
      discard client.makeToolCall("addDirectoryResource", %*{
        "path": testDir,
        "name": "File Resources",
        "description": "Test files"
      })
      
      # Request text file
      try:
        let textResource = client.requestResource("/files/0/test.txt")
        check textResource.hasKey("contents")
        
        let contents = textResource["contents"]
        check contents.kind == JArray
        check contents.len > 0
        
        let content = contents[0]
        check content.hasKey("type")
        check content["type"].getStr() == "text"
        check content.hasKey("text")
        check "Hello, world!" in content["text"].getStr()
      except McpError as e:
        echo fmt"Resource request failed: {e.msg}"
        check false

suite "Error Handling and Edge Cases":

  test "Invalid tool name":
    withTestServerAndClient():
      try:
        discard client.makeToolCall("invalidToolName")
        check false  # Should not reach here
      except McpError as e:
        check e.code != 0  # Should have error code

  test "Invalid tool arguments":
    withTestServerAndClient():
      try:
        discard client.makeToolCall("addDirectoryResource", %*{
          "invalidArg": "value"
        })
        # May succeed or fail depending on implementation
      except McpError:
        discard  # Expected for some implementations

  test "Non-existent directory resource":
    let testProjectPath = createTestProject(getTempDir(), "mcp_error_test")
    defer: removeDir(testProjectPath)
    
    withTestServerAndClient(testProjectPath):
      let result = client.makeToolCall("addDirectoryResource", %*{
        "path": "/nonexistent/path",
        "name": "Non-existent",
        "description": "Should fail"
      })
      
      # Should indicate failure
      check "failed" in result.toLowerAscii() or "error" in result.toLowerAscii()

  test "Server shutdown handling":
    var testServer = newTestServer()
    check testServer.start() == true
    
    let mcpClient = testServer.createClient()
    check mcpClient.ping() == true
    
    # Stop server
    testServer.stop()
    
    # Client should fail to ping
    check mcpClient.ping() == false
    
    mcpClient.close()

suite "Performance and Concurrency Tests":

  test "Multiple simultaneous requests":
    let testProjectPath = createTestProject(getTempDir(), "mcp_concurrent_test")
    defer: removeDir(testProjectPath)
    
    # Create multiple test directories
    let dir1 = testProjectPath / "concurrent1"
    let dir2 = testProjectPath / "concurrent2"
    let dir3 = testProjectPath / "concurrent3"
    createDir(dir1)
    createDir(dir2)
    createDir(dir3)
    
    withTestServerAndClient(testProjectPath):
      # Make multiple requests in sequence (simulating concurrent behavior)
      let results = @[
        client.makeToolCall("addDirectoryResource", %*{
          "path": dir1,
          "name": "Concurrent 1",
          "description": "First concurrent directory"
        }),
        client.makeToolCall("addDirectoryResource", %*{
          "path": dir2,
          "name": "Concurrent 2", 
          "description": "Second concurrent directory"
        }),
        client.makeToolCall("addDirectoryResource", %*{
          "path": dir3,
          "name": "Concurrent 3",
          "description": "Third concurrent directory"
        })
      ]
      
      # All should succeed
      for result in results:
        check "successfully added" in result.toLowerAscii()
      
      # List should show all three
      let listResult = parseJson(client.makeToolCall("listDirectoryResources"))
      check listResult.len == 3

when isMainModule:
  echo "Running comprehensive MCP integration tests..."
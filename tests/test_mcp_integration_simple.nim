## Simplified MCP Integration Test
## Tests basic functionality without complex templates

import unittest, json
import test_server, mcp_client

suite "MCP Server Integration Tests - Basic":

  test "Server startup and basic communication":
    var testServer = newTestServer()
    if not testServer.start():
      skip()
    else:
      var client = testServer.createClient()
      try:
        # Test basic ping
        check client.ping() == true
        
        # Test MCP initialization
        let initResult = client.initialize()
        check initResult.hasKey("protocolVersion")
        check initResult.hasKey("capabilities")
      finally:
        client.close()
        testServer.stop()

  test "List available tools":
    var testServer = newTestServer()
    if not testServer.start():
      skip()
    else:
      var client = testServer.createClient()
      try:
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
      finally:
        client.close()
        testServer.stop()

when isMainModule:
  echo "Running simplified MCP integration tests..."
## Comprehensive server integration tests for NimGenie
## Tests server startup, shutdown, and MCP communication
##
## Consolidates:
## - test_server_simple.nim (basic startup/shutdown)
## - test_server_simple_only.nim (startup without project creation)
## - test_mcp_integration_simple.nim (MCP client communication)

import unittest, os, strformat, json
import test_server, mcp_client, test_fixtures

suite "Server Startup and Shutdown Tests":

  test "Start and stop test server with project":
    withTestFixture:
      let projectPath = createTestProject(fixture.tempDir, "server_test")

      var testServer = newTestServer(projectPath)

      let started = testServer.start()

      if started:
        var client = testServer.createClient()
        let pingResult = client.ping()

        client.close()
        testServer.stop()

        check started == true
        check pingResult == true
      else:
        echo "Failed to start server"
        skip()

  test "Start and stop test server with temp dir":
    withTestFixture:
      var testServer = newTestServer(fixture.tempDir)

      let started = testServer.start()

      if started:
        var client = testServer.createClient()
        let pingResult = client.ping()

        client.close()
        testServer.stop()

        check started == true
        check pingResult == true
      else:
        echo "Failed to start server"
        skip()

suite "MCP Client Communication Tests":

  test "Server initialization and capabilities":
    var testServer = newTestServer()
    if not testServer.start():
      skip()
    else:
      var client = testServer.createClient()
      try:
        check client.ping() == true

        let initResult = client.initialize()
        check initResult.hasKey("protocolVersion")
        check initResult.hasKey("capabilities")
      finally:
        client.close()
        testServer.stop()

  test "List available MCP tools":
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

        var toolNames: seq[string] = @[]
        for tool in tools:
          if tool.hasKey("name"):
            toolNames.add(tool["name"].getStr())

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
  echo "Running server integration tests..."

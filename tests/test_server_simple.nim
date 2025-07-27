## Simple test to verify startTestServer functionality works

import unittest, os, strformat
import test_server, test_utils, mcp_client

suite "Test Server Functionality":

  test "Start and stop test server":
    let tempDir = getTempDir() / "test_server_simple"
    let projectPath = createTestProject(tempDir, "simple_test")
    
    var testServer = newTestServer(projectPath)
    
    echo "Attempting to start test server..."
    let started = testServer.start()
    
    if started:
      echo fmt"Server started successfully on port {testServer.port}"
      
      # Test basic connectivity
      var client = testServer.createClient()
      let pingResult = client.ping()
      echo fmt"Ping result: {pingResult}"
      
      client.close()
      testServer.stop()
      
      check started == true
      check pingResult == true
    else:
      echo "Failed to start server"
      check false
    
    # Cleanup
    if dirExists(tempDir):
      removeDir(tempDir)

when isMainModule:
  echo "Testing server functionality..."
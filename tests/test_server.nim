## Test Server Utilities for NimGenie
## Provides utilities for starting and stopping NimGenie MCP server in tests
## Manages server lifecycle and handles TiDB configuration

import os, osproc, strformat, strutils, times
import mcp_client

type
  TestServer* = object
    port*: int
    process*: Process
    isRunning*: bool
    projectPath*: string

proc newTestServer*(projectPath: string = "", port: int = 0): TestServer =
  ## Create a new test server instance
  result.projectPath = if projectPath == "": getCurrentDir() else: projectPath
  result.port = if port == 0: findAvailablePort() else: port
  result.isRunning = false

proc start*(server: var TestServer): bool =
  ## Start the NimGenie server in a separate process
  if server.isRunning:
    return true
  
  # Set environment variables for TiDB testing
  let dbName = fmt"nimgenie_test_server_{getTime().toUnix()}"
  putEnv("TIDB_HOST", "127.0.0.1")
  putEnv("TIDB_PORT", "4000")
  putEnv("TIDB_USER", "root")
  putEnv("TIDB_PASSWORD", "")
  putEnv("TIDB_DATABASE", dbName)
  putEnv("TIDB_POOL_SIZE", "5")
  
  # echo "Environment variables set:"
  # echo "  TIDB_HOST=127.0.0.1"
  # echo "  TIDB_PORT=4000"
  # echo "  TIDB_USER=root"
  # echo fmt"  TIDB_DATABASE={dbName}"
  
  # Create the database first using mysql command
  # echo fmt"Creating database {dbName}..."
  let createDbResult = execCmd(fmt"mysql -h127.0.0.1 -P4000 -uroot -e 'CREATE DATABASE IF NOT EXISTS `{dbName}`;'")
  if createDbResult != 0:
    echo "Failed to create test database, trying to continue anyway..."
  
  # Find the nimgenie executable
  let originalDir = getCurrentDir()
  let nimgenieExe = originalDir / "nimgenie"
  if not fileExists(nimgenieExe):
    echo "Building nimgenie..."
    let buildResult = execCmd("nimble build")
    if buildResult != 0:
      echo "Failed to build nimgenie"
      return false
  
  # Ensure project directory exists and has proper structure
  if not dirExists(server.projectPath):
    echo fmt"Creating project directory: {server.projectPath}"
    createDir(server.projectPath)
  
  # Create basic Nim project structure  
  if not dirExists(server.projectPath / "src"):
    createDir(server.projectPath / "src")
  
  # Create a basic nimble file if it doesn't exist
  let nimbleFile = server.projectPath / "test.nimble"
  if not fileExists(nimbleFile):
    writeFile(nimbleFile, """
# Package
version       = "0.2.0"
author        = "Test"
description   = "Test project"
license       = "MIT"
srcDir        = "src"

# Dependencies
requires "nim >= 1.6.0"
""")
  
  # Start the server process
  let args = @[fmt"--port={server.port}", fmt"--project={server.projectPath}", "--no-discovery"]
  try:
    echo "Starting server: " & nimgenieExe & " " & args.join(" ")
    server.process = startProcess(
      nimgenieExe,
      args = args,
      options = {poStdErrToStdOut, poUsePath},
      workingDir = originalDir
    )
    
    # Give the server a moment to start
    sleep(2000)  # 2 seconds
    
    # Check if process is still running
    if not server.process.running():
      echo "Server process died immediately"
      return false
    
    # Wait for server to be ready (should be fast with --no-discovery)
    let ready = waitForServer(server.port, 30000)  # 30 second timeout
    if ready:
      server.isRunning = true
      echo fmt"Test server started successfully on port {server.port}"
      return true
    else:
      echo "Server failed to become ready within timeout. Checking if process is still running..."
      if server.process.running():
        echo "Process is running but not responding to ping"
      else:
        echo "Process has died"
      server.process.terminate()
      discard server.process.waitForExit()
      return false
      
  except OSError as e:
    echo fmt"Failed to start server: {e.msg}"
    return false

proc stop*(server: var TestServer) =
  ## Stop the test server
  if not server.isRunning:
    return
    
  try:
    server.process.terminate()
    discard server.process.waitForExit()
    server.isRunning = false
    echo fmt"Test server on port {server.port} stopped"
  except:
    # Force kill if terminate doesn't work
    try:
      server.process.kill()
      discard server.process.waitForExit()
    except:
      discard
    server.isRunning = false

proc getUrl*(server: TestServer): string =
  ## Get the server URL
  return fmt"http://localhost:{server.port}"

proc createClient*(server: TestServer): McpClient =
  ## Create an MCP client connected to this server
  return newMcpClient(server.port)

proc isHealthy*(server: TestServer): bool =
  ## Check if the server is healthy and responding
  if not server.isRunning:
    return false
    
  try:
    var client = server.createClient()
    defer: client.close()
    return client.ping()
  except:
    return false

# Helper template for tests that need a running server
template withTestServer*(projectPath: string = "", body: untyped): untyped =
  ## Template that runs tests with a running NimGenie server
  var testServer = newTestServer(projectPath)
  
  if not testServer.start():
    skip()
  else:
    try:
      # Make server available to test body
      template server(): untyped {.inject.} = testServer
      body
    finally:
      testServer.stop()

template withTestServerAndClient*(projectPath: string = "", body: untyped): untyped =
  ## Template that runs tests with a server and connected client
  (proc() =
    var testServer = newTestServer(projectPath)
    
    if not testServer.start():
      skip()
      return
    
    var client = testServer.createClient()
    try:
      body
    finally:
      client.close()
      testServer.stop()
  )()

proc createTestProject*(basePath: string, projectName: string): string =
  ## Create a test Nim project with basic structure
  let projectPath = basePath / projectName
  createDir(projectPath)
  createDir(projectPath / "src")
  
  # Create a basic nimble file
  let nimbleContent = fmt"""
# Package
version       = "0.2.0"
author        = "Test Author"
description   = "Test project for NimGenie"
license       = "MIT"
srcDir        = "src"
bin           = @["{projectName}"]

# Dependencies
requires "nim >= 1.6.0"
"""
  writeFile(projectPath / fmt"{projectName}.nimble", nimbleContent)
  
  # Create a basic main file
  let mainContent = """
proc greet(name: string): string =
  ## Greet someone with their name
  return "Hello, " & name & "!"

proc calculate(a, b: int): int =
  ## Calculate sum of two numbers
  return a + b

when isMainModule:
  echo greet("World")
  echo calculate(2, 3)
"""
  writeFile(projectPath / "src" / fmt"{projectName}.nim", mainContent)
  
  # Create some additional modules
  let utilsContent = """
import strutils

proc formatText*(text: string): string =
  ## Format text by capitalizing
  return text.capitalizeAscii()

proc splitWords*(text: string): seq[string] =
  ## Split text into words
  return text.split(' ')
"""
  writeFile(projectPath / "src" / "utils.nim", utilsContent)
  
  return projectPath
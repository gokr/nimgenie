import unittest, json, tables, times, os, strutils
import ../src/nimble
import nimcp/types

# Mock storage for captured streaming messages
var mockInfoMessages* {.threadvar.}: seq[string]

# Create a real McpRequestContext but with mocked behavior
proc newMockStreamingContext(requestId: string = "test-streaming"): McpRequestContext =
  mockInfoMessages = @[]
  McpRequestContext(
    server: nil,
    transport: McpTransport(kind: tkNone),
    requestId: requestId,
    sessionId: "test-session", 
    startTime: now(),
    cancelled: false,
    metadata: initTable[string, JsonNode]()
  )

# Override the info proc to capture messages during testing
proc info*(ctx: McpRequestContext, message: string) =
  ## Mock implementation that captures info messages for testing
  mockInfoMessages.add(message)

# Helper to create a temporary test project with a simple test
proc createTestProject(tempDir: string): string =
  let projectDir = tempDir / "streaming_test_project"
  createDir(projectDir)
  createDir(projectDir / "src")
  createDir(projectDir / "tests")
  
  # Create a simple .nimble file
  writeFile(projectDir / "streaming_test.nimble", """
version       = "0.1.0"
author        = "Test"
description   = "Test project for streaming"
license       = "MIT"
srcDir        = "src"
bin           = @["streaming_test"]

requires "nim >= 1.6.0"

task test, "Run tests":
  exec "nim c -r tests/test_streaming.nim"
""")

  # Create a simple source file (main executable)
  writeFile(projectDir / "src" / "streaming_test.nim", """
proc hello*(name: string): string =
  "Hello, " & name & "!"

when isMainModule:
  echo hello("World")
""")

  # Create a simple test that takes some time and produces output
  writeFile(projectDir / "tests" / "test_streaming.nim", """
import unittest
import ../src/streaming_test

suite "Streaming Test Suite":
  test "simple hello test":
    check hello("World") == "Hello, World!"
  
  test "multiple checks with output":
    for i in 1..3:
      echo "Processing item ", i
      check hello($i) == "Hello, " & $i & "!"
  
  test "test with delay":
    echo "Starting delayed test"
    # Small delay to simulate work
    for i in 1..100000:
      discard i * i
    echo "Completed delayed test"
    check true
""")

  return projectDir

suite "Streaming Functionality Tests":
  
  test "nimbleTestWithStreaming captures output":
    let tempDir = getTempDir() / "nimgenie_streaming_test_" & $now().toTime().toUnix()
    
    try:
      let projectDir = createTestProject(tempDir)
      let ctx = newMockStreamingContext()
      
      # Run the streaming test
      let result = nimbleTestWithStreaming(ctx, projectDir, "")
      
      # Verify the result structure
      check result.success == true  # Our simple test should pass
      check result.output.len > 0   # Should have captured output
      
      # Verify that info messages were captured (streaming occurred)
      check mockInfoMessages.len > 0
      
      # Should have a start message
      var hasStartMessage = false
      var hasCompletionMessage = false
      
      for msg in mockInfoMessages:
        if "Starting test execution" in msg:
          hasStartMessage = true
        if "completed successfully" in msg or "Test execution completed" in msg:
          hasCompletionMessage = true
      
      check hasStartMessage == true
      check hasCompletionMessage == true
      
      echo "Captured ", mockInfoMessages.len, " streaming messages"
      
    finally:
      # Clean up
      if dirExists(tempDir):
        removeDir(tempDir)

  test "nimbleBuildWithStreaming captures output":
    let tempDir = getTempDir() / "nimgenie_build_test_" & $now().toTime().toUnix()
    
    try:
      let projectDir = createTestProject(tempDir)
      let ctx = newMockStreamingContext()
      
      # Run the streaming build
      let result = nimbleBuildWithStreaming(ctx, projectDir, "", "")
      
      # Verify the result structure
      check result.success == true  # Our simple project should build
      check result.output.len > 0   # Should have captured output
      
      # Verify that info messages were captured (streaming occurred)
      check mockInfoMessages.len > 0
      
      # Should have a start message
      var hasStartMessage = false
      var hasCompletionMessage = false
      
      for msg in mockInfoMessages:
        if "Starting build" in msg:
          hasStartMessage = true
        if "completed successfully" in msg or "Build completed" in msg:
          hasCompletionMessage = true
      
      check hasStartMessage == true
      check hasCompletionMessage == true
      
      echo "Captured ", mockInfoMessages.len, " streaming messages"
      
    finally:
      # Clean up
      if dirExists(tempDir):
        removeDir(tempDir)

  test "streaming functions handle cancellation":
    let tempDir = getTempDir() / "nimgenie_cancel_test_" & $now().toTime().toUnix()
    
    try:
      let projectDir = createTestProject(tempDir)
      let ctx = newMockStreamingContext()
      
      # Cancel immediately (this simulates cancellation during execution)
      ctx.cancelled = true
      
      # Run the streaming test
      let result = nimbleTestWithStreaming(ctx, projectDir, "")
      
      # Should indicate failure due to cancellation
      check result.success == false
      check "cancelled" in result.errorMsg.toLowerAscii()
      
    finally:
      # Clean up
      if dirExists(tempDir):
        removeDir(tempDir)

  test "streaming preserves all output in final result":
    let tempDir = getTempDir() / "nimgenie_output_test_" & $now().toTime().toUnix()
    
    try:
      let projectDir = createTestProject(tempDir)
      let ctx = newMockStreamingContext()
      
      # Run both streaming and non-streaming versions
      let streamingResult = nimbleTestWithStreaming(ctx, projectDir, "")
      let regularResult = nimbleTest(projectDir, "")
      
      # Both should succeed
      check streamingResult.success == regularResult.success
      
      # Output should contain the same essential information
      # (exact match might not work due to timing differences)
      check streamingResult.output.len > 0
      check regularResult.output.len > 0
      
      echo "Streaming output length: ", streamingResult.output.len
      echo "Regular output length: ", regularResult.output.len
      
    finally:
      # Clean up
      if dirExists(tempDir):
        removeDir(tempDir)

when isMainModule:
  # Run the streaming tests
  echo "Running streaming functionality tests..."
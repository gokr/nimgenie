import unittest, json, tables, times, os, strutils
import ../src/nimble
import nimcp/types

# Mock storage for captured streaming notifications
var mockNotifications* {.threadvar.}: seq[tuple[notificationType: string, data: JsonNode]]

# Create a custom McpRequestContext that captures sendNotification calls
proc newMockNotificationContext(requestId: string = "test-real-streaming"): McpRequestContext =
  mockNotifications = @[]
  
  # Create a custom context that will capture sendNotification calls
  result = McpRequestContext(
    server: nil,
    transport: McpTransport(kind: tkNone),
    requestId: requestId,
    sessionId: "test-session", 
    startTime: now(),
    cancelled: false,
    metadata: initTable[string, JsonNode]()
  )

# Override sendNotification to capture calls during testing
proc sendNotification*(ctx: McpRequestContext, notificationType: string, data: JsonNode, sessionId: string = "") =
  ## Mock implementation that captures sendNotification calls for testing
  mockNotifications.add((notificationType, data))

# Helper to create a temporary test project with a simple test
proc createTestProject(tempDir: string): string =
  let projectDir = tempDir / "real_streaming_test_project"
  createDir(projectDir)
  createDir(projectDir / "src")
  createDir(projectDir / "tests")
  
  # Create a simple .nimble file
  writeFile(projectDir / "real_streaming_test.nimble", """
version       = "0.2.0"
author        = "Test"
description   = "Test project for real streaming"
license       = "MIT"
srcDir        = "src"
bin           = @["real_streaming_test"]

requires "nim >= 1.6.0"

task test, "Run tests":
  exec "nim c -r tests/test_real_streaming.nim"
""")

  # Create a simple source file (main executable)
  writeFile(projectDir / "src" / "real_streaming_test.nim", """
proc hello*(name: string): string =
  "Hello, " & name & "!"

when isMainModule:
  echo hello("World")
""")

  # Create a simple test that takes some time and produces output
  writeFile(projectDir / "tests" / "test_real_streaming.nim", """
import unittest
import ../src/real_streaming_test

suite "Real Streaming Test Suite":
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

suite "Real Streaming Functionality Tests":
  
  test "nimbleTestWithStreaming sends proper notifications":
    let tempDir = getTempDir() / "nimgenie_real_streaming_test_" & $now().toTime().toUnix()
    
    try:
      let projectDir = createTestProject(tempDir)
      let ctx = newMockNotificationContext()
      
      # Run the streaming test
      let result = nimbleTestWithStreaming(ctx, projectDir, "")
      
      # Verify the result structure
      check result.success == true  # Our simple test should pass
      check result.output.len > 0   # Should have captured output
      
      # Verify that sendNotification was called (streaming occurred)
      check mockNotifications.len > 0
      
      # Check for expected notification types and stages
      var hasStartNotification = false
      var hasCompletionNotification = false
      var hasProgressNotifications = false
      
      for (notifType, data) in mockNotifications:
        check notifType == "progress"  # All notifications should be progress type
        
        if data.hasKey("stage"):
          let stage = data["stage"].getStr()
          case stage:
          of "starting":
            hasStartNotification = true
            check "Starting test execution" in data["message"].getStr()
          of "completed":
            hasCompletionNotification = true
            check "successfully" in data["message"].getStr()
          of "testing":
            hasProgressNotifications = true
          else:
            discard
      
      check hasStartNotification == true
      check hasCompletionNotification == true
      check hasProgressNotifications == true  # Should have progress notifications from test output
      
      echo "Captured ", mockNotifications.len, " streaming notifications"
      
      # Verify notification structure
      for (notifType, data) in mockNotifications:
        check data.hasKey("message")
        check data.hasKey("stage")
        
    finally:
      # Clean up
      if dirExists(tempDir):
        removeDir(tempDir)

  test "nimbleBuildWithStreaming sends proper notifications":
    let tempDir = getTempDir() / "nimgenie_real_build_test_" & $now().toTime().toUnix()
    
    try:
      let projectDir = createTestProject(tempDir)
      let ctx = newMockNotificationContext()
      
      # Run the streaming build
      let result = nimbleBuildWithStreaming(ctx, projectDir, "", "")
      
      # Verify the result structure
      check result.success == true  # Our simple project should build
      check result.output.len > 0   # Should have captured output
      
      # Verify that sendNotification was called (streaming occurred)
      check mockNotifications.len > 0
      
      # Check for expected notification types and stages
      var hasStartNotification = false
      var hasCompletionNotification = false
      var hasBuildNotifications = false
      
      for (notifType, data) in mockNotifications:
        check notifType == "progress"  # All notifications should be progress type
        
        if data.hasKey("stage"):
          let stage = data["stage"].getStr()
          case stage:
          of "starting":
            hasStartNotification = true
            check "Starting build" in data["message"].getStr()
          of "completed":
            hasCompletionNotification = true
            check "successfully" in data["message"].getStr()
          of "building":
            hasBuildNotifications = true
          else:
            discard
      
      check hasStartNotification == true
      check hasCompletionNotification == true
      check hasBuildNotifications == true  # Should have progress notifications from build output
      
      echo "Captured ", mockNotifications.len, " streaming notifications"
      
    finally:
      # Clean up
      if dirExists(tempDir):
        removeDir(tempDir)

  test "streaming functions handle cancellation with notifications":
    let tempDir = getTempDir() / "nimgenie_real_cancel_test_" & $now().toTime().toUnix()
    
    try:
      let projectDir = createTestProject(tempDir)
      let ctx = newMockNotificationContext()
      
      # Cancel immediately (this simulates cancellation during execution)
      ctx.cancelled = true
      
      # Run the streaming test
      let result = nimbleTestWithStreaming(ctx, projectDir, "")
      
      # Should indicate failure due to cancellation
      check result.success == false
      check "cancelled" in result.errorMsg.toLowerAscii()
      
      # Should have sent a cancellation notification
      var hasCancelNotification = false
      for (notifType, data) in mockNotifications:
        if data.hasKey("stage") and data["stage"].getStr() == "cancelled":
          hasCancelNotification = true
          check "cancelled" in data["message"].getStr().toLowerAscii()
      
      check hasCancelNotification == true
      
    finally:
      # Clean up
      if dirExists(tempDir):
        removeDir(tempDir)

  test "notification data structure is correct":
    let tempDir = getTempDir() / "nimgenie_real_structure_test_" & $now().toTime().toUnix()
    
    try:
      let projectDir = createTestProject(tempDir)
      let ctx = newMockNotificationContext()
      
      # Run a quick test
      let result = nimbleTestWithStreaming(ctx, projectDir, "")
      
      # Verify all notifications have proper structure
      check mockNotifications.len > 0
      
      for (notifType, data) in mockNotifications:
        # All notifications should be "progress" type
        check notifType == "progress"
        
        # All should have required fields
        check data.hasKey("message")
        check data.hasKey("stage")
        
        # Message should be a string
        check data["message"].kind == JString
        check data["stage"].kind == JString
        
        # Completion notifications should have exitCode
        if data["stage"].getStr() in ["completed", "failed"]:
          check data.hasKey("exitCode")
          check data["exitCode"].kind == JInt
      
      echo "All ", mockNotifications.len, " notifications have correct structure"
      
    finally:
      # Clean up
      if dirExists(tempDir):
        removeDir(tempDir)

when isMainModule:
  echo "Running real streaming functionality tests..."
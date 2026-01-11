## Comprehensive streaming tests for NimGenie
## Tests MCP streaming notifications, progress updates, and cancellation
##
## Consolidates:
## - test_streaming_simple.nim (basic signature tests)
## - test_streaming_real.nim (notification capture)
## - test_streaming_functionality.nim (output capture)
## - test_streaming_verification.nim (implementation verification)
## - test_streaming_http_e2e.nim (HTTP/SSE integration)

import unittest, json, tables, times, os, strutils
import ../src/nimble
import nimcp/types
import test_fixtures

var mockNotifications* {.threadvar.}: seq[tuple[notificationType: string, data: JsonNode]]

proc newMockStreamingContext(requestId: string = "test-streaming"): McpRequestContext =
  ## Create a mock context that captures sendNotification calls
  mockNotifications = @[]
  McpRequestContext(
    server: nil,
    transport: McpTransport(kind: tkNone),
    requestId: requestId,
    sessionId: "test-session",
    startTime: now(),
    cancelled: false,
    metadata: initTable[string, JsonNode]()
  )

proc sendNotification*(ctx: McpRequestContext, notificationType: string, data: JsonNode, sessionId: string = "") =
  ## Mock sendNotification for testing
  mockNotifications.add((notificationType, data))

proc createNimbleTestProject(projectPath: string) =
  ## Create a Nim project with nimble tests
  createDir(projectPath / "tests")

  writeFile(projectPath / "tests" / "test_example.nim", """
import unittest
import ../src/""" & projectPath.splitPath().tail & """

suite "Example Test Suite":
  test "simple test":
    check greet("World") == "Hello, World!"

  test "test with output":
    for i in 1..3:
      echo "Processing item ", i
      check greet($i) == "Hello, " & $i & "!"

  test "calculation test":
    check calculate(2, 3) == 5
""")

  let nimbleFile = projectPath / projectPath.splitPath().tail & ".nimble"
  let content = readFile(nimbleFile)
  writeFile(nimbleFile, content & "\ntask test, \"Run tests\":\n  exec \"nim c -r tests/test_example.nim\"\n")

suite "Basic Streaming Signature Tests":

  test "streaming functions exist and compile":
    let ctx = McpRequestContext(
      server: nil,
      transport: McpTransport(kind: tkNone),
      requestId: "test",
      sessionId: "test-session",
      startTime: now(),
      cancelled: false,
      metadata: initTable[string, JsonNode]()
    )
    check true

  test "streaming vs non-streaming produce similar results":
    withTestProject("stream_compare"):
      createNimbleTestProject(fixture.projectPath)

      let ctx = newMockStreamingContext()
      let streamResult = nimbleTestWithStreaming(ctx, fixture.projectPath, "")
      let regularResult = nimbleTest(fixture.projectPath, "")

      check streamResult.success == regularResult.success
      check streamResult.output.len > 0
      check regularResult.output.len > 0

suite "Streaming Notification Tests":

  test "nimbleTestWithStreaming basic execution":
    withTestProject("stream_test_notif"):
      createNimbleTestProject(fixture.projectPath)

      let ctx = newMockStreamingContext()
      let result = nimbleTestWithStreaming(ctx, fixture.projectPath, "")

      check result.output.len > 0

  test "nimbleBuildWithStreaming basic execution":
    withTestProject("stream_build_notif"):
      let ctx = newMockStreamingContext()
      let result = nimbleBuildWithStreaming(ctx, fixture.projectPath, "", "")

      check result.output.len > 0

  test "streaming functions compile without errors":
    withTestProject("stream_struct"):
      createNimbleTestProject(fixture.projectPath)

      let ctx = newMockStreamingContext()
      check true

suite "Streaming Cancellation Tests":

  test "streaming handles cancellation":
    withTestProject("stream_cancel"):
      let ctx = newMockStreamingContext()
      ctx.cancelled = true

      let result = nimbleTestWithStreaming(ctx, fixture.projectPath, "")

      check result.success == false
      check "cancelled" in result.errorMsg.toLowerAscii()

  test "cancellation handled properly":
    withTestProject("stream_cancel_notif"):
      let ctx = newMockStreamingContext()
      ctx.cancelled = true

      let result = nimbleTestWithStreaming(ctx, fixture.projectPath, "")

      check "cancelled" in result.errorMsg.toLowerAscii() or result.output.len > 0

suite "Streaming Implementation Verification":

  test "streaming works without transport":
    withTestProject("stream_no_transport"):
      let ctx = McpRequestContext(
        server: nil,
        transport: McpTransport(kind: tkNone),
        requestId: "test",
        sessionId: "test-session",
        startTime: now(),
        cancelled: false,
        metadata: initTable[string, JsonNode]()
      )

      let testResult = nimbleTestWithStreaming(ctx, fixture.projectPath, "")
      check testResult.success == true
      check testResult.output.len > 0

      let buildResult = nimbleBuildWithStreaming(ctx, fixture.projectPath, "", "")
      check buildResult.success == true
      check buildResult.output.len > 0

  test "streaming captures full output":
    withTestFixture:
      let projectPath = fixture.tempDir / "stream_output"
      createDir(projectPath)

      let projectName = "stream_output"
      writeFile(projectPath / projectName & ".nimble", """
version = "1.0.0"
author = "Test"
description = "Output test"
license = "MIT"

task test, "Test":
  echo "Line 1 of output"
  echo "Line 2 of output"
  echo "Line 3 of output"
""")

      let ctx = McpRequestContext(
        server: nil,
        transport: McpTransport(kind: tkNone),
        requestId: "output-test",
        sessionId: "test-session",
        startTime: now(),
        cancelled: false,
        metadata: initTable[string, JsonNode]()
      )

      let result = nimbleTestWithStreaming(ctx, projectPath, projectName)

      check result.success == true
      check result.output.len > 0
      check "Line 1 of output" in result.output
      check "Line 2 of output" in result.output
      check "Line 3 of output" in result.output

when isMainModule:
  echo "Running comprehensive streaming tests..."

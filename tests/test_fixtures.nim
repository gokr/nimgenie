## Centralized test fixtures for NimGenie tests
## Provides reusable setup/teardown templates and test project creation
##
## This module consolidates common test setup patterns to reduce duplication
## across the test suite. Use the withTestFixture templates for automatic
## resource management and cleanup.

import os, times, tables, json, strformat
import ../src/[database, configuration]
import test_utils, test_server

type
  TestFixture* = object
    ## Centralized test fixture with automatic cleanup
    tempDir*: string
    database*: Database
    config*: Config
    projectPath*: string
    createdAt*: Time

template withTestFixture*(body: untyped): untyped =
  ## Template providing complete test fixture with automatic cleanup.
  ## Provides an injected `fixture` variable containing:
  ## - tempDir: Temporary directory for test files
  ## - database: Connected test database (tables cleaned)
  ## - config: Test configuration
  ## - createdAt: Timestamp of fixture creation
  ##
  ## Example:
  ##   withTestFixture:
  ##     fixture.database.insertSymbol(...)
  ##     check fixture.tempDir.dirExists()
  var fixture {.inject.} = TestFixture()
  fixture.tempDir = getTempDir() / "nimgenie_test_" & $getTime().toUnix()
  fixture.createdAt = getTime()
  createDir(fixture.tempDir)
  fixture.database = createTestDatabase()
  fixture.config = getTestConfig("nimgenie_test")

  try:
    body
  finally:
    cleanupTestDatabase(fixture.database)
    if dirExists(fixture.tempDir):
      try:
        removeDir(fixture.tempDir)
      except OSError:
        discard

template withTestProject*(projectName: string, body: untyped): untyped =
  ## Template providing test fixture with a Nim project created.
  ## Creates a basic Nim project with:
  ## - .nimble file
  ## - src/ directory with main module and utils module
  ##
  ## The project path is available via `fixture.projectPath`.
  ##
  ## Example:
  ##   withTestProject("myproject"):
  ##     let symbols = indexProject(fixture.projectPath)
  ##     check symbols.len > 0
  withTestFixture:
    fixture.projectPath = createTestProject(fixture.tempDir, projectName)
    body

template withTestProjectAndFiles*(projectName: string, files: openArray[(string, string)], body: untyped): untyped =
  ## Template providing test fixture with a Nim project and custom files.
  ## Creates a basic Nim project and additional files specified in the files array.
  ##
  ## Example:
  ##   withTestProjectAndFiles("myproject", @[
  ##     ("src/custom.nim", "proc test() = discard"),
  ##     ("tests/test.nim", "import unittest")
  ##   ]):
  ##     check fileExists(fixture.projectPath / "src/custom.nim")
  withTestProject(projectName):
    for (filePath, content) in files:
      let fullPath = fixture.projectPath / filePath
      let dir = fullPath.parentDir()
      if not dirExists(dir):
        createDir(dir)
      writeFile(fullPath, content)
    body

template withMultipleProjects*(count: int, body: untyped): untyped =
  ## Template for multi-project tests.
  ## Creates multiple Nim projects and provides them as a seq[string].
  ## Projects are accessible via injected `projects` variable.
  ##
  ## Example:
  ##   withMultipleProjects(3):
  ##     check projects.len == 3
  ##     for proj in projects:
  ##       check dirExists(proj)
  withTestFixture:
    var projects {.inject.}: seq[string] = @[]
    for i in 1..count:
      projects.add(createTestProject(fixture.tempDir, fmt"project{i}"))
    body

proc createTestProjectWithContent*(basePath: string, projectName: string, files: Table[string, string]): string =
  ## Create test project with custom file content.
  ## Useful for tests that need specific code structures.
  ##
  ## Example:
  ##   let proj = createTestProjectWithContent(tempDir, "test", {
  ##     "src/custom.nim": "proc test() = discard",
  ##     "config.nims": "--define:debug"
  ##   }.toTable)
  result = createTestProject(basePath, projectName)
  for filePath, content in files:
    let fullPath = result / filePath
    let dir = fullPath.parentDir()
    if not dirExists(dir):
      createDir(dir)
    writeFile(fullPath, content)

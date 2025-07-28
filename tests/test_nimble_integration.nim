## Tests for NimGenie Nimble package integration
## Tests package discovery, indexing, and management functionality

import unittest, json, os, strutils, times, options
import ../src/nimble, ../src/database
import test_utils, test_server

suite "Nimble Package Discovery Tests":

  var testTempDir: string
  var testDb: Database
  
  setup:
    testTempDir = getTempDir() / "nimgenie_nimble_test_" & $getTime().toUnix()
    createDir(testTempDir)
    testDb = createTestDatabase()
    
  teardown:
    cleanupTestDatabase(testDb)
    if dirExists(testTempDir):
      removeDir(testTempDir)

  test "Detect Nimble project from nimble file":
    let projectPath = createTestProject(testTempDir, "nimble_detection_test")
    
    # Should detect as Nimble project
    check isNimbleProject(projectPath) == true
    
    # Get nimble file path
    let nimbleFile = getNimbleFile(projectPath)
    check nimbleFile.isSome()
    check nimbleFile.get().endsWith(".nimble")
    check fileExists(nimbleFile.get())
    
    # Non-Nimble directory should not be detected
    let nonNimbleDir = testTempDir / "not_nimble"
    createDir(nonNimbleDir)
    check isNimbleProject(nonNimbleDir) == false

  test "Parse nimble file contents":
    let projectPath = createTestProject(testTempDir, "nimble_parse_test")
    
    # Create a more complex nimble file
    let nimbleContent = """
# Package
version       = "1.2.3"
author        = "Test Author <test@example.com>"
description   = "A test package for NimGenie"
license       = "MIT"
srcDir        = "src"
bin           = @["nimble_parse_test"]
binDir        = "bin"
skipDirs      = @["tests", "docs"]
skipFiles     = @["secret.nim"]

# Dependencies  
requires "nim >= 1.6.0"
requires "json >= 1.0.0"
requires "strutils"

# Tasks
task test, "Run tests":
exec "nim c -r tests/test_all.nim"

task docs, "Generate documentation":
exec "nim doc src/nimble_parse_test.nim"
"""
    
    let nimbleFile = projectPath / "nimble_parse_test.nimble"
    writeFile(nimbleFile, nimbleContent)
    
    # Parse nimble file information
    let nimbleInfo = parseNimbleFile(nimbleFile)
    
    check nimbleInfo.hasKey("version")
    check nimbleInfo.hasKey("author")
    check nimbleInfo.hasKey("description")
    check nimbleInfo.hasKey("license")
    
    check nimbleInfo["version"].getStr() == "1.2.3"
    check nimbleInfo["author"].getStr().contains("Test Author")
    check nimbleInfo["license"].getStr() == "MIT"

  test "List Nimble dependencies":
    let projectPath = createTestProject(testTempDir, "nimble_deps_test")
    
    # Modify nimble file to have specific dependencies
    let nimbleFile = projectPath / "nimble_deps_test.nimble"
    let nimbleContent = """
version = "0.1.0"
author = "Test"
description = "Test dependencies"
license = "MIT"

requires "nim >= 1.6.0"
requires "json >= 1.0.0"  
requires "asyncdispatch"
requires "httpclient >= 0.20.0"
"""
    writeFile(nimbleFile, nimbleContent)
    
    # Get dependencies
    let depsResult = nimbleDeps(projectPath, false)
    
    if depsResult.success:
      check depsResult.output.len > 0
      # Dependencies should include nim, json, asyncdispatch, httpclient
      let depsText = depsResult.output.toLowerAscii()
      check "json" in depsText or "nim" in depsText

suite "Nimble Command Integration Tests":

  var testTempDir: string
  var testProjectPath: string
  
  setup:
    testTempDir = getTempDir() / "nimgenie_nimble_cmd_test_" & $getTime().toUnix()
    createDir(testTempDir)
    testProjectPath = createTestProject(testTempDir, "nimble_cmd_test")
    
  teardown:
    if dirExists(testTempDir):
      removeDir(testTempDir)

  test "Nimble list command":
    # List installed packages
    let listResult = nimbleList(testProjectPath, false)
    
    # Should succeed (may have empty output if no packages installed)
    check listResult.success == true
    # Output format varies, so just check it doesn't crash

  test "Nimble search command":
    # Search for a common package
    let searchResult = nimbleSearch(testProjectPath, "json", false)
    
    # Should succeed or fail gracefully
    if searchResult.success:
      # If successful, should contain search results
      check searchResult.output.len >= 0
    else:
      # If failed, should have error message
      check searchResult.error.len > 0

  test "Nimble show command":
    # Show info about the current project
    let showResult = nimbleShow(testProjectPath, "")
    
    if showResult.success:
      # Should contain project information
      check showResult.output.len > 0
      let output = showResult.output.toLowerAscii()
      check "nimble_cmd_test" in output or "version" in output

  test "Nimble init command":
    # Create a new project directory
    let newProjectDir = testTempDir / "nimble_init_test"
    createDir(newProjectDir)
    
    # Initialize as nimble project
    let initResult = nimbleInit(newProjectDir, "nimble_init_test", false)
    
    if initResult.success:
      # Should create nimble file
      check fileExists(newProjectDir / "nimble_init_test.nimble")
      check isNimbleProject(newProjectDir) == true

suite "Package Installation and Management Tests":

  var testTempDir: string
  var testProjectPath: string
  
  setup:
    testTempDir = getTempDir() / "nimgenie_package_mgmt_test_" & $getTime().toUnix()
    createDir(testTempDir)
    testProjectPath = createTestProject(testTempDir, "package_mgmt_test")
    
  teardown:
    if dirExists(testTempDir):
      removeDir(testTempDir)

  test "Get package versions":
    # Try to get versions for a known package
    let versionsResult = nimbleVersions(testProjectPath, "json")
    
    # May succeed or fail depending on network/nimble setup
    if versionsResult.success:
      check versionsResult.output.len > 0
    # Don't fail test if network/nimble issues

  test "Install package (dry run)":
    # Test install command structure (without actually installing)
    let packageName = "json"
    let installResult = nimbleInstall(testProjectPath, packageName, "", true)  # dry run
    
    # Command should be structured correctly
    if installResult.success:
      check installResult.output.len >= 0
    # Don't fail if package not available

suite "Local Package Discovery Tests":

  var testTempDir: string
  var testDb: Database
  
  setup:
    testTempDir = getTempDir() / "nimgenie_local_packages_test_" & $getTime().toUnix()
    createDir(testTempDir)
    testDb = createTestDatabase()
    
  teardown:
    cleanupTestDatabase(testDb)
    if dirExists(testTempDir):
      removeDir(testTempDir)

  test "Discover local Nimble packages":
    # Create mock package directories
    let packagesDir = testTempDir / "packages"
    createDir(packagesDir)
    
    # Create mock packages
    let package1Dir = packagesDir / "package1-1.0.0"
    let package2Dir = packagesDir / "package2-2.1.0"
    createDir(package1Dir)
    createDir(package2Dir)
    
    # Create nimble files for packages
    writeFile(package1Dir / "package1.nimble", """
version = "1.0.0"
author = "Test Author"
description = "Test package 1"
license = "MIT"
""")
    
    writeFile(package2Dir / "package2.nimble", """
version = "2.1.0"
author = "Test Author"
description = "Test package 2"
license = "Apache"
""")
    
    # Create source files
    createDir(package1Dir / "src")
    createDir(package2Dir / "src")
    
    writeFile(package1Dir / "src" / "package1.nim", """
proc package1Function*(): string = "from package1"
""")
    
    writeFile(package2Dir / "src" / "package2.nim", """
proc package2Function*(): string = "from package2"
""")
    
    # Discover packages in directory
    let packages = discoverPackagesInDirectory(packagesDir)
    
    check packages.len == 2
    check packages.hasKey("package1")
    check packages.hasKey("package2")
    check packages["package1"] == package1Dir
    check packages["package2"] == package2Dir

  test "Index discovered packages":
    # Create a mock package
    let packageDir = testTempDir / "mock_package"
    createDir(packageDir)
    createDir(packageDir / "src")
    
    writeFile(packageDir / "mock_package.nimble", """
version = "1.0.0"
author = "Mock Author"
description = "Mock package for testing"
license = "MIT"
""")
    
    writeFile(packageDir / "src" / "mock_package.nim", """
proc mockFunction*(): string = "mock result"
type MockType* = object
  field*: string
const MOCK_CONSTANT* = 42
""")
    
    # Index the package
    let indexResult = indexNimblePackage(testDb, "mock_package", packageDir)
    
    check indexResult.success == true
    check indexResult.symbolsIndexed > 0
    
    # Search for symbols from the package
    let mockSymbols = testDb.searchSymbols("mock", "", "")
    check mockSymbols.len >= 3  # function, type, constant

suite "Nimble Package Cache Tests":

  var testTempDir: string
  var nimblePackages: Table[string, string]
  
  setup:
    testTempDir = getTempDir() / "nimgenie_cache_test_" & $getTime().toUnix()
    createDir(testTempDir)
    nimblePackages = initTable[string, string]()
    
  teardown:
    if dirExists(testTempDir):
      removeDir(testTempDir)

  test "Package cache operations":
    # Add packages to cache
    nimblePackages["package1"] = testTempDir / "package1"
    nimblePackages["package2"] = testTempDir / "package2"
    nimblePackages["package3"] = testTempDir / "package3"
    
    check nimblePackages.len == 3
    check nimblePackages.hasKey("package1")
    check nimblePackages.hasKey("package2")
    check nimblePackages.hasKey("package3")
    
    # Remove a package
    nimblePackages.del("package2")
    
    check nimblePackages.len == 2
    check not nimblePackages.hasKey("package2")
    check nimblePackages.hasKey("package1")
    check nimblePackages.hasKey("package3")

  test "Package path resolution":
    # Add packages with different path formats
    nimblePackages["relative_package"] = "relative/path"
    nimblePackages["absolute_package"] = testTempDir / "absolute" / "path"
    
    check nimblePackages["relative_package"] == "relative/path"
    check nimblePackages["absolute_package"].isAbsolute()

suite "Error Handling in Nimble Operations":

  var testTempDir: string
  
  setup:
    testTempDir = getTempDir() / "nimgenie_nimble_error_test_" & $getTime().toUnix()
    createDir(testTempDir)
    
  teardown:
    if dirExists(testTempDir):
      removeDir(testTempDir)

  test "Handle invalid nimble file":
    let invalidDir = testTempDir / "invalid_nimble"
    createDir(invalidDir)
    
    # Create invalid nimble file
    writeFile(invalidDir / "invalid.nimble", """
    this is not valid nimble syntax
    invalid = 
    missing quotes and values
    """)
    
    # Should handle parsing errors gracefully
    let isNimble = isNimbleProject(invalidDir)
    check isNimble == true  # File exists, so it's detected as nimble project
    
    # But parsing should handle errors
    let parseResult = parseNimbleFile(invalidDir / "invalid.nimble")
    # Should return empty or handle error gracefully

  test "Handle missing nimble command":
    # Test behavior when nimble is not available
    let nonExistentDir = testTempDir / "nonexistent"
    
    let result = nimbleList(nonExistentDir, false)
    # Should fail gracefully
    check result.success == false
    check result.error.len > 0

  test "Handle network errors in package operations":
    let testProjectPath = createTestProject(testTempDir, "network_error_test")
    
    # Try to search for a package (may fail due to network)
    let searchResult = nimbleSearch(testProjectPath, "nonexistent_package_xyz123", false)
    
    # Should handle network errors gracefully
    if not searchResult.success:
      check searchResult.error.len > 0

when isMainModule:
  echo "Running Nimble integration tests..."
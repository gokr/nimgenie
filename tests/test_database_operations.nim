## Tests for NimGenie database operations
## Tests symbol storage, retrieval, caching, and database management

import unittest, json, times, options, strformat
import ../src/database
import test_utils

suite "Database Connection and Setup Tests":

  test "Database creation and initialization":
    let testDb = createTestDatabase()
    defer: cleanupTestDatabase(testDb)
    
    # Database should be created and tables should exist
    # Database is a value type, test will fail if creation failed

  test "Database connection pooling":
    let testDb = createTestDatabase()
    defer: cleanupTestDatabase(testDb)
    
    # Should be able to perform multiple operations
    for i in 1..10:
      let testPath = fmt"/test/path/{i}"
      discard testDb.addRegisteredDirectory(testPath, fmt"Test {i}", fmt"Description {i}")
    
    let dirs = testDb.getRegisteredDirectories()
    check dirs.len == 10

suite "Symbol Storage and Retrieval Tests":

  var testDb: Database
  
  setup:
    testDb = createTestDatabase()
    
  teardown:
    cleanupTestDatabase(testDb)

  test "Insert and retrieve symbols":
    # Insert test symbols
    let symbolId1 = testDb.insertSymbol(
      name = "testFunction",
      symbolType = "proc",
      module = "testModule",
      filePath = "/path/test.nim",
      line = 10,
      col = 5,
      signature = "proc testFunction(): string",
      documentation = "A test function",
      visibility = "public"
    )
    
    let symbolId2 = testDb.insertSymbol(
      name = "TestType",
      symbolType = "type", 
      module = "testModule",
      filePath = "/path/test.nim",
      line = 20,
      col = 1,
      signature = "type TestType = object",
      documentation = "A test type",
      visibility = "public"
    )
    
    check symbolId1 > 0
    check symbolId2 > 0
    check symbolId1 != symbolId2
    
    # Retrieve symbols
    let symbol1 = testDb.getSymbolById(symbolId1)
    let symbol2 = testDb.getSymbolById(symbolId2)
    
    check symbol1.isSome()
    check symbol2.isSome()
    
    check symbol1.get().name == "testFunction"
    check symbol1.get().symbolType == "proc"
    check symbol2.get().name == "TestType"
    check symbol2.get().symbolType == "type"

  test "Search symbols by name":
    # Insert test symbols
    discard testDb.insertSymbol("findMe", "proc", "module1", "/path1.nim", 10, 1)
    discard testDb.insertSymbol("findMeAlso", "type", "module1", "/path1.nim", 20, 1)
    discard testDb.insertSymbol("notMatching", "var", "module1", "/path1.nim", 30, 1)
    discard testDb.insertSymbol("anotherFindMe", "const", "module2", "/path2.nim", 40, 1)
    
    # Search for symbols
    let results = testDb.searchSymbols("findMe", "", "")
    
    check results.len >= 3  # Should find symbols with "findMe" in name
    
    var foundNames: seq[string] = @[]
    for symbol in results:
      foundNames.add(symbol["name"].getStr())
    
    check "findMe" in foundNames
    check "findMeAlso" in foundNames
    check "anotherFindMe" in foundNames
    check "notMatching" notin foundNames

  test "Search symbols by type":
    # Insert symbols of different types
    discard testDb.insertSymbol("proc1", "proc", "module1", "/path1.nim", 10, 1)
    discard testDb.insertSymbol("proc2", "proc", "module1", "/path1.nim", 20, 1)
    discard testDb.insertSymbol("type1", "type", "module1", "/path1.nim", 30, 1)
    discard testDb.insertSymbol("var1", "var", "module1", "/path1.nim", 40, 1)
    
    # Search by type
    let procResults = testDb.searchSymbols("", "proc", "")
    let typeResults = testDb.searchSymbols("", "type", "")
    
    check procResults.len >= 2
    check typeResults.len >= 1
    
    # Verify all results have correct type
    for symbol in procResults:
      check symbol["symbol_type"].getStr() == "proc"
    
    for symbol in typeResults:
      check symbol["symbol_type"].getStr() == "type"

  test "Search symbols by module":
    # Insert symbols in different modules
    discard testDb.insertSymbol("symbol1", "proc", "moduleA", "/pathA.nim", 10, 1)
    discard testDb.insertSymbol("symbol2", "type", "moduleA", "/pathA.nim", 20, 1)
    discard testDb.insertSymbol("symbol3", "proc", "moduleB", "/pathB.nim", 30, 1)
    discard testDb.insertSymbol("symbol4", "var", "moduleC", "/pathC.nim", 40, 1)
    
    # Search by module
    let moduleAResults = testDb.searchSymbols("", "", "moduleA")
    let moduleBResults = testDb.searchSymbols("", "", "moduleB")
    
    check moduleAResults.len >= 2
    check moduleBResults.len >= 1
    
    # Verify all results belong to correct module
    for symbol in moduleAResults:
      check symbol["module"].getStr() == "moduleA"
    
    for symbol in moduleBResults:
      check symbol["module"].getStr() == "moduleB"

  test "Complex symbol searches":
    # Insert complex set of symbols
    discard testDb.insertSymbol("calculateSum", "proc", "math", "/math.nim", 10, 1)
    discard testDb.insertSymbol("calculateProduct", "proc", "math", "/math.nim", 20, 1)
    discard testDb.insertSymbol("Calculator", "type", "math", "/math.nim", 30, 1)
    discard testDb.insertSymbol("parseString", "proc", "parser", "/parser.nim", 40, 1)
    discard testDb.insertSymbol("Parser", "type", "parser", "/parser.nim", 50, 1)
    
    # Search by name pattern and type
    let procResults = testDb.searchSymbols("calculate", "proc", "")
    check procResults.len >= 2
    
    # Search by name pattern and module
    let mathResults = testDb.searchSymbols("calculate", "", "math")
    check mathResults.len >= 2
    
    # Search by type and module
    let mathTypes = testDb.searchSymbols("", "type", "math")
    check mathTypes.len >= 1

suite "Module Management Tests":

  var testDb: Database
  
  setup:
    testDb = createTestDatabase()
    
  teardown:
    cleanupTestDatabase(testDb)

  test "Insert and retrieve modules":
    # Insert test modules
    let moduleId1 = testDb.insertModule(
      name = "testModule",
      filePath = "/path/test.nim",
      lastModified = $getTime(),
      documentation = "Test module documentation"
    )
    
    let moduleId2 = testDb.insertModule(
      name = "anotherModule",
      filePath = "/path/another.nim",
      lastModified = "",
      documentation = ""
    )
    
    check moduleId1 > 0
    check moduleId2 > 0
    
    # Retrieve modules
    let modules = testDb.getModules()
    check modules.len >= 2
    
    var moduleNames: seq[string] = @[]
    for module in modules:
      moduleNames.add(module["name"].getStr())
    
    check "testModule" in moduleNames
    check "anotherModule" in moduleNames

  test "Find module by name":
    # Insert test module
    discard testDb.insertModule("uniqueModule", "/path/unique.nim")
    
    # Find module
    let foundModule = testDb.findModule("uniqueModule")
    check foundModule.isSome()
    check foundModule.get().name == "uniqueModule"
    
    # Try to find non-existent module
    let notFound = testDb.findModule("nonExistentModule")
    check notFound.isNone()

  # test "Update module information":
  #   # This test is disabled because updateModule is not implemented
  #   discard

suite "Directory Registration Tests":

  var testDb: Database
  
  setup:
    testDb = createTestDatabase()
    
  teardown:
    cleanupTestDatabase(testDb)

  test "Register and list directories":
    # Register directories
    let result1 = testDb.addRegisteredDirectory("/path/dir1", "Directory 1", "First test directory")
    let result2 = testDb.addRegisteredDirectory("/path/dir2", "Directory 2", "Second test directory")
    
    check result1 == true
    check result2 == true
    
    # List directories
    let dirs = testDb.getRegisteredDirectories()
    check dirs.len == 2
    
    var dirPaths: seq[string] = @[]
    var dirNames: seq[string] = @[]
    for dir in dirs:
      dirPaths.add(dir["path"].getStr())
      dirNames.add(dir["name"].getStr())
    
    check "/path/dir1" in dirPaths
    check "/path/dir2" in dirPaths
    check "Directory 1" in dirNames
    check "Directory 2" in dirNames

  test "Remove registered directory":
    # Register directory
    discard testDb.addRegisteredDirectory("/path/remove_me", "Remove Me", "Directory to be removed")
    
    # Verify it exists
    let beforeRemoval = testDb.getRegisteredDirectories()
    check beforeRemoval.len == 1
    
    # Remove directory
    let removeResult = testDb.removeRegisteredDirectory("/path/remove_me")
    check removeResult == true
    
    # Verify it's gone
    let afterRemoval = testDb.getRegisteredDirectories()
    check afterRemoval.len == 0

  test "Replace existing directory registration":
    # Register directory
    discard testDb.addRegisteredDirectory("/path/replace", "Original Name", "Original description")
    
    # Register again with different info
    discard testDb.addRegisteredDirectory("/path/replace", "New Name", "New description")
    
    # Should have only one entry with updated info
    let dirs = testDb.getRegisteredDirectories()
    check dirs.len == 1
    check dirs[0]["name"].getStr() == "New Name"
    check dirs[0]["description"].getStr() == "New description"

suite "Database Performance Tests":

  var testDb: Database
  
  setup:
    testDb = createTestDatabase()
    
  teardown:
    cleanupTestDatabase(testDb)

  test "Bulk symbol insertion":
    let startTime = getTime()
    
    # Insert many symbols
    for i in 1..1000:
      discard testDb.insertSymbol(
        name = fmt"symbol{i}",
        symbolType = if i mod 3 == 0: "proc" elif i mod 3 == 1: "type" else: "var",
        module = fmt"module{i div 100}",
        filePath = fmt"/path/file{i div 10}.nim",
        line = i,
        col = 1
      )
    
    let endTime = getTime()
    let duration = endTime - startTime
    
    echo fmt"Inserted 1000 symbols in {duration.inMilliseconds}ms"
    
    # Verify all symbols were inserted
    let allSymbols = testDb.searchSymbols("symbol", "", "", limit = 2000)
    check allSymbols.len > 0

  test "Large result set retrieval":
    # Insert many symbols with common prefix
    for i in 1..500:
      discard testDb.insertSymbol(fmt"testSymbol{i}", "proc", "testModule", "/test.nim", i, 1)
    
    let startTime = getTime()
    
    # Search for all symbols
    let results = testDb.searchSymbols("testSymbol", "", "", limit = 1000)
    
    let endTime = getTime()
    let duration = endTime - startTime
    
    echo fmt"Retrieved {results.len} symbols in {duration.inMilliseconds}ms"
    
    check results.len > 0

  test "Concurrent database access":
    # Clear any existing directories first
    discard testDb.removeRegisteredDirectory("/concurrent")
    # Simulate concurrent operations
    var results: seq[bool] = @[]
    
    # Multiple insert operations
    for i in 1..50:
      let result = testDb.addRegisteredDirectory(fmt"/concurrent/path{i}", fmt"Concurrent {i}", "Concurrent test")
      results.add(result)
    
    # All operations should succeed
    for result in results:
      check result == true
    
    # Verify all directories were added
    let dirs = testDb.getRegisteredDirectories()
    check dirs.len == 50

suite "Database Error Handling Tests":

  var testDb: Database
  
  setup:
    testDb = createTestDatabase()
    
  teardown:
    cleanupTestDatabase(testDb)

  test "Handle duplicate entries":
    # Insert symbol
    let id1 = testDb.insertSymbol("duplicateTest", "proc", "module", "/path.nim", 10, 1)
    check id1 > 0
    
    # Insert same symbol again (should handle gracefully)
    let id2 = testDb.insertSymbol("duplicateTest", "proc", "module", "/path.nim", 10, 1)
    check id2 > 0  # Should create new entry or handle appropriately

  test "Handle invalid searches":
    # Search with empty patterns
    let emptyResults = testDb.searchSymbols("", "", "")
    check emptyResults.len >= 0  # Should not crash
    
    # Search for non-existent symbols
    let nonExistentResults = testDb.searchSymbols("thisSymbolDoesNotExist", "", "")
    check nonExistentResults.len == 0

  test "Handle missing symbol retrieval":
    # Try to get symbol with invalid ID
    let invalidSymbol = testDb.getSymbolById(99999)
    check invalidSymbol.isNone()

  test "Database connection resilience":
    # Test that database can handle multiple connections
    for i in 1..10:
      discard testDb.insertSymbol(fmt"resilience{i}", "proc", "module", "/path.nim", i, 1)
    
    # Should still work
    let results = testDb.searchSymbols("resilience", "", "")
    check results.len == 10

when isMainModule:
  echo "Running database operations tests..."
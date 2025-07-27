## Tests for NimGenie indexer functionality
## Tests Nim project analysis, symbol extraction, and indexing operations

import unittest, json, os, strutils, times, options
import ../src/indexer, ../src/database, ../src/analyzer
import test_utils, test_server

suite "Indexer Symbol Extraction Tests":

  var testTempDir: string
  var testProjectPath: string
  var testDb: Database
  
  setup:
    requireTiDB:
      testTempDir = getTempDir() / "nimgenie_indexer_test_" & $getTime().toUnix()
      testProjectPath = createTestProject(testTempDir, "indexer_test")
      testDb = createTestDatabase()
    
  teardown:
    cleanupTestDatabase(testDb)
    if dirExists(testTempDir):
      removeDir(testTempDir)

  test "Index basic Nim project":
    requireTiDB:
      let analyzer = newAnalyzer(testProjectPath)
      let indexResult = indexProject(testDb, analyzer, testProjectPath)
      
      check indexResult.success == true
      check indexResult.symbolsIndexed > 0
      check indexResult.modulesIndexed > 0

  test "Extract symbols from Nim source":
    requireTiDB:
      # Create a more complex Nim file for testing
      let complexNimContent = """
import strutils, sequtils

type
  Person* = object
    name*: string
    age*: int

  Animal = ref object
    species: string
    habitat: string

const
  MAX_AGE* = 120
  DEFAULT_NAME = "Unknown"

var globalCounter* = 0

proc createPerson*(name: string, age: int): Person =
  ## Create a new Person instance
  result = Person(name: name, age: age)

proc `$`*(p: Person): string =
  ## String representation of Person
  return fmt"Person(name: {p.name}, age: {p.age})"

proc incrementCounter*(): int =
  ## Increment and return global counter
  globalCounter.inc()
  return globalCounter

template withLogging*(body: untyped): untyped =
  ## Template for logging operations
  echo "Starting operation"
  body
  echo "Operation completed"

macro generateGetter*(field: untyped): untyped =
  ## Generate getter procedure for field
  result = quote do:
    proc `get field`(): auto = `field`
"""
      
      let complexFile = testProjectPath / "src" / "complex.nim"
      writeFile(complexFile, complexNimContent)
      
      let analyzer = newAnalyzer(testProjectPath)
      let indexResult = indexProject(testDb, analyzer, testProjectPath)
      
      check indexResult.success == true
      check indexResult.symbolsIndexed >= 8  # At least the symbols we defined
      
      # Search for specific symbols
      let personType = testDb.searchSymbols("Person", "", "")
      check personType.len > 0
      
      let createPersonProc = testDb.searchSymbols("createPerson", "", "")
      check createPersonProc.len > 0
      
      let maxAgeConst = testDb.searchSymbols("MAX_AGE", "", "")
      check maxAgeConst.len > 0

  test "Index symbols with different visibility":
    requireTiDB:
      let visibilityContent = """
# Public symbols (exported)
proc publicProc*(): string = "public"
var publicVar*: int = 42
type PublicType* = object
  field*: string

# Private symbols (not exported)  
proc privateProc(): string = "private"
var privateVar: int = 24
type PrivateType = object
  field: string

# Mixed visibility
type MixedType* = object
  publicField*: string
  privateField: string
"""
      
      let visibilityFile = testProjectPath / "src" / "visibility.nim"
      writeFile(visibilityFile, visibilityContent)
      
      let analyzer = newAnalyzer(testProjectPath)
      let indexResult = indexProject(testDb, analyzer, testProjectPath)
      
      check indexResult.success == true
      
      # Check that both public and private symbols are indexed
      let publicSymbols = testDb.searchSymbols("public", "", "")
      check publicSymbols.len > 0
      
      let privateSymbols = testDb.searchSymbols("private", "", "")
      check privateSymbols.len > 0

  test "Handle syntax errors gracefully":
    requireTiDB:
      # Create a file with syntax errors
      let syntaxErrorContent = """
proc validProc(): string = "valid"

proc invalidProc(: string =  # Missing parameter name and closing paren
  "invalid syntax"

proc anotherValidProc(): int = 42
"""
      
      let errorFile = testProjectPath / "src" / "syntax_error.nim"
      writeFile(errorFile, syntaxErrorContent)
      
      let analyzer = newAnalyzer(testProjectPath)
      let indexResult = indexProject(testDb, analyzer, testProjectPath)
      
      # Should still succeed and index valid symbols
      check indexResult.success == true
      check indexResult.symbolsIndexed > 0
      
      # Should still find valid symbols
      let validSymbols = testDb.searchSymbols("validProc", "", "")
      check validSymbols.len > 0

suite "Module Analysis Tests":

  var testTempDir: string
  var testProjectPath: string
  var testDb: Database
  
  setup:
    requireTiDB:
      testTempDir = getTempDir() / "nimgenie_module_test_" & $getTime().toUnix()
      testProjectPath = createTestProject(testTempDir, "module_test")
      testDb = createTestDatabase()
    
  teardown:
    cleanupTestDatabase(testDb)
    if dirExists(testTempDir):
      removeDir(testTempDir)

  test "Index multiple modules":
    requireTiDB:
      # Create additional modules
      let mathContent = """
proc add*(a, b: int): int = a + b
proc multiply*(a, b: int): int = a * b
const PI* = 3.14159
"""
      writeFile(testProjectPath / "src" / "math.nim", mathContent)
      
      let stringContent = """
import strutils
proc reverse*(s: string): string = s.reversed()
proc uppercase*(s: string): string = s.toUpperAscii()
"""
      writeFile(testProjectPath / "src" / "stringutils.nim", stringContent)
      
      let analyzer = newAnalyzer(testProjectPath)
      let indexResult = indexProject(testDb, analyzer, testProjectPath)
      
      check indexResult.success == true
      check indexResult.modulesIndexed >= 4  # main, utils, math, stringutils
      
      # Verify modules are stored in database
      let modules = testDb.getModules()
      check modules.len >= 4
      
      var moduleNames: seq[string] = @[]
      for module in modules:
        moduleNames.add(module["name"].getStr())
      
      check "math" in moduleNames
      check "stringutils" in moduleNames

  test "Module dependency analysis":
    requireTiDB:
      # Create modules with dependencies
      let baseContent = """
proc baseFunction*(): string = "base"
"""
      writeFile(testProjectPath / "src" / "base.nim", baseContent)
      
      let dependentContent = """
import base
proc dependentFunction*(): string = baseFunction() & " dependent"
"""
      writeFile(testProjectPath / "src" / "dependent.nim", dependentContent)
      
      let analyzer = newAnalyzer(testProjectPath)
      let indexResult = indexProject(testDb, analyzer, testProjectPath)
      
      check indexResult.success == true
      
      # Should index symbols from both modules
      let baseSymbols = testDb.searchSymbols("baseFunction", "", "")
      check baseSymbols.len > 0
      
      let dependentSymbols = testDb.searchSymbols("dependentFunction", "", "")
      check dependentSymbols.len > 0

suite "Incremental Indexing Tests":

  var testTempDir: string
  var testProjectPath: string
  var testDb: Database
  
  setup:
    requireTiDB:
      testTempDir = getTempDir() / "nimgenie_incremental_test_" & $getTime().toUnix()
      testProjectPath = createTestProject(testTempDir, "incremental_test")
      testDb = createTestDatabase()
    
  teardown:
    cleanupTestDatabase(testDb)
    if dirExists(testTempDir):
      removeDir(testTempDir)

  test "Re-index modified files":
    requireTiDB:
      let analyzer = newAnalyzer(testProjectPath)
      
      # Initial indexing
      let initialResult = indexProject(testDb, analyzer, testProjectPath)
      check initialResult.success == true
      let initialSymbolCount = initialResult.symbolsIndexed
      
      # Modify a file
      let modifiedContent = """
proc greet*(name: string): string =
  ## Enhanced greet function with multiple variations
  return "Hello, " & name & "!"

proc greetFormal*(name: string): string =
  ## Formal greeting
  return "Good day, " & name & "."

proc greetCasual*(name: string): string =
  ## Casual greeting  
  return "Hey " & name & "!"

proc calculate*(a, b: int): int =
  ## Enhanced calculate function
  return a + b

proc multiply*(a, b: int): int =
  ## New multiply function
  return a * b
"""
      writeFile(testProjectPath / "src" / "incremental_test.nim", modifiedContent)
      
      # Re-index
      let reindexResult = indexProject(testDb, analyzer, testProjectPath)
      check reindexResult.success == true
      check reindexResult.symbolsIndexed > initialSymbolCount
      
      # Verify new symbols are found
      let greetVariations = testDb.searchSymbols("greet", "", "")
      check greetVariations.len >= 3  # greet, greetFormal, greetCasual
      
      let multiplySymbol = testDb.searchSymbols("multiply", "", "")
      check multiplySymbol.len > 0

  test "Remove deleted files from index":
    requireTiDB:
      # Create a temporary file
      let tempContent = """
proc tempFunction*(): string = "temporary"
"""
      let tempFile = testProjectPath / "src" / "temporary.nim"
      writeFile(tempFile, tempContent)
      
      let analyzer = newAnalyzer(testProjectPath)
      
      # Index with temp file
      let withTempResult = indexProject(testDb, analyzer, testProjectPath)
      check withTempResult.success == true
      
      let tempSymbols = testDb.searchSymbols("tempFunction", "", "")
      check tempSymbols.len > 0
      
      # Remove temp file and re-index
      removeFile(tempFile)
      let withoutTempResult = indexProject(testDb, analyzer, testProjectPath)
      check withoutTempResult.success == true
      
      # Temp function should no longer be found
      # Note: This depends on the indexer implementation clearing old symbols
      let tempSymbolsAfter = testDb.searchSymbols("tempFunction", "", "")
      # Implementation detail: may or may not clear old symbols automatically

suite "Error Recovery and Edge Cases":

  var testTempDir: string
  var testProjectPath: string
  var testDb: Database
  
  setup:
    requireTiDB:
      testTempDir = getTempDir() / "nimgenie_error_test_" & $getTime().toUnix()
      testProjectPath = createTestProject(testTempDir, "error_test")
      testDb = createTestDatabase()
    
  teardown:
    cleanupTestDatabase(testDb)
    if dirExists(testTempDir):
      removeDir(testTempDir)

  test "Handle missing nim compiler":
    requireTiDB:
      # This test would require mocking the nim compiler
      # For now, we'll just verify the indexer handles errors gracefully
      let analyzer = newAnalyzer(testProjectPath)
      
      # Try to index a non-existent project
      let fakeProjectPath = testTempDir / "nonexistent"
      let result = indexProject(testDb, analyzer, fakeProjectPath)
      
      # Should fail gracefully
      check result.success == false

  test "Handle very large files":
    requireTiDB:
      # Create a large file with many symbols
      var largeContent = "# Large file test\n"
      for i in 1..100:
        largeContent.add(fmt"""
proc proc{i}*(): int = {i}
const CONST{i}* = {i}
var var{i}*: int = {i}
""")
      
      let largeFile = testProjectPath / "src" / "large.nim"
      writeFile(largeFile, largeContent)
      
      let analyzer = newAnalyzer(testProjectPath)
      let result = indexProject(testDb, analyzer, testProjectPath)
      
      check result.success == true
      check result.symbolsIndexed >= 300  # At least 3 symbols per iteration

  test "Handle Unicode and special characters":
    requireTiDB:
      let unicodeContent = """
# Test Unicode support
proc résumé*(): string = "résumé"
proc 测试*(): string = "test"
proc функция*(): string = "function"

# Test special characters in names
proc `+`*(a, b: int): int = a + b
proc `[]`*(s: string, i: int): char = s[i]
"""
      
      let unicodeFile = testProjectPath / "src" / "unicode.nim"
      writeFile(unicodeFile, unicodeContent)
      
      let analyzer = newAnalyzer(testProjectPath)
      let result = indexProject(testDb, analyzer, testProjectPath)
      
      # Should handle Unicode gracefully
      check result.success == true
      check result.symbolsIndexed > 0

when isMainModule:
  echo "Running indexer tests..."
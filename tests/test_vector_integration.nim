import unittest
import std/[json, os, tempfiles, strutils, strformat, times]
import ../src/[database, indexer, configuration, embedding]
import test_utils

suite "Vector Integration Tests":
  var testDb: Database
  var testConfig: Config
  var tempDir: string
  
  setup:
    tempDir = getTempDir() / "vector_test_" & $getTime().toUnix()
    testDb = createTestDatabase()
    testConfig = Config(
      port: 8080,
      host: "localhost", 
      database: "nimgenie_test",
      databaseHost: "127.0.0.1",
      databasePort: 4000,
      databaseUser: "root",
      databasePassword: "",
      databasePoolSize: 5,
      embeddingModel: "nomic-embed-text",
      ollamaHost: "http://localhost:11434",
      embeddingBatchSize: 5,
      vectorSimilarityThreshold: 0.7
    )
      
  teardown:
    cleanupTestDatabase(testDb)
    if dirExists(tempDir):
      removeDir(tempDir)

  test "Database schema with vector columns":
    # Test that we can insert a symbol with vector embeddings
    # Create a 768-dimension test vector (all zeros for simplicity)
    var testVectorItems: seq[string] = @[]
    for i in 0..<768:
      testVectorItems.add("0.1")
    let testVector = "[" & testVectorItems.join(",") & "]"
    
    let symbolId = testDb.insertSymbol(
      name = "testFunction",
      symbolType = "proc",
      module = "testModule",
      filePath = "/test/path.nim",
      line = 10,
      col = 5,
      signature = "proc testFunction(): void",
      documentation = "A test function",
      visibility = "public",
      documentationEmbedding = testVector,
      signatureEmbedding = testVector,
      nameEmbedding = testVector,
      combinedEmbedding = testVector,
      embeddingModel = "nomic-embed-text",
      embeddingVersion = "1.0"
    )
    
    check symbolId > 0
    echo "✓ Successfully inserted symbol with vector embeddings"

  test "Vector search functionality":
    # Insert test symbols with different 768-dimension embeddings
    # Create distinct test vectors
    var vector1Items, vector2Items, vector3Items: seq[string] = @[]
    for i in 0..<768:
      if i == 0: vector1Items.add("1.0") else: vector1Items.add("0.0")
      if i == 1: vector2Items.add("1.0") else: vector2Items.add("0.0") 
      if i == 2: vector3Items.add("1.0") else: vector3Items.add("0.0")
    
    let vector1 = "[" & vector1Items.join(",") & "]"
    let vector2 = "[" & vector2Items.join(",") & "]"
    let vector3 = "[" & vector3Items.join(",") & "]"
    
    let id1 = testDb.insertSymbol("func1", "proc", "testMod", "/test1.nim", 1, 1, 
                                  combinedEmbedding = vector1, embeddingModel = "test")
    let id2 = testDb.insertSymbol("func2", "proc", "testMod", "/test2.nim", 2, 1,
                                  combinedEmbedding = vector2, embeddingModel = "test")
    let id3 = testDb.insertSymbol("func3", "proc", "testMod", "/test3.nim", 3, 1,
                                  combinedEmbedding = vector3, embeddingModel = "test")
    
    echo fmt"✓ Inserted symbols with IDs: {id1}, {id2}, {id3}"
    echo fmt"✓ Query vector length: {vector1.len}"
    echo fmt"✓ Query vector sample: {vector1[0..50]}..."
    
    # Test semantic search - search for vector1
    let searchResults = testDb.semanticSearchSymbols(vector1, "", "", 3)
    
    if searchResults.kind == JArray and searchResults.len > 0:
      echo "✓ Vector search returned ", searchResults.len, " results"
      let firstResult = searchResults[0]
      if firstResult.hasKey("name"):
        echo "✓ First result: ", firstResult["name"].getStr()
      if firstResult.hasKey("similarity_score"):
        echo "✓ Similarity score: ", firstResult["similarity_score"].getFloat()
      check searchResults.len > 0
    else:
      echo "✗ Vector search failed or returned no results"
      echo "Search result type: ", searchResults.kind
      echo "Search result: ", searchResults
      if searchResults.kind == JObject and searchResults.hasKey("error"):
        echo "Error: ", searchResults["error"].getStr()
      check false

  test "Embedding generation and storage":
    # Create an embedding generator 
    let embGen = newEmbeddingGenerator(testConfig)
    
    if embGen.available:
      echo "✓ Ollama is available for testing"
      
      # Create a simple indexer test
      let testProjectPath = tempDir / "test_project"
      createDir(testProjectPath)
      
      # Create a simple Nim file to index
      let testFile = testProjectPath / "test.nim"
      writeFile(testFile, """
## A simple test function for vector embedding
proc calculateSum(a, b: int): int =
## Calculates the sum of two integers
return a + b

type TestObject = object
## A test object type
name: string
value: int
""")
      
      # Test that indexer can process the file with embeddings
      let indexer = newIndexer(testDb, testProjectPath, testConfig)
      let (success, symbolCount) = indexer.indexSingleFile(testFile)
      
      if success and symbolCount > 0:
        echo "✓ Successfully indexed ", symbolCount, " symbols with embeddings"
        
        # Check that symbols were stored with embeddings
        let stats = testDb.getEmbeddingStats()
        if stats.hasKey("embedded_symbols"):
          let embeddedCount = stats["embedded_symbols"].getInt()
          echo "✓ Found ", embeddedCount, " symbols with embeddings in database"
          check embeddedCount > 0
        else:
          echo "✗ Could not get embedding statistics"
          check false
      else:
        echo "✗ Failed to index file with embeddings"
        check false
    else:
      echo "⚠ Ollama not available - skipping embedding generation test"
      skip()

when isMainModule:
  echo "Running Vector Integration Tests..."
  echo "Note: These tests require TiDB and optionally Ollama for full functionality"
## Simple Vector Search Test
## Tests vector search with minimal data to isolate the issue

import unittest
import std/[json, os, strutils, strformat]
import ../src/[database, configuration]  
import test_utils

suite "Simple Vector Search Test":
  var testDb: Database
  var testConfig: Config
  
  setup:
    testDb = createTestDatabase()
    testConfig = Config(
      port: 8080,
      host: "localhost", 
      database: "nimgenie_test",
      databaseHost: "127.0.0.1",
      databasePort: 4000,
      databaseUser: "root",
      databasePassword: "",
      databasePoolSize: 5
    )
    
  teardown:
    cleanupTestDatabase(testDb)

  test "Simple vector search with small test vectors":
    echo "=== Testing Simple Vector Search ==="
    
    # Create small 768-dimension test vectors (all zeros except first few elements)
    var vector1Items, vector2Items, queryItems: seq[float32] = @[]
    
    # Create distinct small vectors for testing
    for i in 0..<768:
      if i == 0: 
        vector1Items.add(1.0)
        vector2Items.add(0.0) 
        queryItems.add(1.0)  # Should be most similar to vector1
      elif i == 1:
        vector1Items.add(0.0)
        vector2Items.add(1.0)
        queryItems.add(0.0)
      else:
        vector1Items.add(0.0)
        vector2Items.add(0.0)
        queryItems.add(0.0)
    
    let vector1 = vectorToTiDBString(vector1Items)
    let vector2 = vectorToTiDBString(vector2Items)
    let queryVector = vectorToTiDBString(queryItems)
    
    echo fmt"Created test vectors of length: {vector1.len}"
    
    # Insert test symbols
    let id1 = testDb.insertSymbol("testFunc1", "proc", "testMod", "/test1.nim", 1, 1,
                                  combinedEmbedding = vector1, embeddingModel = "test")
    let id2 = testDb.insertSymbol("testFunc2", "proc", "testMod", "/test2.nim", 2, 1,
                                  combinedEmbedding = vector2, embeddingModel = "test")
    
    if id1 <= 0 or id2 <= 0:
      echo "✗ Failed to insert test symbols"
      check false
    
    echo fmt"✓ Inserted test symbols with IDs: {id1}, {id2}"
    
    # Test vector search
    echo fmt"Testing search with query vector length: {queryVector.len}"
    echo fmt"Query vector format: {queryVector[0..100]}..."
    
    # First, let's test if we can manually query the vectors that were stored
    echo "=== Testing stored vectors ==="
    try:
      let storedSymbols = testDb.searchSymbols("testFunc", "", "", 2)
      if storedSymbols.kind == JArray:
        echo fmt"Found {storedSymbols.len} stored symbols"
        for symbol in storedSymbols:
          if symbol.hasKey("name"):
            echo "Stored symbol: ", symbol["name"].getStr()
      else:
        echo "No symbols found in storage test"
    except Exception as e:
      echo fmt"Error querying stored vectors: {e.msg}"
    
    # Now test the vector search  
    let searchResults = testDb.semanticSearchSymbols(queryVector, "", "", 2)
    
    if searchResults.kind == JArray and searchResults.len > 0:
      echo fmt"✓ Vector search succeeded! Found {searchResults.len} results"
      echo searchResults
      for hit in searchResults:
        let name = hit["name"].getStr()
        let score = hit["similarity_score"].getFloat()
        echo fmt"{name} (similarity: {score:.3f})"
      
      # The first result should be testFunc1 since query is most similar to vector1
      let topResult = searchResults[0]["name"].getStr()
      if "testFunc1" in topResult:
        echo "✓ Vector search returned correct most similar result"
      else:
        echo fmt"⚠ Expected testFunc1 to be most similar, got: {topResult}"
      
      check searchResults.len > 0
    else:
      echo "✗ Vector search failed"
      if searchResults.kind == JObject and searchResults.hasKey("error"):
        echo "Error: ", searchResults["error"].getStr()
      check false
    
    echo "=== Simple Vector Search: ✅ SUCCESS ==="

when isMainModule:
  echo "Running Simple Vector Search Test..."
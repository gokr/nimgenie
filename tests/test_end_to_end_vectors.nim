## End-to-End Vector Embedding Test
## Tests the complete workflow: Ollama → TiDB vectors → Search
## This is a focused test to verify the vector system works properly

import unittest
import std/[json, os, strutils, strformat, times]
import ../src/[database, embedding, configuration]
import test_utils

suite "End-to-End Vector Workflow":
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
      databasePoolSize: 5,
      embeddingModel: "nomic-embed-text",
      ollamaHost: "http://localhost:11434",
      embeddingBatchSize: 5,
      vectorSimilarityThreshold: 0.7
    )
      
  teardown:
    cleanupTestDatabase(testDb)

  test "Complete vector workflow: Generate → Store → Search":
    echo "=== Testing Complete Vector Workflow ==="
    
    # Step 1: Test Ollama connection and embedding generation
    echo "Step 1: Testing Ollama embedding generation..."
    let embGen = newEmbeddingGenerator(testConfig)
    
    if not embGen.available:
      echo "⚠ Ollama not available - skipping end-to-end test"
      skip()
    
    echo "✓ Ollama is available"
    
    # Step 2: Generate embeddings for test data
    echo "Step 2: Generating embeddings for test symbols..."
    let testSymbols = [
      ("parseConfig", "proc parseConfig(filename: string): Config", "Parse configuration from file"),
      ("saveData", "proc saveData(data: JsonNode, path: string)", "Save JSON data to file"),
      ("calculateSum", "proc calculateSum(a, b: int): int", "Calculate sum of two integers")
    ]
    
    var embeddings: seq[tuple[name: string, embedding: TidbVector]] = @[]
    
    for (name, signature, doc) in testSymbols:
      let result = embGen.generateCombinedEmbedding(name, signature, doc)
      if result.success:
        let vector = toTidbVector(result.embedding)
        embeddings.add((name, vector))
        echo fmt"✓ Generated embedding for {name} ({result.embedding.len} dimensions)"
      else:
        echo fmt"✗ Failed to generate embedding for {name}: {result.error}"
        check false
    
    check embeddings.len == 3
    echo fmt"✓ Generated {embeddings.len} embeddings successfully"
    
    # Step 3: Store symbols with embeddings in TiDB
    echo "Step 3: Storing symbols with embeddings in TiDB..."
    var symbolIds: seq[int] = @[]
    
    for i, (name, embedding) in embeddings:
      let (_, signature, doc) = testSymbols[i]
      let symbolId = testDb.insertSymbol(
        name = name,
        symbolType = "proc",
        module = "testModule",
        filePath = "/test/path.nim",
        line = i + 1,
        col = 1,
        signature = signature,
        documentation = doc,
        visibility = "public",
        combinedEmbedding = embedding,
        embeddingModel = "nomic-embed-text",
        embeddingVersion = "1.0"
      )
      
      if symbolId > 0:
        symbolIds.add(symbolId)
        echo fmt"✓ Stored symbol '{name}' with ID {symbolId}"
      else:
        echo fmt"✗ Failed to store symbol '{name}'"
        check false
    
    check symbolIds.len == 3
    echo fmt"✓ Stored {symbolIds.len} symbols with embeddings"
    
    # Step 4: Test vector similarity search
    echo "Step 4: Testing vector similarity search..."
    
    # Generate a query embedding for "configuration parsing"
    let queryResult = embGen.generateEmbedding("configuration file parsing functions")
    if not queryResult.success:
      echo fmt"✗ Failed to generate query embedding: {queryResult.error}"
      check false
    
    let queryVector = toTidbVector(queryResult.embedding)
    echo fmt"✓ Generated query embedding ({queryResult.embedding.len} dimensions)"
    
    # Perform semantic search
    let searchResults = testDb.semanticSearchSymbols(queryVector, "", "", 3)
    
    if searchResults.kind == JArray and searchResults.len > 0:
      echo fmt"✓ Vector search returned {searchResults.len} results"
      
      # Check that results are properly formatted
      let firstResult = searchResults[0]
      if firstResult.hasKey("name") and firstResult.hasKey("similarity_score"):
        let name = firstResult["name"].getStr()
        let score = firstResult["similarity_score"].getFloat()
        echo fmt"✓ Top result: '{name}' with similarity {score:.3f}"
        
        # The "parseConfig" function should be most similar to "configuration file parsing"
        if "parseConfig" in name or "config" in name.toLowerAscii():
          echo "✓ Semantic search correctly identified configuration-related function"
        else:
          echo fmt"⚠ Expected configuration-related function, got: {name}"
        
        check searchResults.len > 0
        check score >= 0.0 and score <= 1.0
      else:
        echo "✗ Search results missing required fields"
        check false
    else:
      echo "✗ Vector search failed or returned no results"
      if searchResults.kind == JObject and searchResults.hasKey("error"):
        echo "Error: ", searchResults["error"].getStr()
      echo fmt"Search results: {searchResults}"
      check false
    
    echo "=== End-to-End Vector Workflow: ✅ SUCCESS ==="

when isMainModule:
  echo "Running End-to-End Vector Integration Test..."
  echo "This test requires:"
  echo "  1. TiDB running (tiup playground)"
  echo "  2. Ollama running with nomic-embed-text model"
  echo ""
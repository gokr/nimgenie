## Tests for TiDB native vector operations in NimGenie
## Tests vector storage, retrieval, and semantic search functionality

import unittest, json, times, options, strformat
import ../src/database
import ../src/embedding
import test_utils

suite "Vector Storage and Retrieval Tests":

  var testDb: Database
  var embeddingGen: EmbeddingGenerator
  
  setup:
    testDb = createTestDatabase()
      embeddingGen = newEmbeddingGenerator(getTestConfig("nimgenie_test"))
      # Ensure we have a test embedding model available
      discard embeddingGen.ensureModel(embeddingGen.config.embeddingModel)
  
  teardown:
    cleanupTestDatabase(testDb)

  test "Store and retrieve vector embeddings":
    # Generate a test embedding
      let embeddingResult = embeddingGen.generateEmbedding("test function for calculations")
      check embeddingResult.success == true
      check embeddingResult.embedding.len > 0
      
      # Convert to JSON string for storage
      let embeddingJson = embeddingToJson(embeddingResult.embedding)
      
      # Insert symbol with embeddings
      let symbolId = testDb.insertSymbol(
        name = "testFunction",
        symbolType = "proc",
        module = "testModule",
        filePath = "/path/test.nim",
        line = 10,
        col = 5,
        signature = "proc testFunction(): string",
        documentation = "A test function"
      )
      
      check symbolId > 0
      
      # Update embeddings
      let success = testDb.updateSymbolEmbeddings(
        symbolId,
        embeddingJson,  # docEmb
        embeddingJson,  # sigEmb
        embeddingJson,  # nameEmb
        embeddingJson,  # combinedEmb
        embeddingGen.config.embeddingModel,
        "1.0"
      )
      
      check success == true
      
      # Verify the symbol has embeddings in both JSON and native vector format
      let symbolOpt = testDb.getSymbolById(symbolId)
      check symbolOpt.isSome()
      
      let symbol = symbolOpt.get()
      check symbol.documentationEmbedding.len > 0
      check symbol.documentationEmbeddingVec.len > 0
      check symbol.signatureEmbedding.len > 0
      check symbol.signatureEmbeddingVec.len > 0
      check symbol.nameEmbedding.len > 0
      check symbol.nameEmbeddingVec.len > 0
      check symbol.combinedEmbedding.len > 0
      check symbol.combinedEmbeddingVec.len > 0

  test "Semantic search with native vectors":
    # Generate embeddings for test symbols
      let embedding1 = embeddingGen.generateEmbedding("file upload handler")
      let embedding2 = embeddingGen.generateEmbedding("image processing function")
      let embedding3 = embeddingGen.generateEmbedding("database query function")
      
      check embedding1.success == true
      check embedding2.success == true
      check embedding3.success == true
      
      # Insert test symbols with embeddings
      let id1 = testDb.insertSymbol("uploadFile", "proc", "fileModule", "/file.nim", 10, 1)
      let id2 = testDb.insertSymbol("processImage", "proc", "imageModule", "/image.nim", 20, 1)
      let id3 = testDb.insertSymbol("queryDatabase", "proc", "dbModule", "/db.nim", 30, 1)
      
      check id1 > 0
      check id2 > 0
      check id3 > 0
      
      # Update embeddings
      discard testDb.updateSymbolEmbeddings(id1, "", "", "", embeddingToJson(embedding1.embedding), embeddingGen.config.embeddingModel, "1.0")
      discard testDb.updateSymbolEmbeddings(id2, "", "", "", embeddingToJson(embedding2.embedding), embeddingGen.config.embeddingModel, "1.0")
      discard testDb.updateSymbolEmbeddings(id3, "", "", "", embeddingToJson(embedding3.embedding), embeddingGen.config.embeddingModel, "1.0")
      
      # Generate query embedding for "file operations"
      let queryEmbedding = embeddingGen.generateEmbedding("file operations")
      check queryEmbedding.success == true
      
      # Perform semantic search
      let queryEmbeddingJson = embeddingToJson(queryEmbedding.embedding)
      let results = testDb.semanticSearchSymbols(queryEmbeddingJson, "", "", limit = 10)
      
      check results.len > 0
      
      # Verify results have similarity scores
      for result in results:
        check result.hasKey("similarity_score")
        let score = result["similarity_score"].getFloat()
        check score >= 0.0 and score <= 1.0
        check result.hasKey("distance")
        let distance = result["distance"].getFloat()
        check distance >= 0.0 and distance <= 2.0

  test "Find similar symbols with native vectors":
    # Generate embeddings for test symbols
      let embedding1 = embeddingGen.generateEmbedding("HTTP request handler")
      let embedding2 = embeddingGen.generateEmbedding("API endpoint function")
      let embedding3 = embeddingGen.generateEmbedding("database connection")
      
      check embedding1.success == true
      check embedding2.success == true
      check embedding3.success == true
      
      # Insert test symbols with embeddings
      let id1 = testDb.insertSymbol("handleRequest", "proc", "httpModule", "/http.nim", 10, 1)
      let id2 = testDb.insertSymbol("processRequest", "proc", "apiModule", "/api.nim", 20, 1)
      let id3 = testDb.insertSymbol("connectDB", "proc", "dbModule", "/db.nim", 30, 1)
      
      check id1 > 0
      check id2 > 0
      check id3 > 0
      
      # Update embeddings
      discard testDb.updateSymbolEmbeddings(id1, "", "", "", embeddingToJson(embedding1.embedding), embeddingGen.config.embeddingModel, "1.0")
      discard testDb.updateSymbolEmbeddings(id2, "", "", "", embeddingToJson(embedding2.embedding), embeddingGen.config.embeddingModel, "1.0")
      discard testDb.updateSymbolEmbeddings(id3, "", "", "", embeddingToJson(embedding3.embedding), embeddingGen.config.embeddingModel, "1.0")
      
      # Find similar symbols to the first one
      let results = testDb.findSimilarByEmbedding(embeddingToJson(embedding1.embedding), excludeId = id1, limit = 10)
      
      check results.len > 0
      
      # Verify results have similarity scores
      for result in results:
        check result.hasKey("similarity_score")
        let score = result["similarity_score"].getFloat()
        check score >= 0.0 and score <= 1.0
        check result.hasKey("distance")
        let distance = result["distance"].getFloat()
        check distance >= 0.0 and distance <= 2.0

  test "Vector similarity ranking":
    # Create symbols with varying similarity to a query
      let queryEmbedding = embeddingGen.generateEmbedding("file upload processing")
      check queryEmbedding.success == true
      
      # Create a very similar symbol
      let similarEmbedding = embeddingGen.generateEmbedding("upload user files to server")
      check similarEmbedding.success == true
      
      # Create a somewhat similar symbol
      let mediumEmbedding = embeddingGen.generateEmbedding("process user data")
      check mediumEmbedding.success == true
      
      # Create a dissimilar symbol
      let dissimilarEmbedding = embeddingGen.generateEmbedding("render 3D graphics")
      check dissimilarEmbedding.success == true
      
      # Insert symbols
      let id1 = testDb.insertSymbol("uploadFiles", "proc", "fileModule", "/file.nim", 10, 1)
      let id2 = testDb.insertSymbol("processUserData", "proc", "userModule", "/user.nim", 20, 1)
      let id3 = testDb.insertSymbol("renderGraphics", "proc", "graphicsModule", "/graphics.nim", 30, 1)
      
      check id1 > 0
      check id2 > 0
      check id3 > 0
      
      # Update embeddings
      discard testDb.updateSymbolEmbeddings(id1, "", "", "", embeddingToJson(similarEmbedding.embedding), embeddingGen.config.embeddingModel, "1.0")
      discard testDb.updateSymbolEmbeddings(id2, "", "", "", embeddingToJson(mediumEmbedding.embedding), embeddingGen.config.embeddingModel, "1.0")
      discard testDb.updateSymbolEmbeddings(id3, "", "", "", embeddingToJson(dissimilarEmbedding.embedding), embeddingGen.config.embeddingModel, "1.0")
      
      # Perform semantic search
      let queryJson = embeddingToJson(queryEmbedding.embedding)
      let results = testDb.semanticSearchSymbols(queryJson, "", "", limit = 10)
      
      check results.len == 3
      
      # Verify ranking: similar should be first, then medium, then dissimilar
      let first = results[0]["name"].getStr()
      let second = results[1]["name"].getStr()
      let third = results[2]["name"].getStr()
      
      check first == "uploadFiles"
      check second == "processUserData"
      check third == "renderGraphics"
      
      # Verify similarity scores are in expected order
      let firstScore = results[0]["similarity_score"].getFloat()
      let secondScore = results[1]["similarity_score"].getFloat()
      let thirdScore = results[2]["similarity_score"].getFloat()
      
      check firstScore > secondScore
      check secondScore > thirdScore

when isMainModule:
  echo "Running vector operations tests..."
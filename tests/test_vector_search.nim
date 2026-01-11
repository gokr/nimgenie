## Comprehensive vector search and embedding tests for NimGenie
## Tests embedding generation, vector storage, retrieval, and semantic search
##
## Consolidates:
## - test_embedding.nim (embedding generation)
## - test_vector_operations.nim (vector storage/retrieval)
## - test_vector_integration.nim (integration tests)
## - test_end_to_end_vectors.nim (end-to-end workflows)
## - test_simple_vector_search.nim (simple vector tests)
##
## These tests only run when Ollama is available at http://localhost:11434

import unittest, json, os, strutils, strformat, httpclient, options
import ../src/[embedding, configuration, database]
import test_utils, test_fixtures

const OLLAMA_AVAILABLE = gorgeEx("curl -s -o /dev/null -w '%{http_code}' http://localhost:11434").output == "200"

when OLLAMA_AVAILABLE:
  echo "Ollama detected - running vector search tests"

  proc getEmbeddingConfig(): Config =
    Config(
      ollamaHost: getEnv("TEST_OLLAMA_HOST", "http://localhost:11434"),
      embeddingModel: getEnv("TEST_EMBEDDING_MODEL", "nomic-embed-text:latest"),
      embeddingBatchSize: 5,
      vectorSimilarityThreshold: 0.7,
      database: "nimgenie_test",
      databaseHost: "127.0.0.1",
      databasePort: 4000,
      databaseUser: "root",
      databasePassword: "",
      databasePoolSize: 5
    )

  suite "Embedding Generation Tests":
    let config = getEmbeddingConfig()

    test "Create embedding generator":
      let generator = newEmbeddingGenerator(config)
      check generator.config.ollamaHost == config.ollamaHost
      check generator.config.embeddingModel == config.embeddingModel
      check generator.client != nil

    test "Check Ollama health":
      let generator = newEmbeddingGenerator(config)
      let isHealthy = generator.checkOllamaHealth()
      check isHealthy == true

    test "Embedding result types":
      let successResult = EmbeddingResult(
        success: true,
        embedding: @[0.1'f32, 0.2'f32, 0.3'f32],
        error: ""
      )
      let failureResult = EmbeddingResult(
        success: false,
        embedding: @[],
        error: "Test error"
      )

      check successResult.success == true
      check successResult.embedding.len == 3
      check successResult.error == ""
      check failureResult.success == false
      check failureResult.embedding.len == 0
      check failureResult.error == "Test error"

  suite "Embedding Strategy Tests":
    let config = getEmbeddingConfig()
    let generator = newEmbeddingGenerator(config)

    test "Documentation embedding preprocessing":
      let emptyResult = generator.generateDocumentationEmbedding("")
      check emptyResult.success == false
      check emptyResult.error == "Empty documentation"

    test "Signature embedding preprocessing":
      let emptyResult = generator.generateSignatureEmbedding("")
      check emptyResult.success == false
      check emptyResult.error == "Empty signature"

    test "Name embedding with context":
      let emptyResult = generator.generateNameEmbedding("", "module")
      check emptyResult.success == false
      check emptyResult.error == "Empty name"

    test "Combined embedding composition":
      let emptyResult = generator.generateCombinedEmbedding("", "", "")
      check emptyResult.success == false

  suite "Vector Storage and Retrieval Tests":

    test "Store and retrieve vector embeddings":
      withTestFixture:
        var embeddingGen = newEmbeddingGenerator(fixture.config)
        discard embeddingGen.ensureModel(embeddingGen.config.embeddingModel)

        let embeddingResult = embeddingGen.generateEmbedding("test function for calculations")
        check embeddingResult.success == true
        check embeddingResult.embedding.len > 0

        let embeddingJson = embeddingToJson(embeddingResult.embedding)

        let symbolId = fixture.database.insertSymbol(
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

        let success = fixture.database.updateSymbolEmbeddings(
          symbolId,
          jsonToTidbVector(embeddingJson),
          jsonToTidbVector(embeddingJson),
          jsonToTidbVector(embeddingJson),
          jsonToTidbVector(embeddingJson),
          embeddingGen.config.embeddingModel,
          "1.0"
        )

        check success == true

        let symbolOpt = fixture.database.getSymbolById(symbolId)
        check symbolOpt.isSome()

        let symbol = symbolOpt.get()
        check symbol.documentationEmbedding.len > 0
        check symbol.signatureEmbedding.len > 0
        check symbol.nameEmbedding.len > 0
        check symbol.combinedEmbedding.len > 0

  suite "Semantic Search Tests":

    test "Semantic search with native vectors":
      withTestFixture:
        var embeddingGen = newEmbeddingGenerator(fixture.config)
        discard embeddingGen.ensureModel(embeddingGen.config.embeddingModel)

        let embedding1 = embeddingGen.generateEmbedding("file upload handler")
        let embedding2 = embeddingGen.generateEmbedding("image processing function")
        let embedding3 = embeddingGen.generateEmbedding("database query function")

        check embedding1.success == true
        check embedding2.success == true
        check embedding3.success == true

        let id1 = fixture.database.insertSymbol("uploadFile", "proc", "fileModule", "/file.nim", 10, 1)
        let id2 = fixture.database.insertSymbol("processImage", "proc", "imageModule", "/image.nim", 20, 1)
        let id3 = fixture.database.insertSymbol("queryDatabase", "proc", "dbModule", "/db.nim", 30, 1)

        check id1 > 0
        check id2 > 0
        check id3 > 0

        discard fixture.database.updateSymbolEmbeddings(id1, jsonToTidbVector(""), jsonToTidbVector(""), jsonToTidbVector(""), jsonToTidbVector(embeddingToJson(embedding1.embedding)), embeddingGen.config.embeddingModel, "1.0")
        discard fixture.database.updateSymbolEmbeddings(id2, jsonToTidbVector(""), jsonToTidbVector(""), jsonToTidbVector(""), jsonToTidbVector(embeddingToJson(embedding2.embedding)), embeddingGen.config.embeddingModel, "1.0")
        discard fixture.database.updateSymbolEmbeddings(id3, jsonToTidbVector(""), jsonToTidbVector(""), jsonToTidbVector(""), jsonToTidbVector(embeddingToJson(embedding3.embedding)), embeddingGen.config.embeddingModel, "1.0")

        let queryEmbedding = embeddingGen.generateEmbedding("file operations")
        check queryEmbedding.success == true

        let queryEmbeddingJson = embeddingToJson(queryEmbedding.embedding)
        let queryVector = jsonToTidbVector(queryEmbeddingJson)
        let results = fixture.database.semanticSearchSymbols(queryVector, "", "", limit = 10)

        check results.kind == JArray
        check results.len > 0

  suite "Simple Vector Search Tests":

    test "Simple vector search with small test vectors":
      withTestFixture:
        var vector1Items, vector2Items, queryItems: seq[float32] = @[]

        for i in 0..<768:
          if i == 0:
            vector1Items.add(1.0)
            vector2Items.add(0.0)
            queryItems.add(1.0)
          elif i == 1:
            vector1Items.add(0.0)
            vector2Items.add(1.0)
            queryItems.add(0.0)
          else:
            vector1Items.add(0.0)
            vector2Items.add(0.0)
            queryItems.add(0.0)

        let vector1 = toTidbVector(vector1Items)
        let vector2 = toTidbVector(vector2Items)
        let queryVector = toTidbVector(queryItems)

        let id1 = fixture.database.insertSymbol("testFunc1", "proc", "testMod", "/test1.nim", 1, 1,
                                      combinedEmbedding = vector1, embeddingModel = "test")
        let id2 = fixture.database.insertSymbol("testFunc2", "proc", "testMod", "/test2.nim", 2, 1,
                                      combinedEmbedding = vector2, embeddingModel = "test")

        check id1 > 0
        check id2 > 0

        let searchResults = fixture.database.semanticSearchSymbols(queryVector, "", "", 2)

        check searchResults.kind == JArray
        if searchResults.len > 0:
          let topResult = searchResults[0]["name"].getStr()
          check "testFunc1" in topResult

else:
  suite "Vector Search Tests - Skipped":
    test "Ollama not available":
      skip("Ollama not available at http://localhost:11434 - vector search tests disabled")

when isMainModule:
  when OLLAMA_AVAILABLE:
    echo "Running vector search tests with Ollama"
  else:
    echo "Ollama not available - vector search tests will be skipped"

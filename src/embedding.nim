import std/[json, strutils, strformat, httpclient, re]
import configuration

type
  EmbeddingGenerator* = object
    config*: Config
    client*: HttpClient
    available*: bool

  EmbeddingResult* = object
    success*: bool
    embedding*: seq[float32]
    error*: string

proc checkOllamaHealth*(generator: EmbeddingGenerator): bool =
  ## Check if Ollama server is running and accessible
  try:
    let response = generator.client.get(generator.config.ollamaHost)
    return response.code == Http200
  except Exception:
    return false

proc newEmbeddingGenerator*(config: Config): EmbeddingGenerator =
  ## Create a new embedding generator with Ollama integration
  result = EmbeddingGenerator(
    config: config,
    client: newHttpClient(),
    available: false
  )
  
  # Check if Ollama is available
  result.available = result.checkOllamaHealth()

proc ensureModel*(generator: EmbeddingGenerator, modelName: string): bool =
  ## Ensure the embedding model is available, pull if needed
  try:
    # Check if model is already available
    let listUrl = generator.config.ollamaHost & "/api/tags"
    let response = generator.client.get(listUrl)
    
    if response.code == Http200:
      let data = parseJson(response.body)
      let models = data["models"]
      
      # Check if our model is in the list
      for model in models:
        if model["name"].getStr().startsWith(modelName):
          return true
      
      # Model not found, try to pull it
      let pullUrl = generator.config.ollamaHost & "/api/pull"
      let pullData = %*{"name": modelName}
      generator.client.headers = newHttpHeaders({"Content-Type": "application/json"})
      let pullResponse = generator.client.post(pullUrl, $pullData)
      
      return pullResponse.code == Http200
    else:
      return false
      
  except Exception as e:
    echo "Error ensuring model availability: ", e.msg
    return false

proc generateEmbedding*(generator: EmbeddingGenerator, text: string, modelName: string = ""): EmbeddingResult =
  ## Generate embedding for given text using Ollama
  if not generator.available:
    return EmbeddingResult(success: false, error: "Ollama not available")
  
  let model = if modelName != "": modelName else: generator.config.embeddingModel
  
  # Ensure model is available
  if not generator.ensureModel(model):
    return EmbeddingResult(success: false, error: fmt"Model {model} not available")
  
  try:
    let url = generator.config.ollamaHost & "/api/embeddings"
    let requestData = %*{
      "model": model,
      "prompt": text
    }
    
    generator.client.headers = newHttpHeaders({"Content-Type": "application/json"})
    let response = generator.client.post(url, $requestData)
    
    if response.code == Http200:
      let data = parseJson(response.body)
      if data.hasKey("embedding"):
        let embeddingJson = data["embedding"]
        var embedding: seq[float32] = @[]
        
        for val in embeddingJson:
          embedding.add(val.getFloat().float32)
        
        return EmbeddingResult(success: true, embedding: embedding)
      else:
        return EmbeddingResult(success: false, error: "No embedding in response")
    else:
      return EmbeddingResult(success: false, error: fmt"HTTP {response.code}: {response.body}")
      
  except Exception as e:
    return EmbeddingResult(success: false, error: e.msg)

proc generateBatchEmbeddings*(generator: EmbeddingGenerator, texts: seq[string], modelName: string = ""): seq[EmbeddingResult] =
  ## Generate embeddings for multiple texts (sequential for now)
  result = @[]
  
  for text in texts:
    result.add(generator.generateEmbedding(text, modelName))

proc embeddingToJson*(embedding: seq[float32]): string =
  ## Convert embedding vector to JSON string for database storage
  let jsonArray = newJArray()
  for val in embedding:
    jsonArray.add(newJFloat(val.float))
  return $jsonArray

proc jsonToEmbedding*(jsonStr: string): seq[float32] =
  ## Convert JSON string back to embedding vector
  try:
    let jsonArray = parseJson(jsonStr)
    result = @[]
    for val in jsonArray:
      result.add(val.getFloat().float32)
  except Exception:
    result = @[]

# ============================================================================
# EMBEDDING GENERATION STRATEGIES
# ============================================================================

proc generateDocumentationEmbedding*(generator: EmbeddingGenerator, doc: string): EmbeddingResult =
  ## Generate embedding for documentation text
  if doc.strip() == "":
    return EmbeddingResult(success: false, error: "Empty documentation")
  
  # Clean up documentation - remove common doc comment artifacts
  let cleaned = doc
    .replace("##", "")
    .replace("##*", "")
    .replace("*##", "")
    .strip()
    .replace(re"\n\s*", " ")  # Normalize whitespace
  
  return generator.generateEmbedding(cleaned)

proc generateSignatureEmbedding*(generator: EmbeddingGenerator, signature: string): EmbeddingResult =
  ## Generate embedding for function/type signature
  if signature.strip() == "":
    return EmbeddingResult(success: false, error: "Empty signature")
  
  # Normalize signature - focus on structure over specific names
  let normalized = signature
    .replace(re"\s+", " ")  # Normalize whitespace
    .strip()
  
  return generator.generateEmbedding(fmt"Function signature: {normalized}")

proc generateNameEmbedding*(generator: EmbeddingGenerator, name: string, module: string): EmbeddingResult =
  ## Generate embedding for symbol name with context
  if name.strip() == "":
    return EmbeddingResult(success: false, error: "Empty name")
  
  # Convert camelCase to words and add module context
  let nameWords = name
    .replace(re"([a-z])([A-Z])", "$1 $2")  # camelCase to words
    .toLowerAscii()
  
  let contextText = fmt"Function: {nameWords} in module {module}"
  return generator.generateEmbedding(contextText)

proc generateCombinedEmbedding*(generator: EmbeddingGenerator, name: string, signature: string, documentation: string): EmbeddingResult =
  ## Generate combined embedding from all symbol information
  var parts: seq[string] = @[]
  
  if name.strip() != "":
    parts.add(fmt"Name: {name}")
  
  if signature.strip() != "":
    parts.add(fmt"Signature: {signature}")
  
  if documentation.strip() != "":
    let cleanDoc = documentation
      .replace("##", "")
      .replace("##*", "")
      .replace("*##", "")
      .strip()
    if cleanDoc != "":
      parts.add(fmt"Description: {cleanDoc}")
  
  if parts.len == 0:
    return EmbeddingResult(success: false, error: "No content to embed")
  
  let combinedText = parts.join(". ")
  return generator.generateEmbedding(combinedText)

proc close*(generator: EmbeddingGenerator) =
  ## Close the HTTP client
  if generator.client != nil:
    generator.client.close()
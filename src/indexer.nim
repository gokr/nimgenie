import std/[json, os, strutils, strformat, times, options]
import database
import analyzer
import embedding
import configuration

type
  Indexer* = object
    database*: Database
    analyzer*: Analyzer
    projectPath*: string
    embeddingGenerator*: EmbeddingGenerator
    config*: Config

proc newIndexer*(database: Database, projectPath: string, config: Config): Indexer =
  ## Create a new indexer for the given project
  result.database = database
  result.projectPath = projectPath
  result.analyzer = newAnalyzer(projectPath)
  result.config = config
  result.embeddingGenerator = newEmbeddingGenerator(config)

proc findNimFiles*(indexer: Indexer, directory: string = ""): seq[string] =
  ## Find all .nim files in the project directory
  let searchDir = if directory == "": indexer.projectPath else: directory
  result = @[]
  
  try:
    for kind, path in walkDir(searchDir):
      case kind:
      of pcFile:
        if path.endsWith(".nim"):
          result.add(path)
      of pcDir:
        # Recursively search subdirectories, but skip common build/cache dirs
        let dirName = extractFilename(path)
        if dirName notin ["nimcache", ".git", "htmldocs", "docs"]:
          result.add(indexer.findNimFiles(path))
      else:
        discard
  except OSError as e:
    echo fmt"Error walking directory {searchDir}: {e.msg}"

proc parseNimDocJson*(indexer: Indexer, jsonOutput: string): int =
  ## Parse nim jsondoc output and store symbols in database
  result = 0
  
  try:
    let docJson = parseJson(jsonOutput)
    
    if not docJson.hasKey("entries"):
      echo "No entries found in nim jsondoc output"
      return 0
    
    # Extract module name from the file path since nim jsondoc doesn't provide module field
    let filePath = if docJson.hasKey("orig"): docJson["orig"].getStr() else: ""
    let moduleName = if filePath != "": extractFilename(filePath).replace(".nim", "") else: "unknown"
    
    # Store the module in the database
    if filePath != "" and moduleName != "unknown":
      let moduleDoc = if docJson.hasKey("moduleDescription"): docJson["moduleDescription"].getStr() else: ""
      discard indexer.database.insertModule(moduleName, filePath, "", moduleDoc)
    
    for entry in docJson["entries"]:
      if not entry.hasKey("name") or not entry.hasKey("type"):
        continue
        
      let name = entry["name"].getStr()
      let symbolType = entry["type"].getStr()
      let line = if entry.hasKey("line"): entry["line"].getInt() else: 0
      let column = if entry.hasKey("column"): entry["column"].getInt() else: 0
      let signature = if entry.hasKey("signature"): entry["signature"].getStr() else: ""
      let documentation = if entry.hasKey("description"): entry["description"].getStr() else: ""
      
      # Determine file path - try to get from entry or use module info
      var filePath = ""
      if entry.hasKey("file"):
        filePath = entry["file"].getStr()
      elif docJson.hasKey("file"):
        filePath = docJson["file"].getStr()
      else:
        filePath = moduleName & ".nim"
      
      # Make file path absolute
      if not isAbsolute(filePath):
        filePath = indexer.projectPath / filePath
      
      # Generate embeddings for the symbol if embedding generator is available
      var docEmb, sigEmb, nameEmb, combinedEmb = ""
      var embeddingModel, embeddingVersion = ""
      
      if indexer.embeddingGenerator.available:
        # Generate embeddings
        let docEmbResult = indexer.embeddingGenerator.generateDocumentationEmbedding(documentation)
        let sigEmbResult = indexer.embeddingGenerator.generateSignatureEmbedding(signature)
        let nameEmbResult = indexer.embeddingGenerator.generateNameEmbedding(name, moduleName)
        let combinedEmbResult = indexer.embeddingGenerator.generateCombinedEmbedding(name, signature, documentation)
        
        # Store embeddings if successful - convert to TiDB vector format
        if docEmbResult.success:
          docEmb = vectorToTiDBString(docEmbResult.embedding)
        if sigEmbResult.success:
          sigEmb = vectorToTiDBString(sigEmbResult.embedding)
        if nameEmbResult.success:
          nameEmb = vectorToTiDBString(nameEmbResult.embedding)
        if combinedEmbResult.success:
          combinedEmb = vectorToTiDBString(combinedEmbResult.embedding)
          
        embeddingModel = indexer.config.embeddingModel
        embeddingVersion = "1.0"
      
      let symbolId = indexer.database.insertSymbol(
        name = name,
        symbolType = symbolType,
        module = moduleName,
        filePath = filePath,
        line = line,
        col = column,
        signature = signature,
        documentation = documentation,
        visibility = "", # Will be determined later if needed
        documentationEmbedding = docEmb,
        signatureEmbedding = sigEmb,
        nameEmbedding = nameEmb,
        combinedEmbedding = combinedEmb,
        embeddingModel = embeddingModel,
        embeddingVersion = embeddingVersion
      )
      
      if symbolId > 0:
        inc result
        
  except JsonParsingError as e:
    echo fmt"Error parsing JSON: {e.msg}"
  except Exception as e:
    echo fmt"Error processing symbols: {e.msg}"

proc parseNimIdxFile*(indexer: Indexer, idxFilePath: string): int =
  ## Parse a .idx file generated by nim doc --index
  result = 0
  
  if not fileExists(idxFilePath):
    echo fmt"Index file does not exist: {idxFilePath}"
    return 0
  
  try:
    let content = readFile(idxFilePath)
    let lines = content.splitLines()
    
    for line in lines:
      if line.strip() == "":
        continue
        
      # .idx files are tab-separated with 6 fields:
      # entry_type \t name \t file_path \t line \t column \t description
      let parts = line.split('\t')
      if parts.len < 6:
        continue
      
      let entryType = parts[0]
      let name = parts[1] 
      let filePath = parts[2]
      let line = try: parseInt(parts[3]) except: 0
      let column = try: parseInt(parts[4]) except: 0
      let description = parts[5]
      
      # Only process Nim symbols (not markup/headings)
      if entryType in ["nimgrp", "nimsym"]:
        let moduleName = extractFilename(filePath).replace(".nim", "")
        let fullPath = if isAbsolute(filePath): filePath else: indexer.projectPath / filePath
        
        let symbolId = indexer.database.insertSymbol(
          name = name,
          symbolType = entryType,
          module = moduleName,
          filePath = fullPath,
          line = line,
          col = column,
          signature = "",
          documentation = description,
          visibility = ""
        )
        
        if symbolId > 0:
          inc result
          
  except IOError as e:
    echo fmt"Error reading index file {idxFilePath}: {e.msg}"
  except Exception as e:
    echo fmt"Error parsing index file {idxFilePath}: {e.msg}"

proc indexSingleFile*(indexer: Indexer, filePath: string): tuple[success: bool, symbolCount: int] =
  ## Index a single Nim file using nim jsondoc
  try:
    when not defined(testing):
      echo fmt"Indexing file: {filePath}"
    
    # Generate JSON documentation for the file using clean output
    let absolutePath = if isAbsolute(filePath): filePath else: indexer.projectPath / filePath
    let cmdResult = indexer.analyzer.extractJsonDoc(absolutePath)
    
    if cmdResult.exitCode != 0:
      when not defined(testing):
        echo fmt"Failed to generate jsondoc for {filePath}: {cmdResult.output}"
      return (success: false, symbolCount: 0)
    
    # Parse and store the symbols from clean JSON output
    let symbolCount = indexer.parseNimDocJson(cmdResult.output)
    
    # Also try to find and parse corresponding .idx file if it exists
    let idxPath = filePath.replace(".nim", ".idx")
    if fileExists(idxPath):
      let idxSymbols = indexer.parseNimIdxFile(idxPath)
      echo fmt"Found {idxSymbols} additional symbols from idx file"
    
    return (success: true, symbolCount: symbolCount)
    
  except Exception as e:
    echo fmt"Error indexing file {filePath}: {e.msg}"
    return (success: false, symbolCount: 0)


proc parseAndStoreDependencies*(indexer: Indexer): bool =
  ## Parse the dependency output from nim genDepend and store in database
  try:
    let depResult = indexer.analyzer.getDependencies()
    
    if depResult["status"].getStr() != "success":
      echo "Failed to get dependencies: ", depResult["message"].getStr()
      return false
    
    let depOutput = depResult["dependencies"].getStr()
    let lines = depOutput.splitLines()
    
    # Clear existing dependencies for this project
    indexer.database.clearFileDependencies()
    
    for line in lines:
      let trimmed = line.strip()
      if trimmed == "" or trimmed.startsWith("digraph") or trimmed == "}" or trimmed == "{":
        continue
      
      # Parse DOT format line: "source" -> "target";
      if "->" in trimmed:
        let parts = trimmed.split("->")
        if parts.len != 2:
          continue
        
        # Extract quoted module names
        var sourceFile = parts[0].strip()
        var targetFile = parts[1].strip()
        
        # Remove quotes and semicolon
        if sourceFile.startsWith("\"") and sourceFile.endsWith("\""):
          sourceFile = sourceFile[1..^2]
        if targetFile.endsWith("\";"):
          targetFile = targetFile[0..^3]
        if targetFile.startsWith("\"") and targetFile.endsWith("\""):
          targetFile = targetFile[1..^2]
        
        # Make paths absolute
        let absSource = if isAbsolute(sourceFile): sourceFile else: indexer.projectPath / sourceFile
        let absTarget = if isAbsolute(targetFile): targetFile else: indexer.projectPath / targetFile
        
        # Insert the dependency
        if not indexer.database.insertFileDependency(absSource, absTarget):
          echo fmt"Failed to store dependency: {absSource} -> {absTarget}"
          return false
    
    echo fmt"Successfully stored {lines.len} dependencies"
    return true
  except Exception as e:
    echo "Error parsing and storing dependencies: ", e.msg
    return false

proc indexProject*(indexer: Indexer): string =
  ## Index the entire project using dependency analysis
  try:
    when not defined(testing):
      echo fmt"Starting project indexing for: {indexer.projectPath}"
    
    # Clear existing symbols for this project
    indexer.database.clearSymbols()
    
    # Find all Nim files
    let nimFiles = indexer.findNimFiles()
    when not defined(testing):
      echo fmt"Found {nimFiles.len} Nim files"
    
    if nimFiles.len == 0:
      return "No Nim files found in project"
    
    var totalSymbols = 0
    var successCount = 0
    var failureCount = 0
    
    # First, parse and store dependencies if enabled in configuration
    if indexer.config.enableDependencyTracking:
      if not parseAndStoreDependencies(indexer):
        echo "Warning: Failed to store dependencies"
    
    # Index each file and track modifications
    for filePath in nimFiles:
      # Get file modification info
      let fileInfo = getFileSize(filePath)
      let modTime = getLastModificationTime(filePath).utc
      let fileHash = "" # In a real implementation, we'd calculate a hash of the file content
      
      # Store file modification info
      if not indexer.database.insertFileModification(filePath, modTime, int(fileInfo), fileHash):
        echo fmt"Warning: Failed to store modification info for {filePath}"
      
      let (success, symbolCount) = indexer.indexSingleFile(filePath)
      if success:
        inc successCount
        totalSymbols += symbolCount
        when not defined(testing):
          echo fmt"✓ {extractFilename(filePath)}: {symbolCount} symbols"
      else:
        inc failureCount
        when not defined(testing):
          echo fmt"✗ Failed to index {extractFilename(filePath)}"
    
    # Try project-wide indexing as well
    when not defined(testing):
      echo "Attempting project-wide indexing..."
    let projectResult = indexer.analyzer.execNimCommand("doc", @["--index:on", "--project", indexer.projectPath.absolutePath])
    
    if projectResult.exitCode == 0:
      when not defined(testing):
        echo "✓ Project-wide indexing completed"
      
      # Look for generated .idx files
      for kind, path in walkDir(indexer.projectPath):
        if kind == pcFile and path.endsWith(".idx"):
          let idxSymbols = indexer.parseNimIdxFile(path)
          if idxSymbols > 0:
            totalSymbols += idxSymbols
            echo fmt"✓ Processed {extractFilename(path)}: {idxSymbols} symbols"
    else:
      echo fmt"Project-wide indexing failed: {projectResult.output}"
    
    let summary = fmt"""
Project indexing completed:
- Files processed: {successCount}/{nimFiles.len}
- Total symbols indexed: {totalSymbols}
- Failures: {failureCount}
"""
    
    echo summary
    return summary
    
  except Exception as e:
    let errorMsg = fmt"Project indexing failed: {e.msg}"
    echo errorMsg
    return errorMsg

proc getFilesToReindex*(indexer: Indexer, changedFiles: seq[string]): seq[string] =
  ## Determine which files need to be re-indexed based on changed files and dependencies
  var filesToReindex: seq[string] = @[]
  
  # Add the changed files themselves
  for file in changedFiles:
    if file notin filesToReindex:
      filesToReindex.add(file)
  
  # Find all files that depend on the changed files (reverse dependencies)
  for changedFile in changedFiles:
    let dependencies = indexer.database.getFileDependencies(targetFile = changedFile)
    for dep in dependencies:
      let sourceFile = dep.sourceFile
      if sourceFile notin filesToReindex:
        filesToReindex.add(sourceFile)
  
  return filesToReindex

proc updateIndex*(indexer: Indexer, filePaths: seq[string] = @[]): string =
  ## Update index for specific files or detect changes automatically
  try:
    var filesToUpdate: seq[string]
    
    if filePaths.len > 0:
      # Specific files were requested
      filesToUpdate = filePaths
    else:
      # Detect changes automatically
      if indexer.config.enableDependencyTracking:
        var changedFiles: seq[string] = @[]
        
        # Check all Nim files
        let nimFiles = indexer.findNimFiles()
        for filePath in nimFiles:
          let fileInfo = getFileSize(filePath)
          let modTime = getLastModificationTime(filePath)
          
          # Get stored modification info
          let storedModOpt = indexer.database.getFileModification(filePath)
          
          if storedModOpt.isSome():
            let storedMod = storedModOpt.get()
            # If file has been modified or doesn't have embeddings, mark for update
            if modTime.utc > storedMod.modificationTime:
              changedFiles.add(filePath)
          else:
            # New file
            changedFiles.add(filePath)
        
        # Determine which files need to be re-indexed based on dependencies
        filesToUpdate = indexer.getFilesToReindex(changedFiles)
        
        # If no dependencies are available but we have changed files, just update changed files
        if filesToUpdate.len == 0 and changedFiles.len > 0:
          filesToUpdate = changedFiles
      else:
        # If dependency tracking is disabled, re-index all files
        filesToUpdate = indexer.findNimFiles()
    
    var updatedCount = 0
    var totalSymbols = 0
    
    for filePath in filesToUpdate:
      # Get file modification info
      let fileInfo = getFileSize(filePath)
      let modTime = getLastModificationTime(filePath)
      let fileHash = "" # In a real implementation, we'd calculate a hash of the file content
      
      # Store file modification info
      if not indexer.database.insertFileModification(filePath, modTime.utc, int(fileInfo), fileHash):
        echo fmt"Warning: Failed to store modification info for {filePath}"
      
      let (success, symbolCount) = indexer.indexSingleFile(filePath)
      if success:
        inc updatedCount
        totalSymbols += symbolCount
        echo fmt"✓ {extractFilename(filePath)}: {symbolCount} symbols"
      else:
        echo fmt"✗ Failed to index {extractFilename(filePath)}"
    
    let summary = fmt"""
Index update completed:
- Files to update: {filesToUpdate.len}
- Files processed: {updatedCount}
- Total symbols indexed: {totalSymbols}
"""
    
    echo summary
    return summary
    
  except Exception as e:
    return fmt"Index update failed: {e.msg}"

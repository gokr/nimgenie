import std/[json, os, strutils, strformat, times, options]
import nimcp
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
    
    let entriesArray = docJson["entries"]
    let entriesCount = entriesArray.len
    
    for i in 0..<entriesCount:
      let entry = entriesArray[i]
      
      if entry.kind != JObject:
        echo fmt"Warning: Entry {i} is not a JObject, skipping"
        continue
        
      if not entry.hasKey("name") or not entry.hasKey("type"):
        continue
      
      let name = entry["name"].getStr()
      let symbolType = entry["type"].getStr()
      let line = if entry.hasKey("line"): entry["line"].getInt() else: 0
      let column = if entry.hasKey("col"): entry["col"].getInt() else: 0
      # Extract signature - it can be a complex object or simple string
      var signature = ""
      if entry.hasKey("signature"):
        let sigField = entry["signature"]
        if sigField.kind == JString:
          signature = sigField.getStr()
        elif sigField.kind == JObject:
          # Complex signature object - convert to readable string
          var sigParts: seq[string] = @[]
          if sigField.hasKey("return"):
            sigParts.add("return: " & sigField["return"].getStr())
          if sigField.hasKey("arguments"):
            var argStrings: seq[string] = @[]
            let argsField = sigField["arguments"]
            if argsField.kind == JArray:
              for arg in argsField:
                if arg.hasKey("name") and arg.hasKey("type"):
                  argStrings.add(arg["name"].getStr() & ": " & arg["type"].getStr())
            if argStrings.len > 0:
              sigParts.add("args: (" & argStrings.join(", ") & ")")
          if sigField.hasKey("pragmas"):
            var pragmaStrings: seq[string] = @[]
            let pragmasField = sigField["pragmas"]
            if pragmasField.kind == JArray:
              for pragma in pragmasField:
                pragmaStrings.add(pragma.getStr())
            if pragmaStrings.len > 0:
              sigParts.add("pragmas: " & pragmaStrings.join(", "))
          signature = sigParts.join("; ")
      let documentation = if entry.hasKey("description"): entry["description"].getStr() else: ""
      
      # nim jsondoc only outputs exported (public) symbols, so all symbols here are public
      let visibility = "public"
      
      # Extract code snippet if available
      let code = if entry.hasKey("code"): entry["code"].getStr() else: ""
      
      # Extract pragmas as JSON string for rich storage
      var pragmasJson = ""
      if entry.hasKey("signature") and entry["signature"].kind == JObject:
        let sigField = entry["signature"]
        if sigField.hasKey("pragmas"):
          let pragmasField = sigField["pragmas"]
          if pragmasField.kind == JArray and pragmasField.len > 0:
            pragmasJson = $pragmasField  # Store as JSON string for later parsing
      
      
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
      var docEmb, sigEmb, nameEmb, combinedEmb = TidbVector(@[])
      var embeddingModel, embeddingVersion = ""
      
      if indexer.embeddingGenerator.available:
        # Generate embeddings
        let docEmbResult = indexer.embeddingGenerator.generateDocumentationEmbedding(documentation)
        let sigEmbResult = indexer.embeddingGenerator.generateSignatureEmbedding(signature)
        let nameEmbResult = indexer.embeddingGenerator.generateNameEmbedding(name, moduleName)
        let combinedEmbResult = indexer.embeddingGenerator.generateCombinedEmbedding(name, signature, documentation)
        
        # Store embeddings if successful - convert to TidbVector format
        if docEmbResult.success:
          docEmb = toTidbVector(docEmbResult.embedding)
        if sigEmbResult.success:
          sigEmb = toTidbVector(sigEmbResult.embedding)
        if nameEmbResult.success:
          nameEmb = toTidbVector(nameEmbResult.embedding)
        if combinedEmbResult.success:
          combinedEmb = toTidbVector(combinedEmbResult.embedding)
          
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
        visibility = visibility,
        code = code,
        pragmas = pragmasJson,
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
          visibility = "",
          code = "",  # .idx files don't contain code snippets
          pragmas = ""  # .idx files don't contain pragma information
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
      # Don't return false - allow indexing to continue even if dependencies fail
      return true
    
    let depOutput = depResult["dependencies"].getStr()
    let lines = depOutput.splitLines()
    
    # Clear existing dependencies for this project
    indexer.database.clearFileDependencies()
    
    var storedCount = 0
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
        
        # Insert the dependency - don't fail if individual insertion fails
        if indexer.database.insertFileDependency(absSource, absTarget):
          storedCount.inc()
    
    echo fmt"Successfully stored {storedCount} dependencies"
    return true
  except Exception as e:
    echo "Error parsing and storing dependencies: ", e.msg
    # Don't fail the entire indexing process due to dependency issues
    return true

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
    
    # Try project-wide indexing as well - look for a main nim file
    when not defined(testing):
      echo "Attempting project-wide indexing..."
    
    # Find a suitable main nim file for project indexing
    var mainFile = ""
    
    # Look for common main file patterns
    let possibleMainFiles = [
      indexer.projectPath / (extractFilename(indexer.projectPath) & ".nim"),
      indexer.projectPath / "src" / (extractFilename(indexer.projectPath) & ".nim"),
      indexer.projectPath / "main.nim",
      indexer.projectPath / "src" / "main.nim"
    ]
    
    for candidate in possibleMainFiles:
      if fileExists(candidate):
        mainFile = candidate
        break
    
    # If no main file found, just skip project-wide indexing
    if mainFile == "":
      when not defined(testing):
        echo "No main file found for project-wide indexing, skipping..."
    else:
      let projectResult = indexer.analyzer.execNimCommand("doc", @["--index:on", "--project", mainFile])
      
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
        when not defined(testing):
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

proc indexProjectWithStreaming*(indexer: Indexer, ctx: McpRequestContext): string =
  ## Index the entire project using dependency analysis with streaming progress updates
  try:
    ctx.sendNotification("progress", %*{"message": fmt"Starting project indexing for: {indexer.projectPath}", "stage": "starting"})
    
    # Clear existing symbols for this project
    ctx.sendNotification("progress", %*{"message": "Clearing existing symbols...", "stage": "cleanup"})
    indexer.database.clearSymbols()
    
    # Find all Nim files
    ctx.sendNotification("progress", %*{"message": "Discovering Nim files...", "stage": "discovery"})
    let nimFiles = indexer.findNimFiles()
    ctx.sendNotification("progress", %*{"message": fmt"Found {nimFiles.len} Nim files", "stage": "discovery"})
    
    if nimFiles.len == 0:
      return "No Nim files found in project"
    
    var totalSymbols = 0
    var successCount = 0
    var failureCount = 0
    
    # First, parse and store dependencies if enabled in configuration
    if indexer.config.enableDependencyTracking:
      ctx.sendNotification("progress", %*{"message": "Parsing and storing dependencies...", "stage": "dependencies"})
      if not parseAndStoreDependencies(indexer):
        ctx.sendNotification("progress", %*{"message": "Warning: Failed to store dependencies", "stage": "warning"})
    
    # Index each file and track modifications
    let totalFiles = nimFiles.len
    for i, filePath in nimFiles:
      let fileName = extractFilename(filePath)
      ctx.sendNotification("progress", %*{
        "message": fmt"Processing file {i+1}/{totalFiles}: {fileName}", 
        "stage": "indexing",
        "progress": float(i) / float(totalFiles) * 100.0
      })
      
      # Get file modification info
      let fileInfo = getFileSize(filePath)
      let modTime = getLastModificationTime(filePath).utc
      let fileHash = "" # In a real implementation, we'd calculate a hash of the file content
      
      # Store file modification info
      if not indexer.database.insertFileModification(filePath, modTime, int(fileInfo), fileHash):
        ctx.sendNotification("progress", %*{"message": fmt"Warning: Failed to store modification info for {fileName}", "stage": "warning"})
      
      let (success, symbolCount) = indexer.indexSingleFile(filePath)
      if success:
        inc successCount
        totalSymbols += symbolCount
        when not defined(testing):
          ctx.sendNotification("progress", %*{"message": fmt"✓ {fileName}: {symbolCount} symbols", "stage": "file_success"})
      else:
        inc failureCount
        ctx.sendNotification("progress", %*{"message": fmt"✗ Failed to index {fileName}", "stage": "file_error"})
    
    # Try project-wide indexing as well - look for a main nim file
    ctx.sendNotification("progress", %*{"message": "Attempting project-wide indexing...", "stage": "project_wide"})
    
    # Find a suitable main nim file for project indexing
    var mainFile = ""
    
    # Look for common main file patterns
    let possibleMainFiles = [
      indexer.projectPath / (extractFilename(indexer.projectPath) & ".nim"),
      indexer.projectPath / "src" / (extractFilename(indexer.projectPath) & ".nim"),
      indexer.projectPath / "main.nim",
      indexer.projectPath / "src" / "main.nim"
    ]
    
    for candidate in possibleMainFiles:
      if fileExists(candidate):
        mainFile = candidate
        break
    
    # If no main file found, just skip project-wide indexing
    if mainFile == "":
      ctx.sendNotification("progress", %*{"message": "No main file found for project-wide indexing, skipping...", "stage": "project_wide"})
    else:
      ctx.sendNotification("progress", %*{"message": fmt"Running project-wide indexing on {extractFilename(mainFile)}...", "stage": "project_wide"})
      let projectResult = indexer.analyzer.execNimCommand("doc", @["--index:on", "--project", mainFile])
      
      if projectResult.exitCode == 0:
        ctx.sendNotification("progress", %*{"message": "✓ Project-wide indexing completed", "stage": "project_wide"})
        
        # Look for generated .idx files
        for kind, path in walkDir(indexer.projectPath):
          if kind == pcFile and path.endsWith(".idx"):
            let idxSymbols = indexer.parseNimIdxFile(path)
            if idxSymbols > 0:
              totalSymbols += idxSymbols
              ctx.sendNotification("progress", %*{"message": fmt"✓ Processed {extractFilename(path)}: {idxSymbols} symbols", "stage": "project_wide"})
      else:
        ctx.sendNotification("progress", %*{"message": fmt"Project-wide indexing failed: {projectResult.output}", "stage": "project_wide_error"})
    
    let summary = fmt"""
Project indexing completed:
- Files processed: {successCount}/{nimFiles.len}
- Total symbols indexed: {totalSymbols}
- Failures: {failureCount}
"""
    
    ctx.sendNotification("progress", %*{"message": "Project indexing completed successfully!", "stage": "completed"})
    echo summary
    return summary
    
  except Exception as e:
    let errorMsg = fmt"Project indexing failed: {e.msg}"
    ctx.sendNotification("progress", %*{"message": errorMsg, "stage": "error"})
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

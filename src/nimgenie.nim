import nimcp
import std/[json, tables, strutils, os]
import database
import indexer
import analyzer

type
  NimGenie* = object
    db*: Database
    symbolCache*: Table[string, JsonNode]
    projectPath*: string

var genie = NimGenie()

mcpServer("nimgenie", "0.1.0"):
  info = ServerInfo(
    name: "nimgenie", 
    version: "0.1.0"
  )
  
  mcpTool:
    proc initialize(projectPath: string = getCurrentDir()): string =
      ## Initialize NimGenie for a specific project directory
      try:
        genie.projectPath = projectPath
        genie.db = initDatabase()
        genie.symbolCache = initTable[string, JsonNode]()
        return fmt"NimGenie initialized for project: {projectPath}"
      except Exception as e:
        return fmt"Failed to initialize: {e.msg}"
    
  mcpTool:
    proc indexProject(): string =
      ## Index the current project using nim doc --index
      try:
        if genie.projectPath == "":
          return "Error: Project not initialized. Call initialize() first."
        
        let indexer = newIndexer(genie.db, genie.projectPath)
        let result = indexer.indexProject()
        
        # Clear cache after reindexing
        genie.symbolCache.clear()
        
        return result
      except Exception as e:
        return fmt"Failed to index project: {e.msg}"
        
  mcpTool:
    proc searchSymbols(query: string, symbolType: string = "", moduleName: string = ""): JsonNode =
      ## Search for symbols by name, optionally filtered by type and module
      try:
        if genie.projectPath == "":
          return %*{"error": "Project not initialized. Call initialize() first."}
        
        let cacheKey = fmt"{query}:{symbolType}:{moduleName}"
        if genie.symbolCache.hasKey(cacheKey):
          return genie.symbolCache[cacheKey]
        
        let results = genie.db.searchSymbols(query, symbolType, moduleName)
        genie.symbolCache[cacheKey] = results
        
        return results
      except Exception as e:
        return %*{"error": fmt"Search failed: {e.msg}"}
        
  mcpTool:
    proc getSymbolInfo(symbolName: string, moduleName: string = ""): JsonNode =
      ## Get detailed information about a specific symbol
      try:
        if genie.projectPath == "":
          return %*{"error": "Project not initialized. Call initialize() first."}
        
        let cacheKey = fmt"info:{symbolName}:{moduleName}"
        if genie.symbolCache.hasKey(cacheKey):
          return genie.symbolCache[cacheKey]
        
        let info = genie.db.getSymbolInfo(symbolName, moduleName)
        genie.symbolCache[cacheKey] = info
        
        return info
      except Exception as e:
        return %*{"error": fmt"Failed to get symbol info: {e.msg}"}
        
  mcpTool:
    proc checkSyntax(filePath: string = ""): JsonNode =
      ## Check syntax and semantics of Nim code
      try:
        if genie.projectPath == "":
          return %*{"error": "Project not initialized. Call initialize() first."}
        
        let analyzer = newAnalyzer(genie.projectPath)
        let targetPath = if filePath == "": genie.projectPath else: filePath
        
        return analyzer.checkSyntax(targetPath)
      except Exception as e:
        return %*{"error": fmt"Syntax check failed: {e.msg}"}
        
  mcpTool:
    proc getProjectStats(): JsonNode =
      ## Get statistics about the indexed project
      try:
        if genie.projectPath == "":
          return %*{"error": "Project not initialized. Call initialize() first."}
        
        return genie.db.getProjectStats()
      except Exception as e:
        return %*{"error": fmt"Failed to get project stats: {e.msg}"}
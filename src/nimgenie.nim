import nimcp
import std/[json, tables, strutils, os, strformat, mimetypes, base64, options, locks, times]
import database
import indexer
import analyzer
import nimble

type
  NimProject* = object
    path*: string
    analyzer*: Analyzer
    lastIndexed*: DateTime
    
  NimGenie* = object
    database*: Database
    projects*: Table[string, NimProject]
    nimblePackages*: Table[string, string]  # package name -> path
    symbolCache*: Table[string, JsonNode]
    registeredDirectories*: seq[string]

var genie: NimGenie
var genieLock: Lock

template withGenie(body: untyped): untyped =
  ## Execute code block with the genie instance safely locked
  ## Uses cast(gcsafe) to bypass compiler's static analysis since we ensure safety through locking
  {.cast(gcsafe).}:
    acquire(genieLock)
    try:
      body
    finally:
      release(genieLock)

proc loadRegisteredDirectories*(genie: var NimGenie) =
  ## Load registered directories from the database into memory
  genie.registeredDirectories = @[]
  let dirData = genie.database.getRegisteredDirectories()
  if dirData.kind == JArray:
    for dir in dirData:
      genie.registeredDirectories.add(dir["path"].getStr())

proc addDirectoryToResources*(genie: var NimGenie, path: string, name: string = "", description: string = ""): bool =
  ## Add a directory to be served as resources
  if not dirExists(path):
    return false
    
  let normalizedPath = path.normalizedPath().absolutePath()
  if genie.database.addRegisteredDirectory(normalizedPath, name, description):
    if normalizedPath notin genie.registeredDirectories:
      genie.registeredDirectories.add(normalizedPath)
    return true
  return false

proc removeDirectoryFromResources*(genie: var NimGenie, path: string): bool =
  ## Remove a directory from being served as resources
  let normalizedPath = path.normalizedPath().absolutePath()
  if genie.database.removeRegisteredDirectory(normalizedPath):
    let index = genie.registeredDirectories.find(normalizedPath)
    if index != -1:
      genie.registeredDirectories.delete(index)
    return true
  return false

proc discoverNimblePackages*(genie: var NimGenie) =
  ## Discover locally installed Nimble packages
  try:
    # Try to find nimble packages directory
    let homeDir = getHomeDir()
    let nimblePkgDirs = @[
      homeDir / ".nimble" / "pkgs",
      homeDir / ".nimble" / "pkgs2",
      "/usr/lib/nim",
      "/usr/local/lib/nim"
    ]
    
    for pkgDir in nimblePkgDirs:
      if dirExists(pkgDir):
        for kind, path in walkDir(pkgDir):
          if kind == pcDir:
            let pkgName = extractFilename(path)
            # Skip version-specific directories, use the base package name
            let basePkgName = pkgName.split('-')[0]
            if basePkgName notin genie.nimblePackages:
              genie.nimblePackages[basePkgName] = path
              echo fmt"Found Nimble package: {basePkgName} at {path}"
  except Exception as e:
    echo fmt"Error discovering Nimble packages: {e.msg}"

proc openGenie*(path: string): NimGenie =
  ## Open or create local instance of NimGenie
  result.database = newDatabase()
  result.projects = initTable[string, NimProject]()
  result.nimblePackages = initTable[string, string]()
  result.symbolCache = initTable[string, JsonNode]()
  
  # Load registered directories from database
  loadRegisteredDirectories(result)
  
  # Discover Nimble packages
  discoverNimblePackages(result)

# MIME type detection utilities
var mimeDB: MimeDb
var mimeDBInitialized = false

proc initMimeTypes() =
  ## Initialize MIME type database
  if not mimeDBInitialized:
    mimeDB = newMimetypes()
    mimeDBInitialized = true

proc detectMimeType*(filePath: string): string =
  ## Detect MIME type from file extension
  if not mimeDBInitialized:
    initMimeTypes()
  
  let ext = filePath.splitFile().ext.toLowerAscii()
  case ext
  of ".png": "image/png"
  of ".jpg", ".jpeg": "image/jpeg"
  of ".gif": "image/gif"
  of ".svg": "image/svg+xml"
  of ".webp": "image/webp"
  of ".bmp": "image/bmp"
  of ".ico": "image/x-icon"
  of ".pdf": "application/pdf"
  of ".txt": "text/plain"
  of ".html", ".htm": "text/html"
  of ".css": "text/css"
  of ".js": "application/javascript"
  of ".json": "application/json"
  of ".xml": "application/xml"
  of ".zip": "application/zip"
  of ".tar": "application/x-tar"
  of ".gz": "application/gzip"
  else:
    try:
      mimeDB.getMimetype(ext)
    except:
      "application/octet-stream"  # Default for unknown types

proc isImageFile*(filePath: string): bool =
  ## Check if file is an image based on MIME type
  let mimeType = detectMimeType(filePath)
  return mimeType.startsWith("image/")

proc encodeFileAsBase64*(filePath: string): string =
  ## Read file and encode as base64 for serving binary content
  let content = readFile(filePath)
  return encode(content)


let server = mcpServer("nimgenie", "0.1.0"):

  mcpTool:
    proc indexCurrentProject(): string {.gcsafe.} =
      ## Index the current project using nim doc --index
      try:
        withGenie:
          # Get or create current project
          let currentPath = getCurrentDir()
          if currentPath notin genie.projects:
            genie.projects[currentPath] = NimProject(
              path: currentPath,
              analyzer: newAnalyzer(currentPath),
              lastIndexed: now()
            )
          
          let indexer = newIndexer(genie.database, currentPath)
          let indexResult = indexer.indexProject()
          
          # Clear cache after reindexing
          genie.symbolCache.clear()
          
          return indexResult
      except Exception as e:
        return fmt"Failed to index project: {e.msg}"
        
  mcpTool:
    proc searchSymbols(query: string, symbolType: string = "", moduleName: string = ""): string {.gcsafe.} =
      ## Search for symbols by name, optionally filtered by type and module
      try:
        withGenie:
          # Check cache first
          let cacheKey = fmt"{query}:{symbolType}:{moduleName}"
          if genie.symbolCache.hasKey(cacheKey):
            return $genie.symbolCache[cacheKey]
          
          let results = genie.database.searchSymbols(query, symbolType, moduleName)
          genie.symbolCache[cacheKey] = results
          
          return $results
      except Exception as e:
        return fmt"Search failed: {e.msg}"
        
  mcpTool:
    proc getSymbolInfo(symbolName: string, moduleName: string = ""): string {.gcsafe.} =
      ## Get detailed information about a specific symbol
      try:
        withGenie:
          let cacheKey = fmt"info:{symbolName}:{moduleName}"
          if genie.symbolCache.hasKey(cacheKey):
            return $genie.symbolCache[cacheKey]
          
          let info = genie.database.getSymbolInfo(symbolName, moduleName)
          genie.symbolCache[cacheKey] = info
          
          return $info
      except Exception as e:
        return fmt"Failed to get symbol info: {e.msg}"
        
  mcpTool:
    proc checkSyntax(filePath: string = ""): string {.gcsafe.} =
      ## Check syntax and semantics of Nim code
      try:
        withGenie:
          let currentPath = getCurrentDir()
          if currentPath notin genie.projects:
            genie.projects[currentPath] = NimProject(
              path: currentPath,
              analyzer: newAnalyzer(currentPath),
              lastIndexed: now()
            )
          
          let project = genie.projects[currentPath]
          let targetPath = if filePath == "": project.path else: filePath
          let res = project.analyzer.checkSyntax(targetPath)
          return $res
      except Exception as e:
        return fmt"Syntax check failed: {e.msg}"
        
  mcpTool:
    proc getProjectStats(): string {.gcsafe.} =
      ## Get statistics about the indexed project
      try:
        withGenie:
          let stats = genie.database.getProjectStats()
          return $stats
      except Exception as e:
        return fmt"Failed to get project stats: {e.msg}"

  mcpTool:
    proc addDirectoryResource(directoryPath: string, name: string = "", description: string = ""): string {.gcsafe.} =
      ## Add a directory to be served as MCP resources
      try:
        withGenie:
          let normalizedPath = directoryPath.normalizedPath().absolutePath()
          if not dirExists(normalizedPath):
            return fmt"Error: Directory does not exist: {normalizedPath}"
            
          if addDirectoryToResources(genie, normalizedPath, name, description):
            return fmt"Successfully added directory resource: {normalizedPath}"
          else:
            return fmt"Failed to add directory resource: {normalizedPath}"
      except Exception as e:
        return fmt"Error adding directory resource: {e.msg}"
        
  mcpTool:
    proc listDirectoryResources(): string {.gcsafe.} =
      ## List all registered directory resources
      try:
        withGenie:
          let dirData = genie.database.getRegisteredDirectories()
          return $dirData
      except Exception as e:
        return fmt"Error listing directory resources: {e.msg}"
        
  mcpTool:
    proc removeDirectoryResource(directoryPath: string): string {.gcsafe.} =
      ## Remove a directory from being served as MCP resources
      try:
        withGenie:
          let normalizedPath = directoryPath.normalizedPath().absolutePath()
          if removeDirectoryFromResources(genie, normalizedPath):
            return fmt"Successfully removed directory resource: {normalizedPath}"
          else:
            return fmt"Failed to remove directory resource: {normalizedPath} (may not be registered)"
      except Exception as e:
        return fmt"Error removing directory resource: {e.msg}"

  mcpTool:
    proc listNimblePackages(): string {.gcsafe.} =
      ## List all discovered Nimble packages
      try:
        withGenie:
          var packagesList = newJArray()
          for name, path in genie.nimblePackages.pairs:
            packagesList.add(%*{
              "name": name,
              "path": path
            })
          return $(%*{
            "packages": packagesList,
            "count": genie.nimblePackages.len
          })
      except Exception as e:
        return fmt"Error listing Nimble packages: {e.msg}"

  mcpTool:
    proc indexNimblePackage(packageName: string): string {.gcsafe.} =
      ## Index a specific Nimble package
      try:
        withGenie:
          if packageName notin genie.nimblePackages:
            return fmt"Package '{packageName}' not found in discovered Nimble packages"
          
          let packagePath: string = genie.nimblePackages[packageName]
          
          # Create a project entry for this package if it doesn't exist
          if packagePath notin genie.projects:
            genie.projects[packagePath] = NimProject(
              path: packagePath,
              analyzer: newAnalyzer(packagePath),
              lastIndexed: now()
            )
          
          let indexer = newIndexer(genie.database, packagePath)
          let indexResult = indexer.indexProject()
          
          # Clear cache after reindexing
          genie.symbolCache.clear()
          
          return fmt"Successfully indexed Nimble package '{packageName}': {indexResult}"
      except Exception as e:
        return fmt"Failed to index Nimble package '{packageName}': {e.msg}"

  # Package Management Tools
  mcpTool:
    proc nimbleInstallPackage(packageName: string, version: string = ""): string {.gcsafe.} =
      ## Install a Nimble package with optional version constraint
      try:
        withGenie:
          let currentPath = getCurrentDir()
          let nimbleResult = nimbleInstall(currentPath, packageName, version)
          return formatNimbleOutput(nimbleResult)
      except Exception as e:
        return fmt"Failed to install package: {e.msg}"

  mcpTool:
    proc nimbleUninstallPackage(packageName: string): string {.gcsafe.} =
      ## Uninstall a Nimble package
      try:
        withGenie:
          let currentPath = getCurrentDir()
          let nimbleResult = nimbleUninstall(currentPath, packageName)
          return formatNimbleOutput(nimbleResult)
      except Exception as e:
        return fmt"Failed to uninstall package: {e.msg}"

  mcpTool:
    proc nimbleSearchPackages(query: string): string {.gcsafe.} =
      ## Search for packages in the Nimble registry
      try:
        withGenie:
          let currentPath = getCurrentDir()
          let nimbleResult = nimbleSearch(currentPath, query)
          return formatNimbleOutput(nimbleResult)
      except Exception as e:
        return fmt"Failed to search packages: {e.msg}"

  mcpTool:
    proc nimbleListPackages(installed: bool = false): string {.gcsafe.} =
      ## List Nimble packages (installed vs available)
      try:
        withGenie:
          let currentPath = getCurrentDir()
          let nimbleResult = nimbleList(currentPath, installed)
          return formatNimbleOutput(nimbleResult)
      except Exception as e:
        return fmt"Failed to list packages: {e.msg}"

  mcpTool:
    proc nimbleRefreshPackages(): string {.gcsafe.} =
      ## Refresh package list from registry
      try:
        withGenie:
          let currentPath = getCurrentDir()
          let nimbleResult = nimbleRefresh(currentPath)
          return formatNimbleOutput(nimbleResult)
      except Exception as e:
        return fmt"Failed to refresh packages: {e.msg}"

  # Project Development Tools
  mcpTool:
    proc nimbleInitProject(projectName: string, packageType: string = "lib"): string {.gcsafe.} =
      ## Initialize a new Nimble project
      try:
        withGenie:
          let currentPath = getCurrentDir()
          let nimbleResult = nimbleInit(currentPath, projectName, packageType)
          
          # After successful project initialization, automatically index it
          if nimbleResult.success:
            let indexer = newIndexer(genie.database, currentPath)
            let indexResult = indexer.indexProject()
            genie.symbolCache.clear()
            return fmt"{formatNimbleOutput(nimbleResult)}\n\nProject indexed: {indexResult}"
          else:
            return formatNimbleOutput(nimbleResult)
      except Exception as e:
        return fmt"Failed to initialize project: {e.msg}"

  mcpTool:
    proc nimbleBuildProject(target: string = "", mode: string = ""): string {.gcsafe.} =
      ## Build the current Nimble project
      try:
        withGenie:
          let currentPath = getCurrentDir()
          let nimbleResult = nimbleBuild(currentPath, target, mode)
          return formatNimbleOutput(nimbleResult)
      except Exception as e:
        return fmt"Failed to build project: {e.msg}"

  mcpTool:
    proc nimbleTestProject(testFilter: string = ""): string {.gcsafe.} =
      ## Run tests for the current Nimble project
      try:
        withGenie:
          let currentPath = getCurrentDir()
          let nimbleResult = nimbleTest(currentPath, testFilter)
          return formatNimbleOutput(nimbleResult)
      except Exception as e:
        return fmt"Failed to run tests: {e.msg}"

  mcpTool:
    proc nimbleRunProject(target: string, args: string = ""): string {.gcsafe.} =
      ## Execute a Nimble project binary
      try:
        withGenie:
          let currentPath = getCurrentDir()
          let argsList = if args.len > 0: args.split(" ") else: @[]
          let nimbleResult = nimbleRun(currentPath, target, argsList)
          return formatNimbleOutput(nimbleResult)
      except Exception as e:
        return fmt"Failed to run project: {e.msg}"

  mcpTool:
    proc nimbleCheckProject(file: string = ""): string {.gcsafe.} =
      ## Validate Nimble project configuration
      try:
        withGenie:
          let currentPath = getCurrentDir()
          let nimbleResult = nimbleCheck(currentPath, file)
          return formatNimbleOutput(nimbleResult)
      except Exception as e:
        return fmt"Failed to check project: {e.msg}"

  # Dependency Management Tools
  mcpTool:
    proc nimbleDevelopPackage(action: string, path: string = ""): string {.gcsafe.} =
      ## Manage development dependencies (add/remove/list)
      try:
        withGenie:
          let currentPath = getCurrentDir()
          let nimbleResult = nimbleDevelop(currentPath, action, path)
          return formatNimbleOutput(nimbleResult)
      except Exception as e:
        return fmt"Failed to manage develop package: {e.msg}"

  mcpTool:
    proc nimbleUpgradePackages(packageName: string = ""): string {.gcsafe.} =
      ## Upgrade packages to latest versions
      try:
        withGenie:
          let currentPath = getCurrentDir()
          let nimbleResult = nimbleUpgrade(currentPath, packageName)
          return formatNimbleOutput(nimbleResult)
      except Exception as e:
        return fmt"Failed to upgrade packages: {e.msg}"

  mcpTool:
    proc nimbleDumpDependencies(): string {.gcsafe.} =
      ## Export current project dependency information
      try:
        withGenie:
          let currentPath = getCurrentDir()
          let nimbleResult = nimbleDump(currentPath)
          return formatNimbleOutput(nimbleResult)
      except Exception as e:
        return fmt"Failed to dump dependencies: {e.msg}"

  # Project Information Tools
  mcpTool:
    proc nimblePackageInfo(packageName: string): string {.gcsafe.} =
      ## Get detailed information about a package
      try:
        withGenie:
          let currentPath = getCurrentDir()
          let nimbleResult = nimbleInfo(currentPath, packageName)
          return formatNimbleOutput(nimbleResult)
      except Exception as e:
        return fmt"Failed to get package info: {e.msg}"

  mcpTool:
    proc nimbleShowDependencies(showTree: bool = false): string {.gcsafe.} =
      ## Display project dependency information
      try:
        withGenie:
          let currentPath = getCurrentDir()
          let nimbleResult = nimbleDeps(currentPath, showTree)
          return formatNimbleOutput(nimbleResult)
      except Exception as e:
        return fmt"Failed to show dependencies: {e.msg}"

  mcpTool:
    proc nimblePackageVersions(packageName: string): string {.gcsafe.} =
      ## List available versions for a package
      try:
        withGenie:
          let currentPath = getCurrentDir()
          let nimbleResult = nimbleVersions(currentPath, packageName)
          return formatNimbleOutput(nimbleResult)
      except Exception as e:
        return fmt"Failed to get package versions: {e.msg}"

  mcpTool:
    proc nimbleShowProject(property: string = ""): string {.gcsafe.} =
      ## Display current project configuration
      try:
        withGenie:
          let currentPath = getCurrentDir()
          let nimbleResult = nimbleShow(currentPath, property)
          return formatNimbleOutput(nimbleResult)
      except Exception as e:
        return fmt"Failed to show project info: {e.msg}"

  mcpTool:
    proc nimbleProjectStatus(): string {.gcsafe.} =
      ## Check if current directory is a Nimble project and show status
      try:
        withGenie:
          let currentPath = getCurrentDir()
          if isNimbleProject(currentPath):
            let nimbleFile = getNimbleFile(currentPath)
            var statusInfo = %*{
              "isNimbleProject": true,
              "projectPath": currentPath,
              "nimbleFile": nimbleFile.get(""),
              "hasSymbolsIndexed": genie.projects.hasKey(currentPath)
            }
            
            # Add dependency information
            let depsResult = nimbleDeps(currentPath, false)
            if depsResult.success:
              statusInfo["dependencies"] = %depsResult.output
              
            return $statusInfo
          else:
            return $(%*{
              "isNimbleProject": false,
              "projectPath": currentPath,
              "message": "Current directory is not a Nimble project. Use nimbleInitProject to create one."
            })
      except Exception as e:
        return fmt"Failed to get project status: {e.msg}"

proc handleFileResource(ctx: McpRequestContext, uri: string, params: Table[string, string]): McpResourceContents {.gcsafe.} =
  ## Handle file resource requests from registered directories
  let dirIndex = params.getOrDefault("dirIndex", "0").parseInt()
  let relativePath = params.getOrDefault("relativePath", "")
  
  withGenie:
    if dirIndex < 0 or dirIndex >= genie.registeredDirectories.len:
      raise newException(IOError, fmt"Invalid directory index: {dirIndex}")
      
    let basePath = genie.registeredDirectories[dirIndex]
    let fullPath = basePath / relativePath
    
    # Security check: ensure the path is within the registered directory
    let normalizedFullPath = fullPath.normalizedPath().absolutePath()
    let normalizedBasePath = basePath.normalizedPath().absolutePath()
    
    if not normalizedFullPath.startsWith(normalizedBasePath):
      raise newException(IOError, "Access denied: path outside registered directory")
      
    if not fileExists(normalizedFullPath):
      raise newException(IOError, fmt"File not found: {relativePath}")
      
    let mimeType = detectMimeType(normalizedFullPath)
    let fileContent = readFile(normalizedFullPath)
    
    var mcpContent: McpContent
    
    if isImageFile(normalizedFullPath) or mimeType.startsWith("application/"):
      # Binary content - encode as base64
      let encodedContent = encodeFileAsBase64(normalizedFullPath)
      mcpContent = createImageContent(encodedContent, mimeType)
    else:
      # Text content
      mcpContent = createTextContent(fileContent)
      
    return McpResourceContents(
      uri: uri,
      mimeType: some(mimeType),
      content: @[mcpContent]
    )

proc handleScreenshotResource(ctx: McpRequestContext, uri: string, params: Table[string, string]): McpResourceContents {.gcsafe.} =
  ## Handle screenshot resource requests from the screenshots directory
  let filepath = params.getOrDefault("filepath", "")
  
  if filepath == "":
    raise newException(IOError, "No filepath specified")
  
  withGenie:
    # Look for screenshots directory in project path or registered directories
    var screenshotPath = ""
    
    # First check if there's a "screenshots" directory in the current project path
    let currentPath = getCurrentDir()
    let projectScreenshotDir = currentPath / "screenshots"
    if dirExists(projectScreenshotDir):
      screenshotPath = projectScreenshotDir / filepath
    else:
      # Fall back to checking registered directories for one named "screenshots"
      for dirPath in genie.registeredDirectories:
        if dirPath.extractFilename().toLowerAscii() == "screenshots" or 
           "screenshot" in dirPath.toLowerAscii():
          screenshotPath = dirPath / filepath
          break
      
      if screenshotPath == "":
        raise newException(IOError, "No screenshots directory found. Create a 'screenshots' directory in your project or register one with addDirectoryResource")
    
    # Security check: ensure the file is within the screenshot directory
    let normalizedScreenshotPath = screenshotPath.normalizedPath().absolutePath()
    let normalizedScreenshotBaseDir = projectScreenshotDir.normalizedPath().absolutePath()
    
    if not normalizedScreenshotPath.startsWith(normalizedScreenshotBaseDir):
      raise newException(IOError, "Access denied: path outside screenshots directory")
      
    if not fileExists(normalizedScreenshotPath):
      raise newException(IOError, fmt"Screenshot not found: {filepath}")
      
    let mimeType = detectMimeType(normalizedScreenshotPath)
    
    var mcpContent: McpContent
    
    if isImageFile(normalizedScreenshotPath):
      # Image content - encode as base64
      let encodedContent = encodeFileAsBase64(normalizedScreenshotPath)
      mcpContent = createImageContent(encodedContent, mimeType)
    else:
      # Text content (maybe screenshot metadata)
      let fileContent = readFile(normalizedScreenshotPath)
      mcpContent = createTextContent(fileContent)
      
    return McpResourceContents(
      uri: uri,
      mimeType: some(mimeType),
      content: @[mcpContent]
    )

proc listDirectoryFiles(dirPath: string, prefix: string = ""): seq[string] =
  ## Recursively list all files in a directory with relative paths
  result = @[]
  try:
    for kind, path in walkDir(dirPath):
      let relPath = if prefix == "": path.extractFilename() else: prefix / path.extractFilename()
      case kind
      of pcFile:
        result.add(relPath)
      of pcDir:
        let subFiles = listDirectoryFiles(path, relPath)
        result.add(subFiles)
      else:
        discard
  except OSError:
    discard  # Skip directories we can't read

proc generateDirectoryResourceUris(): seq[McpResource] =
  ## Generate resource info for all files in registered directories
  result = @[]
  
  for dirIndex, dirPath in genie.registeredDirectories.pairs():
    if not dirExists(dirPath):
      continue
      
    let files = listDirectoryFiles(dirPath)
    for file in files:
      let uri = fmt"/files/{dirIndex}/{file}"
      let name = file.extractFilename()
      let description = fmt"File: {file} from directory: {dirPath}"
      
      # TODO: Fix resource info creation
      discard

# Register screenshots resource template for game development workflow
server.registerResourceTemplateWithContext(
  McpResourceTemplate(
    uriTemplate: "/screenshots/{filepath}",
    name: "Game Screenshots",
    description: some("Access screenshot files from the screenshots directory"),
    mimeType: some("image/png")  # Most screenshots will be PNG
  ),
  handleScreenshotResource
)

# Register general file resource template for registered directories  
server.registerResourceTemplateWithContext(
  McpResourceTemplate(
    uriTemplate: "/files/{dirIndex}/{relativePath}",
    name: "Registered Directory Files",
    description: some("Access files from registered directories"),
    mimeType: none(string)  # MIME type determined dynamically
  ),
  handleFileResource
)

when isMainModule:
  # Initialize the lock
  initLock(genieLock)
  
  # Open local instance of NimGenie for current directory
  genie = openGenie(getCurrentDir())
  # Start server on port 8080
  let transport = newMummyTransport(8080, "localhost")
  transport.serve(server)
import std/[json, strutils, strformat, osproc, os, options, streams, tables]
import nimcp, database, configuration, indexer

type
  NimbleResult* = object
    success*: bool
    output*: string
    errorMsg*: string
    error*: string
    data*: JsonNode

  NimbleCommand* = object
    executable*: string
    workingDir*: string

proc newNimbleCommand*(workingDir: string = ""): NimbleCommand =
  ## Create a new Nimble command executor
  result.executable = "nimble"
  result.workingDir = if workingDir == "": getCurrentDir() else: workingDir

proc executeNimble*(cmd: NimbleCommand, args: varargs[string]): NimbleResult =
  ## Execute a nimble command with the given arguments
  result.data = newJNull()
  
  try:
    let (output, exitCode) = execCmdEx(
      command = cmd.executable & " " & args.join(" "),
      workingDir = cmd.workingDir,
      options = {poUsePath}
    )
    
    result.output = output
    
    result.success = exitCode == 0
    
    if not result.success:
      result.errorMsg = fmt"Nimble command failed with exit code {exitCode}: {result.output}"
      result.error = result.errorMsg
    
    # Try to parse JSON output if available
    if result.success and result.output.len > 0:
      try:
        # Some nimble commands support --json flag, try to parse if it looks like JSON
        if result.output.strip().startsWith("{") or result.output.strip().startsWith("["):
          result.data = parseJson(result.output)
      except JsonParsingError:
        # Not JSON output, keep as string
        discard
        
  except Exception as e:
    result.success = false
    result.errorMsg = fmt"Failed to execute nimble command: {e.msg}"
    result.error = result.errorMsg
    result.output = ""

proc formatNimbleOutput*(nimbleResult: NimbleResult): string =
  ## Format nimble result for LLM consumption
  if not nimbleResult.success:
    return fmt"Error: {nimbleResult.errorMsg}"
  
  if nimbleResult.data.kind != JNull:
    return $nimbleResult.data
  else:
    return nimbleResult.output

# Package Management Operations

proc nimbleInstall*(workingDir: string, packageName: string, version: string = "", dryRun: bool = false): NimbleResult =
  ## Install a package with optional version constraint and optional dry-run
  let cmd = newNimbleCommand(workingDir)
  var args: seq[string] = @[]
  args.add("install")
  if version.len > 0:
    args.add(fmt"{packageName}@{version}")
  else:
    args.add(packageName)
  args.add("--accept")
  if dryRun:
    args.add("--dry-run")
  return cmd.executeNimble(args)

proc nimbleUninstall*(workingDir: string, packageName: string): NimbleResult =
  ## Uninstall a package
  let cmd = newNimbleCommand(workingDir)
  return cmd.executeNimble("uninstall", packageName, "--accept")

proc nimbleSearch*(workingDir: string, query: string, asJson: bool = false): NimbleResult =
  ## Search for packages in the registry. If `asJson` is true, request JSON output.
  let cmd = newNimbleCommand(workingDir)
  if asJson:
    return cmd.executeNimble("search", query, "--json")
  else:
    return cmd.executeNimble("search", query)

proc nimbleList*(workingDir: string, installed: bool = false): NimbleResult =
  ## List packages (installed vs available)
  let cmd = newNimbleCommand(workingDir)
  if installed:
    return cmd.executeNimble("list", "--installed")
  else:
    return cmd.executeNimble("list")

proc nimbleRefresh*(workingDir: string): NimbleResult =
  ## Refresh package list from registry
  let cmd = newNimbleCommand(workingDir)
  return cmd.executeNimble("refresh")

# Project Development Operations

proc nimbleInit*(workingDir: string, projectName: string, accept: bool = true): NimbleResult =
  ## Initialize a new Nimble project. If `accept` is true, pass --accept.
  let cmd = newNimbleCommand(workingDir)
  if accept:
    return cmd.executeNimble("init", projectName, "--accept")
  else:
    return cmd.executeNimble("init", projectName)

proc nimbleBuild*(workingDir: string, target: string = "", mode: string = ""): NimbleResult =
  ## Build project with optional target and mode
  let cmd = newNimbleCommand(workingDir)
  var args = @["build"]
  
  if target.len > 0:
    args.add(target)
  
  if mode.len > 0:
    args.add("--define:" & mode)
    
  return cmd.executeNimble(args)

proc nimbleBuildWithStreaming*(ctx: McpRequestContext, workingDir: string, target: string = "", mode: string = ""): NimbleResult =
  ## Build project with optional target and mode and real-time streaming output
  result.data = newJNull()
  
  try:
    var args = @["build"]
    
    if target.len > 0:
      args.add(target)
    
    if mode.len > 0:
      args.add("--define:" & mode)
    
    let fullCommand = "nimble " & args.join(" ")
    # Send proper streaming notification instead of just logging
    ctx.sendNotification("progress", %*{"message": fmt"Starting build: {fullCommand}", "stage": "starting"})
    
    # Start the process for streaming output
    let process = startProcess(
      command = fullCommand,
      workingDir = workingDir,
      options = {poEvalCommand, poUsePath, poStdErrToStdOut}
    )
    
    var outputLines: seq[string] = @[]
    var line: string
    
    # Read output line by line and stream it
    while readLine(process.outputStream, line):
      outputLines.add(line)
      
      # Send streaming notification for each line of output
      ctx.sendNotification("progress", %*{"message": line, "stage": "building"})
      
      # Check if we should exit early due to cancellation
      if ctx.isCancelled():
        process.terminate()
        result.success = false
        result.errorMsg = "Build was cancelled"
        result.error = result.errorMsg
        result.output = outputLines.join("\n")
        ctx.sendNotification("progress", %*{"message": "Build was cancelled", "stage": "cancelled"})
        return
    
    # Wait for process to complete and get exit code
    let exitCode = process.waitForExit()
    process.close()
    
    result.output = outputLines.join("\n")
    result.success = exitCode == 0
    
    if not result.success:
      result.errorMsg = fmt"Nimble build failed with exit code {exitCode}"
      result.error = result.errorMsg
      ctx.sendNotification("progress", %*{"message": fmt"Build completed with exit code: {exitCode}", "stage": "failed", "exitCode": exitCode})
    else:
      ctx.sendNotification("progress", %*{"message": "Build completed successfully", "stage": "completed", "exitCode": exitCode})
    
  except Exception as e:
    result.success = false
    result.errorMsg = fmt"Failed to execute nimble build: {e.msg}"
    result.error = result.errorMsg
    result.output = ""
    ctx.sendNotification("progress", %*{"message": fmt"Build execution failed: {e.msg}", "stage": "error"})

proc nimbleTest*(workingDir: string, testFilter: string = ""): NimbleResult =
  ## Run project tests with optional filtering
  let cmd = newNimbleCommand(workingDir)
  if testFilter.len > 0:
    return cmd.executeNimble("test", testFilter)
  else:
    return cmd.executeNimble("test")

proc nimbleTestWithStreaming*(ctx: McpRequestContext, workingDir: string, testFilter: string = ""): NimbleResult =
  ## Run project tests with optional filtering and real-time streaming output
  result.data = newJNull()
  
  try:
    var args = @["test"]
    if testFilter.len > 0:
      args.add(testFilter)
    
    let fullCommand = "nimble " & args.join(" ")
    # Send proper streaming notification instead of just logging
    ctx.sendNotification("progress", %*{"message": fmt"Starting test execution: {fullCommand}", "stage": "starting"})
    
    # Start the process for streaming output
    let process = startProcess(
      command = fullCommand,
      workingDir = workingDir,
      options = {poEvalCommand, poUsePath, poStdErrToStdOut}
    )
    
    var outputLines: seq[string] = @[]
    var line: string
    
    # Read output line by line and stream it
    while readLine(process.outputStream, line):
      outputLines.add(line)
      
      # Send streaming notification for each line of output
      ctx.sendNotification("progress", %*{"message": line, "stage": "testing"})
      
      # Check if we should exit early due to cancellation
      if ctx.isCancelled():
        process.terminate()
        result.success = false
        result.errorMsg = "Test execution was cancelled"
        result.error = result.errorMsg
        result.output = outputLines.join("\n")
        ctx.sendNotification("progress", %*{"message": "Test execution was cancelled", "stage": "cancelled"})
        return
    
    # Wait for process to complete and get exit code
    let exitCode = process.waitForExit()
    process.close()
    
    result.output = outputLines.join("\n")
    result.success = exitCode == 0
    
    if not result.success:
      result.errorMsg = fmt"Nimble test failed with exit code {exitCode}"
      result.error = result.errorMsg
      ctx.sendNotification("progress", %*{"message": fmt"Test execution completed with exit code: {exitCode}", "stage": "failed", "exitCode": exitCode})
    else:
      ctx.sendNotification("progress", %*{"message": "Test execution completed successfully", "stage": "completed", "exitCode": exitCode})
    
  except Exception as e:
    result.success = false
    result.errorMsg = fmt"Failed to execute nimble test: {e.msg}"
    result.error = result.errorMsg
    result.output = ""
    ctx.sendNotification("progress", %*{"message": fmt"Test execution failed: {e.msg}", "stage": "error"})

proc nimbleRun*(workingDir: string, target: string, args: seq[string] = @[]): NimbleResult =
  ## Execute project binary with arguments
  let cmd = newNimbleCommand(workingDir)
  var runArgs = @["run", target]
  if args.len > 0:
    runArgs.add("--")
    runArgs.add(args)
  return cmd.executeNimble(runArgs)

proc nimbleCheck*(workingDir: string, file: string = ""): NimbleResult =
  ## Validate project configuration
  let cmd = newNimbleCommand(workingDir)
  if file.len > 0:
    return cmd.executeNimble("check", file)
  else:
    return cmd.executeNimble("check")

# Dependency Management Operations

proc nimbleDevelop*(workingDir: string, action: string, path: string = ""): NimbleResult =
  ## Manage development dependencies
  let cmd = newNimbleCommand(workingDir)
  case action.toLowerAscii()
  of "add":
    if path.len > 0:
      return cmd.executeNimble("develop", path)
    else:
      return NimbleResult(success: false, errorMsg: "Path required for develop add")
  of "remove":
    if path.len > 0:
      return cmd.executeNimble("develop", "--remove", path)
    else:
      return NimbleResult(success: false, errorMsg: "Path required for develop remove")
  of "list":
    return cmd.executeNimble("develop", "--list")
  else:
    return NimbleResult(success: false, errorMsg: fmt"Unknown develop action: {action}")

proc nimbleUpgrade*(workingDir: string, packageName: string = ""): NimbleResult =
  ## Upgrade packages to latest versions
  let cmd = newNimbleCommand(workingDir)
  if packageName.len > 0:
    return cmd.executeNimble("upgrade", packageName, "--accept")
  else:
    return cmd.executeNimble("upgrade", "--accept")

proc nimbleDump*(workingDir: string): NimbleResult =
  ## Export dependency information
  let cmd = newNimbleCommand(workingDir)
  return cmd.executeNimble("dump")

# Project Information Operations

proc nimbleInfo*(workingDir: string, packageName: string): NimbleResult =
  ## Get detailed package information
  let cmd = newNimbleCommand(workingDir)
  return cmd.executeNimble("info", packageName)

proc nimbleDeps*(workingDir: string, showTree: bool = false): NimbleResult =
  ## Display dependency information
  let cmd = newNimbleCommand(workingDir)
  if showTree:
    return cmd.executeNimble("deps", "--tree")
  else:
    return cmd.executeNimble("deps")

proc nimbleVersions*(workingDir: string, packageName: string): NimbleResult =
  ## List available package versions
  let cmd = newNimbleCommand(workingDir)
  return cmd.executeNimble("versions", packageName)

proc nimbleShow*(workingDir: string, property: string = ""): NimbleResult =
  ## Display project configuration
  let cmd = newNimbleCommand(workingDir)
  if property.len > 0:
    return cmd.executeNimble("show", property)
  else:
    return cmd.executeNimble("show")

# Utility functions

proc isNimbleProject*(path: string): bool =
  ## Check if directory contains a .nimble file
  for file in walkFiles(path / "*.nimble"):
    return true
  return false

proc getNimbleFile*(path: string): Option[string] =
  ## Get the .nimble file path for a project
  for file in walkFiles(path / "*.nimble"):
    return some(file)
  return none(string)

proc parseNimbleFile*(filePath: string): JsonNode =
  ## Lightweight parser for simple nimble files.
  ## Extracts basic key = "value" pairs and @[...] arrays into a Json object.
  result = newJObject()
  if not fileExists(filePath):
    return result

  try:
    let contents = readFile(filePath)
    for rawLine in contents.splitLines():
      var line = rawLine.strip()
      if line.len == 0: continue
      if line.startsWith("#"): continue
      if line.startsWith("task "): continue

      let eqPos = line.find('=')
      if eqPos < 0: continue

      let key = line[0..eqPos-1].strip()
      var val = line[eqPos+1..^1].strip()

      # Handle array syntax: @["a", "b"]
      if val.startsWith("@[") and val.endsWith("]"):
        var arr = newJArray()
        var inner = val[2..^2].strip()
        if inner.len > 0:
          for item in inner.split(','):
            var s = item.strip()
            if s.startsWith('"') and s.endsWith('"') and s.len >= 2:
              s = s[1..^2]
            arr.add(newJString(s))
        result[key] = arr
        continue

      # Handle quoted strings
      if val.startsWith('"') and val.endsWith('"') and val.len >= 2:
        let unq = val[1..^2]
        result[key] = newJString(unq)
        continue

      # Fallback: store raw value as string
      result[key] = newJString(val)

  except Exception:
    # Return empty object on parse errors
    result = newJObject()

  return result

proc discoverPackagesInDirectory*(dirPath: string): Table[string, string] =
  ## Discover nimble packages in an arbitrary directory. Returns a table mapping package name -> path
  result = initTable[string, string]()
  if not dirExists(dirPath):
    return result

  for kind, path in walkDir(dirPath):
    if kind == pcDir:
      # Look for .nimble file in the package directory
      for file in walkFiles(path / "*.nimble"):
        let pkgName = extractFilename(file).split('.')[0]
        if pkgName.len > 0 and pkgName notin result:
          result[pkgName] = path
        break

  return result

type PackageIndexResult* = object
  success*: bool
  symbolsIndexed*: int
  error*: string

proc indexNimblePackage*(db: Database, packageName: string, packagePath: string): PackageIndexResult =
  ## Index a Nimble package into the provided `Database` and return a result summary.
  result.success = false
  result.symbolsIndexed = 0
  result.error = ""

  if not dirExists(packagePath):
    result.error = fmt"Package path does not exist: {packagePath}"
    return result

  try:
    # Create a minimal Config for the indexer
    var cfg: Config
    cfg.projectPath = packagePath
    cfg.port = 0
    cfg.host = ""
    cfg.verbose = false
    cfg.showHelp = false
    cfg.showVersion = false
    cfg.database = ""
    cfg.databaseHost = ""
    cfg.databasePort = 0
    cfg.databaseUser = ""
    cfg.databasePassword = ""
    cfg.databasePoolSize = 1
    cfg.noDiscovery = true
    cfg.ollamaHost = ""
    cfg.embeddingModel = ""
    cfg.embeddingBatchSize = 1
    cfg.vectorSimilarityThreshold = 0.0
    cfg.enableDependencyTracking = false
    cfg.externalDbType = ""
    cfg.externalDbHost = ""
    cfg.externalDbPort = 0
    cfg.externalDbUser = ""
    cfg.externalDbPassword = ""
    cfg.externalDbDatabase = ""
    cfg.externalDbPoolSize = 0

    let idx = newIndexer(db, packagePath, cfg)

    let nimFiles = idx.findNimFiles()
    var total = 0
    for f in nimFiles:
      let (ok, count) = idx.indexSingleFile(f)
      if ok:
        total += count

    result.symbolsIndexed = total
    result.success = total > 0
  except Exception as e:
    result.error = e.msg
    result.success = false

  return result
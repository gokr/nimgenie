import std/[json, strutils, strformat, osproc, os, options]

type
  NimbleResult* = object
    success*: bool
    output*: string
    errorMsg*: string
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

proc nimbleInstall*(workingDir: string, packageName: string, version: string = ""): NimbleResult =
  ## Install a package with optional version constraint
  let cmd = newNimbleCommand(workingDir)
  if version.len > 0:
    return cmd.executeNimble("install", fmt"{packageName}@{version}", "--accept")
  else:
    return cmd.executeNimble("install", packageName, "--accept")

proc nimbleUninstall*(workingDir: string, packageName: string): NimbleResult =
  ## Uninstall a package
  let cmd = newNimbleCommand(workingDir)
  return cmd.executeNimble("uninstall", packageName, "--accept")

proc nimbleSearch*(workingDir: string, query: string): NimbleResult =
  ## Search for packages in the registry
  let cmd = newNimbleCommand(workingDir)
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

proc nimbleInit*(workingDir: string, projectName: string, packageType: string = "lib"): NimbleResult =
  ## Initialize a new Nimble project
  let cmd = newNimbleCommand(workingDir)
  return cmd.executeNimble("init", projectName, "--accept", "--type:" & packageType)

proc nimbleBuild*(workingDir: string, target: string = "", mode: string = ""): NimbleResult =
  ## Build project with optional target and mode
  let cmd = newNimbleCommand(workingDir)
  var args = @["build"]
  
  if target.len > 0:
    args.add(target)
  
  if mode.len > 0:
    args.add("--define:" & mode)
    
  return cmd.executeNimble(args)

proc nimbleTest*(workingDir: string, testFilter: string = ""): NimbleResult =
  ## Run project tests with optional filtering
  let cmd = newNimbleCommand(workingDir)
  if testFilter.len > 0:
    return cmd.executeNimble("test", testFilter)
  else:
    return cmd.executeNimble("test")

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
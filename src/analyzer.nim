import std/[json, osproc, strutils, os, strformat]

type
  Analyzer* = object
    projectPath*: string
    
proc newAnalyzer*(projectPath: string): Analyzer =
  ## Create a new analyzer for the given project path
  result.projectPath = projectPath

proc execNimCommand*(analyzer: Analyzer, command: string, args: seq[string] = @[], 
                    workingDir: string = "", quiet: bool = true): tuple[output: string, exitCode: int] =
  ## Execute a nim command and return output and exit code
  ## Set quiet=false to see debug output in tests
  try:
    let dir = if workingDir == "": analyzer.projectPath else: workingDir
    
    when not defined(testing):
      if not quiet:
        let fullCommand = "nim " & command & " " & args.join(" ")
        echo fmt"Executing: {fullCommand} in {dir}"
    
    let (output, exitCode) = execCmdEx("nim " & command & " " & args.join(" "), workingDir = dir)
    
    return (output: output, exitCode: exitCode)
  except OSError as e:
    return (output: fmt"Error executing nim command: {e.msg}", exitCode: -1)

proc extractJsonDoc*(analyzer: Analyzer, filePath: string, quiet: bool = true): tuple[output: string, exitCode: int] =
  ## Extract JSON documentation from a Nim file using jsondoc with clean output
  ## Set quiet=false to see debug output
  try:
    let args = @["--stdout:on", "--hints:off", "--warnings:off", filePath]
    let dir = analyzer.projectPath
    
    when not defined(testing):
      if not quiet:
        let fullCommand = "nim jsondoc " & args.join(" ")
        echo fmt"Executing: {fullCommand} in {dir}"
    
    let (output, exitCode) = execCmdEx("nim jsondoc " & args.join(" "), workingDir = dir)
    
    return (output: output, exitCode: exitCode)
  except OSError as e:
    return (output: fmt"Error executing nim jsondoc command: {e.msg}", exitCode: -1)

proc checkSyntax*(analyzer: Analyzer, targetPath: string): JsonNode =
  ## Check syntax and semantics using nim check
  try:
    let cmdResult = analyzer.execNimCommand("check", @["--hints:off", targetPath])
    
    if cmdResult.exitCode == 0:
      return %*{
        "status": "success",
        "message": "No syntax or semantic errors found",
        "output": cmdResult.output
      }
    else:
      return %*{
        "status": "error",
        "message": "Syntax or semantic errors found",
        "output": cmdResult.output,
        "exit_code": cmdResult.exitCode
      }
      
  except Exception as e:
    return %*{
      "status": "error", 
      "message": fmt"Failed to check syntax: {e.msg}"
    }

proc generateDocs*(analyzer: Analyzer, outputDir: string = "", 
                  includeSource: bool = false): JsonNode =
  ## Generate HTML documentation
  try:
    let outDir = if outputDir == "": analyzer.projectPath / "docs" else: outputDir
    var args = @[fmt"--outdir:{outDir}", "--project"]
    
    if includeSource:
      args.add("--includeSource")
    
    args.add(analyzer.projectPath)
    
    let cmdResult = analyzer.execNimCommand("doc", args)
    
    if cmdResult.exitCode == 0:
      return %*{
        "status": "success",
        "message": fmt"Documentation generated in {outDir}",
        "output": cmdResult.output
      }
    else:
      return %*{
        "status": "error",
        "message": "Failed to generate documentation",
        "output": cmdResult.output,
        "exit_code": cmdResult.exitCode
      }
      
  except Exception as e:
    return %*{
      "status": "error",
      "message": fmt"Failed to generate docs: {e.msg}"
    }

proc findDefinition*(analyzer: Analyzer, filePath: string, line: int, 
                    column: int): JsonNode =
  ## Find definition of symbol at given position using --defusages
  try:
    let defUsagesArg = fmt"--defusages:{filePath},{line},{column}"
    let cmdResult = analyzer.execNimCommand("check", @[defUsagesArg, filePath])
    
    if cmdResult.exitCode == 0:
      # Parse the output to extract definition information
      let lines = cmdResult.output.splitLines()
      var definitions = newJArray()
      
      for line in lines:
        if line.contains("def:"):
          # Parse def: lines - format is usually "def: file:line:col"
          let parts = line.split(":")
          if parts.len >= 4:
            definitions.add(%*{
              "type": "definition",
              "file": parts[1],
              "line": parseInt(parts[2]),
              "column": parseInt(parts[3])
            })
        elif line.contains("usage:"):
          # Parse usage: lines
          let parts = line.split(":")
          if parts.len >= 4:
            definitions.add(%*{
              "type": "usage", 
              "file": parts[1],
              "line": parseInt(parts[2]),
              "column": parseInt(parts[3])
            })
      
      return %*{
        "status": "success",
        "definitions": definitions,
        "raw_output": cmdResult.output
      }
    else:
      return %*{
        "status": "error",
        "message": "Failed to find definition",
        "output": cmdResult.output,
        "exit_code": cmdResult.exitCode
      }
      
  except Exception as e:
    return %*{
      "status": "error",
      "message": fmt"Failed to find definition: {e.msg}"
    }

proc expandMacro*(analyzer: Analyzer, macroName: string, filePath: string): JsonNode =
  ## Expand macro using --expandMacro
  try:
    let expandArg = fmt"--expandMacro:{macroName}"
    let cmdResult = analyzer.execNimCommand("c", @[expandArg, "--verbosity:2", filePath])
    
    return %*{
      "status": if cmdResult.exitCode == 0: "success" else: "error",
      "macro_name": macroName,
      "expanded_code": cmdResult.output,
      "exit_code": cmdResult.exitCode
    }
    
  except Exception as e:
    return %*{
      "status": "error",
      "message": fmt"Failed to expand macro: {e.msg}"
    }

proc getDependencies*(analyzer: Analyzer): JsonNode =
  ## Generate dependency information using genDepend for the project
  try:
    # Find the main source file or project entry point
    var mainFile = ""
    
    # First try to find a .nimble file to determine main module
    for file in walkFiles(analyzer.projectPath / "*.nimble"):
      let nimbleContent = readFile(file)
      # Look for bin entry in nimble file
      for line in nimbleContent.splitLines():
        if line.contains("bin") and line.contains("="):
          let parts = line.split("=")
          if parts.len > 1:
            let binName = parts[1].strip().replace("@[", "").replace("]", "").replace("\"", "") 
            mainFile = analyzer.projectPath / (binName & ".nim")
            break
      if mainFile != "":
        break
    
    # If no nimble file found, look for common main files
    if mainFile == "":
      let commonNames = @["main.nim", "app.nim", extractFilename(analyzer.projectPath) & ".nim"]
      for name in commonNames:
        let candidate = analyzer.projectPath / name
        if fileExists(candidate):
          mainFile = candidate
          break
    
    # If still no main file, look in src/ directory  
    if mainFile == "":
      let srcDir = analyzer.projectPath / "src"
      if dirExists(srcDir):
        for name in @["main.nim", "app.nim", extractFilename(analyzer.projectPath) & ".nim"]:
          let candidate = srcDir / name
          if fileExists(candidate):
            mainFile = candidate
            break
    
    # If still no main file found, just pick the first .nim file
    if mainFile == "":
      for file in walkFiles(analyzer.projectPath / "*.nim"):
        mainFile = file
        break
      if mainFile == "":
        for file in walkFiles(analyzer.projectPath / "src" / "*.nim"):
          mainFile = file
          break
    
    if mainFile == "":
      return %*{
        "status": "error",
        "message": "No Nim source files found in project"
      }
    
    # Generate dependencies for the main file
    # Add the src directory to the path so nim can resolve imports
    let srcDir = analyzer.projectPath / "src"
    var args = @[mainFile]
    if dirExists(srcDir):
      args = @["--path:" & srcDir, mainFile]
    
    let cmdResult = analyzer.execNimCommand("genDepend", args)
    
    if cmdResult.exitCode == 0:
      # nim genDepend creates a .dot file, not stdout output
      let dotFile = mainFile.changeFileExt(".dot")
      if fileExists(dotFile):
        let dotContent = readFile(dotFile)
        return %*{
          "status": "success", 
          "dependencies": dotContent,
          "message": "Dependencies generated successfully",
          "mainFile": mainFile,
          "dotFile": dotFile
        }
      else:
        return %*{
          "status": "error",
          "message": "Dependencies dot file not found",
          "dotFile": dotFile,
          "mainFile": mainFile
        }
    else:
      return %*{
        "status": "error",
        "message": "Failed to generate dependencies",
        "output": cmdResult.output,
        "exit_code": cmdResult.exitCode,
        "mainFile": mainFile
      }
      
  except Exception as e:
    return %*{
      "status": "error",
      "message": fmt"Failed to get dependencies: {e.msg}"
    }

proc dumpConfig*(analyzer: Analyzer): JsonNode =
  ## Dump compiler configuration
  try:
    let cmdResult = analyzer.execNimCommand("dump", @["--dump.format:json"])
    
    if cmdResult.exitCode == 0:
      try:
        # Try to parse as JSON
        let configJson = parseJson(cmdResult.output)
        return %*{
          "status": "success",
          "config": configJson
        }
      except JsonParsingError:
        # If not valid JSON, return as text
        return %*{
          "status": "success", 
          "config_text": cmdResult.output
        }
    else:
      return %*{
        "status": "error",
        "message": "Failed to dump config",
        "output": cmdResult.output,
        "exit_code": cmdResult.exitCode
      }
      
  except Exception as e:
    return %*{
      "status": "error",
      "message": fmt"Failed to dump config: {e.msg}"
    }
import std/[json, osproc, strutils, os, strformat]

type
  Analyzer* = object
    projectPath*: string
    
proc newAnalyzer*(projectPath: string): Analyzer =
  ## Create a new analyzer for the given project path
  result.projectPath = projectPath

proc execNimCommand*(analyzer: Analyzer, command: string, args: seq[string] = @[], 
                    workingDir: string = ""): tuple[output: string, exitCode: int] =
  ## Execute a nim command and return output and exit code
  try:
    let dir = if workingDir == "": analyzer.projectPath else: workingDir
    let fullCommand = "nim " & command & " " & args.join(" ")
    
    echo fmt"Executing: {fullCommand} in {dir}"
    
    let (output, exitCode) = execCmdEx("nim " & command & " " & args.join(" "), workingDir = dir)
    
    return (output: output, exitCode: exitCode)
  except OSError as e:
    return (output: fmt"Error executing nim command: {e.msg}", exitCode: -1)

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
  ## Generate dependency information using genDepend
  try:
    let cmdResult = analyzer.execNimCommand("genDepend", @[analyzer.projectPath])
    
    if cmdResult.exitCode == 0:
      return %*{
        "status": "success", 
        "dependencies": cmdResult.output,
        "message": "Dependencies generated successfully"
      }
    else:
      return %*{
        "status": "error",
        "message": "Failed to generate dependencies",
        "output": cmdResult.output,
        "exit_code": cmdResult.exitCode
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
import std/[json, osproc, strutils, os, tables]

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
    
    let process = startProcess("nim", dir, [command] & args, nil, {poUsePath, poStdErrToStdOut})
    let output = process.outputStream.readAll()
    let exitCode = process.waitForExit()
    process.close()
    
    return (output: output, exitCode: exitCode)
  except OSError as e:
    return (output: fmt"Error executing nim command: {e.msg}", exitCode: -1)

proc checkSyntax*(analyzer: Analyzer, targetPath: string): JsonNode =
  ## Check syntax and semantics using nim check
  try:
    let result = analyzer.execNimCommand("check", @["--hints:off", targetPath])
    
    if result.exitCode == 0:
      return %*{
        "status": "success",
        "message": "No syntax or semantic errors found",
        "output": result.output
      }
    else:
      return %*{
        "status": "error",
        "message": "Syntax or semantic errors found",
        "output": result.output,
        "exit_code": result.exitCode
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
    
    let result = analyzer.execNimCommand("doc", args)
    
    if result.exitCode == 0:
      return %*{
        "status": "success",
        "message": fmt"Documentation generated in {outDir}",
        "output": result.output
      }
    else:
      return %*{
        "status": "error",
        "message": "Failed to generate documentation",
        "output": result.output,
        "exit_code": result.exitCode
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
    let result = analyzer.execNimCommand("check", @[defUsagesArg, filePath])
    
    if result.exitCode == 0:
      # Parse the output to extract definition information
      let lines = result.output.splitLines()
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
        "raw_output": result.output
      }
    else:
      return %*{
        "status": "error",
        "message": "Failed to find definition",
        "output": result.output,
        "exit_code": result.exitCode
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
    let result = analyzer.execNimCommand("c", @[expandArg, "--verbosity:2", filePath])
    
    return %*{
      "status": if result.exitCode == 0: "success" else: "error",
      "macro_name": macroName,
      "expanded_code": result.output,
      "exit_code": result.exitCode
    }
    
  except Exception as e:
    return %*{
      "status": "error",
      "message": fmt"Failed to expand macro: {e.msg}"
    }

proc getDependencies*(analyzer: Analyzer): JsonNode =
  ## Generate dependency information using genDepend
  try:
    let result = analyzer.execNimCommand("genDepend", @[analyzer.projectPath])
    
    if result.exitCode == 0:
      return %*{
        "status": "success", 
        "dependencies": result.output,
        "message": "Dependencies generated successfully"
      }
    else:
      return %*{
        "status": "error",
        "message": "Failed to generate dependencies",
        "output": result.output,
        "exit_code": result.exitCode
      }
      
  except Exception as e:
    return %*{
      "status": "error",
      "message": fmt"Failed to get dependencies: {e.msg}"
    }

proc dumpConfig*(analyzer: Analyzer): JsonNode =
  ## Dump compiler configuration
  try:
    let result = analyzer.execNimCommand("dump", @["--dump.format:json"])
    
    if result.exitCode == 0:
      try:
        # Try to parse as JSON
        let configJson = parseJson(result.output)
        return %*{
          "status": "success",
          "config": configJson
        }
      except JsonParsingError:
        # If not valid JSON, return as text
        return %*{
          "status": "success", 
          "config_text": result.output
        }
    else:
      return %*{
        "status": "error",
        "message": "Failed to dump config",
        "output": result.output,
        "exit_code": result.exitCode
      }
      
  except Exception as e:
    return %*{
      "status": "error",
      "message": fmt"Failed to dump config: {e.msg}"
    }
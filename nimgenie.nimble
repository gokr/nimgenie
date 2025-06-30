# Package

version       = "0.1.0"
author        = "NimGenie Contributors"
description   = "MCP server for Nim programming with intelligent code analysis and indexing"
license       = "MIT"
srcDir        = "src"
bin           = @["nimgenie"]

# Dependencies

requires "nim >= 2.0.0"
requires "nimcp"
requires "db_connector"
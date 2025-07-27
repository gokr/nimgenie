# Package

version       = "0.1.0"
author        = "Göran Krampe"
description   = "MCP server for Nim programming with intelligent code analysis and indexing"
license       = "MIT"
srcDir        = "src"
bin           = @["nimgenie"]

# Dependencies

requires "nim >= 2.2.4"
requires "file:///home/gokr/tankfeud/nimcp"
requires "https://github.com/gokr/debby" # Adds DateTime support
## MCP Client Library for Testing
## Provides utilities for making real HTTP requests to a running NimGenie MCP server
## Used for integration testing of MCP tools and resources

import json, httpclient, strformat, strutils, random, os, times, net

type
  McpClient* = object
    baseUrl: string
    client: HttpClient
    requestId: int
    
  McpRequest* = object
    jsonrpc: string
    `method`: string
    params: JsonNode
    id: int
    
  McpResponse* = object
    jsonrpc: string
    result: JsonNode
    error: JsonNode
    id: int

  McpError* = object of IOError
    code*: int
    message*: string

proc newMcpClient*(port: int): McpClient =
  ## Create a new MCP client instance
  result.baseUrl = fmt"http://localhost:{port}"
  result.client = newHttpClient()
  result.requestId = 0
  result.client.timeout = 30000  # 30 second timeout

proc close*(client: var McpClient) =
  ## Close the MCP client
  client.client.close()

proc makeRequest*(client: var McpClient, methodName: string, params: JsonNode = newJObject()): JsonNode =
  ## Make an MCP JSON-RPC request
  client.requestId.inc()
  
  let request = %*{
    "jsonrpc": "2.0",
    "method": methodName,
    "params": params,
    "id": client.requestId
  }
  
  client.client.headers = newHttpHeaders({"Content-Type": "application/json"})
  
  try:
    let response = client.client.postContent(client.baseUrl, $request)
    let responseJson = parseJson(response)
    
    if responseJson.hasKey("error"):
      let error = responseJson["error"]
      let code = if error.hasKey("code"): error["code"].getInt() else: 0
      let message = if error.hasKey("message"): error["message"].getStr() else: ""
      var mcpError = newException(McpError, fmt"MCP error {code}: {message}")
      mcpError.code = code
      mcpError.message = message
      raise mcpError
      
    return if responseJson.hasKey("result"): responseJson["result"] else: newJNull()
    
  except HttpRequestError as e:
    raise newException(McpError, fmt"HTTP request failed: {e.msg}")
  except JsonParsingError as e:
    raise newException(McpError, fmt"JSON parsing failed: {e.msg}")

proc makeToolCall*(client: var McpClient, toolName: string, arguments: JsonNode = newJObject()): string =
  ## Make an MCP tool call request
  let params = %*{
    "name": toolName,
    "arguments": arguments
  }
  
  let res = client.makeRequest("tools/call", params)
  
  # Extract content from tool result
  if res.hasKey("content") and res["content"].kind == JArray and res["content"].len > 0:
    let content = res["content"][0]
    if content.hasKey("text"):
      return content["text"].getStr()
  
  return $res

proc requestResource*(client: var McpClient, uri: string): JsonNode =
  ## Request a resource from the MCP server
  let params = %*{
    "uri": uri
  }
  
  return client.makeRequest("resources/read", params)

proc listTools*(client: var McpClient): JsonNode =
  ## List available tools from the MCP server
  return client.makeRequest("tools/list")

proc listResources*(client: var McpClient): JsonNode =
  ## List available resources from the MCP server
  return client.makeRequest("resources/list")

proc initialize*(client: var McpClient, clientInfo: JsonNode = %*{"name": "test-client", "version": "1.0.0"}): JsonNode =
  ## Initialize MCP session
  let params = %*{
    "protocolVersion": "2024-11-05",
    "capabilities": {
      "resources": {"subscribe": true},
      "tools": {}
    },
    "clientInfo": clientInfo
  }
  
  return client.makeRequest("initialize", params)

proc ping*(client: var McpClient): bool =
  ## Ping the MCP server to check if it's responsive
  try:
    # Initialize the server first since tools/list requires initialization
    let initResponse = client.initialize()
    if not initResponse.hasKey("protocolVersion"):
      return false
    
    # Try a simple tools/list request 
    let response = client.makeRequest("tools/list")
    return response.hasKey("tools")
  except McpError, HttpRequestError, IOError:
    return false
  except:
    return false

proc findAvailablePort*(): int =
  ## Find an available port for testing
  randomize()
  for i in 0..100:
    let port = 9000 + rand(1000) 
    # Simple availability check - try to bind to the port
    try:
      let testSocket = newSocket()
      testSocket.bindAddr(Port(port))
      testSocket.close()
      return port
    except OSError:
      continue
  return 9000  # fallback

proc waitForServer*(port: int, timeoutMs: int = 10000): bool =
  ## Wait for server to be available on port
  let startTime = getTime()
  let timeoutDuration = initDuration(milliseconds = timeoutMs)
  
  while getTime() - startTime < timeoutDuration:
    try:
      var client = newMcpClient(port)
      defer: client.close()
      
      if client.ping():
        return true
    except McpError:
      discard
    
    sleep(100)  # Wait 100ms before trying again
  
  return false
    
type Config* = object
  port*: int
  host*: string
  projectPath*: string
  verbose*: bool
  showHelp*: bool
  showVersion*: bool
  database*: string
  databaseHost*: string
  databasePort*: int
  databaseUser*: string
  databasePassword*: string
  databasePoolSize*: int
  noDiscovery*: bool

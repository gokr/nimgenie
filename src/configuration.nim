    
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
  # Embedding configuration
  ollamaHost*: string
  embeddingModel*: string
  embeddingBatchSize*: int
  vectorSimilarityThreshold*: float
  # Dependency tracking configuration
  enableDependencyTracking*: bool  # Enable dependency-based incremental indexing

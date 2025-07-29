    
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
  # External database configuration (separate from NimGenie's internal TiDB)
  externalDbType*: string      # "mysql", "tidb", "postgresql"
  externalDbHost*: string
  externalDbPort*: int  
  externalDbUser*: string
  externalDbPassword*: string
  externalDbDatabase*: string
  externalDbPoolSize*: int

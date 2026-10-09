# The default check set, once every check is defined.
# Checks a package configures (caller lists, tolerance names, sentinel directories) join through `gate`'s `checks`.

const CHECKS = (
    Corpus(),
    ModuleBackEdges(),
    ModuleCycles(),
    ContractsPurity(),
    OwnerUniqueness(),
    ModulePiracy(),
    FileBackEdges(),
    FileSinkable(),
    Sinkable(),
    TupleReturns(),
    DeadCode(),
    BlanketExports(),
    StaleExports(),
    ReachesInternal(),
    PrivateImports(),
    DeclaredNames(),
    DeclaredModules(),
    DeclaredExtensions(),
    ForeignFields(),
    BoxedCaptures(),
    AbstractFields(),
    TypeBranches(),
    StorageOverloads(),
    ExpressionClones(),
    OneProducer(),
    CacheKeys(),
    CachedCalls(),
    DerivedReaders(),
)


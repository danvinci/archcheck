# The default check set, once every check is defined, and the run that holds each check to the kinds it declares.
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
)

# A finding's kind must be one its check declares, or the gate has no severity for it.
function run_checks(ctx, checks = CHECKS)
    findings = Finding[]
    for check in checks
        found = run(check, ctx)
        declared = Set(first(pair) for pair in kinds(check))
        stray = Set(f.kind for f in found if !(f.kind in declared))
        if !isempty(stray)
            listed = sort!(collect(stray))
            throw(ArgumentError("$(typeof(check)) emits undeclared kinds $listed"))
        end
        append!(findings, found)
    end
    findings
end

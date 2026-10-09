# The check registry. Each check is a type with two methods: `run` emits its findings, `kinds` declares
# each kind it emits as `kind => :error | :advisory`. A new check is a struct, both methods, and a CHECKS entry.

# Everything a check may read, built once per run.
struct Context{D<:Tuple}
    index::SourceIndex                      # the one parse of src/ and the entry dirs
    graph::ModuleGraph                      # module rank + cross-module references
    root::Module                            # the package module itself; in mods only when it is the package's one module
    mods::Vector{Module}                    # loaded modules at every depth, rank order; reflection checks only
    sites::Dict{Tuple{Symbol,Symbol},Tuple{String,Int}}   # (module, def) -> path and line
    callgraphs::Dict{Symbol,CallGraph}      # per module, built from the index
    entry_dirs::Vector{String}              # tested/scripted entry points; interface checks scan them too
    methods::Union{Nothing,MethodGraph}     # calls between methods from the declared entries; nothing when none is declared
    observed::Union{Nothing,Observation}    # what the workload did; nothing before it runs, or with no workload
    derived::D                              # the package's declared derived values, each a `Derived`
end

function Context(index::SourceIndex, root::Module, mods; entry_dirs = String[], methods = nothing, derived = ())
    graph = build_module_graph(index)
    callgraphs = Dict(m => build_call_graph(index, m) for m in keys(index.rank))
    sites = def_sites(index)
    Context(index, graph, root, mods, sites, callgraphs, entry_dirs, methods, nothing, derived)
end

# The same context once the workload has run.
function Context(ctx::Context; observed::Observation)
    Context(ctx.index, ctx.graph, ctx.root, ctx.mods, ctx.sites, ctx.callgraphs, ctx.entry_dirs, ctx.methods,
            observed, ctx.derived)
end

abstract type Check end

# Required of every check, with no fallback: a check that declares nothing cannot run.
function kinds end

# When a check runs: `:static` reads the source and the loaded modules, before the workload; `:workload` reads
# what the workload did, so it runs after it.
phase(::Check) = :static

struct Corpus <: Check end
struct ModuleBackEdges <: Check end
struct ModuleCycles <: Check end
struct ContractsPurity <: Check end
struct OwnerUniqueness <: Check end
struct ModulePiracy <: Check end
struct FileBackEdges <: Check end
struct FileSinkable <: Check end
struct Sinkable <: Check end
struct TupleReturns <: Check end
struct DeadCode <: Check
    public_is_entry::Bool   # an exported or public name counts as an entry point
end
DeadCode(; public_is_entry::Bool = false) = DeadCode(public_is_entry)
struct BlanketExports <: Check end
struct StaleExports <: Check end
struct ReachesInternal <: Check end
struct PrivateImports <: Check end
struct BoxedCaptures <: Check end
struct AbstractFields <: Check end
struct ReaderSet{S, R<:Tuple} <: Check
    super::Type{S}  # concrete subtypes of this type must answer each reader
    required::R     # (reader, extra argument types after the subject) pairs
end
struct ScanSeeds{D<:Tuple} <: Check
    directories::D  # source directories relative to the repository root, or absolute paths
end
# Modules that do not reference one another, each counted with the modules nested in it; import-linter's
# `independence` contract is the precedent. The constructor refuses a set of one and a member inside another.
struct Independent{N} <: Check
    modules::NTuple{N,Symbol}   # dotted module keys below the package
    function Independent(modules::Symbol...)
        length(modules) >= 2 || throw(ArgumentError("Independent needs two or more modules, got $modules"))
        allunique(modules) || throw(ArgumentError("Independent names a module twice: $modules"))
        for outer in modules, inner in modules
            outer !== inner && is_within_module(inner, outer) &&
                throw(ArgumentError("Independent names $inner, which is nested in $outer"))
        end
        new{length(modules)}(modules)
    end
end
struct DeclaredNames <: Check end
struct DeclaredModules <: Check end
struct DeclaredExtensions <: Check end
struct ForeignFields <: Check end
struct TypeBranches <: Check end

# A hole in the corpus makes every other result untrustworthy, so each one is an error.
function run(::Corpus, ctx)
    files = check_corpus(ctx.index)
    modules = check_module_corpus(ctx.mods, ctx.index.rank)
    vcat(files, modules)
end
kinds(::Corpus) = (:unparsed => :error, :missing_include => :error, :nonliteral_include => :error,
                   :unranked_file => :error, :unranked_module => :error)

run(::ModuleBackEdges, ctx) = check_backedges(ctx.graph)
kinds(::ModuleBackEdges) = (:back_edge => :error,)

run(::ModuleCycles, ctx) = check_cycles(ctx.graph)
kinds(::ModuleCycles) = (:cycle => :error,)

run(::ContractsPurity, ctx) = check_contracts_logic(ctx.index)
kinds(::ContractsPurity) = (:contracts_logic => :error,)

run(::OwnerUniqueness, ctx) = check_dup_owners(ctx.mods, ctx.graph.rank)
kinds(::OwnerUniqueness) = (:duplicate_owner => :error,)

run(::ModulePiracy, ctx) = check_module_piracy(package_modules(ctx); repo = ctx.index.repo)
kinds(::ModulePiracy) = (:module_piracy => :error,)

run(::TupleReturns, ctx) = check_tuple_returns(ctx.index)
kinds(::TupleReturns) = (:tuple_return => :advisory,)

run(check::DeadCode, ctx) = check_dead_code_static(ctx.index; public_is_entry = check.public_is_entry)
kinds(::DeadCode) = (:dead_code => :advisory,)

run(::BlanketExports, ctx) = check_blanket_exports(ctx.index)
kinds(::BlanketExports) = (:blanket_export => :advisory,)

run(::StaleExports, ctx) = check_stale_exports(ctx.mods)
kinds(::StaleExports) = (:stale_export => :advisory,)

run(::ReachesInternal, ctx) = check_reaches_internal(ctx.index, ctx.mods; entry_dirs = ctx.entry_dirs)
kinds(::ReachesInternal) = (:reaches_internal => :advisory,)

run(::PrivateImports, ctx) = check_private_imports(ctx.index)
kinds(::PrivateImports) = (:private_import => :advisory,)

run(::BoxedCaptures, ctx) = check_boxed_captures(ctx.mods; repo = ctx.index.repo)
kinds(::BoxedCaptures) = (:boxed_capture => :advisory,)

run(::AbstractFields, ctx) = check_abstract_fields(ctx.mods, ctx.sites)
kinds(::AbstractFields) = (:abstract_field => :advisory,)

run(check::ReaderSet, ctx) =
    check_reader_set(ctx.mods, check.super, check.required; sites = ctx.sites)
kinds(::ReaderSet) = (:reader_set => :error,)

run(check::ScanSeeds, ctx) = check_scan_seeds(ctx.index; directories = check.directories)
kinds(::ScanSeeds) = (:scan_seed => :advisory,)

run(check::Independent, ctx) = check_independent(ctx.graph, check.modules)
kinds(::Independent) = (:sibling_edge => :error,)

run(::DeclaredNames, ctx) = check_declared_names(ctx.index, ctx.mods)
kinds(::DeclaredNames) = (:undeclared_name => :advisory,)

run(::DeclaredModules, ctx) = check_declared_modules(ctx.index)
kinds(::DeclaredModules) = (:undeclared_module => :advisory,)

run(::DeclaredExtensions, ctx) = check_declared_extensions(package_modules(ctx); repo = ctx.index.repo)
kinds(::DeclaredExtensions) = (:private_extension => :error,)

run(::ForeignFields, ctx) = check_foreign_fields(ctx.index, ctx.mods)
kinds(::ForeignFields) = (:foreign_field => :advisory,)

run(::TypeBranches, ctx) = check_type_branches(ctx.index)
kinds(::TypeBranches) = (:type_branch => :advisory,)

run(::FileBackEdges, ctx) = collect_modules(check_file_backedges, ctx)
kinds(::FileBackEdges) = (:file_backedge => :advisory,)

function run(::FileSinkable, ctx)
    judge = cg -> check_file_sinkable(cg, ctx.sites, ctx.methods, ctx.index.repo)
    collect_modules(judge, ctx)
end
kinds(::FileSinkable) = (:file_sinkable => :advisory,)

# sinkable and extract-candidate are one analysis at two granularities, so one check emits both.
function run(::Sinkable, ctx)
    body_calls = Dict(m => cg.refs for (m, cg) in ctx.callgraphs)
    sink = check_sinkable(ctx.mods, ctx.graph.rank, body_calls, ctx.sites; repo = ctx.index.repo)
    vcat(sink, check_extract_candidates(sink))
end
kinds(::Sinkable) = (:sinkable => :advisory, :extract_candidate => :advisory)

function collect_modules(f, ctx)
    findings = Finding[]
    for m in sort(collect(keys(ctx.index.rank)), by = m -> ctx.index.rank[m])
        append!(findings, f(ctx.callgraphs[m]))
    end
    findings
end

# Each kind the checks declare, at its severity. `error_kinds` promotes kinds to :error and cannot demote one;
# naming a kind no check declares throws, so a typo cannot pass as a promotion.
function severities(checks; error_kinds = ())
    table = Dict{Symbol,Symbol}()
    for check in checks, (kind, severity) in kinds(check)
        severity in SEVERITIES || throw(ArgumentError("$(typeof(check)) declares $kind as $severity"))
        table[kind] = severity
    end
    for kind in error_kinds
        haskey(table, kind) || throw(ArgumentError("error_kinds names $kind, which no running check declares"))
        table[kind] = :error
    end
    table
end

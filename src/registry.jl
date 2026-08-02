# The check registry. Each check is a type; `run` is its one method. Adding a check is a struct, a
# method, and an entry in CHECKS - the gate never changes.

# Everything a check may read, built once per run.
struct Context
    index::SourceIndex                      # the one parse of src/ and the entry dirs
    graph::ModuleGraph                      # module rank + cross-module references
    mods::Vector{Module}                    # loaded submodules, rank order; reflection checks only
    sites::Dict{Tuple{Symbol,Symbol},Tuple{String,Int}}   # (module, def) -> path and line
    callgraphs::Dict{Symbol,CallGraph}      # per module, built from the index
    entry_dirs::Vector{String}              # tested/scripted entry points; interface checks scan them too
end

function Context(index::SourceIndex, mods; entry_dirs = String[])
    graph = build_module_graph(index)
    callgraphs = Dict(m => build_call_graph(index, m) for m in keys(index.rank))
    sites = def_sites(index)
    Context(index, graph, mods, sites, callgraphs, entry_dirs)
end

abstract type Check end

struct Corpus <: Check end
struct ModuleBackEdges <: Check end
struct ModuleCycles <: Check end
struct ContractsPurity <: Check end
struct OwnerUniqueness <: Check end
struct FileBackEdges <: Check end
struct FileSinkable <: Check end
struct Sinkable <: Check end
struct TupleReturns <: Check end
struct DeadCode <: Check end
struct BlanketExports <: Check end
struct StaleExports <: Check end
struct ReachesInternal <: Check end
struct BoxedCaptures <: Check end
struct AbstractFields <: Check end

run(::Corpus, ctx) = check_corpus(ctx.index)
run(::ModuleBackEdges, ctx) = check_backedges(ctx.graph)
run(::ModuleCycles, ctx) = check_cycles(ctx.graph)
run(::ContractsPurity, ctx) = check_contracts_logic(ctx.index)
run(::OwnerUniqueness, ctx) = check_dup_owners(ctx.mods, ctx.graph.rank)
run(::TupleReturns, ctx) = check_tuple_returns(ctx.index)
run(::DeadCode, ctx) = check_dead_code_static(ctx.index)
run(::BlanketExports, ctx) = check_blanket_exports(ctx.index)
run(::StaleExports, ctx) = check_stale_exports(ctx.mods)
run(::ReachesInternal, ctx) = check_reaches_internal(ctx.index, ctx.mods; entry_dirs = ctx.entry_dirs)
run(::BoxedCaptures, ctx) = check_boxed_captures(ctx.mods; repo = ctx.index.repo)
run(::AbstractFields, ctx) = check_abstract_fields(ctx.mods, ctx.sites)

run(::FileBackEdges, ctx) = collect_modules(check_file_backedges, ctx)
run(::FileSinkable, ctx) = collect_modules(cg -> check_file_sinkable(cg, ctx.sites), ctx)

# sinkable and extract-candidate are one analysis at two granularities, so one check emits both.
function run(::Sinkable, ctx)
    body_calls = Dict(m => cg.refs for (m, cg) in ctx.callgraphs)
    sink = check_sinkable(ctx.mods, ctx.graph.rank, body_calls, ctx.sites; repo = ctx.index.repo)
    vcat(sink, check_extract_candidates(sink))
end

function collect_modules(f, ctx)
    findings = Finding[]
    for m in sort(collect(keys(ctx.index.rank)), by = m -> ctx.index.rank[m])
        append!(findings, f(ctx.callgraphs[m]))
    end
    findings
end

const CHECKS = (
    Corpus(),
    ModuleBackEdges(),
    ModuleCycles(),
    ContractsPurity(),
    OwnerUniqueness(),
    FileBackEdges(),
    FileSinkable(),
    Sinkable(),
    TupleReturns(),
    DeadCode(),
    BlanketExports(),
    StaleExports(),
    ReachesInternal(),
    BoxedCaptures(),
    AbstractFields(),
)

function run_checks(ctx, checks = CHECKS)
    findings = Finding[]
    for check in checks
        append!(findings, run(check, ctx))
    end
    findings
end

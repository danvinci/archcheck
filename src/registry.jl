# The check contract, the context every check reads, and the default checks' `run` and `kinds` methods.

"""Everything one run of the gate builds for a check to read."""
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

"""What `gate` builds for `pkg`, so `run(check, Context(pkg))` runs one check without the gate. `entries` seed the method graph."""
function Context(pkg::Module; src = joinpath(pkgdir(pkg), "src"), entry_dirs = String[], entries = (), derived = ())
    pkg_name = string(nameof(pkg))
    spine = joinpath(src, pkg_name * ".jl")
    root = nameof(pkg)
    rank, dir2mod = package_layout(spine, root)
    index = build_source_index(src, rank, dir2mod; entry_dirs, root)
    ordered = sort(collect(keys(index.rank)), by = m -> index.rank[m])
    mods = Module[loaded_module(pkg, m) for m in ordered]
    project = package_modules(pkg, mods)
    methods = isempty(entries) ? nothing : method_graph(entries, project, value_names(index))
    Context(index, pkg, mods; entry_dirs, methods, derived)
end

# The same context once the workload has run.
function Context(ctx::Context; observed::Observation)
    Context(ctx.index, ctx.graph, ctx.root, ctx.mods, ctx.sites, ctx.callgraphs, ctx.entry_dirs, ctx.methods,
            observed, ctx.derived)
end

"""A rule over a package: a subtype declares the findings it may emit and produces them, and names its stage when it reads a workload. A package passes its own through the `checks` keyword."""
abstract type Check end

"""Each kind of finding a check emits, as `kind => :error` or `kind => :advisory`. Every check declares them; a finding of an undeclared kind throws."""
function kinds end

"""A check's findings over the parsed and loaded package, as a `Vector{Finding}`. Given a context built from the package alone, it works without the full gate."""
function run end

"""When a check reads the package: `:static` by default, before the workload, from the parse and the loaded modules; `:workload` after it, from `ctx.observed`."""
phase(::Check) = :static

# A finding's kind must be one its check declares, or the gate has no severity for it.
function run_checks(ctx, checks)
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

"""Runs in `CHECKS`. A file that fails to parse, an include of a missing file or a non-string, or a file or module the spine leaves unranked."""
struct Corpus <: Check end
"""Runs in `CHECKS`. A module references another that finishes loading at the same rank or later."""
struct ModuleBackEdges <: Check end
"""Runs in `CHECKS`. Modules reference one another in a cycle."""
struct ModuleCycles <: Check end
"""Runs in `CHECKS`. A function in the contracts module does more than name a type and its interface."""
struct ContractsPurity <: Check end
"""Runs in `CHECKS`. Two modules export one name bound to different objects."""
struct OwnerUniqueness <: Check end
"""Runs in `CHECKS`. A method extends a function owned outside the defining module, on argument types owned outside that module's subtree."""
struct ModulePiracy <: Check end
"""Runs in `CHECKS`. A file calls into a file the wrapper includes later."""
struct FileBackEdges <: Check end
"""Runs in `CHECKS`. Every callee of a definition lives in one lower-ranked file, and at most half the module's files reach that file."""
struct FileSinkable <: Check end
"""Runs in `CHECKS`. A definition touches only modules that rank below its own, or one file holds several such definitions."""
struct Sinkable <: Check end
"""Runs in `CHECKS`. A function body ends in a bare tuple of three or more slots."""
struct TupleReturns <: Check end
"""Runs in `CHECKS`. A top-level definition has no reference in the source or the entry directories. `public_is_entry`, on by default, counts an exported or public name as a reference; an application turns it off."""
struct DeadCode <: Check
    public_is_entry::Bool   # an exported or public name counts as an entry point
end
DeadCode(; public_is_entry::Bool = true) = DeadCode(public_is_entry)
"""Runs in `CHECKS`. A module wrapper exports its whole namespace with `names` and `all` set."""
struct BlanketExports <: Check end
"""Runs in `CHECKS`. An exported name is undefined."""
struct StaleExports <: Check end
"""Runs in `CHECKS`. Source refers to a name its module leaves unexported and unmarked public."""
struct ReachesInternal <: Check end
"""Runs in `CHECKS`. An import binds a name whose leading underscore marks it private."""
struct PrivateImports <: Check end
"""Runs in `CHECKS`. A closure assigns a captured local in more than one place, so lowering boxes it."""
struct BoxedCaptures <: Check end
"""Runs in `CHECKS`. A struct field's stored type leaves dispatch open."""
struct AbstractFields <: Check end
"""Configured through `gate(...; checks)` with a supertype and the readers its concrete subtypes must answer. A subtype with no matching method is a finding."""
struct ReaderSet{S, R<:Tuple} <: Check
    super::Type{S}  # concrete subtypes of this type must answer each reader
    required::R     # (reader, extra argument types after the subject) pairs
end
"""Configured through `gate(...; checks)` with the directories to read. Fixed integer counts in one method form a uniform grid."""
struct ScanSeeds{D<:Tuple} <: Check
    directories::D  # source directories relative to the repository root, or absolute paths
end
"""Configured through `gate(...; checks)` with two or more modules. A reference from one, or from a module nested in it, to another is a finding."""
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
"""Runs in `CHECKS`. A reference reaches a name the module it is written through leaves unexported and unmarked public."""
struct DeclaredNames <: Check end
"""Runs in `CHECKS`. A reference reaches a module the wrapper's using and import lines omit."""
struct DeclaredModules <: Check end
"""Runs in `CHECKS`. A method is added to a function its owner leaves unmarked public or undocumented."""
struct DeclaredExtensions <: Check end
"""Runs in `CHECKS`. Code reads a field of a struct another module owns."""
struct ForeignFields <: Check end
"""Runs in `CHECKS`. A runtime type test on a method's own parameter picks a path."""
struct TypeBranches <: Check end

# A hole in the corpus makes every other result untrustworthy, so each one is an error.
function run(::Corpus, ctx)
    files = check_corpus(ctx.index)
    modules = check_module_corpus(package_modules(ctx), ctx.index.rank; repo = ctx.index.repo)
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

run(::StaleExports, ctx) = check_stale_exports(package_modules(ctx); repo = ctx.index.repo)
kinds(::StaleExports) = (:stale_export => :advisory,)

run(::ReachesInternal, ctx) = check_reaches_internal(ctx.index, ctx.mods, nameof(ctx.root); entry_dirs = ctx.entry_dirs)
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

# The check contract, the context every check reads, and the default checks' `run` and `kinds` methods.

"""Everything one run of the gate builds for a check to read."""
struct Context{D<:Tuple}
    index::SourceIndex                      # the one parse of src/ and the entry dirs
    root::Module                            # the package module itself
    mods::Vector{Module}                    # loaded modules at every depth, root and extensions too, rank order
    sites::Dict{Tuple{Symbol,Symbol},Tuple{String,Int}}   # (module, def) -> path and line
    callgraphs::Dict{Symbol,CallGraph}      # per module, built from the index
    defined::Vector{Method}                 # every live method the package's modules define, in source order
    added::Vector{Method}                   # live methods other modules add on functions the package owns
    nested::Vector{Method}                  # live methods an unranked direct child defines, in source order
    recorded::RecordedPaths                 # repo-relative path of each file the three method lists record
    methods::Union{Nothing,MethodGraph}     # calls between methods from the declared entries; nothing when none is declared
    observed::Union{Nothing,Observation}    # what the workload did; nothing before it runs, or with no workload
    derived::D                              # the package's declared derived values, each a `Derived`
end

# One walk of the method table: the live methods the package's modules define, in source order, the live
# methods other modules add on functions those modules own, and the live methods an unranked direct child defines.
function read_methods(mods)
    project = Set{Module}(mods)
    defined = Method[]
    foreign = Method[]
    nested = Method[]
    each_loaded_method() do method
        classify_method!(defined, foreign, nested, method, project)
    end
    finish_methods(defined, foreign, nested, project)
end

function Context(index::SourceIndex, root::Module, mods; methods = nothing, derived = ())
    callgraphs = Dict(m => build_call_graph(index, m) for m in keys(index.rank))
    sites = def_sites(index)
    modules = package_modules(root, mods)
    defined, added, nested = read_methods(modules)
    recorded = recorded_paths(index.repo, (defined, added, nested))
    Context(index, root, mods, sites, callgraphs, defined, added, nested, recorded, methods, nothing, derived)
end

"""What `gate` builds for `pkg`, so `run(check, Context(pkg))` runs one check without the gate. `entries` seed the method graph."""
function Context(pkg::Module; src = joinpath(pkgdir(pkg), "src"), entry_dirs = String[], entries = (), derived = ())
    parses = package_parses(src)
    parse_package!(parses, source_root(src), entry_dirs)
    extensions = loaded_extensions(pkg, parses.repo)
    index = build_source_index(parses, src; entry_dirs, package = pkg, extensions)
    ordered = sort(collect(keys(index.rank)), by = m -> index.rank[m])
    mods = Module[]
    for key in ordered
        loaded = loaded_module(pkg, key)
        isnothing(loaded) || push!(mods, loaded)
    end
    unwalked = Context(index, pkg, mods; derived)
    with_method_graph(unwalked, entries)
end

# The same context once the workload has run, with the method lists `observe` read after it: methods the workload
# defines are in that walk.
function Context(ctx::Context; observed::Observation, census)
    lists = (census.defined, census.added, census.nested)
    recorded = recorded_paths(ctx.index.repo, lists)
    Context(ctx.index, ctx.root, ctx.mods, ctx.sites, ctx.callgraphs, census.defined, census.added, census.nested,
            recorded, ctx.methods, observed, ctx.derived)
end

# The context with the calls between methods from `entries`; unchanged when none is declared. The walk makes a
# specialization of each method it walks, so a workload's reach and compiled calls are read before it.
function with_method_graph(ctx::Context, entries)
    isempty(entries) && return ctx
    project = package_modules(ctx)
    names = value_names(ctx.index)
    methods = method_graph(entries, project, names, ctx.defined)
    if !isnothing(ctx.observed)
        add_compiled_edges!(methods, ctx.observed.specializations, project)
    end
    Context(ctx.index, ctx.root, ctx.mods, ctx.sites, ctx.callgraphs, ctx.defined, ctx.added, ctx.nested, ctx.recorded,
            methods, ctx.observed, ctx.derived)
end

"""A rule over a package: a subtype declares the findings it may emit and produces them, and names its stage when it reads a workload. A package passes its own through the `checks` keyword."""
abstract type Check end

"""Each kind of finding a check emits, as `kind => :error` or `kind => :advisory`. Every check declares them; a finding of an undeclared kind throws."""
function kinds end

"""A check's findings over the parsed and loaded package, as a `Vector{Finding}`. Given a context built from the package alone, it works without the full gate."""
function run end

"""When a check reads the package: `:static` by default, before the workload, from the parse and the loaded modules; `:graph` after the method graph's walk, which follows the workload, from `ctx.methods`; `:workload` then too, from `ctx.observed`."""
phase(::Check) = :static

# A finding's kind must be one its check declares, or the gate has no severity for it.
function declared_findings(check, found)
    declared = Set(first(pair) for pair in kinds(check))
    stray = Set(f.kind for f in found if !(f.kind in declared))
    if !isempty(stray)
        listed = sort!(collect(stray))
        throw(ArgumentError("$(typeof(check)) emits undeclared kinds $listed"))
    end
    found
end

function run_checks(ctx, checks)
    findings = Finding[]
    for check in checks
        found = run(check, ctx)
        declared = declared_findings(check, found)
        append!(findings, declared)
    end
    findings
end

# The static checks only read the finished `Context`, so with more than one thread each runs as its own task; their
# findings join in the checks' order.
function run_static_checks(ctx, checks)
    results = ordered_results(run, Any, checks, ctx)
    findings = Finding[]
    for (check, found) in zip(checks, results)
        declared = declared_findings(check, found)
        append!(findings, declared)
    end
    findings
end

"""Runs in `CHECKS`. A file that fails to parse; for a load Julia kept no include record of, an include of a missing file or of a path computed at load; a src/ file no include call in loaded code names, outside every directory such a computed include names; an include Julia recorded that no include call the parse reads ran. A loaded module the index leaves unranked whose `module` line or a method of it Julia records in the repository, outside the files no include names. A module another package's macro fills with its own code holds no package source."""
struct Corpus <: Check end
"""Runs in `CHECKS`. A module references another that finishes loading at the same rank or later. A reference to an enclosing module counts only with `strict`, which holds every module to the layering."""
struct ModuleBackEdges <: Check
    strict::Bool   # a reference to an enclosing module counts
end
ModuleBackEdges(; strict::Bool = false) = ModuleBackEdges(strict)
"""Runs in `CHECKS`. Modules reference one another in a cycle. A reference to an enclosing module counts only with `strict`."""
struct ModuleCycles <: Check
    strict::Bool   # a reference to an enclosing module counts
end
ModuleCycles(; strict::Bool = false) = ModuleCycles(strict)
"""Runs in `CHECKS`. Two modules export one name bound to different objects; a name a module only declares `public` is no export. A module and one it encloses count only with `strict`."""
struct OwnerUniqueness <: Check
    strict::Bool   # a module and one it encloses count as two owners
end
OwnerUniqueness(; strict::Bool = false) = OwnerUniqueness(strict)
"""Runs in `CHECKS`. A method extends a function owned outside the package on argument types owned outside it. With `strict`, the defining module stands for the package: its own functions, its own subtree's types. A module in the package's `ext/` directory owns what it defines and what the root owns, in either mode."""
struct ModulePiracy <: Check
    strict::Bool   # ownership is the defining module's rather than the package's
end
ModulePiracy(; strict::Bool = false) = ModulePiracy(strict)
"""Runs in `CHECKS`. A method reads a name the package's load binds only after the method's file is done: in a file it includes later, an import placed later, or a module it opens later."""
struct FileBackEdges <: Check end
"""Runs in `CHECKS`. Every function a definition calls lives in one lower-ranked file. The module's types and the package's exported or public names are vocabulary and place nothing."""
struct FileSinkable <: Check end
"""Runs in `CHECKS`. A definition touches only modules that rank below its own, and no package its extension alone loads, or one file holds several such definitions."""
struct Sinkable <: Check end
"""Runs in `CHECKS`. A function body ends in a bare tuple of three or more slots."""
struct TupleReturns <: Check end
"""Runs in `CHECKS`. A top-level function no root reaches through the names code reads, cycles included. A definition is judged only when a loaded method at its line adds to the package's own function of its name; a method added through an alias to another module's function, a form a macro rewrites, and one in an extension Julia has not loaded stay unjudged, and what they read is a root. Roots are the names entry scripts and extensions Julia has not loaded read, names read outside any function, `__init__`, methods on functions or types the package does not judge, and, with `public_is_entry` on by default, exported or public names; an application turns it off."""
struct DeadCode <: Check
    public_is_entry::Bool   # an exported or public name counts as an entry point
end
DeadCode(; public_is_entry::Bool = true) = DeadCode(public_is_entry)
"""Runs in `CHECKS`. A module wrapper exports its whole namespace with `names` and `all` set."""
struct BlanketExports <: Check end
"""Runs in `CHECKS`. An exported name is undefined; a name a module only declares `public` is no export."""
struct StaleExports <: Check end
"""Runs in `CHECKS`. Code reads a name through a module that neither exports it nor declares it public, one of the package's modules or any other: a step of a qualified path, a qualified method or macro name, or a name a `using` or `import` clause binds, in source files and entry scripts alike. `allowed` names the outside modules whose internals the package reads on purpose."""
struct ReachesInternal{N} <: Check
    allowed::NTuple{N,Module}   # outside modules whose internal names the package reads on purpose
end
ReachesInternal(; allowed::Tuple{Vararg{Module}} = ()) = ReachesInternal(allowed)
"""Runs in `CHECKS`. A closure assigns a captured local in more than one place, so lowering boxes it."""
struct BoxedCaptures <: Check end
"""Runs in `CHECKS`. A method names an argument or assigns a local that no read resolves to, or every method of a function the package owns leaves one position unread under one declared type. A name starting with `_` is exempt from the first two. A name a Base or Core macro call writes counts as read, and so does one any other macro's expansion holds, or every name when that expansion throws."""
struct UnusedBindings <: Check end
"""Runs in `CHECKS`. A struct field's stored type leaves dispatch open. A container's own element types decide: a concrete element closes it whatever that element holds, so `Vector{Vector{Any}}` is closed."""
struct AbstractFields <: Check end
"""Configured through `gate(...; checks)` with a supertype and the readers its concrete subtypes must answer. A subtype with no matching method is a finding."""
struct ReaderSet{S, R<:Tuple} <: Check
    super::Type{S}  # concrete subtypes of this type must answer each reader
    required::R     # (reader, extra argument types after the subject) pairs
end
"""Configured through `gate(...; checks)` with two or more modules. A reference from one, or from a module nested in it, to another is a finding."""
struct Independent{N} <: Check
    modules::NTuple{N,Symbol}   # dotted module keys below the package
    function Independent(modules::Symbol...)
        length(modules) >= 2 || throw(ArgumentError("Independent needs two or more modules, got $modules"))
        allunique(modules) || throw(ArgumentError("Independent names a module twice: $modules"))
        new{length(modules)}(modules)
    end
end
"""Runs in `CHECKS`. A module with a wrapper file reaches another module that no `using` or `import` line of its own names, in any of its files."""
struct DeclaredModules <: Check end
"""Configured through `gate(...; checks)` by a package that holds its modules apart. A method is added to a function another of its modules owns and leaves unmarked public or undocumented."""
struct DeclaredExtensions <: Check end
"""Runs in `CHECKS`. Code reads a field of a struct another module owns."""
struct ForeignFields <: Check end
"""Runs in `CHECKS`. A runtime type test on a method's own parameter picks a path."""
struct TypeBranches <: Check end

# A hole in the corpus makes every other result untrustworthy, so each one is an error.
function run(::Corpus, ctx)
    root = nameof(ctx.root)
    files = check_corpus(ctx.index, root)
    unincluded = Set(normpath(path) for path in ctx.index.unincluded)
    modules = check_module_corpus(package_modules(ctx), ctx.index.rank, ctx.nested, unincluded;
                                  recorded = ctx.recorded)
    vcat(files, modules)
end
kinds(::Corpus) = (:unparsed => :error, :missing_include => :error, :nonliteral_include => :error,
                   :unranked_file => :error, :unranked_module => :error)

run(check::ModuleBackEdges, ctx) = check_backedges(ctx.index, ctx.root; strict = check.strict)
kinds(::ModuleBackEdges) = (:back_edge => :error,)

run(check::ModuleCycles, ctx) = check_cycles(ctx.index, ctx.root; strict = check.strict)
kinds(::ModuleCycles) = (:cycle => :error,)

run(check::OwnerUniqueness, ctx) = check_dup_owners(ctx.mods, ctx.index.rank; strict = check.strict)
kinds(::OwnerUniqueness) = (:duplicate_owner => :error,)

run(check::ModulePiracy, ctx) = check_module_piracy(ctx.defined, ctx.root; recorded = ctx.recorded, strict = check.strict)
kinds(::ModulePiracy) = (:module_piracy => :error,)

run(::TupleReturns, ctx) = check_tuple_returns(ctx.index)
kinds(::TupleReturns) = (:tuple_return => :advisory,)

function run(check::DeadCode, ctx)
    modules = package_modules(ctx)
    owned = owned_functions_by_site(ctx.defined, modules, ctx.recorded)
    check_dead_code_static(ctx.index, modules, owned; public_is_entry = check.public_is_entry)
end
kinds(::DeadCode) = (:dead_code => :advisory,)

run(::BlanketExports, ctx) = check_blanket_exports(ctx.index)
kinds(::BlanketExports) = (:blanket_export => :advisory,)

run(::StaleExports, ctx) = check_stale_exports(package_modules(ctx); repo = ctx.index.repo)
kinds(::StaleExports) = (:stale_export => :advisory,)

# One compiled run for every length of `allowed`.
function run(@nospecialize(check::ReachesInternal), ctx)
    allowed = collect(Module, check.allowed)
    check_reaches_internal(ctx.index, ctx.mods, ctx.root; allowed)
end
kinds(::ReachesInternal) = (:reaches_internal => :advisory,)

run(::BoxedCaptures, ctx) = check_boxed_captures(ctx.defined; recorded = ctx.recorded)
kinds(::BoxedCaptures) = (:boxed_capture => :advisory,)

function run(::UnusedBindings, ctx)
    modules = package_modules(ctx)
    project = Set{Module}(modules)
    owned = owned_functions(ctx.defined, project)
    check_unused_bindings(ctx.index, ctx.defined, ctx.added, project, owned, ctx.root, ctx.recorded)
end
kinds(::UnusedBindings) = (:unused_argument => :advisory, :unused_local => :advisory,
                           :ignored_parameter => :advisory)

run(::AbstractFields, ctx) = check_abstract_fields(package_modules(ctx), ctx.sites, ctx.index)
kinds(::AbstractFields) = (:abstract_field => :advisory,)

run(check::ReaderSet, ctx) =
    check_reader_set(package_modules(ctx), check.super, check.required; sites = ctx.sites)
kinds(::ReaderSet) = (:reader_set => :error,)

run(check::Independent, ctx) = check_independent(ctx.index, ctx.root, check.modules)
kinds(::Independent) = (:sibling_edge => :error,)

run(::DeclaredModules, ctx) = check_declared_modules(ctx.index)
kinds(::DeclaredModules) = (:undeclared_module => :advisory,)

function run(::DeclaredExtensions, ctx)
    modules = package_modules(ctx)
    check_declared_extensions(ctx.defined, modules; recorded = ctx.recorded)
end
kinds(::DeclaredExtensions) = (:private_extension => :error,)

run(::ForeignFields, ctx) = check_foreign_fields(ctx.index, ctx.mods)
kinds(::ForeignFields) = (:foreign_field => :advisory,)

run(::TypeBranches, ctx) = check_type_branches(ctx.index, ctx.defined, ctx.recorded)
kinds(::TypeBranches) = (:type_branch => :advisory,)

run(::FileBackEdges, ctx) = check_file_backedges(ctx.index, ctx.mods, ctx.root)
kinds(::FileBackEdges) = (:file_backedge => :advisory,)

function run(::FileSinkable, ctx)
    published = published_names(ctx.index)
    judge = function (cg::CallGraph)
        vocabulary = union(cg.types, cg.shared, published)
        check_file_sinkable(cg, ctx.sites, ctx.methods, ctx.recorded, vocabulary)
    end
    collect_modules(judge, ctx)
end
kinds(::FileSinkable) = (:file_sinkable => :advisory,)
phase(::FileSinkable) = :graph

# sinkable and extract-candidate are one analysis at two granularities, so one check emits both.
function run(::Sinkable, ctx)
    body_calls = Dict(m => cg.refs for (m, cg) in ctx.callgraphs)
    grouped = methods_by_function(ctx.defined)
    sink = check_sinkable(ctx.mods, ctx.index.rank, body_calls, ctx.sites, grouped, ctx.root;
                          recorded = ctx.recorded)
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

# The check registry. Each check is a type with two methods: `run` emits its findings, `kinds` declares
# each kind it emits as `kind => :error | :advisory`. A new check is a struct, both methods, and a CHECKS entry.

# Everything a check may read, built once per run.
struct Context
    index::SourceIndex                      # the one parse of src/ and the entry dirs
    graph::ModuleGraph                      # module rank + cross-module references
    root::Module                            # the package module itself; it has no rank, so it is not in mods
    mods::Vector{Module}                    # loaded modules at every depth, rank order; reflection checks only
    sites::Dict{Tuple{Symbol,Symbol},Tuple{String,Int}}   # (module, def) -> path and line
    callgraphs::Dict{Symbol,CallGraph}      # per module, built from the index
    entry_dirs::Vector{String}              # tested/scripted entry points; interface checks scan them too
end

function Context(index::SourceIndex, root::Module, mods; entry_dirs = String[])
    graph = build_module_graph(index)
    callgraphs = Dict(m => build_call_graph(index, m) for m in keys(index.rank))
    sites = def_sites(index)
    Context(index, graph, root, mods, sites, callgraphs, entry_dirs)
end

abstract type Check end

# Required of every check, with no fallback: a check that declares nothing cannot run.
function kinds end

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
struct DeadCode <: Check end
struct BlanketExports <: Check end
struct StaleExports <: Check end
struct ReachesInternal <: Check end
struct PrivateImports <: Check end
struct BoxedCaptures <: Check end
struct AbstractFields <: Check end
struct ReaderSet <: Check
    super::Type     # concrete subtypes of this type must answer each reader
    required::Tuple # (reader, extra argument types after the subject) pairs
end
struct ScanSeeds <: Check
    directories::Tuple # source directories relative to the repository root, or absolute paths
end
# Modules that do not reference one another, each counted with the modules nested in it; import-linter's
# `independence` contract is the precedent. The constructor refuses a set of one and a member inside another.
struct Independent <: Check
    modules::Tuple{Vararg{Symbol}}   # dotted module keys below the package
    function Independent(modules::Symbol...)
        length(modules) >= 2 || throw(ArgumentError("Independent needs two or more modules, got $modules"))
        allunique(modules) || throw(ArgumentError("Independent names a module twice: $modules"))
        for outer in modules, inner in modules
            outer !== inner && is_within_module(inner, outer) &&
                throw(ArgumentError("Independent names $inner, which is nested in $outer"))
        end
        new(modules)
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

run(::ModulePiracy, ctx) = check_module_piracy([ctx.root; ctx.mods]; repo = ctx.index.repo)
kinds(::ModulePiracy) = (:module_piracy => :error,)

run(::TupleReturns, ctx) = check_tuple_returns(ctx.index)
kinds(::TupleReturns) = (:tuple_return => :advisory,)

run(::DeadCode, ctx) = check_dead_code_static(ctx.index)
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

run(::DeclaredExtensions, ctx) = check_declared_extensions([ctx.root; ctx.mods]; repo = ctx.index.repo)
kinds(::DeclaredExtensions) = (:private_extension => :error,)

run(::ForeignFields, ctx) = check_foreign_fields(ctx.index, ctx.mods)
kinds(::ForeignFields) = (:foreign_field => :advisory,)

# type-branch: an `isa` or `typeof` test on the method's own parameter picks a path that dispatch should pick.
# A throw-only branch validates input; lambda parameters, loop targets and destructured names are not the method's.
function run(::TypeBranches, ctx)
    findings = Finding[]
    discarded = IdSet{JS.SyntaxNode}()   # nodes whose value is discarded; only there do `&&` and `||` pick a path
    function visit(file, node, owner, params)
        kids = child_nodes(node)
        kids === nothing && return
        k = JS.kind(node)
        is_statement = node in discarded
        if k == K"block"
            union!(discarded, is_statement ? kids : kids[1:end-1])
        elseif k == K"for" || k == K"while"
            push!(discarded, last(kids))
        elseif is_statement && k in (K"if", K"elseif", K"let", K"&&", K"||")
            union!(discarded, kids[2:end])
        elseif is_statement && k in (K"try", K"catch", K"finally")
            union!(discarded, kids)
        end
        is_method = is_method_form(node)
        call = is_method ? signature_call(kids[1]) : nothing
        if k == K"->" || k == K"do" || (is_method && isnothing(call))
            foreach(part -> visit(file, part, "", Symbol[]), kids)
            return
        elseif is_method
            head, arguments... = child_nodes(call)
            items = JS.SyntaxNode[]
            for argument in arguments
                if JS.kind(argument) == K"parameters"
                    append!(items, child_nodes(argument))
                else
                    push!(items, argument)
                end
            end
            own = Symbol[]
            for item in items
                names = Symbol[]
                _argname!(names, item)
                bound = item
                while JS.kind(bound) in (K"=", K"...", K"::")
                    bound = first(child_nodes(bound))
                end
                JS.kind(bound) == K"tuple" || append!(own, names)
            end
            name = JS.sourcetext(head)
            foreach(body -> visit(file, body, name, own), kids[2:end])
            return
        elseif k == K"for" || k == K"generator"
            body = k == K"for" ? last(kids) : first(kids)
            specs = k == K"for" ? kids[1:end-1] : kids[2:end]
            targets = Symbol[]
            foreach(spec -> bound_names!(targets, spec), specs)
            foreach(spec -> visit(file, spec, owner, params), specs)
            visit(file, body, owner, setdiff(params, targets))
            return
        end
        is_logical = k == K"&&" || k == K"||"
        if k == K"if" || k == K"elseif" || k == K"?" || (is_logical && is_statement)
            test = kids[1]
            branch = kids[2]
            statements = JS.kind(branch) == K"block" ? child_nodes(branch) : [branch]
            is_guard = false
            if length(statements) == 1 && JS.kind(only(statements)) == K"call"
                callee = first(child_nodes(only(statements)))
                is_guard = callee.val === :throw
            end
            parts = child_nodes(test)
            operator = nothing
            operands = parts
            if JS.kind(test) == K"<:"
                operator = :(<:)
            elseif JS.kind(test) == K"call"
                is_infix = JS.is_infix_op_call(test)
                operator = is_infix ? parts[2].val : parts[1].val
                operands = is_infix ? parts[[1, 3]] : parts[2:end]
            end
            subjects = JS.SyntaxNode[]
            if operator === :isa
                push!(subjects, first(operands))
            elseif operator in (:(==), :(===), :(!=), :(!==), :(<:))
                for operand in operands
                    inner = child_nodes(operand)
                    is_typeof = JS.kind(operand) == K"call" && length(inner) == 2 && first(inner).val === :typeof
                    is_typeof && push!(subjects, last(inner))
                end
            end
            tested = findfirst(subject -> subject.val in params, subjects)
            if !is_guard && !isnothing(tested)
                parameter = subjects[tested].val
                line = Int(JS.source_location(test)[1])
                detail = "a runtime type test on the method's own parameter picks the path"
                push!(findings, Finding(file.mod, :type_branch, file.path, "$owner:$parameter", line, detail))
            end
        end
        foreach(child -> visit(file, child, owner, params), kids)
    end
    for file in ctx.index.files
        path = joinpath(ctx.index.repo, file.path)
        tree = parse_file(read(path, String), file.path)
        isnothing(tree) || visit(file, tree, "", Symbol[])
    end
    findings
end
kinds(::TypeBranches) = (:type_branch => :advisory,)

run(::FileBackEdges, ctx) = collect_modules(check_file_backedges, ctx)
kinds(::FileBackEdges) = (:file_backedge => :advisory,)

run(::FileSinkable, ctx) = collect_modules(cg -> check_file_sinkable(cg, ctx.sites), ctx)
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

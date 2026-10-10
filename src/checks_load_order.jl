# file-backedge as Julia's load reads it: a method binds the names its body reads when it runs, so a method reads a
# name late when the load makes that name's first binding only after the method's file is done.

# ---- what each method reads ----

"""One member read through a qualifier that can name a module."""
struct MemberRead
    qualifier::JS.SyntaxNode   # the code before the dot
    member::Symbol             # the name after it
    bound::Set{Symbol}         # names local where the read sits
end

"""The names one method reads when it runs: each bare name, and each member read through a qualifier."""
struct MethodReads
    refs::Dict{Symbol,Set{Symbol}}   # walk target -> bare names its code reads
    members::Vector{MemberRead}      # each member read through a qualifier
end

function note_member!(reads::MethodReads, scope, qualifier, member)
    is_module_path(qualifier, scope.bound) || return
    read = MemberRead(qualifier, member, scope.bound)
    push!(reads.members, read)
end

"""A method loaded code defines at its top level: a function's method, a macro, a type's inner constructors, or an
anonymous function."""
struct ReaderForm
    form::JS.SyntaxNode   # the definition
    name::Symbol          # the name a finding gives it
end

const ANONYMOUS_READER = Symbol("->")

# The methods a piece of loaded code defines outside any other method, past branches this Julia skips.
function collect_readers!(readers, node)
    kind = JS.kind(node)
    kind == K"quote" && return readers
    if is_method_form(node)
        children = child_nodes(node)
        child_count(children) < 2 && return readers
        name = method_name_of(children[1])
        isnothing(name) || push!(readers, ReaderForm(node, name))
        return readers
    end
    if kind == K"macro"
        children = child_nodes(node)
        name = sig_name(children[1])
        isnothing(name) || push!(readers, ReaderForm(node, Symbol("@", name)))
        return readers
    end
    if kind == K"struct"
        children = child_nodes(node)
        name = type_name(children[1])
        isnothing(name) || push!(readers, ReaderForm(node, name))
        return readers
    end
    if kind == K"->" || kind == K"do"
        push!(readers, ReaderForm(node, ANONYMOUS_READER))
        return readers
    end
    for child in live_children(node)
        collect_readers!(readers, child)
    end
    readers
end

const READS_TARGET = :_

function inner_constructors(node)
    children = child_nodes(node)
    body = last(children)
    JS.kind(body) == K"block" || return JS.SyntaxNode[]
    statements = child_nodes(body)
    isnothing(statements) && return JS.SyntaxNode[]
    filter(is_inner_constructor, statements)
end

function form_reads(form::JS.SyntaxNode)
    refs = Dict(READS_TARGET => Set{Symbol}())
    reads = MethodReads(refs, MemberRead[])
    scope = ScanScope(READS_TARGET, Set{Symbol}(), 0, 0, nothing, false)
    kind = JS.kind(form)
    if kind == K"macro"
        children = child_nodes(form)
        absorb_method!(reads, children[1], children[2], scope)
    elseif kind == K"struct"
        for constructor in inner_constructors(form)
            walk_scoped!(reads, constructor, scope, nothing)
        end
    else
        walk_scoped!(reads, form, scope, nothing)
    end
    reads
end

function bare_reads(reads::MethodReads)
    names = Set{Symbol}()
    for read in values(reads.refs)
        union!(names, read)
    end
    names
end

# ---- the judgement ----

# Whether a module the code uses exports `name` bound to the object the module's own binding holds, so the name
# resolves before the clause that binds it explicitly.
function resolves_through_using(home::Module, name::Symbol)
    isdefined(home, name) || return false
    value = getglobal(home, name)
    exports_value(Core, name, value) && return true
    used = ccall(:jl_module_usings, Any, (Any,), home)::Vector{Any}
    for candidate in used
        candidate isa Module || continue
        exports_value(candidate, name, value) && return true
    end
    false
end

function exports_value(candidate::Module, name::Symbol, value)
    Base.isexported(candidate, name) || return false
    isdefined(candidate, name) || return false
    getglobal(candidate, name) === value
end

"""What one judgement of late reads resolves against: the load's bindings and the package's loaded modules."""
struct LateJudge
    walk::LoadWalk                   # each code's place and each name's first binding
    by_key::Dict{Symbol,Module}      # each loaded package module by its key
    by_module::IdDict{Module,Symbol} # each loaded package module -> its key
end

function LateJudge(walk::LoadWalk, mods, package::Module)
    by_key = Dict{Symbol,Module}()
    by_module = IdDict{Module,Symbol}()
    for loaded in package_modules(package, mods)
        key = module_key(loaded)
        by_key[key] = loaded
        by_module[loaded] = key
    end
    LateJudge(walk, by_key, by_module)
end

"""A file pair the load binds late: the methods that read across it and the names they read."""
struct LateEdge
    mod::Symbol            # module of the code that reads
    from::Int              # position of the reading code
    to::Int                # position of the code that binds
    readers::Set{Symbol}   # methods that read a name late
    names::Set{Symbol}     # the names they read late
end

# The binding `name` reads in module `key` when the load has started `started` includes; nothing when the load has
# bound it by then, or a module the code uses resolves it until its explicit binding.
function late_binding(judge::LateJudge, key::Symbol, name::Symbol, started::Int)
    bound = get(judge.walk.names, key, nothing)
    isnothing(bound) && return nothing
    binding = get(bound, name, nothing)
    isnothing(binding) && return nothing
    binding.started > started || return nothing
    binding.is_import || return binding
    home = get(judge.by_key, key, nothing)
    isnothing(home) && return binding
    resolves_through_using(home, name) && return nothing
    binding
end

# Whether the parse sees where a package module binds `name`: a binding the load walk recorded, or the module's own
# name. Code another module evaluates into it binds where no file shows.
function is_seen_binding(judge::LateJudge, holder::Symbol, current::Module, name::Symbol)
    name === nameof(current) && return true
    bound = get(judge.walk.names, holder, nothing)
    isnothing(bound) && return false
    haskey(bound, name)
end

# The package module a qualifier names, resolved from the code's module through bindings the parse sees. Nothing
# for a local, another package's module, or a step the load binds late, judged as that step's own read.
function member_module(judge::LateJudge, key::Symbol, read::MemberRead, started::Int)
    path = dotted_names(read.qualifier)
    isnothing(path) && return nothing
    head = first(path)
    head in read.bound && return nothing
    current = get(judge.by_key, key, nothing)
    for name in path
        current isa Module || return nothing
        holder = get(judge.by_module, current, nothing)
        isnothing(holder) && return nothing
        is_seen_binding(judge, holder, current, name) || return nothing
        late = late_binding(judge, holder, name, started)
        isnothing(late) || return nothing
        isdefined(current, name) || return nothing
        current = getglobal(current, name)
    end
    current isa Module || return nothing
    get(judge.by_module, current, nothing)
end

function note_late!(edges, judge::LateJudge, position::Int, reader::ReaderForm, name::Symbol, binding)
    isnothing(binding) && return edges
    files = judge.walk.index.files
    file = files[position]
    target = files[binding.code]
    target.path == file.path && return edges
    pair = (file.path, target.path)
    edge = get!(edges, pair) do
        LateEdge(file.mod, position, binding.code, Set{Symbol}(), Set{Symbol}())
    end
    push!(edge.readers, reader.name)
    push!(edge.names, name)
    edges
end

function judge_reader!(edges, judge::LateJudge, position::Int, reader::ReaderForm)
    file = judge.walk.index.files[position]
    load = judge.walk.loads[position]
    byte = JS.first_byte(reader.form)
    started = started_at(load, byte)
    reads = form_reads(reader.form)
    for name in bare_reads(reads)
        binding = late_binding(judge, file.mod, name, started)
        note_late!(edges, judge, position, reader, name, binding)
    end
    for read in reads.members
        through = member_module(judge, file.mod, read, started)
        isnothing(through) && continue
        binding = late_binding(judge, through, read.member, started)
        note_late!(edges, judge, position, reader, read.member, binding)
    end
    edges
end

# Two load places below the module place they share: `1->3` for two files of one module.
function relative_places(from::Vector{Int}, to::Vector{Int})
    shared = 0
    limit = min(length(from), length(to))
    while shared < limit && from[shared + 1] == to[shared + 1]
        shared += 1
    end
    from_rest = from[(shared + 1):end]
    to_rest = to[(shared + 1):end]
    from_text = join(from_rest, ".")
    to_text = join(to_rest, ".")
    "$from_text->$to_text"
end

function edge_finding(index::SourceIndex, edge::LateEdge)
    from_file = index.files[edge.from]
    to_file = index.files[edge.to]
    from_place = load_place(from_file)
    to_place = load_place(to_file)
    order = relative_places(from_place, to_place)
    readers = sort!(collect(edge.readers))
    names = sort!(collect(edge.names))
    evidence = [:include_order => order, :via => join(readers, " "), :names => join(names, " ")]
    detail = "reads a name the load binds only in a file it reaches later"
    Finding(edge.mod, :file_backedge, from_file.path, to_file.path, 0, detail, evidence)
end

# file-backedge: a method reads a name the load binds after the method's file is done. A qualified read counts in the
# package module its qualifier names; another package's name is that package's.
function check_file_backedges(index::SourceIndex, mods, package::Module)
    walk = load_walk(index, nameof(package))
    judge = LateJudge(walk, mods, package)
    edges = Dict{Tuple{String,String},LateEdge}()
    for position in walk.order
        file = index.files[position]
        readers = collect_readers!(ReaderForm[], file.tree)
        for reader in readers
            judge_reader!(edges, judge, position, reader)
        end
    end
    findings = Finding[]
    for edge in values(edges)
        push!(findings, edge_finding(index, edge))
    end
    sort!(findings; by = finding -> (finding.file, finding.symbol))
end

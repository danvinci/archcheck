# file-backedge as Julia's load reads it: a method binds the names its body reads when it runs, so a method reads a
# name late when the load makes that name's first binding only after the method's file is done.

# ---- the methods loaded code defines ----

const ANONYMOUS_READER = Symbol("->")

# The name a finding gives a method form: its function, `@name` for a macro, `->` for an anonymous function.
function reader_name(form)::Union{Nothing,Symbol}
    kind = JS.kind(form)
    kind == K"->" && return ANONYMOUS_READER
    kind == K"do" && return ANONYMOUS_READER
    signature = first(child_nodes(form))
    kind == K"macro" || return method_name_of(signature)
    name = sig_name(signature)
    isnothing(name) && return nothing
    Symbol("@", name)
end

# The name of a method form loaded code defines, judged once per form; nothing for a form in quoted code or in a
# branch this Julia skips while it loads.
function loaded_reader!(readers, form, root)
    haskey(readers, form) && return readers[form]
    named = reader_name(form)
    if in_quote(form, root) || in_skipped_branch(form, root)
        named = nothing
    end
    readers[form] = named
    named
end

function in_quote(node, root)
    current = node.parent
    while !isnothing(current) && current !== root
        JS.kind(current) == K"quote" && return true
        current = current.parent
    end
    false
end

# ---- the judgement ----

# Whether a module the code uses exports `name` bound to the object the module's own binding holds, so the name
# resolves before the clause that binds it explicitly.
function resolves_through_using(home::Module, name::Symbol)
    isdefined(home, name) || return false
    value = getglobal(home, name)
    exports_value(Core, name, value) && return true
    for candidate in used_modules(home)
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
function member_module(judge::LateJudge, key::Symbol, qualifier, started::Int)
    path = dotted_names(qualifier)
    isnothing(path) && return nothing
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

function note_late!(edges, judge::LateJudge, position::Int, reader::Symbol, name::Symbol, binding)
    isnothing(binding) && return edges
    files = judge.walk.index.files
    file = files[position]
    target = files[binding.code]
    target.path == file.path && return edges
    pair = (file.path, target.path)
    edge = get!(edges, pair) do
        LateEdge(file.mod, position, binding.code, Set{Symbol}(), Set{Symbol}())
    end
    push!(edge.readers, reader)
    push!(edge.names, name)
    edges
end

# One read a method makes when it runs: its bare name in the code's module, or its member in the package module its
# qualifier names. A signature's annotations run where the method is defined, so they read nothing late.
function judge_read!(edges, judge::LateJudge, position::Int, readers, read::NameRead)
    form = read.method
    isnothing(form) && return edges
    read.in_signature && return edges
    read.is_quoted && return edges
    file =judge.walk.index.files[position]
    reader = loaded_reader!(readers, form, file.tree)
    isnothing(reader) && return edges
    load = judge.walk.loads[position]
    byte = JS.first_byte(form)
    started = started_at(load, byte)
    holder = file.mod
    if is_member(read)
        holder = member_module(judge, file.mod, read.qualifier, started)
        isnothing(holder) && return edges
    end
    binding = late_binding(judge, holder, read.name, started)
    note_late!(edges, judge, position, reader, read.name, binding)
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
        readers = IdDict{JS.SyntaxNode,Union{Nothing,Symbol}}()
        for read in file.scan.reads
            judge_read!(edges, judge, position, readers, read)
        end
    end
    findings = Finding[]
    for edge in values(edges)
        push!(findings, edge_finding(index, edge))
    end
    sort!(findings; by = finding -> (finding.file, finding.symbol))
end

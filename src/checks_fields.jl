# foreign-field: a field read on another module's struct, unless a public type documents the field. Receivers are
# typed by annotations, aliases, field chains, and inference when it gives one concrete type.

# Annotations from the signature, on a fresh type dict. The signature's default values stay unread.
function method_types(state, node, outer)
    types = copy(outer)
    children = child_nodes(node)
    child_count(children) == 0 && return types
    sig = first(children)
    typevars = Symbol[]
    where_vars!(typevars, sig)
    parts = call_parts(sig)
    isnothing(parts) && return types
    if JS.kind(parts.head) == K"::"
        bind_annotated!(state, types, parts.head, typevars)
    end
    for arg in parts.arguments
        if JS.kind(arg) == K"parameters"
            parameters = child_nodes(arg)
            isnothing(parameters) && continue
            for item in parameters
                bind_annotated!(state, types, item, typevars)
            end
        else
            bind_annotated!(state, types, arg, typevars)
        end
    end
    types
end

# The first child is a signature or an iterator clause. Field reads start at the next child.
function walk_tail!(state, scope, node)
    children = child_nodes(node)
    isnothing(children) && return
    last_index = length(children)::Int
    for index in 2:last_index
        walk_field_reads!(state, scope, children[index])
    end
end

function walk_method!(state, scope, node)
    typed = method_types(state, node, scope)
    walk_tail!(state, typed, node)
end

# A closure's assignments stay inside it.
function walk_closure!(state, scope, node)
    children = child_nodes(node)
    inner = copy(scope)
    walk_field_reads!(state, inner, children[2])
end

# Iterator specs bind before the body.
function walk_iterated!(state, scope, node, spec_range, body_index)
    children = child_nodes(node)
    for index in spec_range
        bind_iteration!(state, scope, children[index])
    end
    walk_field_reads!(state, scope, children[body_index])
end

function walk_for!(state, scope, node)
    children = child_nodes(node)
    last_index = length(children)::Int
    spec_end = last_index - 1
    spec_range = 1:spec_end
    walk_iterated!(state, scope, node, spec_range, last_index)
end

function walk_generator!(state, scope, node)
    children = child_nodes(node)
    last_index = length(children)::Int
    spec_range = 2:last_index
    walk_iterated!(state, scope, node, spec_range, 1)
end

function walk_assignment!(state, scope, node)
    children = child_nodes(node)
    walk_field_reads!(state, scope, children[2])
    source = value_source(state, scope, children[2])
    bind_target!(state, scope, children[1], source)
end

# One iterator's collection is read in the names already bound. The target is typed after that read.
function bind_iteration!(state, scope, node)
    children = child_nodes(node)
    isnothing(children) && return
    kind = JS.kind(node)
    if (kind == K"in" || kind == K"=") && length(children) == 2
        collection = children[2]
        walk_field_reads!(state, scope, collection)
        source = value_source(state, scope, collection)
        element = nothing
        if !isnothing(source)
            element = Deferred(IteratedStep{Deferred}(source))
        end
        bind_target!(state, scope, children[1], element)
        return
    end
    if kind == K"iteration"
        for child in children
            bind_iteration!(state, scope, child)
        end
        return
    end
    if kind == K"filter"
        bind_iteration!(state, scope, first(children))
        walk_tail!(state, scope, node)
        return
    end
    walk_field_reads!(state, scope, node)
end

# Unspecialized: the source is a type, a deferred value, or nothing, and each would compile its own walk.
function bind_target!(state, scope, target, @nospecialize(source))
    kind = JS.kind(target)
    if target.val isa Symbol
        key = type_key(state, target)
        if isnothing(source)
            delete!(scope, key)
        else
            scope[key] = source
        end
        return
    end
    if kind == K"::"
        bind_annotated!(state, scope, target, Symbol[])
        return
    end
    if kind == K"tuple"
        parts = child_nodes(target)
        isnothing(parts) && return
        kinds = [JS.kind(part) for part in parts]
        has_spread = K"..." in kinds || K"parameters" in kinds
        is_positional = !isnothing(source) && !has_spread
        for index in eachindex(parts)
            element = nothing
            if is_positional
                element = Deferred(TupleStep{Deferred}(source, index))
            end
            bind_target!(state, scope, parts[index], element)
        end
        return
    end
    identifiers = JS.SyntaxNode[]
    _argname!(identifiers, target)
    for identifier in identifiers
        key = type_key(state, identifier)
        delete!(scope, key)
    end
    walk_field_reads!(state, scope, target)
end

function record_read!(state, scope, node)
    children = child_nodes(node)
    receiver = first(children)
    member = last(children)
    typed = receiver_type(state, scope, receiver)
    isnothing(typed) && return
    line = source_line(node)
    written = JS.sourcetext(receiver)
    push!(state.reads, FieldRead(typed, member.val, line, written))
end

function walk_field!(state, scope, node)
    record_read!(state, scope, node)
    base = child -> walk_field_reads!(state, scope, child)
    walk_dot_base!(base, node)
end

function walk_children!(state, scope, node)
    children = child_nodes(node)
    isnothing(children) && return
    for child in children
        walk_field_reads!(state, scope, child)
    end
end

function walk_field_reads!(state, scope, node)
    children = child_nodes(node)
    isnothing(children) && return
    kind = JS.kind(node)
    kind == K"quote" && return
    is_method_form(node) && return walk_method!(state, scope, node)
    if (kind == K"->" || kind == K"do") && length(children) >= 2
        return walk_closure!(state, scope, node)
    end
    if kind == K"for" && length(children) >= 2
        return walk_for!(state, scope, node)
    end
    if kind == K"generator" && length(children) >= 2
        return walk_generator!(state, scope, node)
    end
    if kind == K"=" && length(children) == 2 && !is_sig(children[1])
        return walk_assignment!(state, scope, node)
    end
    if holds_values(kind)
        value = child -> walk_field_reads!(state, scope, child)
        return walk_value_children!(value, node)
    end
    if kind == K"." && length(children) == 2 && children[2].val isa Symbol
        return walk_field!(state, scope, node)
    end
    walk_children!(state, scope, node)
end

# Every field read in a parsed file on a receiver the scan types, in the module's namespace.
function field_reads(file::FileNode, mod::Module, inferred::InferredTypes, steps::IterateSteps)
    state = ReadState(mod, file.scan, FieldRead[], inferred, steps)
    scope = ScopeTypes()
    walk_field_reads!(state, scope, file.tree)
    state
end

# A field S's docstring documents. Julia records field docstrings under `:fields` only when S has its own docstring.
function is_documented_field(S::DataType, field)
    home = parentmodule(S)
    entries = recorded_docs(home, nameof(S))
    for entry in entries
        recorded = get(entry.data, :fields, nothing)
        !isnothing(recorded) && haskey(recorded, field) && return true
    end
    false
end

# The read a caller may make of another module's struct: a field a public type documents.
function is_open_read(S::DataType, field)
    home = parentmodule(S)
    is_public = Base.ispublic(home, nameof(S))
    is_public && is_documented_field(S, field)
end

# The read's standing: a declared field of a concrete struct, a property the struct does not declare, or a read
# through an abstract annotation, which no declaration settles.
function read_kind(S::DataType, field)
    isabstracttype(S) && return "abstract"
    hasfield(S, field) ? "field" : "property"
end

# The concrete structs the package's modules define, each once. A hashed set compiles its insert once per type.
function package_structs(mods)
    found = Base.IdSet{DataType}()
    for mod in mods, name in names(mod; all = true)
        isdefined(mod, name) || continue
        value = getfield(mod, name)
        body = declared_datatype(value)
        isnothing(body) && continue
        isabstracttype(body) && continue
        parentmodule(body) === mod && push!(found, body)
    end
    found
end

# An abstract annotation declares no field, so the structs below it that do decide whose field the read is: another
# module's when every one is, and unjudged when none in the package declares it.
function is_foreign_abstract_read(structs, @nospecialize(annotation), field, reader::Symbol, key_of)
    declarers = 0
    for body in structs
        body <: annotation || continue
        hasfield(body, field) || continue
        key_of[parentmodule(body)] == reader && return false
        declarers += 1
    end
    declarers > 0
end

function check_foreign_fields(index::SourceIndex, mods)
    by_key = Dict(module_key(M) => M for M in mods)
    key_of = Dict(M => module_key(M) for M in mods)
    structs = package_structs(mods)
    findings = Finding[]
    inferred = InferredTypes()
    steps = IterateSteps()
    for file in index.files
        M = get(by_key, file.mod, nothing)
        isnothing(M) && continue
        # a read through a Union reads the field on each member
        for access in field_reads(file, M, inferred, steps).reads, member in union_members(access.type)
            S = declared_datatype(member)
            isnothing(S) && continue
            is_abstract_read = isabstracttype(S)
            if is_abstract_read && !is_foreign_abstract_read(structs, member, access.field, file.mod, key_of)
                continue
            end
            owner = get(key_of, parentmodule(S), nothing)
            (isnothing(owner) || owner == file.mod || is_open_read(S, access.field)) && continue
            symbol = "$owner.$(nameof(S)).$(access.field)"
            detail = "reads a field of a struct another module owns"
            evidence = [:receiver => access.receiver, :declared => read_kind(S, access.field)]
            push!(findings, Finding(file.mod, :foreign_field, file.path, symbol, access.line, detail, evidence))
        end
    end
    findings
end

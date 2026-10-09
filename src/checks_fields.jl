# foreign-field: a field read on another module's struct, unless it is a contract type or a public type documenting
# the field. Receivers are typed by annotations, aliases, field chains, and inference when it gives one concrete type.

# Locals are those `child_locals` records for this child. The type dict stays shared, so a binding made
# earlier in the walk remains visible.
function child_scope(scope, node, index)
    locals = child_locals(node, index, scope.locals)
    Scope(scope.types, locals)
end

# Annotations from the signature, on a fresh type dict. The signature's default values stay unread.
function method_types(mod, node, outer::Scope)
    types = copy(outer.types)
    kids = child_nodes(node)
    (isnothing(kids) || isempty(kids)) && return types
    sig = first(kids)
    argument_names = sig_argnames(sig)
    for name in argument_names
        delete!(types, name)
    end
    typevars = Symbol[]
    where_vars!(typevars, sig)
    call = signature_call(sig)
    isnothing(call) && return types
    parts = child_nodes(call)
    (isnothing(parts) || isempty(parts)) && return types
    head = first(parts)
    if JS.kind(head) == K"::"
        bind_annotated!(types, mod, head, typevars)
    end
    for arg in parts[2:end]
        if JS.kind(arg) == K"parameters"
            parameters = child_nodes(arg)
            isnothing(parameters) && continue
            for item in parameters
                bind_annotated!(types, mod, item, typevars)
            end
        else
            bind_annotated!(types, mod, arg, typevars)
        end
    end
    types
end

# The first child is a signature or an iterator clause. Field reads start at the next child.
function walk_tail!(state, scope, node)
    kids = child_nodes(node)
    isnothing(kids) && return
    for index in 2:length(kids)
        inner = child_scope(scope, node, index)
        walk_field_reads!(state, inner, kids[index])
    end
end

function walk_method!(state, scope, node)
    types = method_types(state.mod, node, scope)
    typed = Scope(types, scope.locals)
    walk_tail!(state, typed, node)
end

function walk_closure!(state, scope, node)
    kids = child_nodes(node)
    types = copy(scope.types)
    params = Symbol[]
    _argname!(params, first(kids))
    for name in params
        delete!(types, name)
    end
    locals = child_locals(node, 2, scope.locals)
    inner = Scope(types, locals)
    walk_field_reads!(state, inner, kids[2])
end

# Iterator specs bind before the body. A target's type is dropped once the body has been walked.
function walk_iterated!(state, scope, node, spec_range, body_index)
    kids = child_nodes(node)
    targets = Symbol[]
    for index in spec_range
        spec_scope = child_scope(scope, node, index)
        bind_iteration!(state, spec_scope, targets, kids[index])
    end
    body_scope = child_scope(scope, node, body_index)
    walk_field_reads!(state, body_scope, kids[body_index])
    for target in targets
        delete!(scope.types, target)
    end
end

function walk_for!(state, scope, node)
    kids = child_nodes(node)
    last_index = length(kids)
    spec_range = 1:(last_index - 1)
    walk_iterated!(state, scope, node, spec_range, last_index)
end

function walk_generator!(state, scope, node)
    kids = child_nodes(node)
    spec_range = 2:length(kids)
    walk_iterated!(state, scope, node, spec_range, 1)
end

function walk_assignment!(state, scope, node)
    kids = child_nodes(node)
    rhs = child_scope(scope, node, 2)
    walk_field_reads!(state, rhs, kids[2])
    source = value_source(state, rhs, kids[2])
    bind_target!(state, scope, kids[1], source)
end

# One iterator's collection is read in the names already bound. The target is typed after that read.
function bind_iteration!(state, scope, targets, node)
    kids = child_nodes(node)
    isnothing(kids) && return
    kind = JS.kind(node)
    if (kind == K"in" || kind == K"=") && length(kids) == 2
        collection_scope = child_scope(scope, node, 2)
        collection = kids[2]
        walk_field_reads!(state, collection_scope, collection)
        source = value_source(state, collection_scope, collection)
        element = nothing
        if !isnothing(source)
            element = Deferred(element_type, (source,))
        end
        target = kids[1]
        bind_target!(state, scope, target, element)
        _argname!(targets, target)
        return
    end
    if kind == K"iteration"
        for index in eachindex(kids)
            inner = child_scope(scope, node, index)
            bind_iteration!(state, inner, targets, kids[index])
        end
        return
    end
    if kind == K"filter"
        inner = child_scope(scope, node, 1)
        bind_iteration!(state, inner, targets, first(kids))
        walk_tail!(state, scope, node)
        return
    end
    walk_field_reads!(state, scope, node)
end

function bind_target!(state, scope, target, source)
    name = target.val
    kind = JS.kind(target)
    if name isa Symbol
        if isnothing(source)
            delete!(scope.types, name)
        else
            scope.types[name] = source
        end
        return
    end
    if kind == K"::"
        bind_annotated!(scope.types, state.mod, target, Symbol[])
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
                element = Deferred(tuple_element, (source, index))
            end
            bind_target!(state, scope, parts[index], element)
        end
        return
    end
    names = Symbol[]
    _argname!(names, target)
    for bound_name in names
        delete!(scope.types, bound_name)
    end
    walk_field_reads!(state, scope, target)
end

function record_read!(state, scope, node)
    kids = child_nodes(node)
    receiver = first(kids)
    member = last(kids)
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
    kids = child_nodes(node)
    isnothing(kids) && return
    for index in eachindex(kids)
        inner = child_scope(scope, node, index)
        walk_field_reads!(state, inner, kids[index])
    end
end

function walk_field_reads!(state, scope, node)
    kids = child_nodes(node)
    isnothing(kids) && return
    kind = JS.kind(node)
    kind == K"quote" && return
    is_method_form(node) && return walk_method!(state, scope, node)
    if (kind == K"->" || kind == K"do") && length(kids) >= 2
        return walk_closure!(state, scope, node)
    end
    if kind == K"for" && length(kids) >= 2
        return walk_for!(state, scope, node)
    end
    if kind == K"generator" && length(kids) >= 2
        return walk_generator!(state, scope, node)
    end
    if kind == K"=" && length(kids) == 2 && !is_sig(kids[1])
        return walk_assignment!(state, scope, node)
    end
    if holds_values(kind)
        value = child -> walk_field_reads!(state, scope, child)
        return walk_value_children!(value, node)
    end
    if kind == K"." && length(kids) == 2 && kids[2].val isa Symbol
        return walk_field!(state, scope, node)
    end
    walk_children!(state, scope, node)
end

# Every field read in a parsed file on a receiver the scan types, in the module's namespace.
function field_reads(tree, mod::Module)
    state = ReadState(mod, FieldRead[])
    types = Dict{Symbol,Union{Type,Deferred}}()
    locals = Set{Symbol}()
    scope = Scope(types, locals)
    walk_field_reads!(state, scope, tree)
    state
end

# The docstrings `home` records for its binding `name`; nothing when it records none. The lookup leaves a module
# with no docs uninitialised.
function recorded_docs(home::Module, name::Symbol)
    docs = Base.Docs.meta(home; autoinit = false)
    isnothing(docs) && return nothing
    binding = Base.Docs.Binding(home, name)
    get(docs, binding, nothing)
end

# A field S's docstring documents. Julia records field docstrings under `:fields` only when S has its own docstring.
function is_documented_field(S::DataType, field)
    home = parentmodule(S)
    entries = recorded_docs(home, nameof(S))
    isnothing(entries) && return false
    for entry in values(entries.docs)
        recorded = get(entry.data, :fields, nothing)
        !isnothing(recorded) && haskey(recorded, field) && return true
    end
    false
end

# Reads a caller may make of another module's struct: contract types, and the fields a public type documents.
function is_open_read(owner, S::DataType, field)
    is_within_module(owner, CONTRACTS_MODULE) && return true
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

function check_foreign_fields(index::SourceIndex, mods)
    by_key = Dict(module_key(M) => M for M in mods)
    key_of = Dict(M => module_key(M) for M in mods)
    findings = Finding[]
    for file in index.files
        M = get(by_key, file.mod, nothing)
        isnothing(M) && continue
        # a read through a Union reads the field on each member
        for access in field_reads(file.tree, M).reads, member in Base.uniontypes(access.type)
            S = Base.unwrap_unionall(member)
            S isa DataType || continue
            owner = get(key_of, parentmodule(S), nothing)
            (isnothing(owner) || owner == file.mod || is_open_read(owner, S, access.field)) && continue
            symbol = "$owner.$(nameof(S)).$(access.field)"
            detail = "reads a field of a struct another module owns"
            evidence = [:receiver => access.receiver, :declared => read_kind(S, access.field)]
            push!(findings, Finding(file.mod, :foreign_field, file.path, symbol, access.line, detail, evidence))
        end
    end
    findings
end

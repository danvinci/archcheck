# foreign-field: a field read on another module's struct, unless it is a contract type or a public type documenting
# the field. A syntax heuristic: receivers are typed by annotations, aliases of typed names, and field chains.

# One field read on a typed receiver.
struct FieldRead
    type::Type          # the receiver's declared type
    field::Symbol       # the name read
    line::Int           # source line
    receiver::String    # the receiver expression as written
end

# Names typed within one scope.
struct Scope
    types::Dict{Symbol,Type}   # name -> declared type
    called::Set{Symbol}        # locals bound from a call that takes a typed name; no type without inference
end
Base.copy(scope::Scope) = Scope(copy(scope.types), copy(scope.called))

# One file's reads, walked in the namespace of the module that owns the file.
struct ReadState
    mod::Module                      # the file's module, where annotations resolve
    reads::Vector{FieldRead}         # reads on typed receivers
    call_bound::Base.RefValue{Int}   # reads on call-bound locals, the untyped remainder
end

# The type an annotation names in M: a name or a dotted path, parameters dropped. A `where` variable names none.
function annotation_type(M::Module, node, typevars)
    JS.kind(node) == K"curly" && return annotation_type(M, first(child_nodes(node)), typevars)
    path = dotted_names(node)
    isnothing(path) && return nothing
    first(path) in typevars && return nothing
    value = M
    for name in path
        value isa Module && isdefined(value, name) || return nothing
        value = getfield(value, name)
    end
    value isa Type ? value : nothing
end

function bind_annotated!(types, M, arg, typevars)
    k = JS.kind(arg)
    k == K"=" && return bind_annotated!(types, M, first(child_nodes(arg)), typevars)
    k == K"::" || return
    kids = child_nodes(arg)
    length(kids) == 2 || return
    name = kids[1].val
    name isa Symbol || return
    declared = annotation_type(M, kids[2], typevars)
    if !isnothing(declared)
        types[name] = declared
    end
end

# The scope inside a method: the outer one less every name the signature binds, plus its annotated arguments.
function method_scope(M, sig, outer::Scope)
    scope = copy(outer)
    for name in sig_argnames(sig)
        delete!(scope.types, name)
        delete!(scope.called, name)
    end
    typevars = Symbol[]
    where_vars!(typevars, sig)
    call = signature_call(sig)
    isnothing(call) && return scope
    kids = child_nodes(call)
    head = first(kids)
    JS.kind(head) == K"::" && bind_annotated!(scope.types, M, head, typevars)
    for arg in kids[2:end]
        items = JS.kind(arg) == K"parameters" ? child_nodes(arg) : (arg,)
        for item in items
            bind_annotated!(scope.types, M, item, typevars)
        end
    end
    scope
end

function declared_field_type(T, field)
    S = Base.unwrap_unionall(T)
    S isa DataType && isstructtype(S) && hasfield(S, field) || return nothing
    declared = fieldtype(S, field)
    declared isa Type ? declared : nothing
end

# The declared type of a receiver: a typed name, or a field chain from one through declared field types.
function receiver_type(types, node)
    node.val isa Symbol && return get(types, node.val, nothing)
    JS.kind(node) == K"." || return nothing
    kids = child_nodes(node)
    (kids === nothing || length(kids) != 2) && return nothing
    base = receiver_type(types, kids[1])
    field = kids[2].val
    (isnothing(base) || !(field isa Symbol)) && return nothing
    declared_field_type(base, field)
end

function takes_typed(types, node)
    JS.kind(node) == K"call" || return false
    arguments = child_nodes(node)[2:end]
    any(arg -> !isnothing(receiver_type(types, arg)), arguments)
end

function bind_local!(state, scope, lhs, rhs)
    name = lhs.val
    if name isa Symbol
        typed = receiver_type(scope.types, rhs)
        delete!(scope.called, name)
        if isnothing(typed)
            delete!(scope.types, name)
            takes_typed(scope.types, rhs) && push!(scope.called, name)
        else
            scope.types[name] = typed
        end
    elseif JS.kind(lhs) == K"::"
        bind_annotated!(scope.types, state.mod, lhs, Symbol[])
    else
        walk_field_reads!(state, scope, lhs)
    end
end

function record_read!(state, scope, node)
    receiver, member = child_nodes(node)
    typed = receiver_type(scope.types, receiver)
    if isnothing(typed)
        receiver.val isa Symbol && receiver.val in scope.called && (state.call_bound[] += 1)
        return
    end
    line = Int(JS.source_location(node)[1])
    push!(state.reads, FieldRead(typed, member.val, line, JS.sourcetext(receiver)))
end

function walk_field_reads!(state, scope, node)
    kids = child_nodes(node)
    kids === nothing && return
    k = JS.kind(node)
    if k == K"quote"
        return
    elseif is_method_form(node)
        inner = method_scope(state.mod, kids[1], scope)
        for c in kids[2:end]
            walk_field_reads!(state, inner, c)
        end
    elseif (k == K"->" || k == K"do") && length(kids) >= 2
        inner = copy(scope)
        params = Symbol[]
        _argname!(params, kids[1])
        foreach(name -> delete!(inner.types, name), params)
        walk_field_reads!(state, inner, kids[2])
    elseif k == K"=" && length(kids) == 2 && !is_sig(kids[1])
        walk_field_reads!(state, scope, kids[2])
        bind_local!(state, scope, kids[1], kids[2])
    elseif k == K"call" || k == K"parameters" || k == K"tuple"
        walk_value_children!(c -> walk_field_reads!(state, scope, c), node)
    elseif k == K"." && length(kids) == 2 && kids[2].val isa Symbol
        record_read!(state, scope, node)
        walk_field_reads!(state, scope, kids[1])
    else
        for c in kids
            walk_field_reads!(state, scope, c)
        end
    end
end

# Every field read in a parsed file on a receiver the syntax types, in M's namespace.
function field_reads(tree, M::Module)
    state = ReadState(M, FieldRead[], Ref(0))
    walk_field_reads!(state, Scope(Dict{Symbol,Type}(), Set{Symbol}()), tree)
    state
end

is_contract(owner) = owner === CONTRACTS_MODULE || startswith(string(owner), "$CONTRACTS_MODULE.")

# A field S's docstring documents. Julia records field docstrings under `:fields` only when S has its own docstring;
# the lookup leaves a module with no docs uninitialised.
function is_documented_field(S::DataType, field)
    home = parentmodule(S)
    docs = Base.Docs.meta(home; autoinit = false)
    isnothing(docs) && return false
    binding = Base.Docs.Binding(home, nameof(S))
    entries = get(docs, binding, nothing)
    isnothing(entries) && return false
    for entry in values(entries.docs)
        recorded = get(entry.data, :fields, nothing)
        !isnothing(recorded) && haskey(recorded, field) && return true
    end
    false
end

# Reads a caller may make of another module's struct: contract types, and the fields a public type documents.
function is_open_read(owner, S::DataType, field)
    is_contract(owner) && return true
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
        path = joinpath(index.repo, file.path)
        tree = parse_file(read(path, String), file.path)
        isnothing(tree) && continue
        for access in field_reads(tree, M).reads
            S = Base.unwrap_unionall(access.type)
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

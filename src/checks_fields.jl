# foreign-field: a field read on another module's struct, unless it is a contract type or a public type documenting
# the field. Receivers are typed by annotations, aliases, field chains, and inference when it gives one concrete type.

# One field read on a typed receiver.
struct FieldRead
    type::Type          # the receiver's declared type, or the concrete type inferred for it
    field::Symbol       # the name read
    line::Int           # source line
    receiver::String    # the receiver expression as written
end

# A bound value's type, computed on the first read that needs it, so inference runs only for values read through.
mutable struct Deferred
    const compute::Function     # computes the type, or nothing, from `arguments`
    const arguments::Tuple      # what compute reads, captured when the binding is walked
    type::Union{Type,Nothing}   # the result, once computed
    is_computed::Bool           # whether compute has run
end
Deferred(compute, arguments) = Deferred(compute, arguments, nothing, false)

# A binding's type: a declared type as it is, a deferred one computed on first use.
resolved(::Nothing) = nothing
resolved(T::Type) = T
function resolved(deferred::Deferred)
    if !deferred.is_computed
        deferred.type = deferred.compute(deferred.arguments...)
        deferred.is_computed = true
    end
    deferred.type
end

# Names typed within one scope.
struct Scope
    types::Dict{Symbol,Union{Type,Deferred}}   # name -> declared type, or its value's type deferred to a read
    locals::Set{Symbol}                        # names a local binding may hold; a call through one reaches no global
end
function Base.copy(scope::Scope)
    types = copy(scope.types)
    locals = copy(scope.locals)
    Scope(types, locals)
end

# One file's reads, walked in the namespace of the module that owns the file.
struct ReadState
    mod::Module                      # the file's module, where annotations and callees resolve
    reads::Vector{FieldRead}         # reads on typed receivers
end

# The value a dotted path binds in M when every binding along it is constant; nothing otherwise.
function constant_value(M::Module, path)
    value = M
    for name in path
        value isa Module && isdefined(value, name) && isconst(value, name) || return nothing
        value = getfield(value, name)
    end
    value
end

# The type an annotation names in M: a name or a dotted path, parameters dropped. A `where` variable names none.
function annotation_type(M::Module, node, typevars)
    JS.kind(node) == K"curly" && return annotation_type(M, first(child_nodes(node)), typevars)
    path = dotted_names(node)
    isnothing(path) && return nothing
    first(path) in typevars && return nothing
    value = constant_value(M, path)
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

# Every name a binding under node introduces: assignment and loop targets, closure and method parameters, local
# method names, `local` and `catch` variables. Keyword labels count too, which only makes the set larger.
function bound_names!(names, node)
    kids = child_nodes(node)
    kids === nothing && return
    k = JS.kind(node)
    if is_method_form(node)
        local_name = sig_name(kids[1])
        isnothing(local_name) || push!(names, local_name)
        union!(names, sig_argnames(kids[1]))
    elseif k == K"=" || k == K"in" || k == K"->" || k == K"do" || k == K"catch"
        _argname!(names, kids[1])
    elseif k == K"local"
        foreach(declared -> _argname!(names, declared), kids)
    end
    for c in kids
        bound_names!(names, c)
    end
end

# The scope inside a method: the outer one less every name the signature binds, plus its annotated arguments.
# Every name the method binds is local there.
function method_scope(M, node, outer::Scope)
    scope = copy(outer)
    sig, body... = child_nodes(node)
    for name in sig_argnames(sig)
        delete!(scope.types, name)
        push!(scope.locals, name)
    end
    foreach(part -> bound_names!(scope.locals, part), body)
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

# The type a receiver has: a typed name, a field chain through declared field types, or a call or an index whose
# inferred result is one concrete type.
function receiver_type(state, scope, node)
    if node.val isa Symbol
        bound = get(scope.types, node.val, nothing)
        return resolved(bound)
    end
    k = JS.kind(node)
    k == K"call" && return call_type(state, scope, node)
    k == K"ref" && return inferred_result(state, scope, Base.getindex, child_nodes(node))
    k == K"." || return nothing
    kids = child_nodes(node)
    (kids === nothing || length(kids) != 2) && return nothing
    base = receiver_type(state, scope, kids[1])
    field = kids[2].val
    (isnothing(base) || !(field isa Symbol)) && return nothing
    declared_field_type(base, field)
end

# The type of a literal, or of the constant a global name binds; nothing for anything else.
function value_type(state, scope, node)
    JS.kind(node) == K"string" && return String
    value = node.val
    isnothing(value) && return nothing
    value isa Symbol || return typeof(value)
    value in scope.locals && return nothing
    bound = constant_value(state.mod, (value,))
    isnothing(bound) ? nothing : Core.Typeof(bound)
end

# What the scan knows of an argument's type, Any when nothing. A type with free type variables names no values.
function argument_type(state, scope, node)
    known = receiver_type(state, scope, node)
    if isnothing(known)
        known = value_type(state, scope, node)
    end
    isnothing(known) && return Any
    Base.has_free_typevars(known) ? Any : known
end

# T when it is one concrete type; nothing for a Union, an abstract type or Any.
concrete_type(T) = T isa DataType && isconcretetype(T) ? T : nothing

# Inference gives Any for a call more methods than this match, so the scan skips such a call.
const INFERENCE_METHODS_MAX = Core.Compiler.InferenceParams().max_methods

# The one concrete type Julia infers for calling f with arguments of these types; nothing for any other result.
function inferred_type(f, signature)
    matches = methods(f, signature)
    (isempty(matches) || length(matches) > INFERENCE_METHODS_MAX) && return nothing
    result = Base.infer_return_type(f, signature)
    concrete_type(result)
end

# The NamedTuple type a call's keyword arguments form; nothing when one is splatted or not named plainly.
function keywords_type(state, scope, keywords)
    names = Symbol[]
    types = Any[]
    for keyword in keywords
        key = keyword
        value = keyword
        if JS.kind(keyword) == K"="
            key, value = child_nodes(keyword)
        end
        key.val isa Symbol || return nothing
        push!(names, key.val)
        push!(types, argument_type(state, scope, value))
    end
    NamedTuple{Tuple(names), Tuple{types...}}
end

# The concrete type Julia infers for applying f to these operands, each typed as far as the scan knows it.
# A splat or a do-block leaves the call's arguments unknown, so it types nothing.
function inferred_result(state, scope, f, operands)
    positional = Any[]
    keywords = JS.SyntaxNode[]
    for operand in operands
        k = JS.kind(operand)
        if k == K"parameters"
            append!(keywords, child_nodes(operand))
        elseif k == K"="
            push!(keywords, operand)
        elseif k == K"..." || k == K"do"
            return nothing
        else
            push!(positional, argument_type(state, scope, operand))
        end
    end
    if isempty(keywords)
        signature = Tuple{positional...}
        return inferred_type(f, signature)
    end
    named = keywords_type(state, scope, keywords)
    isnothing(named) && return nothing
    callee_type = Core.Typeof(f)
    signature = Tuple{named, callee_type, positional...}
    inferred_type(Core.kwcall, signature)
end

# A call through a global function no local binding shadows, typed by inference.
function call_type(state, scope, node)
    kids = child_nodes(node)
    head = first(kids)
    operands = kids[2:end]
    if JS.is_infix_op_call(node)
        head = kids[2]
        operands = kids[3:end]
        pushfirst!(operands, kids[1])
    elseif JS.is_postfix_op_call(node)
        head = last(kids)
        operands = kids[1:end-1]
    end
    path = dotted_names(head)
    isnothing(path) && return nothing
    first(path) in scope.locals && return nothing
    f = constant_value(state.mod, path)
    isnothing(f) && return nothing
    inferred_result(state, scope, f, operands)
end

# The element a loop over a collection binds, when every step of `iterate` yields one concrete type.
function element_type(collection)
    T = resolved(collection)
    (isnothing(T) || Base.has_free_typevars(T)) && return nothing
    first_step = iterate_step(Tuple{T})
    isnothing(first_step) && return nothing
    state = fieldtype(first_step, 2)
    next_step = iterate_step(Tuple{T, state})
    next_step == first_step || return nothing
    element = fieldtype(first_step, 1)
    concrete_type(element)
end

# The (element, state) tuple type Julia infers for an `iterate` call that does not end the loop.
function iterate_step(signature)
    stepped = Base.infer_return_type(iterate, signature)
    step = typeintersect(stepped, Tuple{Any,Any})
    step isa DataType && fieldcount(step) == 2 ? step : nothing
end

# The type of the value at a position of a destructured tuple, when the tuple's type is concrete and that long.
function tuple_element(destructured, position)
    T = resolved(destructured)
    T isa DataType && T <: Tuple && isconcretetype(T) || return nothing
    position <= fieldcount(T) ? fieldtype(T, position) : nothing
end

# The type an assignment or a loop binds from an expression: an alias shares its name's entry; a field chain, a call
# or an index defers its type, computed in the scope as it stands here, to the first read that needs it.
function value_source(state, scope, node)
    node.val isa Symbol && return get(scope.types, node.val, nothing)
    k = JS.kind(node)
    (k == K"call" || k == K"ref" || k == K".") || return nothing
    frozen = copy(scope)
    Deferred(receiver_type, (state, frozen, node))
end

# Binds what an assignment or loop target names to the parts of a value with this type source; nothing unbinds them.
function bind_target!(state, scope, target, source)
    name = target.val
    k = JS.kind(target)
    if name isa Symbol
        if isnothing(source)
            delete!(scope.types, name)
        else
            scope.types[name] = source
        end
    elseif k == K"::"
        bind_annotated!(scope.types, state.mod, target, Symbol[])
    elseif k == K"tuple"
        parts = child_nodes(target)
        kinds = [JS.kind(part) for part in parts]
        is_positional = !isnothing(source) && !(K"..." in kinds || K"parameters" in kinds)
        for (position, part) in enumerate(parts)
            element = is_positional ? Deferred(tuple_element, (source, position)) : nothing
            bind_target!(state, scope, part, element)
        end
    else
        names = Symbol[]
        _argname!(names, target)
        foreach(bound -> delete!(scope.types, bound), names)
        walk_field_reads!(state, scope, target)
    end
end

# Walks each `target in collection` of a loop in order, binding the target to the collection's element type; the
# targets it binds collect into `targets`.
function bind_iteration!(state, scope, targets, node)
    kids = child_nodes(node)
    k = JS.kind(node)
    if (k == K"in" || k == K"=") && length(kids) == 2
        target, collection = kids
        walk_field_reads!(state, scope, collection)
        source = value_source(state, scope, collection)
        element = isnothing(source) ? nothing : Deferred(element_type, (source,))
        bind_target!(state, scope, target, element)
        _argname!(targets, target)
    elseif k == K"iteration"
        foreach(spec -> bind_iteration!(state, scope, targets, spec), kids)
    elseif k == K"filter"
        bind_iteration!(state, scope, targets, first(kids))
        foreach(condition -> walk_field_reads!(state, scope, condition), kids[2:end])
    else
        walk_field_reads!(state, scope, node)
    end
end

# A loop's targets are local to it: bound for its body, marked local, unbound after it.
function walk_loop!(state, scope, specs, body)
    targets = Symbol[]
    foreach(spec -> bind_iteration!(state, scope, targets, spec), specs)
    union!(scope.locals, targets)
    walk_field_reads!(state, scope, body)
    foreach(target -> delete!(scope.types, target), targets)
end

function record_read!(state, scope, node)
    receiver, member = child_nodes(node)
    typed = receiver_type(state, scope, receiver)
    isnothing(typed) && return
    line = Int(JS.source_location(node)[1])
    written = JS.sourcetext(receiver)
    push!(state.reads, FieldRead(typed, member.val, line, written))
end

function walk_field_reads!(state, scope, node)
    kids = child_nodes(node)
    kids === nothing && return
    k = JS.kind(node)
    if k == K"quote"
        return
    elseif is_method_form(node)
        inner = method_scope(state.mod, node, scope)
        for c in kids[2:end]
            walk_field_reads!(state, inner, c)
        end
    elseif (k == K"->" || k == K"do") && length(kids) >= 2
        inner = copy(scope)
        params = Symbol[]
        _argname!(params, kids[1])
        foreach(name -> delete!(inner.types, name), params)
        union!(inner.locals, params)
        bound_names!(inner.locals, kids[2])
        walk_field_reads!(state, inner, kids[2])
    elseif k == K"for" && length(kids) >= 2
        walk_loop!(state, scope, kids[1:end-1], last(kids))
    elseif k == K"generator" && length(kids) >= 2
        walk_loop!(state, scope, kids[2:end], first(kids))
    elseif k == K"let" || k == K"try" || k == K"while"
        bound_names!(scope.locals, node)
        foreach(c -> walk_field_reads!(state, scope, c), kids)
    elseif k == K"=" && length(kids) == 2 && !is_sig(kids[1])
        walk_field_reads!(state, scope, kids[2])
        source = value_source(state, scope, kids[2])
        bind_target!(state, scope, kids[1], source)
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

# Every field read in a parsed file on a receiver the scan types, in M's namespace.
function field_reads(tree, M::Module)
    state = ReadState(M, FieldRead[])
    types = Dict{Symbol,Union{Type,Deferred}}()
    locals = Set{Symbol}()
    walk_field_reads!(state, Scope(types, locals), tree)
    state
end

is_contract(owner) = is_within_module(owner, CONTRACTS_MODULE)

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

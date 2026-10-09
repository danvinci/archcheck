# The type a receiver expression has: an annotation, a field chain, or one concrete inferred call.

# Whether `vars` holds this type variable by identity.
function contains_typevar(vars, var)
    for seen in vars
        seen === var && return true
    end
    false
end

# Free type variables of a receiver type, skipping any an enclosing union-all binds.
function collect_free_typevars!(found, bound, @nospecialize(receiver_type::TypeVar))
    contains_typevar(bound, receiver_type) && return
    contains_typevar(found, receiver_type) && return
    push!(found, receiver_type)
    nothing
end

function collect_free_typevars!(found, bound, @nospecialize(receiver_type::Union))
    collect_free_typevars!(found, bound, receiver_type.a)
    collect_free_typevars!(found, bound, receiver_type.b)
    nothing
end

function collect_free_typevars!(found, bound, @nospecialize(receiver_type::UnionAll))
    push!(bound, receiver_type.var)
    collect_free_typevars!(found, bound, receiver_type.body)
    pop!(bound)
    nothing
end

function collect_free_typevars!(found, bound, @nospecialize(receiver_type::Core.TypeofVararg))
    collect_free_typevars!(found, bound, receiver_type.T)
    isdefined(receiver_type, :N) || return
    collect_free_typevars!(found, bound, receiver_type.N)
    nothing
end

function collect_free_typevars!(found, bound, @nospecialize(receiver_type::DataType))
    for parameter in receiver_type.parameters
        collect_free_typevars!(found, bound, parameter)
    end
    nothing
end

collect_free_typevars!(found, bound, @nospecialize(::Any)) = nothing

# A datatype whose parameters are still free is a union-all body. Binding those parameters yields the
# union-all whose unwrap is this same datatype.
function bind_free_parameters(@nospecialize(receiver_type))
    receiver_type isa TypeVar && return receiver_type
    Base.has_free_typevars(receiver_type) || return receiver_type
    found = TypeVar[]
    bound = TypeVar[]
    collect_free_typevars!(found, bound, receiver_type)
    wrapped = receiver_type
    for parameter in reverse(found)
        wrapped = UnionAll(parameter, wrapped)
    end
    wrapped
end

# One field read on a typed receiver.
struct FieldRead{T}
    type::Type{T}               # the receiver's declared type, or the concrete type inferred for it
    field::Symbol               # the name read
    line::Int                   # source line
    receiver::String            # the receiver expression as written
    function FieldRead(receiver_type::Type, field::Symbol, line::Int, receiver::AbstractString)
        text = String(receiver)
        parameter = bind_free_parameters(receiver_type)
        new{parameter}(parameter, field, line, text)
    end
end

# A type a binding's computation returned.
struct ComputedType{T}
    type::T                     # the computed type
end

# The computation ran and named no type.
struct NoComputedType end

# A bound value's type, computed on the first read that needs it, so inference runs only for values read through.
# An empty holder means the computation ran and named no type. An absent holder means it has not run.
mutable struct Deferred{F<:Function, A<:Tuple}
    const compute::F            # computes the type, or nothing, from `arguments`
    const arguments::A          # what compute reads, captured when the binding is walked
    result::Union{Nothing,NoComputedType,ComputedType}  # absent until compute has run
end
function Deferred(compute::F, arguments::A) where {F<:Function, A<:Tuple}
    Deferred{F,A}(compute, arguments, nothing)
end

# A binding's type: a declared type as it is, a deferred one computed on first use.
resolved(::Nothing) = nothing
resolved(T::Type) = T
function resolved(deferred::Deferred)
    held = computed_result(deferred)
    held isa ComputedType || return nothing
    held.type
end

function computed_result(deferred::Deferred)
    held = deferred.result
    isnothing(held) || return held
    value = deferred.compute(deferred.arguments...)
    if isnothing(value)
        deferred.result = NoComputedType()
    else
        deferred.result = ComputedType(value)
    end
    deferred.result
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
struct ReadState{E}
    mod::Module                      # the file's module, where annotations and callees resolve
    reads::Vector{E}                 # reads on typed receivers
end

# The value a dotted path binds in `mod` when every binding along it is constant; nothing otherwise.
function constant_value(mod::Module, path)
    value = mod
    for name in path
        value isa Module && isdefined(value, name) && isconst(value, name) || return nothing
        value = getfield(value, name)
    end
    value
end

type_application_failed(::TypeError) = true
type_application_failed(::MethodError) = true
type_application_failed(::ArgumentError) = true
type_application_failed(::Any) = false

function apply_parameters(head, parameters)
    try
        return head{parameters...}
    catch err
        type_application_failed(err) || rethrow()
        return nothing
    end
end

# An integer parameter stays the integer it writes. A type parameter resolves in `mod`.
function written_parameter(mod, node)
    literal = node.val
    literal isa Integer && return literal
    written_type(mod, node)
end

# The type `node` writes in `mod`, parameters applied. Nothing when any part stays unresolved.
function written_type(mod::Module, node)
    if JS.kind(node) == K"curly"
        parts = child_nodes(node)
        isnothing(parts) && return nothing
        isempty(parts) && return nothing
        head_node = first(parts)
        head = written_type(mod, head_node)
        head isa Type || return nothing
        parameters = Any[]
        for part in parts[2:end]
            parameter = written_parameter(mod, part)
            isnothing(parameter) && return nothing
            push!(parameters, parameter)
        end
        return apply_parameters(head, parameters)
    end
    path = dotted_names(node)
    isnothing(path) && return nothing
    value = constant_value(mod, path)
    value isa Type || return nothing
    value
end

# A where-variable at the head of an annotation names no type in `mod`.
function opens_on_typevar(node, typevars)
    isempty(typevars) && return false
    path = dotted_names(node)
    if !isnothing(path)
        return first(path) in typevars
    end
    JS.kind(node) == K"curly" || return false
    parts = child_nodes(node)
    missing = isnothing(parts) || isempty(parts)
    missing && return false
    opens_on_typevar(first(parts), typevars)
end

# The datatype an applied type is built on. A union has no single datatype.
function type_head(@nospecialize(applied))
    applied isa Union && return nothing
    applied isa Type || return nothing
    name = Base.typename(applied)
    name.wrapper
end

function bind_annotated!(types, mod, arg, typevars)
    kind = JS.kind(arg)
    if kind == K"="
        kids = child_nodes(arg)
        target = first(kids)
        return bind_annotated!(types, mod, target, typevars)
    end
    kind == K"::" || return
    kids = child_nodes(arg)
    length(kids) == 2 || return
    name = kids[1].val
    name isa Symbol || return
    node = kids[2]
    opens_on_typevar(node, typevars) && return
    declared = written_type(mod, node)
    isnothing(declared) && return
    types[name] = declared
end

# The type a field read on T yields: the field's declared type, or for a Union the Union of each member's. A member
# that declares no such field, or declares it through a type variable, leaves the read untyped.
function declared_field_type(T, field)
    declared = Type[]
    for member in Base.uniontypes(T)
        struct_type = Base.unwrap_unionall(member)
        struct_type isa DataType && isstructtype(struct_type) && hasfield(struct_type, field) || return nothing
        member_declared = fieldtype(struct_type, field)
        member_declared isa Type || return nothing
        push!(declared, member_declared)
    end
    Union{declared...}
end

# The type a receiver has: a typed name, a field chain through declared field types (through each member of a
# Union), or a call or an index whose inferred result is one concrete type.
function receiver_type(state, scope, node)
    if node.val isa Symbol
        bound = get(scope.types, node.val, nothing)
        return resolved(bound)
    end
    kind = JS.kind(node)
    kind == K"call" && return call_type(state, scope, node)
    kind == K"ref" && return inferred_result(state, scope, Base.getindex, child_nodes(node))
    kind == K"." || return nothing
    kids = child_nodes(node)
    (isnothing(kids) || length(kids) != 2) && return nothing
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
    isnothing(bound) && return nothing
    Core.Typeof(bound)
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
            pair = child_nodes(keyword)
            key = first(pair)
            value = last(pair)
        end
        key.val isa Symbol || return nothing
        push!(names, key.val)
        argument = argument_type(state, scope, value)
        push!(types, argument)
    end
    NamedTuple{Tuple(names), Tuple{types...}}
end

# The concrete type Julia infers for applying f to these operands, each typed as far as the scan knows it.
# A splat or a do-block leaves the call's arguments unknown, so it types nothing.
function inferred_result(state, scope, f, operands)
    positional = Any[]
    keywords = JS.SyntaxNode[]
    for operand in operands
        kind = JS.kind(operand)
        if kind == K"parameters"
            append!(keywords, child_nodes(operand))
        elseif kind == K"="
            push!(keywords, operand)
        elseif kind == K"..." || kind == K"do"
            return nothing
        else
            argument = argument_type(state, scope, operand)
            push!(positional, argument)
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
    fn = constant_value(state.mod, path)
    isnothing(fn) && return nothing
    inferred_result(state, scope, fn, operands)
end

# The element a loop over a collection binds, when every step of `iterate` yields one concrete type.
function element_type(collection)
    collection_type = resolved(collection)
    (isnothing(collection_type) || Base.has_free_typevars(collection_type)) && return nothing
    first_step = iterate_step(Tuple{collection_type})
    isnothing(first_step) && return nothing
    step_state = fieldtype(first_step, 2)
    next_step = iterate_step(Tuple{collection_type, step_state})
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
    tuple_type = resolved(destructured)
    tuple_type isa DataType && tuple_type <: Tuple && isconcretetype(tuple_type) || return nothing
    position <= fieldcount(tuple_type) ? fieldtype(tuple_type, position) : nothing
end

# The type an assignment or a loop binds from an expression: an alias shares its name's entry; a field chain, a call
# or an index defers its type, computed in the scope as it stands here, to the first read that needs it.
function value_source(state, scope, node)
    node.val isa Symbol && return get(scope.types, node.val, nothing)
    kind = JS.kind(node)
    (kind == K"call" || kind == K"ref" || kind == K".") || return nothing
    frozen = copy(scope)
    Deferred(receiver_type, (state, frozen, node))
end

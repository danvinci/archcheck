# The method source a probe evaluates: argument shape, waits, and the probe body.

const SKIPPED_MACROS = (Symbol("@generated"), Symbol("@kwdef"), Symbol("@enum"))

macro_symbol(name::Symbol) = name
macro_symbol(::Any) = nothing
macro_symbol(name::QuoteNode) = macro_symbol(name.value)
macro_symbol(name::GlobalRef) = name.name

function macro_symbol(name::Expr)
    name.head === :. || return nothing
    isempty(name.args) && return nothing
    macro_symbol(last(name.args))
end

function unwrap_signature(signature)
    node = signature
    while node isa Expr && (node.head === :where || node.head === :(::))
        isempty(node.args) && return node
        inner = node.args[1]
        inner isa Expr || return node
        node = inner
    end
    node
end

struct ArgumentShape
    arguments::Expr     # tuple of parameter names passed to the probe
    positional::Expr    # positional arguments of the key call, splats kept
    keywords::Expr      # keyword arguments of the key call
end

function keep_name!(names, found::Symbol)
    push!(names, found)
    true
end

keep_name!(names, ::Any) = false

parameter_symbol(name::Symbol) = name
parameter_symbol(::Any) = nothing

function parameter_symbol(node::Expr)
    if node.head === :macrocall
        isempty(node.args) && return nothing
        return parameter_symbol(last(node.args))
    end
    if node.head === :(::)
        length(node.args) == 2 || return nothing
        return parameter_symbol(node.args[1])
    end
    names_inner = node.head === :kw || node.head === :... || node.head === :(=) || node.head === :<:
    names_inner || return nothing
    isempty(node.args) && return nothing
    parameter_symbol(node.args[1])
end

function keep_positional!(names, forms, found, is_splat::Bool)
    kept = keep_name!(names, found)
    kept || return nothing
    if is_splat
        form = Expr(:..., found)
        push!(forms, form)
        return nothing
    end
    push!(forms, found)
    nothing
end

function keep_keyword!(names, forms, found)
    kept = keep_name!(names, found)
    kept || return nothing
    pair = Expr(:kw, found, found)
    push!(forms, pair)
    nothing
end

function collect_keyword!(names, forms, node::Symbol)
    keep_keyword!(names, forms, node)
end

collect_keyword!(names, forms, ::Any) = nothing

function collect_keyword!(names, forms, node::Expr)
    if node.head === :parameters || node.head === :tuple
        for child in node.args
            collect_keyword!(names, forms, child)
        end
        return nothing
    end
    found = parameter_symbol(node)
    keep_keyword!(names, forms, found)
    nothing
end

function collect_positional!(names, forms, node::Symbol)
    keep_positional!(names, forms, node, false)
end

collect_positional!(names, forms, ::Any) = nothing

function collect_positional!(names, forms, node::Expr)
    if node.head === :...
        isempty(node.args) && return nothing
        found = parameter_symbol(node.args[1])
        return keep_positional!(names, forms, found, true)
    end
    found = parameter_symbol(node)
    keep_positional!(names, forms, found, false)
end

function collect_call!(positional_names, positional_forms, keyword_names, keyword_forms, call)
    head = call.args[1]
    if head isa Expr && head.head === :(::)
        collect_positional!(positional_names, positional_forms, head)
    end
    for argument in call.args[2:end]
        if argument isa Expr && argument.head === :parameters
            collect_keyword!(keyword_names, keyword_forms, argument)
        else
            collect_positional!(positional_names, positional_forms, argument)
        end
    end
    nothing
end

# An argument the source leaves unnamed (`::Type{T}`) or names `_` takes a fresh name, so the probe hashes it:
# two calls that differ only in such an argument are distinct calls.
function is_unreadable(name::Symbol)
    text = string(name)
    all(==('_'), text)
end

# A destructured argument `(a, b)` takes the name of its slot and is unpacked as the method's first statement, the
# way lowering unpacks it; the name is fixed by the slot, so a second naming of the same signature agrees.
destructured_name(slot::Int) = Symbol("#destructured#", slot)

function named_argument(name::Symbol, slot::Int, unpacking)
    is_unreadable(name) || return name
    gensym(:argument)
end

named_argument(argument::Any, slot::Int, unpacking) = argument

function named_argument(argument::Expr, slot::Int, unpacking)
    head = argument.head
    if head === :tuple
        name = destructured_name(slot)
        assignment = Expr(:(=), argument, name)
        push!(unpacking, assignment)
        return name
    end
    if head === :(::) && length(argument.args) == 1
        fresh = gensym(:argument)
        return Expr(:(::), fresh, argument.args[1])
    end
    if head === :(::) || head === :kw || head === :...
        inner = named_argument(argument.args[1], slot, unpacking)
        rest = argument.args[2:end]
        return Expr(head, inner, rest...)
    end
    if head === :macrocall
        inner = named_argument(last(argument.args), slot, unpacking)
        leading = argument.args[1:(end - 1)]
        return Expr(:macrocall, leading..., inner)
    end
    argument
end

# A callable written `(::Foo)(x)` is an argument too; a function name is none.
named_callable(head::Expr, unpacking) = head.head === :(::) ? named_argument(head, 1, unpacking) : head
named_callable(head::Any, unpacking) = head

function named_call(call::Expr, unpacking)
    callable = named_callable(call.args[1], unpacking)
    args = Any[callable]
    for slot in 2:length(call.args)
        argument = call.args[slot]
        named = named_argument(argument, slot, unpacking)
        push!(args, named)
    end
    Expr(:call, args...)
end

"""`signature` with every argument named, and the statements that unpack its destructured arguments pushed to
`unpacking`."""
named_signature(node::Any, unpacking) = node

function named_signature(node::Expr, unpacking)
    if node.head === :where || node.head === :(::)
        isempty(node.args) && return node
        inner = named_signature(node.args[1], unpacking)
        rest = node.args[2:end]
        return Expr(node.head, inner, rest...)
    end
    node.head === :call || return node
    named_call(node, unpacking)
end

"""`body` after the statements that unpack the destructured arguments of `signature`."""
function unpacked_body(signature, body)
    unpacking = Any[]
    copied = deepcopy(signature)
    named_signature(copied, unpacking)
    Expr(:block, unpacking..., body)
end

# A type as source under a method's where-clause: a closed type is spliced as itself, and a type holding the
# method's parameters is spelled out, so each parameter resolves to the binding the where-clause makes.
type_expression(variable::TypeVar) = variable.name
type_expression(value::Symbol) = QuoteNode(value)
type_expression(value::Any) = value

function type_expression(type::Type)
    has_free_variables(type) || return type
    spelled_type(type)
end

function type_expression(vararg::Core.TypeofVararg)
    has_free_variables(vararg) || return vararg
    element = type_expression(vararg.T)
    isdefined(vararg, :N) || return Expr(:curly, Vararg, element)
    count = type_expression(vararg.N)
    Expr(:curly, Vararg, element, count)
end

function spelled_parameters(head, parameters)
    args = Any[head]
    for parameter in parameters
        spelled = type_expression(parameter)
        push!(args, spelled)
    end
    Expr(:curly, args...)
end

function spelled_type(type::DataType)
    wrapper = type.name.wrapper
    spelled_parameters(wrapper, type.parameters)
end

function spelled_type(type::Union)
    members = union_members(type)
    spelled_parameters(Union, members)
end

function spelled_type(type::UnionAll)
    body = type_expression(type.body)
    bound = variable_bound(type.var)
    Expr(:where, body, bound)
end

function variable_bound(variable::TypeVar)
    name = variable.name
    upper = type_expression(variable.ub)
    if variable.lb !== Union{}
        lower = type_expression(variable.lb)
        return Expr(:comparison, lower, :<:, name, :<:, upper)
    end
    variable.ub === Any && return name
    Expr(:<:, name, upper)
end

"""`call` under the where-clause binding every parameter of `signature`, outermost first."""
function where_clause(call::Expr, signature::Type)
    bounds = Any[]
    node = signature
    while node isa UnionAll
        bound = variable_bound(node.var)
        push!(bounds, bound)
        node = node.body
    end
    isempty(bounds) && return call
    Expr(:where, call, bounds...)
end

"""The parameter name at each slot lowering gives a method after its keywords: the callable, then each positional
argument. `Symbol("")` marks a slot the source binds no name to."""
function slot_names(signature::Expr)
    call = unwrap_signature(signature)
    slots = Symbol[]
    callable = call.args[1]
    is_bound = callable isa Expr && callable.head === :(::)
    callable_name = is_bound ? parameter_symbol(callable) : nothing
    push!(slots, something(callable_name, Symbol("")))
    for argument in call.args[2:end]
        argument isa Expr && argument.head === :parameters && continue
        found = parameter_symbol(argument)
        push!(slots, something(found, Symbol("")))
    end
    slots
end

function argument_shape(signature::Expr)
    positional_names = Symbol[]
    positional_forms = Any[]
    keyword_names = Symbol[]
    keyword_forms = Any[]
    call = unwrap_signature(signature)
    if call isa Expr && call.head === :call
        collect_call!(positional_names, positional_forms, keyword_names, keyword_forms, call)
    end
    argument_names = Any[]
    append!(argument_names, positional_names)
    append!(argument_names, keyword_names)
    parameters = Expr(:parameters, keyword_forms...)
    arguments = Expr(:tuple, argument_names...)
    positional = Expr(:tuple, positional_forms...)
    keywords = Expr(:tuple, parameters)
    ArgumentShape(arguments, positional, keywords)
end

const JOIN_NAMES = (:fetch, :wait)

# The join names a method leaves unbound, read from its parse: there each one names Base's `fetch` or `wait`.
function free_joins(form)
    bound = Set{Symbol}()
    bound_names!(bound, form)
    free = Symbol[]
    for name in JOIN_NAMES
        name in bound || push!(free, name)
    end
    free
end

is_wait_name(name, site) = name in site.free_joins

# The name a join is written by, `wait` or `Base.wait`; a quoted `:wait` is a symbol value and names none.
written_join(node::Symbol) = node
written_join(node::GlobalRef) = node.name
written_join(node::Expr) = node.head === :. ? macro_symbol(node) : nothing
written_join(::Any) = nothing

# The probe a wait becomes, holding the session it records in.
function wait_probe(name::Symbol, site)
    if name === :fetch
        return Base.Fix1(probe_fetch, site.session)
    end
    Base.Fix1(probe_wait, site.session)
end

function is_sync_macro(node::Expr)
    node.head === :macrocall || return false
    isempty(node.args) && return false
    name = macro_symbol(node.args[1])
    name === Symbol("@sync")
end

function rewrite_children(node::Expr, site)
    args = Any[]
    for child in node.args
        walked = rewrite_waits(child, site)
        push!(args, walked)
    end
    Expr(node.head, args...)
end

function rewrite_broadcast(node, site)
    length(node.args) < 2 && return nothing
    tail = node.args[2]
    tail isa Expr || return nothing
    tail.head === :tuple || return nothing
    name = written_join(node.args[1])
    is_wait_name(name, site) || return nothing
    probe = wait_probe(name, site)
    rewritten_tail = rewrite_waits(tail, site)
    Expr(:., probe, rewritten_tail)
end

function rewrite_dot(node, site)
    rewritten = rewrite_broadcast(node, site)
    if !isnothing(rewritten)
        return rewritten
    end
    rewrite_children(node, site)
end

function rewrite_wait_head(node, site)
    name = written_join(node)
    is_wait_name(name, site) || return node
    wait_probe(name, site)
end

function rewrite_call(node, site)
    isempty(node.args) && return node
    args = Any[]
    for child in node.args
        walked = rewrite_waits(child, site)
        replaced = rewrite_wait_head(walked, site)
        push!(args, replaced)
    end
    Expr(:call, args...)
end

function rewrite_sync(node, site)
    body = last(node.args)
    rewritten = rewrite_waits(body, site)
    channel = GlobalRef(Base, :Channel)
    finish = GlobalRef(@__MODULE__, :log_sync_end)
    bound = sync_binding()
    opened = Expr(:call, channel, Inf)
    binding = Expr(:(=), bound, opened)
    value = gensym(:sync_value)
    assign = Expr(:(=), value, rewritten)
    logged = Expr(:call, finish, site.session, bound)
    block = Expr(:block, assign, logged, value)
    Expr(:let, binding, block)
end

rewrite_waits(node, site) = node

function rewrite_waits(node::Expr, site)
    rewrite_head(Val(node.head), node, site)
end

rewrite_head(::Val{:quote}, node::Expr, site) = node

function rewrite_head(::Val{:macrocall}, node::Expr, site)
    is_sync_macro(node) && return rewrite_sync(node, site)
    rewrite_children(node, site)
end

rewrite_head(::Val{:.}, node::Expr, site) = rewrite_dot(node, site)
rewrite_head(::Val{:call}, node::Expr, site) = rewrite_call(node, site)
rewrite_head(::Val, node::Expr, site) = rewrite_children(node, site)

function key_hash_expr(session::ProbeSession, key, positional, keywords, producer::Symbol)
    isnothing(key) && return nothing
    key_name = string(nameof(key))
    producer_name = string(producer)
    hashed = GlobalRef(@__MODULE__, :declared_key_hash)
    compute = :(() -> $key($positional...; $keywords...))
    :($hashed($compute, $session, $key_name, $producer_name))
end

function scoped_run(is_probed::Bool, parent_pair, scope, parent, invocation, body)
    if is_probed
        return quote
            $parent_pair = $parent => $invocation
            $scope($parent_pair) do
                $body()
            end
        end
    end
    :($body())
end

"""One method a probe rewrites: the session its calls record in, and where the method is written."""
struct ProbeSite{K}
    session::ProbeSession    # the session that armed the probe
    name::Symbol             # function the method belongs to
    file::String             # repo-relative path of the method
    line::Int                # its source line
    is_probed::Bool          # false for an ambient function, whose calls only mark the probed calls inside
    key::K                   # the producer's declared key function; nothing when it declares none
    free_joins::Vector{Symbol}   # `fetch` and `wait` unless the method binds the name to a value of its own
end

function probe_body(site::ProbeSite, shape::ArgumentShape, body)
    session = site.session
    name = site.name
    result = gensym(:probe_result)
    invocation = gensym(:invocation)
    body_closure = gensym(:probe_body)
    arguments = shape.arguments
    hashed = key_hash_expr(session, site.key, shape.positional, shape.keywords, name)
    rewritten = rewrite_waits(body, site)
    enter = GlobalRef(@__MODULE__, :probe_enter)
    leave = GlobalRef(@__MODULE__, :probe_leave)
    abort = GlobalRef(@__MODULE__, :probe_abort)
    type_of = GlobalRef(Core, :typeof)
    quoted_name = QuoteNode(name)
    scope = GlobalRef(Base.ScopedValues, :with)
    parent = session.parent
    parent_pair = gensym(:parent_pair)
    entered = :($enter($session, $quoted_name, $(site.file), $(site.line), $arguments, $hashed, $(site.is_probed)))
    run = scoped_run(site.is_probed, parent_pair, scope, parent, invocation, body_closure)
    # The method's own code runs in this closure, whose compiled specialization records that code's effects.
    quote
        $body_closure = () -> $rewritten
        $invocation = $entered
        local $result
        try
            $result = $run
        catch
            $abort($session)
            rethrow()
        end
        $leave($session, $result, $type_of($body_closure))
        $result
    end
end

function is_short_method(definition::Expr)
    definition.head === :(=) || return false
    isempty(definition.args) && return false
    signature = definition.args[1]
    signature isa Expr || return false
    signature.head === :call || signature.head === :where || signature.head === :(::)
end

is_inner_expr(argument) = argument isa Expr

function rewrite_macro(definition::Expr, site::ProbeSite)
    macro_name = macro_symbol(definition.args[1])
    macro_name in SKIPPED_MACROS && return nothing
    inner_index = findlast(is_inner_expr, definition.args)
    isnothing(inner_index) && return nothing
    inner = definition.args[inner_index]
    rewritten = rewrite_definition(inner, site)
    isnothing(rewritten) && return nothing
    macro_name === Symbol("@doc") && return rewritten
    args = Vector{Any}(undef, length(definition.args))
    for index in eachindex(definition.args)
        args[index] = definition.args[index]
    end
    args[inner_index] = rewritten
    Expr(:macrocall, args...)
end

function rewrite_definition(definition::Expr, site::ProbeSite)
    if definition.head === :macrocall
        return rewrite_macro(definition, site)
    end
    long_form = definition.head === :function && length(definition.args) == 2
    short_form = is_short_method(definition)
    long_form || short_form || return nothing
    copied = deepcopy(definition.args[1])
    unpacking = Any[]
    signature = named_signature(copied, unpacking)
    shape = argument_shape(signature)
    written = deepcopy(definition.args[2])
    body = Expr(:block, unpacking..., written)
    probed = probe_body(site, shape, body)
    Expr(:function, signature, probed)
end

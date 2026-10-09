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
    text = string(found)
    all(==('_'), text) && return false
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

function is_wait_name(name)
    name === :fetch && return true
    name === :wait && return true
    false
end

function wait_probe(name::Symbol)
    if name === :fetch
        return GlobalRef(@__MODULE__, :probe_fetch)
    end
    GlobalRef(@__MODULE__, :probe_wait)
end

function is_sync_macro(node::Expr)
    node.head === :macrocall || return false
    isempty(node.args) && return false
    name = macro_symbol(node.args[1])
    name === Symbol("@sync")
end

function rewrite_children(node::Expr)
    args = Any[]
    for child in node.args
        walked = rewrite_waits(child)
        push!(args, walked)
    end
    Expr(node.head, args...)
end

function rewrite_broadcast(node)
    length(node.args) < 2 && return nothing
    tail = node.args[2]
    tail isa Expr || return nothing
    tail.head === :tuple || return nothing
    name = macro_symbol(node.args[1])
    is_wait_name(name) || return nothing
    probe = wait_probe(name)
    rewritten_tail = rewrite_waits(tail)
    Expr(:., probe, rewritten_tail)
end

function rewrite_dot(node)
    rewritten = rewrite_broadcast(node)
    if !isnothing(rewritten)
        return rewritten
    end
    rewrite_children(node)
end

function rewrite_wait_head(node)
    name = macro_symbol(node)
    is_wait_name(name) || return node
    wait_probe(name)
end

function rewrite_call(node)
    isempty(node.args) && return node
    args = Any[]
    for child in node.args
        walked = rewrite_waits(child)
        replaced = rewrite_wait_head(walked)
        push!(args, replaced)
    end
    Expr(:call, args...)
end

function rewrite_sync(node)
    body = last(node.args)
    rewritten = rewrite_waits(body)
    channel = GlobalRef(Base, :Channel)
    finish = GlobalRef(@__MODULE__, :log_sync_end)
    bound = Base.sync_varname
    opened = Expr(:call, channel, Inf)
    binding = Expr(:(=), bound, opened)
    value = gensym(:sync_value)
    assign = Expr(:(=), value, rewritten)
    logged = Expr(:call, finish, bound)
    block = Expr(:block, assign, logged, value)
    Expr(:let, binding, block)
end

rewrite_waits(node) = node

function rewrite_waits(node::Expr)
    rewrite_head(Val(node.head), node)
end

rewrite_head(::Val{:quote}, node::Expr) = node

function rewrite_head(::Val{:macrocall}, node::Expr)
    is_sync_macro(node) && return rewrite_sync(node)
    rewrite_children(node)
end

rewrite_head(::Val{:.}, node::Expr) = rewrite_dot(node)
rewrite_head(::Val{:call}, node::Expr) = rewrite_call(node)
rewrite_head(::Val, node::Expr) = rewrite_children(node)

function key_hash_expr(key, positional, keywords, producer::Symbol)
    isnothing(key) && return nothing
    key_name = string(nameof(key))
    producer_name = string(producer)
    quote
        try
            value = $key($positional...; $keywords...)
            hash(value)
        catch cause
            shown = sprint(showerror, cause)
            message = "key " * $key_name * " of producer " * $producer_name * " failed: " * shown
            throw(ArgumentError(message))
        end
    end
end

function scoped_run(is_probed::Bool, parent_pair, scope, parent, quoted_name, rewritten)
    if is_probed
        return quote
            $parent_pair = $parent => $quoted_name
            $scope($parent_pair) do
                (() -> $rewritten)()
            end
        end
    end
    quote
        (() -> $rewritten)()
    end
end

function probe_body(name::Symbol, file::String, line::Int, shape::ArgumentShape, key, is_probed::Bool, body)
    session_active = gensym(:session_active)
    result = gensym(:probe_result)
    arguments = shape.arguments
    hashed = key_hash_expr(key, shape.positional, shape.keywords, name)
    rewritten = rewrite_waits(body)
    enter = GlobalRef(@__MODULE__, :probe_enter)
    leave = GlobalRef(@__MODULE__, :probe_leave)
    abort = GlobalRef(@__MODULE__, :probe_abort)
    quoted_name = QuoteNode(name)
    scope = GlobalRef(Base.ScopedValues, :with)
    parent = GlobalRef(@__MODULE__, :PARENT_CALL)
    parent_pair = gensym(:parent_pair)
    entered = :($enter($quoted_name, $file, $line, $arguments, $hashed, $is_probed))
    run = scoped_run(is_probed, parent_pair, scope, parent, quoted_name, rewritten)
    quote
        $session_active = $entered
        local $result
        try
            $result = $run
        catch
            $abort($session_active)
            rethrow()
        end
        $leave($session_active, $result)
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

function rewrite_macro(definition::Expr, name::Symbol, file::String, line::Int, is_probed::Bool, key)
    macro_name = macro_symbol(definition.args[1])
    macro_name in SKIPPED_MACROS && return nothing
    inner_index = findlast(is_inner_expr, definition.args)
    isnothing(inner_index) && return nothing
    inner = definition.args[inner_index]
    rewritten = rewrite_definition(inner, name, file, line, is_probed, key)
    isnothing(rewritten) && return nothing
    macro_name === Symbol("@doc") && return rewritten
    args = Vector{Any}(undef, length(definition.args))
    for index in eachindex(definition.args)
        args[index] = definition.args[index]
    end
    args[inner_index] = rewritten
    Expr(:macrocall, args...)
end

function rewrite_definition(definition::Expr, name::Symbol, file::String, line::Int, is_probed::Bool, key)
    if definition.head === :macrocall
        return rewrite_macro(definition, name, file, line, is_probed, key)
    end
    long_form = definition.head === :function && length(definition.args) == 2
    short_form = is_short_method(definition)
    long_form || short_form || return nothing
    signature = definition.args[1]
    shape = argument_shape(signature)
    body = deepcopy(definition.args[2])
    probed = probe_body(name, file, line, shape, key, is_probed, body)
    copied = deepcopy(signature)
    Expr(:function, copied, probed)
end

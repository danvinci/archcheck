# The call zoom: declared methods observed while a workload runs. Julia has no function-entry hook, so a probed
# method is evaluated again from its parsed source with an entry and an exit probe, and restored afterwards.

"""What a package asks the gate to observe: the functions to probe, and the functions whose callees read state no
argument shows (a session over a global library), whose calls the analyses set apart."""
Base.@kwdef struct Probes{F<:Tuple,A<:Tuple}
    functions::F              # every method of each, defined in the package, is probed
    ambient::A = ()           # a probed call inside one of these reads state its arguments do not show
    slow_s::Float64 = 0.005   # a call shorter than this leaves no record (s)
end

struct ProbeSkip
    method::String     # printed method that was not rewritten
    reason::String     # why the rewrite was refused
end

struct MethodSource
    mod::Module         # where the statement evaluates
    definition::Expr    # statement put back on the way out
    name::Symbol        # function the method belongs to
    signature::String   # printed signature of the wrapper
end

struct ProbeHandle
    session::ProbeSession            # where records accumulate
    originals::Vector{MethodSource}  # statements to evaluate back
end

# The statement evaluated again: the method form with the macro calls that wrap it. A docstring stays out, since
# the docs outlive the deleted method and evaluating one again replaces them.
function definition_statement(form)
    node = form
    while !isnothing(node.parent)
        parent = node.parent
        kind = JS.kind(parent)
        kind == K"macrocall" || break
        node = parent
    end
    node
end

function is_in_struct(form)
    node = form.parent
    while !isnothing(node)
        kind = JS.kind(node)
        kind == K"struct" && return true
        node = node.parent
    end
    false
end

# A type's default constructors have no source form, and its inner constructors call `new`, which only its struct
# body defines; its outer constructors are probed.
is_unprobed_constructor(::Type, located) = isnothing(located) || is_in_struct(located.form)
is_unprobed_constructor(::Any, located) = false

function note_skip!(skipped, method, reason::String)
    label = string(method)
    push!(skipped, ProbeSkip(label, reason))
    nothing
end

function skip_error(skipped)
    lines = String[]
    for skip in skipped
        line = skip.method * ": " * skip.reason
        push!(lines, line)
    end
    text = join(lines, "; ")
    ArgumentError(text)
end

# The saved definition is retagged to the method's file, so the restored method records that path.
retag_lines!(node, ::Symbol) = node

function retag_lines!(node::Expr, file::Symbol)
    for index in eachindex(node.args)
        arg = node.args[index]
        if arg isa LineNumberNode
            node.args[index] = LineNumberNode(arg.line, file)
        else
            retag_lines!(arg, file)
        end
    end
    node
end

function keyword_method(method)
    decls = Base.kwarg_decl(method)
    isempty(decls) && return nothing
    body = Base.unwrap_unionall(method.sig)
    params = body.parameters
    tail = params[2:end]
    owner = params[1]
    bare = Tuple{NamedTuple, owner, tail...}
    # The method's where-clause binds the parameters of the query.
    query = Base.rewrap_unionall(bare, method.sig)
    which(Core.kwcall, query)
end

# Deleting first makes the following definition a fresh method.
function drop_method!(method)
    keyword = keyword_method(method)
    if !isnothing(keyword)
        Base.delete_method(keyword)
    end
    Base.delete_method(method)
    nothing
end

# The evaluated wrapper keeps this signature. Its file and line are the probe source.
function lookup_method(source)
    fn = getfield(source.mod, source.name)
    for method in methods(fn)
        method.module === source.mod || continue
        label = string(method.sig)
        label == source.signature && return method
    end
    nothing
end

function key_for(derived, method)
    for declared in derived
        isnothing(declared.key) && continue
        table = methods(declared.producer)
        method in table && return declared.key
    end
    nothing
end

function install_method!(method, located, is_probed::Bool, originals, skipped, key)
    if isdefined(method, :generator)
        note_skip!(skipped, method, "generated")
        return nothing
    end
    if isnothing(located)
        note_skip!(skipped, method, "no source site in the index")
        return nothing
    end
    statement = definition_statement(located.form)
    saved = Expr(statement)
    retag_lines!(saved, method.file)
    line = Int(method.line)
    probed = rewrite_definition(saved, method.name, located.file.path, line, is_probed, key)
    if isnothing(probed)
        note_skip!(skipped, method, "a form the rewrite does not take")
        return nothing
    end
    home = method.module
    source = keyword_source(method, saved, probed, home)
    if isnothing(source)
        source = replaced_source(method, saved, probed, home)
    end
    push!(originals, source)
    nothing
end

# The keyword body binding stays the one lowering created. A fresh name would sit in a
# later world than the caller that armed the probe.
function body_parameter(name::Symbol)
    name === Symbol("") && return gensym(:outer)
    name
end

function body_call(body::Function, method::Method)
    names = Base.method_argnames(method)
    args = Any[]
    last_index = length(names)
    for index in 2:last_index
        parameter = body_parameter(names[index])
        if method.isva && index == last_index
            parameter = Expr(:..., parameter)
        end
        push!(args, parameter)
    end
    Expr(:call, nameof(body), args...)
end

function defined_body(method::Method)
    decls = Base.kwarg_decl(method)
    isempty(decls) && return nothing
    Base.bodyfunction(method)
end

function newest_method(body::Function)
    chosen = nothing
    for method in methods(body)
        if isnothing(chosen) || method.primary_world > chosen.primary_world
            chosen = method
        end
    end
    chosen
end

function function_body(definition::Expr)
    long_form = definition.head === :function && length(definition.args) == 2
    short_form = definition.head === :(=) && length(definition.args) == 2
    long_form || short_form || return nothing
    definition.args[2]
end

function keyword_source(method::Method, saved::Expr, probed::Expr, home::Module)
    probed.head === :function || return nothing
    body = defined_body(method)
    isnothing(body) && return nothing
    inner = function_body(saved)
    isnothing(inner) && return nothing
    target = newest_method(body)
    isnothing(target) && return nothing
    call = body_call(body, target)
    copied_call = deepcopy(call)
    copied_inner = deepcopy(inner)
    original = Expr(:function, copied_call, copied_inner)
    probed_inner = probed.args[2]
    replacement = Expr(:function, call, probed_inner)
    Base.delete_method(target)
    try
        Core.eval(home, replacement)
    catch
        Core.eval(home, original)
        rethrow()
    end
    installed = newest_method(body)
    label = string(installed.sig)
    body_name = nameof(body)
    MethodSource(home, original, body_name, label)
end

function replaced_source(method::Method, saved::Expr, probed::Expr, home::Module)
    name = method.name
    label = string(method.sig)
    source = MethodSource(home, saved, name, label)
    drop_method!(method)
    try
        Core.eval(home, probed)
    catch
        Core.eval(home, saved)
        rethrow()
    end
    source
end

function install!(functions, is_probed::Bool, ctx, originals, skipped)
    modules = package_modules(ctx)
    for target in functions
        defined = methods(target)
        for method in defined
            home = method.module
            home in modules || continue
            located = method_form(ctx.index, method)
            is_unprobed_constructor(target, located) && continue
            key = key_for(ctx.derived, method)
            install_method!(method, located, is_probed, originals, skipped, key)
        end
    end
    nothing
end

function restore_originals(originals)
    for source in originals
        current = lookup_method(source)
        if !isnothing(current)
            drop_method!(current)
        end
        Core.eval(source.mod, source.definition)
    end
    nothing
end

function except_installed(functions, installed)
    kept = Any[]
    for func in functions
        func in installed && continue
        push!(kept, func)
    end
    kept
end

function keyed_producers(derived)
    producers = Any[]
    for declared in derived
        isnothing(declared.key) && continue
        push!(producers, declared.producer)
    end
    producers
end

"""Evaluates every method of the probed functions defined in the package again, from the index's parse, with an
entry and an exit probe. Returns the handle that collects the records and later restores the methods."""
function arm!(probes::Probes, ctx)
    active = ACTIVE[]
    isnothing(active) || throw(ArgumentError("a probe session is already armed"))
    records = ProbeRecord[]
    waits = WaitRecord[]
    session = ProbeSession(probes.slow_s, records, waits, ReentrantLock())
    originals = MethodSource[]
    skipped = ProbeSkip[]
    ACTIVE[] = session
    try
        producers = keyed_producers(ctx.derived)
        install!(producers, true, ctx, originals, skipped)
        listed = except_installed(probes.functions, producers)
        ambient = except_installed(probes.ambient, producers)
        install!(listed, true, ctx, originals, skipped)
        install!(ambient, false, ctx, originals, skipped)
        isempty(skipped) || throw(skip_error(skipped))
    catch
        restore_originals(originals)
        ACTIVE[] = nothing
        rethrow()
    end
    ProbeHandle(session, originals)
end

"""Restores every method a handle probed to its source definition and returns the calls and the waits collected while armed."""
function disarm!(armed::ProbeHandle)
    restore_originals(armed.originals)
    active = ACTIVE[]
    if active === armed.session
        ACTIVE[] = nothing
    end
    records = copy(armed.session.records)
    waits = copy(armed.session.waits)
    ProbeTrace(records, waits)
end

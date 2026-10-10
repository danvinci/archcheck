# The call zoom: declared methods observed while a workload runs. Julia has no function-entry hook, so a probed
# method is evaluated again from its parsed source with an entry and an exit probe, and restored afterwards.

"""What a package asks the gate to observe: the functions to probe, and the functions whose callees read state no
argument shows (a session over a global library), whose calls the analyses set apart. Each is the function itself
or its path in the package, `:name` in the root module or `:(Sub.name)`, so a package's own tests can name one it
keeps internal."""
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
    mod::Module                  # where the statement evaluates
    definition::Expr             # statement put back on the way out
    name::Symbol                 # function the methods belong to
    signatures::Vector{String}   # printed signature of each method the probed statement defines
end

struct ProbeHandle{F<:Tuple}
    session::ProbeSession            # where records accumulate
    originals::Vector{MethodSource}  # statements to evaluate back
    functions::F                     # every function whose methods the session rewrote: producers, probed, ambient
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
function lookup_method(source::MethodSource, signature::String)
    fn = getfield(source.mod, source.name)
    for method in methods(fn)
        method.module === source.mod || continue
        label = string(method.sig)
        label == signature && return method
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

# A rewritten method holds its session among its roots, the literals its code names.
function holds_session(method::Method)
    isdefined(method, :roots) || return false
    for root in method.roots
        root isa ProbeSession && return true
    end
    false
end

# A keyword method's body is rewritten in place of the method the table lists for it.
function is_probed_method(method::Method)
    holds_session(method) && return true
    body = defined_body(method)
    isnothing(body) && return false
    rewritten = newest_method(body)
    isnothing(rewritten) && return false
    holds_session(rewritten)
end

# A keyword form's body runs for every method the form defines, so the method that names the body leads.
function form_lead(group::Vector{Method})
    for method in group
        body = defined_body(method)
        isnothing(body) || return method
    end
    first(group)
end

# Why a listed method cannot be rewritten; nothing when it can.
function refusal(method::Method, located)
    is_probed_method(method) && return "probed by a session still armed"
    isdefined(method, :generator) && return "generated"
    isnothing(located) && return "no source site in the index"
    nothing
end

# One source form, rewritten once for every listed method it defines.
function install_form!(group::Vector{Method}, located, session, is_probed::Bool, originals, skipped, derived)
    for member in group
        reason = refusal(member, located)
        isnothing(reason) && continue
        note_skip!(skipped, member, reason)
        return nothing
    end
    method = form_lead(group)
    key = key_for(derived, method)
    statement = definition_statement(located.form)
    saved = Expr(statement)
    retag_lines!(saved, method.file)
    line = Int(method.line)
    joins = free_joins(located.form)
    site = ProbeSite(session, method.name, located.file.path, line, is_probed, key, joins)
    probed = rewrite_definition(saved, site)
    if isnothing(probed)
        note_skip!(skipped, method, "a form the rewrite does not take")
        return nothing
    end
    home = method.module
    source = keyword_source(method, saved, probed, home)
    if isnothing(source)
        source = replaced_source(group, saved, probed, home)
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

# The keyword body method's own signature: its declared types under its where-clause, lowering's names for the
# keyword slots, and the probed source's names for the slots after them, which the probed body reads.
function body_signature(body::Function, target::Method, slots::Vector{Symbol})
    names = Base.method_argnames(target)
    declared = Base.unwrap_unionall(target.sig)
    types = declared.parameters
    keyword_end = length(names) - length(slots)
    args = Any[]
    for index in 2:length(names)
        written = index > keyword_end ? slots[index - keyword_end] : names[index]
        parameter = body_parameter(written)
        annotation = type_expression(types[index])
        typed = Expr(:(::), parameter, annotation)
        push!(args, typed)
    end
    call = Expr(:call, nameof(body), args...)
    where_clause(call, target.sig)
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

# The body method that exists after the replacement is evaluated. The table changed, so the earlier read does not name it.
function install_keyword_body!(body::Function, target::Method, original::Expr, replacement::Expr, home::Module)
    Base.delete_method(target)
    try
        Core.eval(home, replacement)
    catch
        Core.eval(home, original)
        rethrow()
    end
    newest_method(body)
end

function keyword_source(method::Method, saved::Expr, probed::Expr, home::Module)
    probed.head === :function || return nothing
    body = defined_body(method)
    isnothing(body) && return nothing
    inner = function_body(saved)
    isnothing(inner) && return nothing
    target = newest_method(body)
    isnothing(target) && return nothing
    probed_signature = probed.args[1]
    slots = slot_names(probed_signature)
    call = body_signature(body, target, slots)
    copied_call = deepcopy(call)
    saved_signature = saved.args[1]
    copied_inner = unpacked_body(saved_signature, inner)
    original = Expr(:function, copied_call, copied_inner)
    probed_inner = probed.args[2]
    replacement = Expr(:function, call, probed_inner)
    installed = install_keyword_body!(body, target, original, replacement, home)
    label = string(installed.sig)
    body_name = nameof(body)
    MethodSource(home, original, body_name, [label])
end

function replaced_source(group::Vector{Method}, saved::Expr, probed::Expr, home::Module)
    lead = first(group)
    labels = String[]
    for method in group
        label = string(method.sig)
        push!(labels, label)
    end
    source = MethodSource(home, saved, lead.name, labels)
    for method in group
        drop_method!(method)
    end
    try
        Core.eval(home, probed)
    catch
        Core.eval(home, saved)
        rethrow()
    end
    source
end

function methods_of_form(listed, located, form)
    group = Method[]
    for index in eachindex(listed)
        found = located[index]
        isnothing(found) && continue
        found.form === form && push!(group, listed[index])
    end
    group
end

# Positional defaults make several listed methods from one source form, and evaluating the form again defines
# them all, so each form is installed once, for its whole group.
function install_target!(target, session, is_probed::Bool, ctx, originals, skipped)
    modules = package_modules(ctx)
    listed = Method[]
    located = Any[]
    for method in methods(target)
        method.module in modules || continue
        found = method_form(ctx.index, method)
        push!(listed, method)
        push!(located, found)
    end
    installed = Base.IdSet{Any}()
    for index in eachindex(listed)
        method = listed[index]
        found = located[index]
        is_unprobed_constructor(target, found) && continue
        if isnothing(found)
            reason = refusal(method, found)
            note_skip!(skipped, method, reason)
            continue
        end
        found.form in installed && continue
        push!(installed, found.form)
        group = methods_of_form(listed, located, found.form)
        install_form!(group, found, session, is_probed, originals, skipped, ctx.derived)
    end
    nothing
end

function install!(functions, session, is_probed::Bool, ctx, originals, skipped)
    for target in functions
        install_target!(target, session, is_probed, ctx, originals, skipped)
    end
    nothing
end

function restore_originals(originals)
    for source in originals
        for signature in source.signatures
            current = lookup_method(source, signature)
            isnothing(current) || drop_method!(current)
        end
        Core.eval(source.mod, source.definition)
    end
    nothing
end

function probed_function(ctx, path::Symbol)
    found = package_callable(ctx, path)
    isnothing(found) && throw(ArgumentError("no function in the package is at the path $path"))
    found
end

probed_function(ctx, path::Expr) = probed_function(ctx, Symbol(string(path)))
probed_function(ctx, target) = target

function probed_functions(ctx, targets)
    resolved = Any[]
    for target in targets
        found = probed_function(ctx, target)
        push!(resolved, found)
    end
    resolved
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
entry and an exit probe. Returns the handle that collects the records and later restores the methods. Sessions
nest: a method another armed session probes is refused."""
function arm!(probes::Probes, ctx)
    session = ProbeSession(probes.slow_s)
    originals = MethodSource[]
    skipped = ProbeSkip[]
    try
        producers = keyed_producers(ctx.derived)
        install!(producers, session, true, ctx, originals, skipped)
        named = probed_functions(ctx, probes.functions)
        named_ambient = probed_functions(ctx, probes.ambient)
        listed = except_installed(named, producers)
        ambient = except_installed(named_ambient, producers)
        install!(listed, session, true, ctx, originals, skipped)
        install!(ambient, session, false, ctx, originals, skipped)
        isempty(skipped) || throw(skip_error(skipped))
        rewritten = (producers..., listed..., ambient...)
        return ProbeHandle(session, originals, rewritten)
    catch
        restore_originals(originals)
        rethrow()
    end
end

"""Restores every method a handle probed to its source definition and returns the calls and the waits collected while armed."""
function disarm!(armed::ProbeHandle)
    restore_originals(armed.originals)
    records = copy(armed.session.records)
    waits = copy(armed.session.waits)
    ProbeTrace(records, waits)
end

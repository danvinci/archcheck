# The method zoom of the call graph: the methods each call can land on. The name graph merges every method of a
# function into one node; this one keeps them apart.

"""Calls between methods. An edge joins a caller to a method a call can land on: the one inference resolved, or, for
a call left to runtime dispatch, each package method the call's inferred types match."""
struct MethodGraph
    edges::Dict{Method,Set{Method}}   # caller -> methods its calls can land on; every walked method is a key
end

# A keyword body is the generated `#name#N` function. Its edges belong to the method the source wrote.
const KEYWORD_BODY = r"^#[^#]+#[0-9]+$"

"""The calls between methods reached from `entries`, each a `Core.MethodInstance` or a `(function, argument types)`
pair; only methods `modules` define expand, and `values` names the functions a callee unknown at its site can hold."""
function method_graph(entries, modules, values)
    module_set = Set{Module}(modules)
    edges = Dict{Method,Set{Method}}()
    pending = Core.MethodInstance[]
    walked = Dict{Method,Any}()   # method -> the signature its walks cover
    for entry in entries
        instance = entry_instance(entry)
        push!(pending, instance)
    end
    # A resolved call is an edge on the inference frame, including one the optimized code drops.
    interp = Core.Compiler.NativeInterpreter()
    while !isempty(pending)
        reached = pop!(pending)
        instance = covering_instance(walked, reached)
        isnothing(instance) && continue
        walked[instance.def] = instance.specTypes
        expand_instance!(edges, pending, instance, module_set, values, interp)
    end
    MethodGraph(edges)
end

# A method reached outside the signature its walks cover is walked again at the join of both. Each join climbs the
# type lattice, so argument types inference nests across walks stop at a signature covering every nesting.
function covering_instance(walked, reached::Core.MethodInstance)
    method = reached.def
    haskey(walked, method) || return reached
    covered = walked[method]
    reached.specTypes <: covered && return nothing
    joined = typejoin(covered, reached.specTypes)
    instance_at(method, joined)
end

function entry_instance(@nospecialize(entry))
    entry isa Core.MethodInstance && return entry
    if !(entry isa Tuple) || length(entry) != 2
        throw(ArgumentError("an entry is a method instance or a function and its argument types"))
    end
    func = entry[1]
    argtypes = entry[2]
    instance = Base.method_instance(func, argtypes)
    isnothing(instance) && throw(ArgumentError("no method instance matches the entry"))
    instance
end

function expand_instance!(edges, pending, instance, module_set, values, interp)
    frame = inference_frame(instance, interp)
    if is_kwcall_method(instance.def)
        body = keyword_body_from(frame)
        isnothing(body) || push!(pending, body)
        return
    end
    caller = written_method(instance.def)
    get!(edges, caller, Set{Method}())
    record_resolved!(edges, pending, frame, caller, module_set)
    code = inferred_code(instance, interp)
    isnothing(code) && return
    record_dispatched!(edges, pending, code, instance, caller, module_set, values)
end

function inference_frame(instance::Core.MethodInstance, interp)
    result = Core.Compiler.InferenceResult(instance)
    # `:no` leaves this inference's resolved calls on the frame.
    frame = Core.Compiler.InferenceState(result, :no, interp)
    Core.Compiler.typeinf(interp, frame)
    frame
end

function keyword_body_from(frame)
    for edge in frame.edges
        target = called_instance(edge)
        isnothing(target) && continue
        is_keyword_body(target.def) && return target
    end
    nothing
end

function record_resolved!(edges, pending, frame, caller, module_set)
    for edge in frame.edges
        target = called_instance(edge)
        isnothing(target) && continue
        callee = written_method(target.def)
        if callee === caller && is_keyword_body(target.def)
            enqueue_target!(pending, target, module_set)
            continue
        end
        add_edge!(edges, caller, callee)
        enqueue_target!(pending, target, module_set)
        record_passed!(edges, pending, caller, target, module_set)
    end
end

# A call left to runtime dispatch can land on each package method its inferred types match. Each is an edge, walked
# at the types the call holds, so a method reached only through such a call keeps its own calls in the graph.
function record_dispatched!(edges, pending, code, instance, caller, module_set, values)
    sptypes = Core.Compiler.sptypes_from_meth_instance(instance)
    for stmt in code.code
        stmt isa Expr || continue
        stmt.head === :call || continue
        call = dispatch_signature(code, sptypes, stmt.args)
        isnothing(call) && continue
        for match in package_matches(call, module_set, values)
            callee = written_method(match.method)
            add_edge!(edges, caller, callee)
            target = Core.Compiler.specialize_method(match)
            enqueue_target!(pending, target, module_set)
        end
    end
end

# The callee and argument types inference holds at a call; nothing for a builtin, or for a call it proved unreachable.
function dispatch_signature(code, sptypes, args)
    types = Any[]
    for arg in args
        inferred = Core.Compiler.argextype(arg, code, sptypes)
        widened = Core.Compiler.widenconst(inferred)
        widened === Union{} && return nothing
        push!(types, widened)
    end
    callee = first(types)
    # A splatted call left to runtime dispatch runs through `_apply_iterate`, which passes the function third.
    callee === typeof(Core._apply_iterate) && return Tuple{types[3], Vararg{Any}}
    callee <: Core.Builtin && return nothing
    Tuple{types...}
end

# The methods dispatch could pick for `call`, kept to those the package defines. A callee unknown at the site holds
# a function the package writes as a value, or an anonymous one.
function package_matches(call, module_set, values)
    world = Base.get_world_counter()
    matches = Base._methods_by_ftype(call, -1, world)::Vector
    callee = fieldtype(call, 1)
    is_known = isconcretetype(callee) || Base.isType(callee)
    kept = Core.MethodMatch[]
    for match in matches
        written = written_method(match.method)
        written.module in module_set || continue
        is_known || can_be_value(written, values) || continue
        push!(kept, match)
    end
    kept
end

can_be_value(method::Method, values) = startswith(string(method.name), "#") || method.name in values

function inferred_code(instance::Core.MethodInstance, interp)
    asts = Base.code_typed_by_type(instance.specTypes; interp)
    for pair in asts
        code = pair.first
        code isa Core.CodeInfo && return code
    end
    nothing
end

called_instance(target::Core.CodeInstance) = target.def
called_instance(target::Core.MethodInstance) = target
called_instance(@nospecialize(::Any)) = nothing

function add_edge!(edges, caller, callee)
    callees = get!(edges, caller, Set{Method}())
    push!(callees, callee)
end

# A function passed into an outside call expands at the specialization that inference compiled for it.
# When that call compiled none, the method expands at its declared signature.
function record_passed!(edges, pending, caller, target, module_set)
    is_kwcall_method(target.def) && return
    target.def.module in module_set && return
    signature = Base.unwrap_unionall(target.specTypes)
    signature isa DataType || return
    parameters = signature.parameters
    for index in eachindex(parameters)
        index == 1 && continue
        argument = parameters[index]
        connect_function_type!(edges, pending, caller, argument, module_set)
    end
end

function is_owned_function_type(@nospecialize(argument), module_set)
    argument isa DataType || return false
    isconcretetype(argument) || return false
    argument <: Function || return false
    parentmodule(argument) in module_set
end

function connect_compiled!(edges, pending, caller, owned, module_set)
    connected = false
    for method in owned
        compiled = Base.specializations(method)
        specs = collect(Core.MethodInstance, compiled)
        isempty(specs) && continue
        connected = true
        connect_method!(edges, pending, caller, method, specs, module_set)
    end
    connected
end

function connect_declared!(edges, pending, caller, owned, module_set)
    for method in owned
        instance = declared_instance(method)
        instances = Core.MethodInstance[instance]
        connect_method!(edges, pending, caller, method, instances, module_set)
    end
end

function connect_function_type!(edges, pending, caller, @nospecialize(argument), module_set)
    is_owned_function_type(argument, module_set) || return
    owned = passed_methods(argument, module_set)
    connected = connect_compiled!(edges, pending, caller, owned, module_set)
    connected && return
    connect_declared!(edges, pending, caller, owned, module_set)
end

function passed_methods(@nospecialize(argument), module_set)
    signature = Tuple{argument, Vararg{Any}}
    world = Base.get_world_counter()
    matches = Base._methods_by_ftype(signature, -1, world)
    found = Method[]
    for match in matches
        method = match.method
        method.module in module_set || continue
        push!(found, method)
    end
    found
end

function connect_method!(edges, pending, caller, method, instances, module_set)
    written = written_method(method)
    add_edge!(edges, caller, written)
    for instance in instances
        enqueue_target!(pending, instance, module_set)
    end
end

# A method specialized to the part of `signature` its own signature admits, type variables it leaves open kept free.
function instance_at(method::Method, @nospecialize(signature))
    intersection = ccall(:jl_type_intersection_with_env, Any, (Any, Any), signature, method.sig)::Core.SimpleVector
    Core.Compiler.specialize_method(method, intersection[1], intersection[2])
end

# A method at its declared signature: the widest specialization, so its calls cover every narrower one's.
declared_instance(method::Method) = instance_at(method, method.sig)

function enqueue_target!(pending, target, module_set)
    method = target.def
    if is_kwcall_method(method)
        home = written_method(method).module
        home in module_set || return
        push!(pending, target)
        return
    end
    method.module in module_set || return
    push!(pending, target)
end

is_kwcall_method(method::Method) = is_kwcall_signature(method.sig)

function is_keyword_body(method::Method)
    text = string(method.name)
    occursin(KEYWORD_BODY, text)
end

function written_method(method::Method)
    is_kwcall_method(method) && return written_from_kwcall(method)
    is_keyword_body(method) && return written_from_body(method)
    method
end

function written_from_kwcall(method::Method)
    parts = split_signature(method.sig)
    func = function_instance(parts[1])
    isnothing(func) && return method
    found = method_for(func, parts[2], method)
    isnothing(found) && return method
    found
end

function named_function_param(params, wanted)
    for index in eachindex(params)
        value = function_instance(params[index])
        isnothing(value) && continue
        nameof(value) === wanted || continue
        return (value, index)
    end
    nothing
end

function written_from_body(method::Method)
    wanted = Symbol(written_name(method.name))
    params = Base.unwrap_unionall(method.sig).parameters
    located = named_function_param(params, wanted)
    isnothing(located) && return method
    func, func_index = located
    positional = params[func_index + 1:end]
    found = method_for(func, positional, method)
    isnothing(found) && return method
    found
end

function function_instance(@nospecialize(type))
    type isa DataType || return nothing
    isdefined(type, :instance) || return nothing
    value = getfield(type, :instance)
    value isa Function || return nothing
    value
end

# Positional types read from a keyword method can hold the written method's type variables; wrap them again.
function method_for(func, positional, keyword_method::Method)
    open_types = Tuple{positional...}
    argtype = Base.rewrap_unionall(open_types, keyword_method.sig)
    hasmethod(func, argtype) || return nothing
    which(func, argtype)
end

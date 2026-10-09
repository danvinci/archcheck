# The method zoom of the call graph: which method each call lands on, as inference resolves it. The name graph
# merges every method of a function into one node; this one keeps them apart.

"""Calls between methods. An edge is a call inference resolved to one method; a call it left to runtime dispatch
stays a name under its caller, so a gap in the graph is counted rather than silent."""
struct MethodGraph
    edges::Dict{Method,Set{Method}}        # caller -> callees inference resolved to one method
    unresolved::Dict{Method,Set{Symbol}}   # caller -> names of calls left to runtime dispatch
end

# A keyword body is the generated `#name#N` function. Its edges belong to the method the source wrote.
const KEYWORD_BODY = r"^#[^#]+#[0-9]+$"

"""The calls between methods reached from `entries`, each a `Core.MethodInstance` or a `(function, argument tuple
type)` pair, read from that instance's inference edges; only methods `modules` define expand."""
function method_graph(entries, modules)
    module_set = Set{Module}(modules)
    edges = Dict{Method,Set{Method}}()
    unresolved = Dict{Method,Set{Symbol}}()
    pending = Core.MethodInstance[]
    seen = Set{Core.MethodInstance}()
    for entry in entries
        instance = entry_instance(entry)
        push!(pending, instance)
    end
    # A resolved call is an edge on the inference frame, including one the optimized code drops.
    interp = Core.Compiler.NativeInterpreter()
    while !isempty(pending)
        instance = pop!(pending)
        instance in seen && continue
        push!(seen, instance)
        expand_instance!(edges, unresolved, pending, instance, module_set, interp)
    end
    MethodGraph(edges, unresolved)
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

function expand_instance!(edges, unresolved, pending, instance, module_set, interp)
    frame = inference_frame(instance, interp)
    if is_kwcall_method(instance.def)
        body = keyword_body_from(frame)
        isnothing(body) || push!(pending, body)
        return
    end
    caller = written_method(instance.def)
    record_resolved!(edges, pending, frame, caller, module_set)
    code = inferred_code(instance, interp)
    isnothing(code) && return
    scan_unresolved!(unresolved, code, caller, module_set, frame)
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

function resolved_names(frame)
    names = Set{Symbol}()
    for edge in frame.edges
        target = called_instance(edge)
        isnothing(target) && continue
        push!(names, target.def.name)
    end
    names
end

function scan_unresolved!(unresolved, code, caller, module_set, frame)
    resolved = resolved_names(frame)
    slot_names = code.slotnames
    for stmt in code.code
        stmt isa Expr || continue
        stmt.head === :call || continue
        name = callee_name(stmt.args[1], slot_names)
        if !isnothing(name) && name in resolved
            continue
        end
        record_call!(unresolved, stmt, caller, module_set, slot_names)
    end
end

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
        isnothing(instance) && continue
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

function declared_instance(method::Method)
    signature = method.sig
    signature isa DataType || return nothing
    Core.Compiler.specialize_method(method, signature, Core.svec())
end

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

function record_call!(unresolved, stmt, caller, module_set, slot_names)
    callee = stmt.args[1]
    is_builtin_callee(callee) && return
    name = callee_name(callee, slot_names)
    isnothing(name) && return
    owned = is_owned_callee(callee, module_set)
    dynamic = is_dynamic_callee(callee)
    owned || dynamic || return
    names = get!(unresolved, caller, Set{Symbol}())
    push!(names, name)
end

function constant_function(callee::GlobalRef)
    isdefined(callee.mod, callee.name) || return nothing
    value = getfield(callee.mod, callee.name)
    value isa Function || return nothing
    value
end

constant_function(callee::Function) = callee
constant_function(@nospecialize(::Any)) = nothing

is_builtin_value(::Core.Builtin) = true
is_builtin_value(::Core.IntrinsicFunction) = true
is_builtin_value(@nospecialize(::Any)) = false

function is_builtin_callee(@nospecialize(callee))
    value = constant_function(callee)
    isnothing(value) && return false
    is_builtin_value(value)
end

function is_owned_callee(@nospecialize(callee), module_set)
    callee isa GlobalRef && return callee.mod in module_set
    value = constant_function(callee)
    isnothing(value) && return false
    parentmodule(value) in module_set
end

is_dynamic_callee(::Core.Argument) = true
is_dynamic_callee(::Core.SlotNumber) = true
is_dynamic_callee(::Core.SSAValue) = true
is_dynamic_callee(::Expr) = true
is_dynamic_callee(@nospecialize(::Any)) = false

callee_name(callee::GlobalRef, slot_names) = callee.name
callee_name(callee::Function, slot_names) = nameof(callee)
callee_name(callee::Core.Argument, slot_names) = slot_symbol(slot_names, callee.n)
callee_name(callee::Core.SlotNumber, slot_names) = slot_symbol(slot_names, callee.id)
callee_name(@nospecialize(::Any), slot_names) = nothing

function slot_symbol(slot_names, index)
    index in eachindex(slot_names) || return nothing
    slot_names[index]
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

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

function called_instance(@nospecialize(target))
    target isa Core.CodeInstance && return target.def
    target isa Core.MethodInstance && return target
    nothing
end

function add_edge!(edges, caller, callee)
    callees = get!(edges, caller, Set{Method}())
    push!(callees, callee)
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
    add_unresolved!(unresolved, caller, name)
end

function add_unresolved!(unresolved, caller, name)
    names = get!(unresolved, caller, Set{Symbol}())
    push!(names, name)
end

function constant_function(@nospecialize(callee))
    if callee isa GlobalRef
        isdefined(callee.mod, callee.name) || return nothing
        value = getfield(callee.mod, callee.name)
        return value isa Function ? value : nothing
    end
    callee isa Function && return callee
    nothing
end

function is_builtin_callee(@nospecialize(callee))
    value = constant_function(callee)
    isnothing(value) && return false
    value isa Core.Builtin || value isa Core.IntrinsicFunction
end

function is_owned_callee(@nospecialize(callee), module_set)
    callee isa GlobalRef && return callee.mod in module_set
    value = constant_function(callee)
    isnothing(value) && return false
    parentmodule(value) in module_set
end

function is_dynamic_callee(@nospecialize(callee))
    callee isa Core.Argument && return true
    callee isa Core.SlotNumber && return true
    callee isa Core.SSAValue && return true
    callee isa Expr && return true
    false
end

function callee_name(@nospecialize(callee), slot_names)
    callee isa GlobalRef && return callee.name
    callee isa Function && return nameof(callee)
    if callee isa Core.Argument
        return slot_symbol(slot_names, callee.n)
    end
    if callee isa Core.SlotNumber
        return slot_symbol(slot_names, callee.id)
    end
    nothing
end

function slot_symbol(slot_names, index)
    index in eachindex(slot_names) || return nothing
    slot_names[index]
end

function is_kwcall_method(method::Method)
    method.sig <: Tuple{typeof(Core.kwcall),Any,Any,Vararg}
end

function is_keyword_body(method::Method)
    text = string(method.name)
    !isnothing(match(KEYWORD_BODY, text))
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
    found = method_for(func, parts[2])
    isnothing(found) && return method
    found
end

function written_from_body(method::Method)
    wanted = Symbol(written_name(method.name))
    params = Base.unwrap_unionall(method.sig).parameters
    func = nothing
    func_index = 0
    for index in eachindex(params)
        value = function_instance(params[index])
        isnothing(value) && continue
        nameof(value) === wanted || continue
        func = value
        func_index = index
        break
    end
    isnothing(func) && return method
    positional = params[func_index+1:end]
    found = method_for(func, positional)
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

function method_for(func, positional)
    argtype = Tuple{positional...}
    instance = Base.method_instance(func, argtype)
    isnothing(instance) && return nothing
    instance.def
end

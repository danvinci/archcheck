# The method zoom of the call graph: the methods each call can land on. The name graph merges every method of a
# function into one node; this one keeps them apart.

"""Calls between methods. An edge joins a caller to a method a call can land on: the one inference resolved, or, for
a call left to runtime dispatch, each package method the call's inferred types match."""
struct MethodGraph
    edges::Dict{Method,Set{Method}}   # caller -> methods its calls can land on; every walked method is a key
end

# A keyword body is the generated `#name#N` function. Its edges belong to the method the source wrote.
const KEYWORD_BODY = r"^#[^#]+#[0-9]+$"

# Inference reads a callee it already holds more precisely than one it meets mid-walk, so a first walk in a cold
# process can land a call differently. The graph is the walk a further walk reproduces.
const GRAPH_WALKS_MAX = 4

# Where a runtime-dispatched call can land depends on its signature alone, so one graph matches each signature once.
struct CallLandings
    module_set::Set{Module}        # modules whose methods expand and whose methods a dispatched call can land on
    held::Base.IdSet{Method}       # package methods a callee unknown at its site can land on
    prefixes::Vector{Type}         # the signatures of the held methods' functions, each open after its function slot
    by_call::IdDict{Any,Vector{Tuple{Method,Core.MethodInstance}}}   # call signature -> each landing's written method and specialization
end

function CallLandings(modules, values)
    module_set = Set{Module}(modules)
    held = Base.IdSet{Method}()
    for method in project_methods(modules)
        is_held(method, values) && push!(held, method)
    end
    prefixes = held_signatures(held)
    by_call = IdDict{Any,Vector{Tuple{Method,Core.MethodInstance}}}()
    CallLandings(module_set, held, prefixes, by_call)
end

"""The calls between methods reached from `entries`, each a `Core.MethodInstance` or a `(function, argument types)`
pair; only methods `modules` define expand, and `values` names the functions a callee unknown at its site can hold."""
function method_graph(entries, modules, values)
    landings = CallLandings(modules, values)
    previous = nothing
    for _walk in 1:GRAPH_WALKS_MAX
        current = walk_methods(entries, landings)
        is_settled = !isnothing(previous) && current.edges == previous.edges
        is_settled && return current
        previous = current
    end
    error("the method graph changed on each of $GRAPH_WALKS_MAX walks")
end

function walk_methods(entries, landings::CallLandings)
    edges = Dict{Method,Set{Method}}()
    pending = Core.MethodInstance[]
    walked = Dict{Method,Any}()   # method -> the signature its walks cover
    # A walk only widens what it covers, so a specialization met once stays covered.
    met = Base.IdSet{Core.MethodInstance}()
    for entry in entries
        instance = entry_instance(entry)
        push!(pending, instance)
    end
    # A resolved call is an edge on the inference frame, including one the optimized code drops.
    interp = Core.Compiler.NativeInterpreter()
    while !isempty(pending)
        reached = pop!(pending)
        reached in met && continue
        push!(met, reached)
        instance = covering_instance(walked, reached)
        isnothing(instance) && continue
        walked[instance.def] = instance.specTypes
        expand_instance!(edges, pending, instance, landings, interp)
    end
    MethodGraph(edges)
end

# Each held method's function as the signature up to its function slot, open after it.
function held_signatures(held)
    # Types with free variables share hash buckets, so the set compares by identity: equal signatures of plain
    # functions are one cached object.
    found = Base.IdSet{Type}()
    for method in held
        prefix = callee_prefix(method)
        push!(found, prefix)
    end
    collect(Type, found)
end

# A callee unknown at its site lands on what the package can hand it: a function or type the source writes as a
# value, an anonymous function, or a callable object, whose instances any construction yields.
function is_held(method::Method, values)
    written = written_method(method)
    signature = split_signature(written.sig)
    slot = first(signature)
    slot isa Type || return true
    Base.isType(slot) && return written.name in values
    slot <: Function || return true
    can_be_value(written, values)
end

function callee_prefix(method::Method)
    parameters = Base.unwrap_unionall(method.sig).parameters
    if is_kwcall_method(method)
        func = parameters[3]
        prefix = Tuple{typeof(Core.kwcall),Any,func,Vararg{Any}}
    else
        func = parameters[1]
        prefix = Tuple{func,Vararg{Any}}
    end
    Base.has_free_typevars(func) || return prefix
    Base.rewrap_unionall(prefix, method.sig)
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

function expand_instance!(edges, pending, instance, landings::CallLandings, interp)
    module_set = landings.module_set
    is_keyword = is_kwcall_method(instance.def)
    frame = inference_frame(instance, interp; optimize = !is_keyword)
    isnothing(frame) && return
    if is_keyword
        body = keyword_body_from(frame)
        isnothing(body) || push!(pending, body)
        return
    end
    caller = written_method(instance.def)
    get!(edges, caller, Set{Method}())
    record_resolved!(edges, pending, frame, caller, module_set)
    record_dispatched!(edges, pending, frame.src, instance, caller, landings)
end

# One inference for both readers: the frame keeps its resolved calls, and `optimize` makes `src` the code `code_typed`
# returns. Nothing when inference fails.
function inference_frame(instance::Core.MethodInstance, interp; optimize::Bool)
    Core.Compiler.typeinf_frame(interp, instance, optimize)
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
function record_dispatched!(edges, pending, code, instance, caller, landings::CallLandings)
    module_set = landings.module_set
    sptypes = Core.Compiler.sptypes_from_meth_instance(instance)
    for (position, stmt) in pairs(code.code)
        stmt isa Expr || continue
        stmt.head === :call || continue
        is_inlined_package_call(code, position, module_set) && continue
        call = dispatch_signature(code, sptypes, stmt.args)
        isnothing(call) && continue
        for (callee, target) in landing_targets!(landings, call)
            add_edge!(edges, caller, callee)
            enqueue_target!(pending, target, module_set)
        end
    end
end

# The written method and the specialization of each package method `call` lands on.
function landing_targets!(landings::CallLandings, call)
    cached = get(landings.by_call, call, nothing)
    isnothing(cached) || return cached
    found = Tuple{Method,Core.MethodInstance}[]
    for match in package_matches(call, landings)
        callee = written_method(match.method)
        target = Core.Compiler.specialize_method(match)
        push!(found, (callee, target))
    end
    landings.by_call[call] = found
    found
end

# The optimizer copies an inlined method's calls into its caller. A package method keeps its own: the walk reaches it
# through the caller's resolved edge, at the types the copy holds.
function is_inlined_package_call(code, position, module_set)
    debuginfo = code.debuginfo
    location = Base.IRShow.getdebugidx(debuginfo, position)
    inlined_index = Int(location[2])
    inlined_index == 0 && return false
    inlined = debuginfo.edges[inlined_index].def
    inlined isa Core.MethodInstance || return false
    method = inlined.def
    method isa Method || return false
    method.module in module_set
end

# The callee and argument types inference holds at a call; nothing for a builtin, or for a call it proved unreachable.
function dispatch_signature(code, sptypes, args)
    types = Any[]
    for arg in args
        widened = widened_type(code, sptypes, arg)
        widened === Union{} && return nothing
        push!(types, widened)
    end
    callee = first(types)
    callee === typeof(Core._apply_iterate) && return spread_signature(code, sptypes, args, types)
    callee <: Core.Builtin && return nothing
    Tuple{types...}
end

function widened_type(code, sptypes, arg)
    inferred = Core.Compiler.argextype(arg, code, sptypes)
    Core.Compiler.widenconst(inferred)
end

# A splatted call runs through `_apply_iterate(iterate, f, spreads...)`, which calls `f` on the spreads' members in
# order. A spread of known length adds its member types; the first of unknown length leaves the rest open.
function spread_signature(code, sptypes, args, types)
    flattened = Any[types[3]]
    for index in 4:length(args)
        members = spread_members(code, sptypes, args[index], types[index])
        if isnothing(members)
            push!(flattened, Vararg{Any})
            break
        end
        append!(flattened, members)
    end
    Tuple{flattened...}
end

# The member types of a spread of known length: a tuple, or a `Core.svec` the code builds, as a keyword call's
# arguments are. Nothing for any other spread.
function spread_members(code, sptypes, arg, @nospecialize(spread))
    if spread isa DataType && spread <: Tuple
        parameters = spread.parameters
        is_open = !isempty(parameters) && Base.isvarargtype(last(parameters))
        is_open && return nothing
        return collect(Any, parameters)
    end
    spread === Core.SimpleVector || return nothing
    built_members(code, sptypes, arg)
end

# The argument types of the `Core.svec` call whose result `arg` names.
function built_members(code, sptypes, arg::Core.SSAValue)
    built = code.code[arg.id]
    built isa Expr || return nothing
    built.head === :call || return nothing
    builder = widened_type(code, sptypes, first(built.args))
    builder === typeof(Core.svec) || return nothing
    members = Any[]
    for member in built.args[2:end]
        member_type = widened_type(code, sptypes, member)
        push!(members, member_type)
    end
    members
end

built_members(code, sptypes, @nospecialize(::Any)) = nothing

# The function a call calls: a keyword call holds it in its third slot.
function called_function(call)
    head = fieldtype(call, 1)
    head === typeof(Core.kwcall) || return head
    fieldtype(call, 3)
end

# The methods dispatch could pick for `call`, kept to those the package defines. A callee is known when its type
# names one function or type; a `DataType` names none, so a call on it matches what the package holds.
function package_matches(call, landings::CallLandings)
    callee = called_function(call)
    is_type_object = callee <: Type && !Base.isType(callee)
    is_known = Base.isType(callee) || (isconcretetype(callee) && !is_type_object)
    is_known && return known_matches(call, landings.module_set)
    held_matches(call, landings)
end

function known_matches(call, module_set)
    world = Base.get_world_counter()
    matches = Base._methods_by_ftype(call, -1, world)::Vector
    kept = Core.MethodMatch[]
    for match in matches
        written = written_method(match.method)
        written.module in module_set || continue
        push!(kept, match)
    end
    kept
end

# Each held signature the call's types admit, matched against that function's own methods, kept to held methods.
function held_matches(call, landings::CallLandings)
    world = Base.get_world_counter()
    kept = Core.MethodMatch[]
    for prefix in landings.prefixes
        narrowed = typeintersect(call, prefix)
        narrowed === Union{} && continue
        matches = Base._methods_by_ftype(narrowed, -1, world)::Vector
        for match in matches
            match.method in landings.held || continue
            push!(kept, match)
        end
    end
    kept
end

can_be_value(method::Method, values) = startswith(string(method.name), "#") || method.name in values

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

# The method zoom of the call graph: the methods each call can land on. The name graph merges every method of a
# function into one node; this one keeps them apart.

"""What the walk's inference proved about one call a walked method writes, merged over its instances and its method's
declared signature, so a bit holds for every argument the method accepts."""
struct CallFact
    file::Symbol            # file the call's line sits in, as the code records it; empty when it records none
    line::Int               # source line of the call; 0 when the code records none
    callee::Symbol          # name of the function or type called; empty when the callee's type names neither
    via::Symbol             # :call, :apply for a splatted call, :kwcall for a call with keywords
    is_used::Bool           # some instance reads the call's value
    is_failing::Bool        # at every instance no method matches any argument type inference allows there
    failing::String         # the call signatures no method matches, `;`-joined; empty when a method matches
    is_stub::Bool           # the called function has no method at all
    is_forward::Bool        # keywords passed through a splat whose names inference does not know
    is_effect_free::Bool    # writes no state
    is_terminating::Bool    # terminates
    is_nothrow::Bool        # cannot throw
    is_consistent::Bool     # equal arguments give an equal result
    is_generated::Bool      # a method the call matches is `@generated`
    is_value::Bool          # returns, and returns a value other than `nothing`
    returns::String         # the inferred return type at the first instance walked; empty unless it drops a pure value
end

"""Calls between methods. An edge joins a caller to a method a call can land on: the one inference resolved, or, for
a call left to runtime dispatch, each package method the call's inferred types match."""
struct MethodGraph
    edges::Dict{Method,Set{Method}}         # caller -> methods its calls can land on; every walked method is a key
    calls::Dict{Method,Vector{CallFact}}    # caller -> what the walk's inference proved about each call it writes
    typed::Dict{Method,Vector{Core.CodeInfo}}   # caller -> the code inference typed at each instance walked, unoptimized
end

# Inference reads a callee it already holds more precisely than one it meets mid-walk, so a first walk in a cold
# process can land a call differently. The graph is the walk a further walk reproduces.
const GRAPH_WALKS_MAX = 4

# Where a runtime-dispatched call can land depends on its signature alone, so one graph matches each signature once.
struct CallLandings{M<:AbstractSet,P<:AbstractVector,C<:AbstractDict}
    module_set::Set{Module}   # modules whose methods expand and whose methods a dispatched call can land on
    held::M                   # package methods a callee unknown at its site can land on
    prefixes::P               # the signatures of the held methods' functions, each open after its function slot
    by_call::C                # call signature -> the written method and specialization of each landing
end

function CallLandings(modules, values, defined)
    module_set = Set{Module}(modules)
    held = Base.IdSet{Method}()
    for method in defined
        method.module in module_set || continue
        is_held(method, values) && push!(held, method)
    end
    prefixes = held_signatures(held)
    by_call = IdDict{Any,Vector{Tuple{Method,Core.MethodInstance}}}()
    CallLandings(module_set, held, prefixes, by_call)
end

"""The calls between methods reached from `entries`, each a `Core.MethodInstance` or a `(function, argument types)`
pair. Only methods `modules` define expand; `defined` lists them, and `values` names an unknown callee's functions."""
function method_graph(entries, modules, values, defined)
    landings = CallLandings(modules, values, defined)
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
    typed = Dict{Method,Vector{Core.CodeInfo}}()
    pending = Core.MethodInstance[]
    walked = Dict{Method,Any}()   # method -> the signature its walks cover
    # A walk only widens what it covers, so a specialization met once stays covered.
    met = Base.IdSet{Core.MethodInstance}()
    recorded = Tuple{Core.MethodInstance,Vector{CallFact}}[]
    callees = IdDict{Core.MethodInstance,Vector{Core.MethodInstance}}()
    caused = IdDict{Core.MethodInstance,Core.MethodInstance}()
    entry_instances = Core.MethodInstance[]
    for entry in entries
        instance = entry_instance(entry)
        push!(pending, instance)
        push!(entry_instances, instance)
    end
    # A resolved call is an edge on the inference frame, including one the optimized code drops.
    interp = inference_interpreter()
    while !isempty(pending)
        reached = pop!(pending)
        reached in met && continue
        push!(met, reached)
        instance = covering_instance(walked, reached)
        isnothing(instance) && continue
        walked[instance.def] = instance.specTypes
        expansion = expand_instance!(edges, typed, pending, instance, landings, interp)
        expansion.has_frame || continue
        caused[reached] = instance
        push!(recorded, (instance, expansion.facts))
        callees[instance] = expansion.targets
    end
    calls = merge_reached_calls(entry_instances, recorded, caused, callees)
    merge_declared_calls!(calls, walked, interp)
    MethodGraph(edges, calls, typed)
end

# A method walked only at narrower types answers for every argument it accepts, so its declared instance is inferred
# for facts alone, adding no edge: a bit failing there fails for the call, whatever a default or an entry fixed.
function merge_declared_calls!(calls, walked, interp)
    for (method, covered) in walked
        is_kwcall_method(method) && continue
        declared = declared_instance(method)
        declared.specTypes <: covered && continue
        caller = written_method(method)
        known = get(calls, caller, nothing)
        isnothing(known) && continue
        frame = inference_frame(declared, interp)
        isnothing(frame) && continue
        widest = CallFact[]
        record_calls!(widest, frame)
        for fact in widest
            index = site_index(known, fact)
            isnothing(index) && continue
            known[index] = merged_fact(known[index], fact)
        end
    end
    calls
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
    holds_type = slot isa DataType && !isnothing(type_object_held(slot))
    holds_type && return written.name in values
    slot <: Function || return true
    can_be_value(written, values)
end

function callee_prefix(method::Method)
    parameters = signature_types(method.sig)
    if is_kwcall_method(method)
        func = parameters[3]
        prefix = Tuple{typeof(Core.kwcall),Any,func,Vararg{Any}}
    else
        func = parameters[1]
        prefix = Tuple{func,Vararg{Any}}
    end
    has_free_variables(func) || return prefix
    under_clauses_of(prefix, method.sig)
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
    instance = method_instance_at(func, argtypes)
    isnothing(instance) && throw(ArgumentError("no method instance matches the entry"))
    instance
end

# One expansion of an instance. A keyword wrapper carries its body's edges and no facts of its own.
struct InstanceExpansion
    has_frame::Bool                           # inference produced a frame
    facts::Vector{CallFact}                   # call facts read from that frame
    targets::Vector{Core.MethodInstance}      # instances the frame's edges name
end

function without_frame()
    InstanceExpansion(false, CallFact[], Core.MethodInstance[])
end

function expand_instance!(edges, typed, pending, instance, landings::CallLandings, interp)
    module_set = landings.module_set
    frame = inference_frame(instance, interp)
    isnothing(frame) && return without_frame()
    targets = called_instances(frame)
    if is_kwcall_method(instance.def)
        body = keyword_body_from(frame)
        isnothing(body) && return without_frame()
        push!(pending, body)
        return InstanceExpansion(true, CallFact[], targets)
    end
    caller = written_method(instance.def)
    get!(edges, caller, Set{Method}())
    facts = CallFact[]
    record_calls!(facts, frame)
    # The optimizer rewrites `frame.src` in place (`ir_to_codeinf!`, Compiler/src/optimize.jl).
    unoptimized = copy(frame.src)
    kept = get!(Vector{Core.CodeInfo}, typed, caller)
    push!(kept, unoptimized)
    code = optimized_code(frame, interp)
    record_resolved!(edges, pending, frame, caller, module_set)
    isnothing(code) || record_dispatched!(edges, pending, code, instance, caller, landings)
    InstanceExpansion(true, facts, targets)
end

function called_instances(frame)
    found = Core.MethodInstance[]
    for edge in frame.edges
        target = called_instance(edge)
        isnothing(target) || push!(found, target)
    end
    found
end

# Facts are read at every expanded instance. Merged ones are those an entry reaches through resolved calls, so an
# instance expanded before its caller resolves it still counts, and a landing no resolved call names does not.
function merge_reached_calls(entries, recorded, caused, callees)
    counted = reached_expansions(entries, caused, callees)
    calls = Dict{Method,Vector{CallFact}}()
    for (instance, facts) in recorded
        instance in counted || continue
        is_kwcall_method(instance.def) && continue
        caller = written_method(instance.def)
        dest = get!(Vector{CallFact}, calls, caller)
        for fact in facts
            merge_fact!(dest, fact)
        end
    end
    calls
end

function reached_expansions(entries, caused, callees)
    counted = Base.IdSet{Core.MethodInstance}()
    seen = Base.IdSet{Core.MethodInstance}()
    pending = Core.MethodInstance[]
    for entry in entries
        push!(pending, entry)
    end
    while !isempty(pending)
        reached = pop!(pending)
        reached in seen && continue
        push!(seen, reached)
        expansion = get(caused, reached, nothing)
        isnothing(expansion) && continue
        expansion in counted && continue
        push!(counted, expansion)
        targets = callees[expansion]
        for target in targets
            push!(pending, target)
        end
    end
    counted
end

# One inference for every reader: the frame keeps its resolved calls and, per statement, its call info, effect flags
# and readers; `src` is the unoptimized code. Nothing when inference fails.
function inference_frame(instance::Core.MethodInstance, interp)
    Core.Compiler.typeinf_frame(interp, instance, false)
end

# The code `code_typed` returns, built from the frame the way `Core.Compiler.typeinf_frame` builds it when asked to
# optimize (Compiler/src/typeinfer.jl); nothing for a constant result, whose code calls nothing.
function optimized_code(frame, interp)
    Core.Compiler.result_is_constabi(interp, frame.result) && return nothing
    state = Core.Compiler.OptimizationState(frame, interp)
    Core.Compiler.optimize(interp, state, frame.result)
    inlined = Core.svec(state.inlining.edges...)
    Core.Compiler.ir_to_codeinf!(state, frame, inlined)
end

# Every call the frame's code writes, read before the optimizer rewrites the statements it describes. Inference
# leaves `stmt_info`, `ssaflags` and `ssavalue_uses` indexed as `src.code` (Compiler/src/inferencestate.jl).
function record_calls!(facts, frame)
    code = frame.src
    for position in eachindex(code.code)
        info = frame.stmt_info[position]
        branches = call_branches!(Core.Compiler.MethodMatchInfo[], info)
        if holds_unknown_apply(info)
            record_apply_veto!(facts, frame, position, branches, info)
            continue
        end
        if isempty(branches)
            fact = unknown_call(frame, position, info)
            isnothing(fact) || merge_fact!(facts, fact)
            continue
        end
        route = call_route(info)
        fact = call_fact(frame, position, branches, route)
        isnothing(fact) || merge_fact!(facts, fact)
    end
end

# A call stored to a local is one statement, and the call sits on the right of `=`.
function call_expression(statement::Expr)
    statement.head === :call && return statement
    statement.head === :(=) || return nothing
    stored = statement.args[2]
    stored isa Expr || return nothing
    stored.head === :call || return nothing
    stored
end

call_expression(@nospecialize(::Any)) = nothing

# A stored value sits in a slot, which `ssavalue_uses` does not track, so only a bare call can go unread.
function is_read(frame, position)
    statement = frame.src.code[position]
    is_bare_call = statement isa Expr && statement.head === :call
    !is_bare_call || !isempty(frame.ssavalue_uses[position])
end

# Inference records `NoCallInfo` when more methods match than it considers. That instance proves nothing about the
# call, so the fact vetoes a failure and a dropped value instead of agreeing by absence.
function unknown_call(frame, position, ::Core.Compiler.NoCallInfo)
    code = frame.src
    statement = code.code[position]
    named = named_callee(code, statement)
    isnothing(named) && return nothing
    file, line = statement_location(frame.src.debuginfo, frame.linfo, position)
    is_used = is_read(frame, position)
    callee = named[1]
    via = named[2]
    veto_fact(file, line, callee, via, is_used)
end

unknown_call(_frame, _position, @nospecialize(::Any)) = nothing

# A splatted call keeps its dispatch in `ApplyCallInfo`, and a union of splat shapes keeps one per member.
# `NoCallInfo` inside either proves nothing about that splat, the same as a direct call left without call info.
function holds_unknown_apply(info::Core.Compiler.ApplyCallInfo)
    holds_unknown_call(info.call)
end

function holds_unknown_apply(info::Core.Compiler.UnionSplitApplyCallInfo)
    for inner in info.infos
        holds_unknown_apply(inner) && return true
    end
    false
end

function holds_unknown_apply(info::Core.Compiler.ConstCallInfo)
    holds_unknown_apply(info.call)
end

holds_unknown_apply(@nospecialize(::Any)) = false

holds_unknown_call(::Core.Compiler.NoCallInfo) = true

function holds_unknown_call(info::Core.Compiler.ConstCallInfo)
    holds_unknown_call(info.call)
end

holds_unknown_call(@nospecialize(::Any)) = false

function record_apply_veto!(facts, frame, position, branches, info)
    route = call_route(info)
    if isempty(branches)
        fact = unknown_apply(frame, position, route)
        isnothing(fact) || merge_fact!(facts, fact)
        return
    end
    known = call_fact(frame, position, branches, route)
    isnothing(known) && return
    merge_fact!(facts, known)
    veto = veto_fact(known.file, known.line, known.callee, known.via, known.is_used)
    merge_fact!(facts, veto)
end

# The splatted call is `_apply_iterate(iterate, f, spreads...)`, so the callee is the third argument.
function unknown_apply(frame, position, route)
    code = frame.src
    statement = code.code[position]
    name = applied_name(code, statement)
    isnothing(name) && return nothing
    file, line = statement_location(frame.src.debuginfo, frame.linfo, position)
    is_used = is_read(frame, position)
    veto_fact(file, line, name, route, is_used)
end

function applied_name(code, statement::Expr)
    call = call_expression(statement)
    isnothing(call) && return nothing
    args = call.args
    length(args) < 3 && return nothing
    head = held_type(code, first(args))
    head === typeof(Core._apply_iterate) || return nothing
    func = held_type(code, args[3])
    isnothing(func) && return nothing
    name = callee_slot_name(func)
    name === Symbol("") && return nothing
    name
end

applied_name(_code, @nospecialize(::Any)) = nothing

function named_callee(code, statement)
    call = call_expression(statement)
    isnothing(call) && return nothing
    args = call.args
    isempty(args) && return nothing
    head = first(args)
    held = held_type(code, head)
    isnothing(held) && return nothing
    is_builtin_type(held) && return nothing
    if held === typeof(Core.kwcall)
        length(args) < 3 && return nothing
        func = held_type(code, args[3])
        isnothing(func) && return nothing
        name = callee_slot_name(func)
        name === Symbol("") && return nothing
        return (name, :kwcall)
    end
    name = callee_slot_name(held)
    name === Symbol("") && return nothing
    (name, :call)
end

function held_type(code, arg::Core.SSAValue)
    types = code.ssavaluetypes
    types isa Vector || return nothing
    unwrap_held(types[arg.id])
end

function held_type(code, arg::Core.SlotNumber)
    unwrap_held(code.slottypes[arg.id])
end

function held_type(_code, arg::GlobalRef)
    isdefined(arg.mod, arg.name) || return nothing
    value = getfield(arg.mod, arg.name)
    value isa Function || return nothing
    typeof(value)
end

held_type(_code, @nospecialize(::Any)) = nothing

unwrap_held(held::Core.Const) = typeof(held.val)
function unwrap_held(@nospecialize(held))
    held isa Type || return nothing
    held
end

function is_builtin_type(@nospecialize(held))
    held isa DataType || return false
    held <: Core.Builtin
end

function veto_fact(file, line, callee, via, is_used)
    CallFact(file, line, callee, via, is_used, false, "", false, false, false, false, false, false, false, false, "")
end

# The dispatches of one statement's call, each a `MethodMatchInfo` (Compiler/src/stmtinfo.jl): a constant-propagated
# call keeps its dispatch in `call`, a splatted one in each `ApplyCallInfo`, a union-split one a branch per member type.
call_branches!(found, info::Core.Compiler.ConstCallInfo) = call_branches!(found, info.call)
call_branches!(found, info::Core.Compiler.ApplyCallInfo) = call_branches!(found, info.call)
call_branches!(found, info::Core.Compiler.UnionSplitInfo) = append!(found, info.split)
call_branches!(found, info::Core.Compiler.MethodMatchInfo) = push!(found, info)
call_branches!(found, @nospecialize(_info)) = found

function call_branches!(found, info::Core.Compiler.UnionSplitApplyCallInfo)
    for inner in info.infos
        call_branches!(found, inner)
    end
    found
end

call_route(::Core.Compiler.ApplyCallInfo) = :apply
call_route(::Core.Compiler.UnionSplitApplyCallInfo) = :apply
call_route(@nospecialize(_info)) = :call

# A statement's effect flags are the call's effects at the argument types inference holds there
# (`flags_for_effects`, Compiler/src/optimize.jl).
has_flag(flags::UInt32, flag::UInt32) = flags & flag == flag

# Inference types a call it proved unreachable `Union{}`, which lists no argument types, so it yields no fact.
function call_fact(frame, position, branches, route)
    parameters = signature_types(first(branches).atype)
    isempty(parameters) && return nothing
    is_keyword = length(parameters) >= 3 && parameters[1] === typeof(Core.kwcall)
    called = is_keyword ? parameters[3] : parameters[1]
    via = is_keyword ? :kwcall : route
    file, line = statement_location(frame.src.debuginfo, frame.linfo, position)
    is_used = is_read(frame, position)
    is_failing = all(is_unmatched, branches)
    failing = is_failing ? join((type_text(branch.atype) for branch in branches), "; ") : ""
    is_stub = is_failing && has_no_method(called)
    is_forward = is_keyword && !has_known_names(parameters[2])
    flags = frame.ssaflags[position]
    is_effect_free = has_flag(flags, Core.Compiler.IR_FLAG_EFFECT_FREE)
    is_terminating = has_flag(flags, Core.Compiler.IR_FLAG_TERMINATES)
    is_nothrow = has_flag(flags, Core.Compiler.IR_FLAG_NOTHROW)
    is_consistent = has_flag(flags, Core.Compiler.IR_FLAG_CONSISTENT)
    is_generated = any(matches_generated, branches)
    returned = returned_type(branches)
    is_value = returned !== Nothing && returned !== Union{}
    is_dropped = !is_used && is_effect_free
    returns = is_dropped ? type_text(returned) : ""
    callee = callee_slot_name(called)
    CallFact(file, line, callee, via, is_used, is_failing, failing, is_stub, is_forward, is_effect_free,
             is_terminating, is_nothrow, is_consistent, is_generated, is_value, returns)
end

# A `MethodMatchInfo` holds the dispatch's matches in `results.matches` and, per match, the `CodeInstance` inference
# produced for it in `edges`, or nothing (Compiler/src/stmtinfo.jl).
is_unmatched(branch::Core.Compiler.MethodMatchInfo) = isempty(branch.results.matches)

function matches_generated(branch::Core.Compiler.MethodMatchInfo)
    for match in branch.results.matches
        is_generated_method(match.method) && return true
    end
    false
end

# The union of the return types the matched instances inferred; a match inference left without an instance returns
# what any call may.
function returned_type(branches)
    returned = Union{}
    for branch in branches
        for edge in branch.edges
            inferred = edge isa Core.CodeInstance ? edge.rettype : Any
            returned = Union{returned, inferred}
        end
    end
    returned
end

function has_no_method(@nospecialize(called))
    func = function_instance(called)
    isnothing(func) && return false
    isempty(methods(func))
end

function has_known_names(@nospecialize(keywords))
    keywords isa DataType || return false
    keywords <: NamedTuple || return false
    first(keywords.parameters) isa Tuple
end

# The name a callee slot's type gives the call: a function's, a callable object type's, or a constructed type's.
function callee_slot_name(@nospecialize(called))
    func = function_instance(called)
    isnothing(func) || return nameof(func)
    held = called isa DataType ? type_object_held(called) : nothing
    if isnothing(held)
        called isa DataType || return Symbol("")
        return nameof(called)
    end
    body = declared_datatype(held)
    isnothing(body) && return Symbol("")
    nameof(body)
end

# One fact per site, callee and route: two calls of one callee on one line, or one call at two instances, merge.
function merge_fact!(facts, fact::CallFact)
    index = site_index(facts, fact)
    isnothing(index) && return push!(facts, fact)
    facts[index] = merged_fact(facts[index], fact)
    facts
end

function site_index(facts, fact::CallFact)
    site = (fact.file, fact.line, fact.callee, fact.via)
    findfirst(known -> (known.file, known.line, known.callee, known.via) == site, facts)
end

function merged_fact(known::CallFact, fact::CallFact)
    is_failing = known.is_failing && fact.is_failing
    failing = is_failing ? known.failing : ""
    CallFact(known.file, known.line, known.callee, known.via,
             known.is_used || fact.is_used,
             is_failing, failing,
             known.is_stub && fact.is_stub,
             known.is_forward && fact.is_forward,
             known.is_effect_free && fact.is_effect_free,
             known.is_terminating && fact.is_terminating,
             known.is_nothrow && fact.is_nothrow,
             known.is_consistent && fact.is_consistent,
             known.is_generated || fact.is_generated,
             known.is_value && fact.is_value,
             known.returns)
end

"""A call fact's effect bits as inference prints them: `+` holds, `!` fails, for consistent, effect-free, nothrow and
terminates."""
function effects_text(fact::CallFact)
    marks = ((fact.is_consistent, "c"), (fact.is_effect_free, "e"), (fact.is_nothrow, "n"), (fact.is_terminating, "t"))
    parts = String[]
    for (holds, letter) in marks
        sign = holds ? "+" : "!"
        push!(parts, sign * letter)
    end
    join(parts, ",")
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
    inlined = inlined_instance(code.debuginfo, position)
    isnothing(inlined) && return false
    method = inlined.def
    method isa Method || return false
    method.module in module_set
end

# The callee and argument types inference holds at a call. Nothing for a builtin, an unreachable call, or an argument
# outside the position `widened_argument_type` reads.
function dispatch_signature(code, sptypes, args)
    types = Any[]
    for arg in args
        widened = widened_argument_type(code, sptypes, arg)
        isnothing(widened) && return nothing
        widened === Union{} && return nothing
        push!(types, widened)
    end
    callee = first(types)
    callee === typeof(Core._apply_iterate) && return spread_signature(code, sptypes, args, types)
    callee <: Core.Builtin && return nothing
    Tuple{types...}
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
        is_open = !isempty(parameters) && is_vararg_type(last(parameters))
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
    builder = widened_argument_type(code, sptypes, first(built.args))
    isnothing(builder) && return nothing
    builder === typeof(Core.svec) || return nothing
    members = Any[]
    for member in built.args[2:end]
        member_type = widened_argument_type(code, sptypes, member)
        isnothing(member_type) && return nothing
        push!(members, member_type)
    end
    members
end

built_members(_code, _sptypes, @nospecialize(::Any)) = nothing

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
    held = callee isa DataType ? type_object_held(callee) : nothing
    is_type_object = callee <: Type && isnothing(held)
    is_known = !isnothing(held) || (isconcretetype(callee) && !is_type_object)
    is_known && return known_matches(call, landings.module_set)
    held_matches(call, landings)
end

function known_matches(call, module_set)
    matches = matching_methods(call)
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
    kept = Core.MethodMatch[]
    for prefix in landings.prefixes
        narrowed = typeintersect(call, prefix)
        narrowed === Union{} && continue
        matches = matching_methods(narrowed)
        for match in matches
            match.method in landings.held || continue
            push!(kept, match)
        end
    end
    kept
end

can_be_value(method::Method, values) = is_generated_name(method.name) || method.name in values

called_instance(target::Core.CodeInstance) = target.def
called_instance(target::Core.MethodInstance) = target
called_instance(@nospecialize(::Any)) = nothing

function add_edge!(edges, caller, callee)
    callees = get!(edges, caller, Set{Method}())
    push!(callees, callee)
end

# A keyword sorter's edge to its own body is the fold onto the method the source wrote.
function add_folded_edge!(edges, caller_method::Method, callee_method::Method, module_set)
    caller = written_method(caller_method)
    callee = written_method(callee_method)
    caller.module in module_set || return
    callee.module in module_set || return
    is_body = callee === caller && is_keyword_body(callee_method)
    is_body && return
    add_edge!(edges, caller, callee)
end

"""Package calls recorded on `instances`' native code, joined onto `graph`'s edges. An added edge carries no call fact."""
function add_compiled_edges!(graph::MethodGraph, instances, modules)
    module_set = Set{Module}(modules)
    for instance in instances
        caller_method = instance.def
        caller_method isa Method || continue
        # A replaced method stays in the table, and the code on it is the definition a later one overwrote.
        is_latest(caller_method) || continue
        for callee_method in compiled_edge_methods(instance)
            is_latest(callee_method) || continue
            add_folded_edge!(graph.edges, caller_method, callee_method, module_set)
        end
    end
    graph
end

# A function passed into an outside call expands at the specialization that inference compiled for it.
# When that call compiled none, the method expands at its declared signature.
function record_passed!(edges, pending, caller, target, module_set)
    is_kwcall_method(target.def) && return
    target.def.module in module_set && return
    parameters = signature_types(target.specTypes)
    isempty(parameters) && return
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
        compiled = method_instances(method)
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
    matches = matching_methods(signature)
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
    params = signature_types(method.sig)
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
    argtype = under_clauses_of(open_types, keyword_method.sig)
    hasmethod(func, argtype) || return nothing
    which(func, argtype)
end

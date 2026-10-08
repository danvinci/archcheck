# The call zoom: declared methods observed while a workload runs. Julia has no function-entry hook, so a probed
# method is evaluated again from its parsed source with an entry and an exit probe, and restored afterwards.

using CRC32c: crc32c

"""What a package asks the gate to observe: the functions to probe, and the functions whose callees read state no
argument shows (a session over a global library), whose calls the analyses set apart."""
Base.@kwdef struct Probes{F<:Tuple,A<:Tuple}
    functions::F              # every method of each, defined in the package, is probed
    ambient::A = ()           # a probed call inside one of these reads state its arguments do not show
    slow_s::Float64 = 0.005   # a call shorter than this leaves no record (s)
end

"""One probed call that ran at least the probes' slow threshold. Hashes are of content, so equal values hash equal
whatever object holds them; identities are `objectid`s, so they match the same object only."""
struct ProbeRecord
    name::Symbol                 # the probed function
    site::Tuple{String,Int}      # its method's file, repo-relative, and line
    caller::Symbol               # the nearest probed function open on the task; Symbol("") at a task's root
    enclosing::Vector{Symbol}    # every probed function open on the task when the call began, outermost first
    task::UInt                   # objectid of the task that ran the call
    start_s::Float64             # time() at entry (s)
    stop_s::Float64              # time() at exit (s)
    arguments::UInt              # content hash of the argument tuple, keywords included
    result::UInt                 # content hash of the returned value
    result_id::UInt              # objectid of a non-bits result; 0 for a bits value
    reads::Vector{UInt}          # objectids of the non-bits objects the arguments reach within three container levels
    is_fed::Bool                 # an argument is a Channel: workers fed from one share their arguments by design
end

const CONTENT_DEPTH_MAX = 24
const READ_DEPTH_MAX = 3
const READ_WIDTH_MAX = 256
const FRAME_KEY = :archcheck_probe_frames
const ARGUMENT_KEY = :archcheck_probe_arguments
const SKIPPED_MACROS = (Symbol("@generated"), Symbol("@kwdef"), Symbol("@enum"))
const ROOT_CALLER = Symbol("")

struct ProbeSkip
    method::String     # printed method that was not rewritten
    reason::String     # why the rewrite was refused
end

struct MethodSource
    mod::Module        # where the statement evaluates
    definition::Expr   # statement put back on the way out
end

struct LocatedMethod
    file::String       # repo-relative path
    line::Int          # source line
    definition::Expr   # top-level statement that defines it
end

struct OpenFrame
    name::Symbol                 # function running
    file::String                 # repo-relative path
    line::Int                    # source line
    started::Float64             # entry time (s)
    caller::Symbol               # nearest recorded caller at entry
    enclosing::Vector{Symbol}    # calls already open, outermost first
    is_probed::Bool              # true when this call was asked for
end

mutable struct ProbeSession
    slow_s::Float64                 # minimum duration that leaves a record (s)
    records::Vector{ProbeRecord}    # calls that met the duration
    lock::ReentrantLock             # guards the record list
end

struct ProbeHandle
    session::ProbeSession            # where records accumulate
    originals::Vector{MethodSource}  # statements to evaluate back
end

const ACTIVE = Ref{Union{Nothing,ProbeSession}}(nothing)

function content_hash(value)
    memo = IdDict{Any,UInt}()
    hash_value(value, zero(UInt), memo, 0)
end

function hash_value(value, seed::UInt, memo, depth::Int)
    depth > CONTENT_DEPTH_MAX && return hash(:depth, seed)
    if ismutable(value) && haskey(memo, value)
        cached = memo[value]
        return hash(cached, seed)
    end
    result = hash_content(value, seed, memo, depth)
    if ismutable(value)
        memo[value] = result
    end
    result
end

function hash_content(value::Union{Number,Symbol,String,Char,Nothing,Bool}, seed::UInt, memo, depth::Int)
    hash(value, seed)
end

function hash_content(value::Union{Module,Function,Type,Task,Channel,Base.AbstractLock,Ptr,IO}, seed::UInt, memo, depth::Int)
    identity = objectid(value)
    hash(identity, seed)
end

function hash_content(value::Array, seed::UInt, memo, depth::Int)
    element = eltype(value)
    packed = isbitstype(element) && !Base.datatype_haspadding(element)
    packed || return hash_items(value, seed, memo, depth)
    flat = vec(value)
    bytes = reinterpret(UInt8, flat)
    digest = crc32c(bytes)
    width = length(bytes)
    kind = typeof(value)
    mixed = (digest, width, kind)
    hash(mixed, seed)
end

function hash_content(value::AbstractArray, seed::UInt, memo, depth::Int)
    hash_items(value, seed, memo, depth)
end

function hash_content(value::AbstractSet, seed::UInt, memo, depth::Int)
    hash_items(value, seed, memo, depth)
end

function hash_content(value::AbstractDict, seed::UInt, memo, depth::Int)
    hash_pairs(value, seed, memo, depth)
end

function hash_content(value, seed::UInt, memo, depth::Int)
    kind = typeof(value)
    if isbits(value) && !Base.datatype_haspadding(kind)
        return hash(value, seed)
    end
    hash_fields(value, seed, memo, depth)
end

function hash_items(value, seed::UInt, memo, depth::Int)
    acc = hash(typeof(value), seed)
    deeper = depth + 1
    for item in value
        acc = hash_value(item, acc, memo, deeper)
    end
    acc
end

function hash_pairs(value, seed::UInt, memo, depth::Int)
    acc = hash(typeof(value), seed)
    deeper = depth + 1
    for pair in value
        key = pair.first
        item = pair.second
        keyed = hash_value(key, acc, memo, deeper)
        acc = hash_value(item, keyed, memo, deeper)
    end
    acc
end

function hash_fields(value, seed::UInt, memo, depth::Int)
    acc = hash(typeof(value), seed)
    deeper = depth + 1
    count = nfields(value)
    for index in 1:count
        isdefined(value, index) || continue
        field = getfield(value, index)
        acc = hash_value(field, acc, memo, deeper)
    end
    acc
end

is_channel(::Channel) = true
is_channel(::Any) = false

function arguments_fed(arguments)
    for argument in arguments
        is_channel(argument) && return true
    end
    false
end

is_skipped_read(::Union{Module,Function,Type,Symbol,String}) = true
is_skipped_read(::Any) = false

is_read_container(::AbstractArray) = true
is_read_container(::Tuple) = true
is_read_container(::Any) = false

function collect_reads!(found, value, depth::Int)
    isbits(value) && return found
    is_skipped_read(value) && return found
    push!(found, objectid(value))
    depth >= READ_DEPTH_MAX && return found
    is_read_container(value) || return found
    length(value) > READ_WIDTH_MAX && return found
    for item in value
        collect_reads!(found, item, depth + 1)
    end
    found
end

function read_ids(arguments)
    found = Set{UInt}()
    for argument in arguments
        collect_reads!(found, argument, 0)
    end
    collect(found)
end

function result_identity(result)
    isbits(result) && return UInt(0)
    objectid(result)
end

function stored_local(key::Symbol)
    storage = task_local_storage()
    get(storage, key, nothing)
end

function current_frames()
    stored = stored_local(FRAME_KEY)
    if isnothing(stored)
        fresh = OpenFrame[]
        task_local_storage(FRAME_KEY, fresh)
        return fresh
    end
    stored::Vector{OpenFrame}
end

function current_arguments()
    stored = stored_local(ARGUMENT_KEY)
    if isnothing(stored)
        fresh = Any[]
        task_local_storage(ARGUMENT_KEY, fresh)
        return fresh
    end
    stored::Vector{Any}
end

function nearest_caller(frames)
    index = length(frames)
    while index >= 1
        frame = frames[index]
        frame.is_probed && return frame.name
        index -= 1
    end
    ROOT_CALLER
end

function probe_enter(name::Symbol, file::String, line::Int, arguments::Tuple, is_probed::Bool)
    session = ACTIVE[]
    isnothing(session) && return false
    frames = current_frames()
    held = current_arguments()
    open_names = Symbol[]
    for frame in frames
        push!(open_names, frame.name)
    end
    caller = nearest_caller(frames)
    started = time()
    entered = OpenFrame(name, file, line, started, caller, open_names, is_probed)
    push!(frames, entered)
    push!(held, arguments)
    true
end

function make_record(frame::OpenFrame, arguments, result, stopped::Float64)
    argument_hash = content_hash(arguments)
    result_hash = content_hash(result)
    identity = result_identity(result)
    reached = read_ids(arguments)
    fed = arguments_fed(arguments)
    task_id = objectid(current_task())
    site = (frame.file, frame.line)
    ProbeRecord(frame.name, site, frame.caller, frame.enclosing, task_id,
                frame.started, stopped, argument_hash, result_hash, identity, reached, fed)
end

function push_record(session::ProbeSession, record::ProbeRecord)
    lock(session.lock) do
        push!(session.records, record)
    end
    nothing
end

function probe_leave(session_active::Bool, result)
    session_active || return nothing
    frames = current_frames()
    held = current_arguments()
    frame = pop!(frames)
    arguments = pop!(held)
    session = ACTIVE[]
    isnothing(session) && return nothing
    stopped = time()
    duration = stopped - frame.started
    duration >= session.slow_s || return nothing
    record = make_record(frame, arguments, result, stopped)
    push_record(session, record)
    nothing
end

function probe_abort(session_active::Bool)
    session_active || return nothing
    frames = current_frames()
    held = current_arguments()
    pop!(frames)
    pop!(held)
    nothing
end

macro_symbol(macro_name::Symbol) = macro_name
macro_symbol(::Any) = nothing

function macro_symbol(macro_name::QuoteNode)
    macro_symbol(macro_name.value)
end

function macro_symbol(macro_name::GlobalRef)
    macro_name.name
end

function macro_symbol(macro_name::Expr)
    macro_name.head === :. || return nothing
    isempty(macro_name.args) && return nothing
    nested = last(macro_name.args)
    macro_symbol(nested)
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

function push_plain!(names, bare::Symbol)
    text = string(bare)
    all(==('_'), text) && return nothing
    push!(names, bare)
    nothing
end

collect_argument_names!(names, argument::Symbol) = push_plain!(names, argument)
collect_argument_names!(names, ::Any) = nothing

function collect_argument_names!(names, argument::Expr)
    if argument.head === :parameters || argument.head === :tuple
        for child in argument.args
            collect_argument_names!(names, child)
        end
        return nothing
    end
    if argument.head === :(::)
        length(argument.args) == 2 || return nothing
        return collect_argument_names!(names, argument.args[1])
    end
    head = argument.head
    if head === :kw || head === :... || head === :(=) || head === :<:
        return collect_argument_names!(names, argument.args[1])
    end
    if head === :macrocall
        return collect_argument_names!(names, last(argument.args))
    end
    nothing
end

function argument_names(signature::Expr)
    call = unwrap_signature(signature)
    call isa Expr || return Symbol[]
    call.head === :call || return Symbol[]
    names = Symbol[]
    head = call.args[1]
    if head isa Expr && head.head === :(::)
        collect_argument_names!(names, head)
    end
    for argument in call.args[2:end]
        collect_argument_names!(names, argument)
    end
    names
end

function probe_body(name::Symbol, file::String, line::Int, arg_names::Vector{Symbol}, is_probed::Bool, body)
    session_active = gensym(:session_active)
    result = gensym(:probe_result)
    arguments = Expr(:tuple)
    for arg_name in arg_names
        push!(arguments.args, arg_name)
    end
    enter = GlobalRef(@__MODULE__, :probe_enter)
    leave = GlobalRef(@__MODULE__, :probe_leave)
    abort = GlobalRef(@__MODULE__, :probe_abort)
    quoted_name = QuoteNode(name)
    quote
        $session_active = $enter($quoted_name, $file, $line, $arguments, $is_probed)
        local $result
        try
            $result = (() -> $body)()
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

function rewrite_macro(definition::Expr, name::Symbol, file::String, line::Int, is_probed::Bool)
    macro_name = macro_symbol(definition.args[1])
    macro_name in SKIPPED_MACROS && return nothing
    inner_index = findlast(arg -> arg isa Expr, definition.args)
    isnothing(inner_index) && return nothing
    inner = definition.args[inner_index]
    rewritten = rewrite_definition(inner, name, file, line, is_probed)
    isnothing(rewritten) && return nothing
    macro_name === Symbol("@doc") && return rewritten
    args = Vector{Any}(undef, length(definition.args))
    for index in eachindex(definition.args)
        args[index] = definition.args[index]
    end
    args[inner_index] = rewritten
    Expr(:macrocall, args...)
end

function rewrite_definition(definition::Expr, name::Symbol, file::String, line::Int, is_probed::Bool)
    if definition.head === :macrocall
        return rewrite_macro(definition, name, file, line, is_probed)
    end
    long_form = definition.head === :function && length(definition.args) == 2
    short_form = is_short_method(definition)
    long_form || short_form || return nothing
    signature = definition.args[1]
    names = argument_names(signature)
    body = deepcopy(definition.args[2])
    probed = probe_body(name, file, line, names, is_probed, body)
    copied = deepcopy(signature)
    Expr(:function, copied, probed)
end

function macro_body(node)
    children = child_nodes(node)
    children === nothing && return nothing
    body = nothing
    for child in children
        kind = JS.kind(child)
        selected = kind == K"function" || kind == K"=" || kind == K"macrocall"
        selected || continue
        body = child
    end
    body
end

function method_form(node)
    kind = JS.kind(node)
    if kind == K"macrocall"
        inner = macro_body(node)
        isnothing(inner) && return nothing
        return method_form(inner)
    end
    is_method_form(node) || return nothing
    node
end

function matches_method(node, method)
    form = method_form(node)
    isnothing(form) && return false
    located = JS.source_location(form)
    line = Int(located[1])
    line == method.line || return false
    signature = child_nodes(form)[1]
    called = sig_name(signature)
    isnothing(called) || called === method.name
end

function find_definition(node, method)
    kind = JS.kind(node)
    if kind == K"toplevel" || kind == K"block"
        children = child_nodes(node)
        children === nothing && return nothing
        for child in children
            found = find_definition(child, method)
            isnothing(found) || return found
        end
        return nothing
    end
    if kind == K"module"
        children = child_nodes(node)
        children === nothing && return nothing
        for child in children
            JS.kind(child) == K"block" || continue
            found = find_definition(child, method)
            isnothing(found) || return found
        end
        return nothing
    end
    matches_method(node, method) || return nothing
    Expr(node)
end

function locate_method(index, method)
    method_path = String(method.file)
    method_path = normpath(method_path)
    for file in index.files
        absolute = joinpath(index.repo, file.path)
        absolute = normpath(absolute)
        relative = normpath(file.path)
        matched = method_path == absolute || method_path == relative
        matched || continue
        found = find_definition(file.tree, method)
        isnothing(found) && continue
        return LocatedMethod(file.path, method.line, found)
    end
    nothing
end

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

# The index parses files under repo-relative names. Every definition this file evaluates records the file the
# original method recorded, so a reader of `method.file` sees the same path before, during and after the probe.
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

function install_method!(method, is_probed::Bool, index, originals, skipped)
    if isdefined(method, :generator)
        note_skip!(skipped, method, "generated")
        return nothing
    end
    located = locate_method(index, method)
    if isnothing(located)
        note_skip!(skipped, method, "no source site in the index")
        return nothing
    end
    saved = deepcopy(located.definition)
    retag_lines!(saved, method.file)
    probed = rewrite_definition(saved, method.name, located.file, located.line, is_probed)
    if isnothing(probed)
        note_skip!(skipped, method, "a form the rewrite does not take")
        return nothing
    end
    Core.eval(method.module, probed)
    push!(originals, MethodSource(method.module, saved))
    nothing
end

function install!(functions, is_probed::Bool, ctx, originals, skipped)
    modules = package_modules(ctx)
    for target in functions
        defined = methods(target)
        for method in defined
            home = method.module
            home in modules || continue
            install_method!(method, is_probed, ctx.index, originals, skipped)
        end
    end
    nothing
end

function restore_originals(originals)
    for source in originals
        Core.eval(source.mod, source.definition)
    end
    nothing
end

"""Evaluates every method of the probed functions defined in the package again, from the index's parse, with an
entry and an exit probe. Returns the handle that collects the records and later restores the methods."""
function arm!(probes::Probes, ctx)
    active = ACTIVE[]
    isnothing(active) || throw(ArgumentError("a probe session is already armed"))
    records = ProbeRecord[]
    session = ProbeSession(probes.slow_s, records, ReentrantLock())
    originals = MethodSource[]
    skipped = ProbeSkip[]
    ACTIVE[] = session
    try
        install!(probes.functions, true, ctx, originals, skipped)
        install!(probes.ambient, false, ctx, originals, skipped)
        isempty(skipped) || throw(skip_error(skipped))
    catch
        restore_originals(originals)
        ACTIVE[] = nothing
        rethrow()
    end
    ProbeHandle(session, originals)
end

"""Restores every method a handle probed to its source definition and returns the records collected while armed."""
function disarm!(armed::ProbeHandle)
    restore_originals(armed.originals)
    active = ACTIVE[]
    if active === armed.session
        ACTIVE[] = nothing
    end
    copy(armed.session.records)
end

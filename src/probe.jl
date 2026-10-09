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

"""One probed call that ran at least the probes' slow threshold. `arguments` is `hash` of the declared key when the
producer declares one, and the content hash of the arguments otherwise. Identities are `objectid`s."""
struct ProbeRecord
    name::Symbol                 # the probed function
    site::Tuple{String,Int}      # its method's file, repo-relative, and line
    caller::Symbol               # the nearest probed function open on the task; Symbol("") at a task's root
    enclosing::Vector{Symbol}    # every probed function open on the task when the call began, outermost first
    task::UInt                   # objectid of the task that ran the call
    start_s::Float64             # time() at entry (s)
    stop_s::Float64              # time() at exit (s)
    arguments::UInt              # hash of the declared key, or the content hash of the arguments
    result::UInt                 # content hash of the returned value
    result_id::UInt              # objectid of a non-bits result; 0 for a bits value
    reads::Vector{UInt}          # objectids of the non-bits objects the arguments reach within three container levels
    is_fed::Bool                 # an argument is a Channel: workers fed from one share their arguments by design
    is_ambient::Bool             # this call is a non-probed function, or one encloses it
end

"""One wait a probed method made for a task. The result identity is an `objectid`, so it matches the same object only."""
struct WaitRecord
    consumer::Symbol             # function that waited
    site::Tuple{String,Int}      # that method's file and line
    task::UInt                   # objectid of the waiting task
    child::UInt                  # objectid of the task that was waited
    start_s::Float64             # time() when the wait began (s)
    stop_s::Float64              # time() when the wait ended (s)
    result_id::UInt              # objectid of a non-bits result; 0 for a bits value
    reads::Vector{UInt}          # objectids the result reaches within three container levels
end

"""The calls and the waits collected while a probe handle was armed."""
struct ProbeTrace
    records::Vector{ProbeRecord}  # probed calls
    waits::Vector{WaitRecord}     # waits those calls logged
end

const CONTENT_DEPTH_MAX = 24
const READ_DEPTH_MAX = 3
const READ_WIDTH_MAX = 256
const FRAME_KEY = :archcheck_probe_frames
const ARGUMENT_KEY = :archcheck_probe_arguments
const SKIPPED_MACROS = (Symbol("@generated"), Symbol("@kwdef"), Symbol("@enum"))
const ROOT_CALLER = Symbol("")
const PARENT_CALL = Base.ScopedValues.ScopedValue{Symbol}(ROOT_CALLER)

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

struct OpenFrame
    name::Symbol                 # function running
    file::String                 # repo-relative path
    line::Int                    # source line
    started::Float64             # entry time (s)
    caller::Symbol               # nearest recorded caller at entry
    enclosing::Vector{Symbol}    # calls already open, outermost first
    is_probed::Bool                    # true when this call was asked for
    is_ambient::Bool                   # this call is a non-probed function, or one encloses it
    key_hash::Union{Nothing,UInt}      # hash of the declared key; nothing when the producer declares none
end

mutable struct ProbeSession
    slow_s::Float64                 # minimum duration that leaves a record (s)
    records::Vector{ProbeRecord}    # calls that met the duration
    waits::Vector{WaitRecord}       # waits logged while armed
    lock::ReentrantLock             # guards the record list and the wait list
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

function ancestor_names(frames)
    names = Symbol[]
    for frame in frames
        push!(names, frame.name)
    end
    names
end

function ambient_call(frames, is_probed::Bool)
    is_probed || return true
    for frame in frames
        frame.is_probed || return true
    end
    false
end

function caller_of(frames)
    caller = nearest_caller(frames)
    if caller !== ROOT_CALLER
        return caller
    end
    PARENT_CALL[]
end

function probe_enter(name::Symbol, file::String, line::Int, arguments::Tuple,
        key_hash::Union{Nothing,UInt}, is_probed::Bool)
    session = ACTIVE[]
    isnothing(session) && return false
    frames = current_frames()
    held = current_arguments()
    names = ancestor_names(frames)
    caller = caller_of(frames)
    covered = ambient_call(frames, is_probed)
    started = time()
    entered = OpenFrame(name, file, line, started, caller, names, is_probed, covered, key_hash)
    push!(frames, entered)
    push!(held, arguments)
    true
end

function make_record(frame::OpenFrame, arguments, result, stopped::Float64)
    argument_hash = content_hash(arguments)
    keyed = frame.key_hash
    if !isnothing(keyed)
        argument_hash = keyed
    end
    result_hash = content_hash(result)
    identity = result_identity(result)
    reached = read_ids(arguments)
    fed = arguments_fed(arguments)
    task_id = objectid(current_task())
    site = (frame.file, frame.line)
    names = copy(frame.enclosing)
    ProbeRecord(frame.name, site, frame.caller, names, task_id,
                frame.started, stopped, argument_hash, result_hash, identity, reached, fed,
                frame.is_ambient)
end

function push_record(session::ProbeSession, record::ProbeRecord)
    lock(session.lock) do
        push!(session.records, record)
    end
    nothing
end

function push_wait(session::ProbeSession, record::WaitRecord)
    lock(session.lock) do
        push!(session.waits, record)
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

function active_frames()
    stored = stored_local(FRAME_KEY)
    isnothing(stored) && return nothing
    stored::Vector{OpenFrame}
end

function probed_frame()
    frames = active_frames()
    isnothing(frames) && return nothing
    slot = length(frames)
    while slot >= 1
        frame = frames[slot]
        frame.is_probed && return frame
        slot -= 1
    end
    nothing
end

function result_reads(result)
    found = Set{UInt}()
    collect_reads!(found, result, 0)
    collect(found)
end

function record_wait(frame::OpenFrame, child::Task, started::Float64, stopped::Float64, result)
    identity = result_identity(result)
    reached = result_reads(result)
    site = (frame.file, frame.line)
    consumer_task = objectid(current_task())
    child_task = objectid(child)
    WaitRecord(frame.name, site, consumer_task, child_task, started, stopped, identity, reached)
end

function finish_wait(child::Task, started::Float64, result)
    frame = probed_frame()
    isnothing(frame) && return result
    session = ACTIVE[]
    isnothing(session) && return result
    stopped = time()
    record = record_wait(frame, child, started, stopped, result)
    push_wait(session, record)
    result
end

function probe_fetch(child::Task)
    started = time()
    try
        result = Base.fetch(child)
        return finish_wait(child, started, result)
    catch
        finish_wait(child, started, nothing)
        rethrow()
    end
end

function probe_fetch(value)
    Base.fetch(value)
end

function probe_wait(child::Task)
    started = time()
    try
        Base.wait(child)
    catch
        finish_wait(child, started, nothing)
        rethrow()
    end
    finish_wait(child, started, nothing)
    nothing
end

function probe_wait(value)
    Base.wait(value)
end

function wait_synced(item::Task, errors)
    started = time()
    Base._wait(item)
    finish_wait(item, started, nothing)
    Base.istaskfailed(item) || return nothing
    failed = Base.TaskFailedException(item)
    push!(errors, failed)
    nothing
end

function wait_synced(item, errors)
    try
        Base.wait(item)
    catch error
        push!(errors, error)
    end
    nothing
end

function take_synced(channel, errors)
    while isready(channel)
        item = take!(channel)
        wait_synced(item, errors)
    end
    nothing
end

function late_synced(channel, errors)
    isready(channel) || return nothing
    raced = Any[]
    for item in channel
        push!(raced, item)
    end
    isempty(raced) && return nothing
    late = Base.ScheduledAfterSyncException(raced)
    pushfirst!(errors, late)
    nothing
end

function throw_synced(errors)
    isempty(errors) && return nothing
    collected = CompositeException()
    for error in errors
        push!(collected, error)
    end
    throw(collected)
end

function log_sync_end(channel)
    errors = Any[]
    take_synced(channel, errors)
    close(channel)
    late_synced(channel, errors)
    throw_synced(errors)
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

struct ArgumentShape
    positional::Vector{Symbol}   # positional parameter names, in order
    splats::Vector{Bool}         # the positional parameter at that index is a varargs
    keywords::Vector{Symbol}     # keyword parameter names, in order
end

parameter_name(name::Symbol) = name
parameter_name(::Any) = nothing

function parameter_name(argument::Expr)
    if argument.head === :macrocall
        isempty(argument.args) && return nothing
        return parameter_name(last(argument.args))
    end
    if argument.head === :(::)
        length(argument.args) == 2 || return nothing
        return parameter_name(argument.args[1])
    end
    head = argument.head
    if head === :kw || head === :... || head === :(=) || head === :<:
        isempty(argument.args) && return nothing
        return parameter_name(argument.args[1])
    end
    nothing
end

add_keyword!(names, name::Symbol) = push_plain!(names, name)
add_keyword!(names, ::Any) = nothing

function add_keyword!(names, argument::Expr)
    if argument.head === :parameters || argument.head === :tuple
        for child in argument.args
            add_keyword!(names, child)
        end
        return nothing
    end
    found = parameter_name(argument)
    isnothing(found) && return nothing
    push_plain!(names, found)
    nothing
end

function remember!(names, splats, found::Symbol, is_splat::Bool)
    before = length(names)
    push_plain!(names, found)
    length(names) == before && return nothing
    push!(splats, is_splat)
    nothing
end

remember!(names, splats, ::Any, ::Bool) = nothing

add_positional!(names, splats, name::Symbol) = remember!(names, splats, name, false)
add_positional!(names, splats, ::Any) = nothing

function add_positional!(names, splats, argument::Expr)
    if argument.head === :...
        isempty(argument.args) && return nothing
        found = parameter_name(argument.args[1])
        return remember!(names, splats, found, true)
    end
    found = parameter_name(argument)
    remember!(names, splats, found, false)
end

function argument_shape(signature::Expr)
    positional = Symbol[]
    splats = Bool[]
    keywords = Symbol[]
    call = unwrap_signature(signature)
    call isa Expr || return ArgumentShape(positional, splats, keywords)
    call.head === :call || return ArgumentShape(positional, splats, keywords)
    head = call.args[1]
    if head isa Expr && head.head === :(::)
        add_positional!(positional, splats, head)
    end
    for argument in call.args[2:end]
        if argument isa Expr && argument.head === :parameters
            add_keyword!(keywords, argument)
        else
            add_positional!(positional, splats, argument)
        end
    end
    ArgumentShape(positional, splats, keywords)
end

function positionals_expr(names::Vector{Symbol}, splats::Vector{Bool})
    args = Any[]
    for index in eachindex(names)
        name = names[index]
        if splats[index]
            push!(args, Expr(:..., name))
        else
            push!(args, name)
        end
    end
    Expr(:tuple, args...)
end

function keywords_expr(names::Vector{Symbol})
    pairs = Any[]
    for name in names
        push!(pairs, Expr(:kw, name, name))
    end
    parameters = Expr(:parameters, pairs...)
    Expr(:tuple, parameters)
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

is_sync_macro(::Any) = false

function is_sync_macro(node::Expr)
    node.head === :macrocall || return false
    isempty(node.args) && return false
    name = macro_symbol(node.args[1])
    name === Symbol("@sync")
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
    isnothing(rewritten) || return rewritten
    args = Any[]
    for child in node.args
        walked = rewrite_waits(child)
        push!(args, walked)
    end
    Expr(:., args...)
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
    node.head === :quote && return node
    if is_sync_macro(node)
        return rewrite_sync(node)
    end
    if node.head === :.
        return rewrite_dot(node)
    end
    if node.head === :call
        return rewrite_call(node)
    end
    args = Any[]
    for child in node.args
        walked = rewrite_waits(child)
        push!(args, walked)
    end
    Expr(node.head, args...)
end

function arguments_expr(shape::ArgumentShape)
    arguments = Expr(:tuple)
    for name in shape.positional
        push!(arguments.args, name)
    end
    for name in shape.keywords
        push!(arguments.args, name)
    end
    arguments
end

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

function probe_body(name::Symbol, file::String, line::Int, shape::ArgumentShape, key, is_probed::Bool, body)
    session_active = gensym(:session_active)
    result = gensym(:probe_result)
    arguments = arguments_expr(shape)
    positional = positionals_expr(shape.positional, shape.splats)
    keywords = keywords_expr(shape.keywords)
    hashed = key_hash_expr(key, positional, keywords, name)
    rewritten = rewrite_waits(body)
    enter = GlobalRef(@__MODULE__, :probe_enter)
    leave = GlobalRef(@__MODULE__, :probe_leave)
    abort = GlobalRef(@__MODULE__, :probe_abort)
    quoted_name = QuoteNode(name)
    scope = GlobalRef(Base.ScopedValues, :with)
    parent = GlobalRef(@__MODULE__, :PARENT_CALL)
    parent_pair = gensym(:parent_pair)
    entered = :($enter($quoted_name, $file, $line, $arguments, $hashed, $is_probed))
    if is_probed
        run = quote
            $parent_pair = $parent => $quoted_name
            $scope($parent_pair) do
                (() -> $rewritten)()
            end
        end
    else
        run = quote
            (() -> $rewritten)()
        end
    end
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

function rewrite_macro(definition::Expr, name::Symbol, file::String, line::Int, is_probed::Bool, key)
    macro_name = macro_symbol(definition.args[1])
    macro_name in SKIPPED_MACROS && return nothing
    inner_index = findlast(arg -> arg isa Expr, definition.args)
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

# The statement evaluated again: the method form with the macro calls that wrap it. A docstring stays out, since
# the docs outlive the deleted method and evaluating one again replaces them.
function definition_statement(form)
    node = form
    while !isnothing(node.parent)
        JS.kind(node.parent) == K"macrocall" || break
        node = node.parent
    end
    node
end

function is_in_struct(form)
    node = form.parent
    while !isnothing(node)
        JS.kind(node) == K"struct" && return true
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
    push!(originals, source)
    nothing
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
        producers = Any[]
        for declared in ctx.derived
            isnothing(declared.key) && continue
            push!(producers, declared.producer)
        end
        install!(producers, true, ctx, originals, skipped)
        listed = filter(func -> !(func in producers), probes.functions)
        ambient = filter(func -> !(func in producers), probes.ambient)
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

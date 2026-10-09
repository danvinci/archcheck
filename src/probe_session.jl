# Open frames on a task, and the records a probe session keeps.

"""One probed call that ran at least the probes' slow threshold. `arguments` is `hash` of the declared key when the
producer declares one, and the content hash of the arguments otherwise. Identities are `objectid`s."""
struct ProbeRecord
    name::Symbol                 # the probed function
    site::Tuple{String,Int}      # its method's file, repo-relative, and line
    caller::Symbol               # the nearest probed function open on the task; Symbol("") at a task's root
    enclosing::Vector{Symbol}    # every function open on the task when the call began, outermost first
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

const FRAME_KEY = :archcheck_probe_frames
const ARGUMENT_KEY = :archcheck_probe_arguments
const ROOT_CALLER = Symbol("")
const PARENT_CALL = Base.ScopedValues.ScopedValue{Symbol}(ROOT_CALLER)

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

const ACTIVE = Ref{Union{Nothing,ProbeSession}}(nothing)

is_channel(::Channel) = true
is_channel(::Any) = false

function arguments_fed(arguments)
    for argument in arguments
        is_channel(argument) && return true
    end
    false
end

function stored_local(key::Symbol)
    storage = task_local_storage()
    get(storage, key, nothing)
end

function stored_vector(key::Symbol, ::Type{T}) where {T}
    stored = stored_local(key)
    isnothing(stored) && return nothing
    stored::Vector{T}
end

function task_vector(key::Symbol, ::Type{T}) where {T}
    stored = stored_vector(key, T)
    if isnothing(stored)
        fresh = T[]
        task_local_storage(key, fresh)
        return fresh
    end
    stored
end

active_frames() = stored_vector(FRAME_KEY, OpenFrame)

function nearest_probed(frames)
    index = length(frames)
    while index >= 1
        frame = frames[index]
        frame.is_probed && return frame
        index -= 1
    end
    nothing
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
    frame = nearest_probed(frames)
    if !isnothing(frame)
        name = frame.name
        if name !== ROOT_CALLER
            return name
        end
    end
    PARENT_CALL[]
end

function probed_frame()
    frames = active_frames()
    isnothing(frames) && return nothing
    nearest_probed(frames)
end

function probe_enter(name::Symbol, file::String, line::Int, arguments::Tuple,
        key_hash::Union{Nothing,UInt}, is_probed::Bool)
    session = ACTIVE[]
    isnothing(session) && return false
    frames = task_vector(FRAME_KEY, OpenFrame)
    held = task_vector(ARGUMENT_KEY, Any)
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
    frames = task_vector(FRAME_KEY, OpenFrame)
    held = task_vector(ARGUMENT_KEY, Any)
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
    frames = task_vector(FRAME_KEY, OpenFrame)
    held = task_vector(ARGUMENT_KEY, Any)
    pop!(frames)
    pop!(held)
    nothing
end

# Open frames on a task, and the records a probe session keeps.

"""One probed call that ran at least the probes' slow threshold. `arguments` is `hash` of the declared key when the
producer declares one, and the content hash of the arguments otherwise. Identities are `objectid`s."""
struct ProbeRecord
    name::Symbol                 # the probed function
    site::Tuple{String,Int}      # its method's file, repo-relative, and line
    caller::Symbol               # the nearest probed function open on the task; Symbol("") at a task's root
    caller_invocation::UInt      # that caller's call, numbered as `Invocation` says; 0 at a task's root
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
    is_argument_returned::Bool   # the non-bits result is one of the call's arguments, the same object
    body::DataType               # the probed body's closure type, whose effects are the original body's
end

"""One wait a probed method made on a task or another waitable value. Identities are `objectid`s, so each matches
the same object only."""
struct WaitRecord
    consumer::Symbol             # function that waited
    site::Tuple{String,Int}      # that method's file and line
    task::UInt                   # objectid of the waiting task
    child::UInt                  # objectid of the waited object: a task, or a value such as a `Future`
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

const ROOT_CALLER = Symbol("")

"""One call of a probed function. Each call takes its session's next number on entry, so each number of a session
names one call, on one task or many, recursive or not; number 0 is a root, the call of no probed function."""
struct Invocation
    name::Symbol   # the function called; `ROOT_CALLER` at a root
    id::UInt       # the call's number in its session
end

const ROOT_INVOCATION = Invocation(ROOT_CALLER, UInt(0))

struct OpenFrame{A<:Tuple}
    name::Symbol                 # function running
    file::String                 # repo-relative path
    line::Int                    # source line
    started::Float64             # entry time (s)
    invocation::UInt             # this call's number in its session
    caller::Invocation           # nearest probed call open at entry, or the one that spawned the task
    enclosing::Vector{Symbol}    # calls already open, outermost first
    arguments::A                 # the call's arguments, hashed when it leaves
    is_probed::Bool                    # true when this call was asked for
    is_ambient::Bool                   # this call is a non-probed function, or one encloses it
    key_hash::Union{Nothing,UInt}      # hash of the declared key; nothing when the producer declares none
end

"""What one `arm!` collects. Each rewritten method holds the session that armed it, and each task keeps the frames
of a session under that session, so sessions armed at once keep their calls apart."""
mutable struct ProbeSession
    slow_s::Float64                 # minimum duration that leaves a record (s)
    records::Vector{ProbeRecord}    # calls that met the duration
    waits::Vector{WaitRecord}       # waits logged while armed
    lock::ReentrantLock             # guards the record list and the wait list
    parent::Base.ScopedValues.ScopedValue{Invocation}   # the probed call open where a task was spawned
    @atomic calls::UInt             # the number the latest call took
end

function ProbeSession(slow_s::Float64)
    parent = Base.ScopedValues.ScopedValue{Invocation}(ROOT_INVOCATION)
    ProbeSession(slow_s, ProbeRecord[], WaitRecord[], ReentrantLock(), parent, ROOT_INVOCATION.id)
end

is_channel(@nospecialize(value)) = value isa Channel

function is_argument_result(@nospecialize(result), @nospecialize(arguments))
    isbits(result) && return false
    for argument in arguments
        argument === result && return true
    end
    false
end

function arguments_fed(@nospecialize(arguments))
    for argument in arguments
        is_channel(argument) && return true
    end
    false
end

# A task's open frames for one session, stored in the task under the session; nothing when none is open.
function session_frames(session::ProbeSession)
    storage = task_local_storage()
    stored = get(storage, session, nothing)
    isnothing(stored) && return nothing
    stored::Vector{OpenFrame}
end

function opened_frames(session::ProbeSession)
    stored = session_frames(session)
    isnothing(stored) || return stored
    fresh = OpenFrame[]
    task_local_storage(session, fresh)
    fresh
end

function close_frame(session::ProbeSession)
    frames = session_frames(session)::Vector{OpenFrame}
    frame = pop!(frames)
    if isempty(frames)
        storage = task_local_storage()
        delete!(storage, session)
    end
    frame
end

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

function caller_of(session::ProbeSession, frames)
    frame = nearest_probed(frames)
    isnothing(frame) && return session.parent[]
    Invocation(frame.name, frame.invocation)
end

function probed_frame(session::ProbeSession)
    frames = session_frames(session)
    isnothing(frames) && return nothing
    nearest_probed(frames)
end

"""The task-local mark of a record being taken for one session. The package code its hashes run, such as an
argument's own `hash`, runs unrecorded while the mark is set, so a probed call inside it leaves no frame."""
struct Recording
    session::ProbeSession   # the session whose record is being taken
end

function is_recording(session::ProbeSession)
    storage = task_local_storage()
    marker = Recording(session)
    haskey(storage, marker)
end

function unrecorded(take, session::ProbeSession)
    marker = Recording(session)
    task_local_storage(take, marker, true)
end

# A declared key runs under the recording mark, as the hashes do: a probed call it makes belongs to taking a record.
function declared_key_hash(compute, session::ProbeSession, key_name::String, producer_name::String)
    is_recording(session) && return nothing
    try
        unrecorded(session) do
            value = compute()
            hash(value)
        end
    catch cause
        shown = sprint(showerror, cause)
        message = "key " * key_name * " of producer " * producer_name * " failed: " * shown
        throw(ArgumentError(message))
    end
end

# Returns this call's invocation, which a task the call spawns takes as its parent.
function probe_enter(session::ProbeSession, name::Symbol, file::String, line::Int, @nospecialize(arguments::Tuple),
        key_hash::Union{Nothing,UInt}, is_probed::Bool)
    is_recording(session) && return session.parent[]
    frames = opened_frames(session)
    names = ancestor_names(frames)
    caller = caller_of(session, frames)
    covered = ambient_call(frames, is_probed)
    number = @atomic session.calls += 1
    started = time()
    entered = OpenFrame(name, file, line, started, number, caller, names, arguments, is_probed, covered, key_hash)
    push!(frames, entered)
    Invocation(name, number)
end

function make_record(@nospecialize(frame::OpenFrame), @nospecialize(result), stopped::Float64, body::DataType)
    arguments = frame.arguments
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
    caller = frame.caller
    returned = is_argument_result(result, arguments)
    ProbeRecord(frame.name, site, caller.name, caller.id, names, task_id,
                frame.started, stopped, argument_hash, result_hash, identity, reached, fed,
                frame.is_ambient, returned, body)
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

# The record is taken under the recording mark, which its caller found unset. Its values stay unspecialized and no
# closure carries them, so the record path compiles once for every argument and result type a run meets.
function take_record(session::ProbeSession, @nospecialize(frame::OpenFrame), @nospecialize(result), stopped::Float64,
        body::DataType)
    marker = Recording(session)
    storage = task_local_storage()
    storage[marker] = true
    try
        return make_record(frame, result, stopped, body)
    finally
        delete!(storage, marker)
    end
end

function probe_leave(session::ProbeSession, @nospecialize(result), body::DataType)
    is_recording(session) && return nothing
    frame = close_frame(session)
    stopped = time()
    duration = stopped - frame.started
    duration >= session.slow_s || return nothing
    record = take_record(session, frame, result, stopped, body)
    push_record(session, record)
    nothing
end

function probe_abort(session::ProbeSession)
    is_recording(session) && return nothing
    close_frame(session)
    nothing
end

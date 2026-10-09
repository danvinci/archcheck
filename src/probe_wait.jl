# Waits a probed method makes, and the close of a synced block. The waited object is a task, or any other value
# `fetch` and `wait` accept, such as a `Future` that `@spawnat` puts in a synced block.

function record_wait(frame::OpenFrame, child, started::Float64, stopped::Float64, result)
    identity = result_identity(result)
    reached = read_ids((result,))
    site = (frame.file, frame.line)
    consumer_task = objectid(current_task())
    child_id = objectid(child)
    WaitRecord(frame.name, site, consumer_task, child_id, started, stopped, identity, reached)
end

function finish_wait(child, started::Float64, result)
    frame = probed_frame()
    isnothing(frame) && return result
    session = ACTIVE[]
    isnothing(session) && return result
    stopped = time()
    record = record_wait(frame, child, started, stopped, result)
    push_wait(session, record)
    result
end

function probe_fetch(child)
    started = time()
    try
        result = Base.fetch(child)
        return finish_wait(child, started, result)
    catch
        finish_wait(child, started, nothing)
        rethrow()
    end
end

function probe_wait(child)
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

# `wait` on a failed task throws its `TaskFailedException`, the error `@sync` collects for it.
function wait_synced(item, errors)
    started = time()
    try
        Base.wait(item)
    catch failure
        push!(errors, failure)
    end
    finish_wait(item, started, nothing)
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

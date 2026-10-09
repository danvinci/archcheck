# Waits a probed method makes, and the close of a synced block.

function record_wait(frame::OpenFrame, child::Task, started::Float64, stopped::Float64, result)
    identity = result_identity(result)
    reached = read_ids((result,))
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

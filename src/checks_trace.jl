# Workload checks over probed calls: repeated arguments, one value from two functions, waits left unread.

const SECOND_DIGITS = 6

struct Rebuilds <: Check end
struct TwoNames <: Check end
struct Waits <: Check end

kinds(::Rebuilds) = (:rebuild => :advisory,)
kinds(::TwoNames) = (:two_names => :advisory,)
kinds(::Waits) = (:wait => :advisory,)

phase(::Rebuilds) = :workload
phase(::TwoNames) = :workload
phase(::Waits) = :workload

struct RepeatKey
    name::Symbol      # function that repeated
    caller::Symbol    # caller of those repeats
    file::String      # method file, repo-relative
    line::Int         # method line
end

struct WaitKey
    file::String       # consumer method file, repo-relative
    line::Int          # consumer method line
    consumer::Symbol   # function that waited
    waited::Symbol     # function whose result stayed unread
end

struct LaterUse
    blocked::Bool     # a probed call on the consumer task started after the wait
    reads::Set{UInt}  # object ids those calls reached
end

function trace_records(ctx)
    observed = ctx.observed
    isnothing(observed) && return ProbeRecord[]
    observed.records
end

# A probed method is one `arm!` found in the index, so its file is indexed.
function module_at(index, path::String)
    file = indexed_file(index, path)
    file.mod
end

function seconds_text(seconds::Float64)
    rounded = round(seconds; digits = SECOND_DIGITS)
    string(rounded)
end

function elapsed_s(record)
    record.stop_s - record.start_s
end

function is_plain_call(record)
    record.is_fed && return false
    record.is_ambient && return false
    true
end

function call_encloses(outer, inner)
    outer.task == inner.task || return false
    outer.start_s <= inner.start_s || return false
    inner.stop_s <= outer.stop_s || return false
    wider = outer.start_s < inner.start_s
    wider || inner.stop_s < outer.stop_s
end

function enclosed_by(records, slot, others)
    record = records[slot]
    for other_slot in others
        other_slot == slot && continue
        other = records[other_slot]
        if call_encloses(other, record)
            return true
        end
    end
    false
end

function plain_ordered(records)
    kept = ProbeRecord[]
    ordered = sort(records; by = record -> record.start_s)
    for record in ordered
        is_plain_call(record) || continue
        push!(kept, record)
    end
    kept
end

function repeat_slots(records)
    seen = Dict{Tuple{Symbol,UInt},Int}()
    slots = Int[]
    for slot in eachindex(records)
        record = records[slot]
        key = (record.name, record.arguments)
        if haskey(seen, key)
            push!(slots, slot)
        else
            seen[key] = slot
        end
    end
    slots
end

function repeat_key(record)
    file = record.site[1]
    line = record.site[2]
    RepeatKey(record.name, record.caller, file, line)
end

function group_repeats(records, slots)
    kept = ProbeRecord[]
    for slot in slots
        enclosed_by(records, slot, slots) && continue
        record = records[slot]
        push!(kept, record)
    end
    group_by(kept, RepeatKey, repeat_key)
end

function total_seconds(records)
    total = 0.0
    for record in records
        total += elapsed_s(record)
    end
    total
end

function rebuild_finding(index, key, records)
    mod = module_at(index, key.file)
    count = length(records)
    total = total_seconds(records)
    function_name = string(key.name)
    caller_name = string(key.caller)
    repeat_count = string(count)
    seconds = seconds_text(total)
    evidence = Pair{Symbol,String}[
        :function => function_name,
        :caller => caller_name,
        :repeats => repeat_count,
        :seconds => seconds,
    ]
    detail = "the same arguments were evaluated again"
    Finding(mod, :rebuild, key.file, function_name, key.line, detail, evidence)
end

function rebuild_findings(index, records)
    kept = plain_ordered(records)
    slots = repeat_slots(kept)
    grouped = group_repeats(kept, slots)
    found = Finding[]
    for (key, repeats) in grouped
        finding = rebuild_finding(index, key, repeats)
        push!(found, finding)
    end
    found
end

function distinct_names(records)
    names = Symbol[]
    for record in records
        if !(record.name in names)
            push!(names, record.name)
        end
    end
    names
end

function joined_names(names)
    labels = String[]
    for name in names
        label = string(name)
        push!(labels, label)
    end
    sort!(labels)
    join(labels, " ")
end

function outermost_records(records)
    kept = ProbeRecord[]
    for slot in eachindex(records)
        covered = eachindex(records)
        enclosed_by(records, slot, covered) && continue
        record = records[slot]
        push!(kept, record)
    end
    kept
end

function result_key(record)
    record.result
end

function result_groups(records)
    kept = ProbeRecord[]
    for record in records
        record.result_id == UInt(0) && continue
        push!(kept, record)
    end
    group_by(kept, UInt, result_key)
end

function two_name_finding(index, record, functions, values)
    file = record.site[1]
    line = record.site[2]
    mod = module_at(index, file)
    symbol = string(record.name)
    evidence = Pair{Symbol,String}[
        :functions => functions,
        :values => values,
    ]
    detail = "two functions returned one value"
    Finding(mod, :two_names, file, symbol, line, detail, evidence)
end

function two_name_findings(index, records)
    kept = plain_ordered(records)
    grouped = result_groups(kept)
    found = Finding[]
    for group in values(grouped)
        outer = outermost_records(group)
        names = distinct_names(outer)
        length(names) < 2 && continue
        functions = joined_names(names)
        values_text = string(length(outer))
        for record in outer
            finding = two_name_finding(index, record, functions, values_text)
            push!(found, finding)
        end
    end
    found
end

function later_use(records, wait)
    consumer = wait.task
    reached = Set{UInt}()
    blocked = false
    for record in records
        record.task == consumer || continue
        record.start_s >= wait.stop_s || continue
        blocked = true
        for id in record.reads
            push!(reached, id)
        end
    end
    LaterUse(blocked, reached)
end

function child_calls(records, wait)
    children = ProbeRecord[]
    for record in records
        record.task == wait.child || continue
        record.stop_s <= wait.stop_s || continue
        push!(children, record)
    end
    children
end

function root_child(records)
    root = nothing
    for slot in eachindex(records)
        covered = eachindex(records)
        enclosed_by(records, slot, covered) && continue
        record = records[slot]
        if isnothing(root) || record.start_s < root.start_s
            root = record
        end
    end
    root
end

function result_read(wait, reached)
    for id in wait.reads
        id in reached && return true
    end
    false
end

function wait_key(wait, waited::Symbol)
    file = wait.site[1]
    line = wait.site[2]
    WaitKey(file, line, wait.consumer, waited)
end

function add_seconds!(totals, key, seconds::Float64)
    prior = get(totals, key, 0.0)
    totals[key] = prior + seconds
    nothing
end

# A wait with no later probed call on its own task ends the task's probed work.
function note_wait!(totals, records, wait)
    later = later_use(records, wait)
    later.blocked || return nothing
    children = child_calls(records, wait)
    used = result_read(wait, later.reads)
    if !used && wait.result_id != UInt(0)
        root = root_child(children)
        if !isnothing(root)
            key = wait_key(wait, root.name)
            span = elapsed_s(wait)
            add_seconds!(totals, key, span)
        end
    end
    for child in children
        child.result_id == UInt(0) && continue
        child.result_id in wait.reads && continue
        child.result_id in later.reads && continue
        key = wait_key(wait, child.name)
        span = elapsed_s(child)
        add_seconds!(totals, key, span)
    end
    nothing
end

function wait_totals(records, waits)
    totals = Dict{WaitKey,Float64}()
    for wait in waits
        note_wait!(totals, records, wait)
    end
    totals
end

function wait_finding(index, key, seconds::Float64)
    mod = module_at(index, key.file)
    consumer = string(key.consumer)
    waited = string(key.waited)
    span = seconds_text(seconds)
    evidence = Pair{Symbol,String}[
        :consumer => consumer,
        :waited => waited,
        :seconds => span,
    ]
    detail = "a wait finished and a later call left the result unread"
    Finding(mod, :wait, key.file, waited, key.line, detail, evidence)
end

function wait_findings(index, records, waits)
    totals = wait_totals(records, waits)
    found = Finding[]
    for (key, seconds) in totals
        finding = wait_finding(index, key, seconds)
        push!(found, finding)
    end
    found
end

function run(::Rebuilds, ctx)
    records = trace_records(ctx)
    rebuild_findings(ctx.index, records)
end

function run(::TwoNames, ctx)
    records = trace_records(ctx)
    two_name_findings(ctx.index, records)
end

function run(::Waits, ctx)
    records = trace_records(ctx)
    observed = ctx.observed
    waits = WaitRecord[]
    if !isnothing(observed)
        waits = observed.waits
    end
    wait_findings(ctx.index, records, waits)
end

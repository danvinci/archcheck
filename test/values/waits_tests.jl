# Each unread join form. A fetch whose value is read, a method on the allowlist, and a local spelled like a join
# stay quiet, an enclosing method's local included. A wait is judged where the method graph walked its call.

function wait_rows(found)
    rows = Tuple{String,Symbol,String,String,Int,Symbol}[]
    for finding in found
        form = ev(finding, :form)
        call = ev(finding, :call)
        row = (finding.symbol, finding.mod, form, call, finding.line, finding.kind)
        push!(rows, row)
    end
    sort!(rows)
    rows
end

const WAIT_JOINS = load_package("WaitJoins", """
function dropped(task)
    fetch(task)
    nothing
end
function returned(task)
    return fetch(task)
end
function assigned(task)
    held = fetch(task)
    held
end
function waited(task)
    wait(task)
end
function passed(tasks)
    foreach(fetch, tasks)
end
function mapped(tasks)
    held = map(fetch, tasks)
    held
end
function synced()
    @sync begin
        identity(1)
    end
end
function launched(cmd)
    run(cmd; wait = false)
end
function named(tasks)
    foldl(+, tasks; init = fetch)
end
function barrier(task, tasks)
    fetch(task)
    nothing
    wait(task)
    foreach(fetch, tasks)
    @sync begin
        identity(1)
    end
end
function carried(records, wait)
    later_use(records, wait)
end
function signed(fetch)
    identity(1)
end
function enclosed(tasks)
    wait = identity
    inner() = foreach(wait, tasks)
    inner
end
""")

@testset "each unread join form fires, and a used fetch or an allowed method stays quiet" begin
    entries = ((WAIT_JOINS.pkg.waited, Tuple{Task}),)
    ctx = case_context(WAIT_JOINS; entries)
    check = UnreadWaits(; allowed = (:barrier,))
    found = ArchCheck.run(check, ctx)
    rows = wait_rows(found)
    expected = [
        ("dropped", :WaitJoins, "fetch", "fetch(task)", 3, :unread_wait),
        ("passed", :WaitJoins, "passed", "foreach(fetch, tasks)", 17, :unread_wait),
        ("synced", :WaitJoins, "sync", "@sync begin identity(1) end", 24, :unread_wait),
        ("waited", :WaitJoins, "wait", "wait(task)", 14, :unread_wait),
    ]
    @test rows == expected
end

const WAIT_SIGNALS = load_package("WaitSignals", """
struct Stream
    condition::Threads.Condition
end
function drained(stream::Stream)
    lock(stream.condition)
    wait(stream.condition)
    unlock(stream.condition)
end
function ready(event::Base.Event)
    wait(event)
end
function joined(task::Task)
    wait(task)
end
function settled(task::Task)
    wait(task; throw = false)
    istaskdone(task)
end
function unwalked(task)
    wait(task)
end
""")

@testset "a wait joins a task only where its call resolves to the task's wait in a walked method" begin
    pkg = WAIT_SIGNALS.pkg
    stream = (pkg.drained, Tuple{pkg.Stream})
    event = (pkg.ready, Tuple{Base.Event})
    task = (pkg.joined, Tuple{Task})
    keyword = (pkg.settled, Tuple{Task})
    entries = (stream, event, task, keyword)
    ctx = case_context(WAIT_SIGNALS; entries)
    check = UnreadWaits()
    found = ArchCheck.run(check, ctx)
    symbols = sort!([f.symbol for f in found])
    @test symbols == ["joined", "settled"]
end

const KEPT_RESULTS = load_package("KeptResults", """
function collected(tasks)
    results = map(fetch, tasks)
    results
end
function total(tasks)
    sum(fetch, tasks)
end
function settled(tasks)
    foreach(wait, tasks)
end
function discarded(tasks)
    map(fetch, tasks)
    nothing
end
function described()
    typeof(wait)
end
""")

@testset "a join passed to a call whose value is kept drops nothing" begin
    ctx = case_context(KEPT_RESULTS)
    check = UnreadWaits()
    found = ArchCheck.run(check, ctx)
    symbols = sort!([f.symbol for f in found])
    @test symbols == ["discarded", "settled"]
end

const QUOTED_JOIN = load_package("QuotedJoin", """
function emitted(task)
    quote
        wait(\$task)
        fetch(\$task)
        @sync identity(1)
        nothing
    end
end
""")

@testset "a join inside a quote is code the method returns" begin
    entries = ((QUOTED_JOIN.pkg.emitted, Tuple{Task}),)
    ctx = case_context(QUOTED_JOIN; entries)
    check = UnreadWaits()
    found = ArchCheck.run(check, ctx)
    @test isempty(found)
end

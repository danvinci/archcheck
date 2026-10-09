# Each unread join form. A fetch whose value is read, and a method on the allowlist, stay quiet.

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
""")

@testset "each unread join form fires, and a used fetch or an allowed method stays quiet" begin
    ctx = case_context(WAIT_JOINS)
    check = UnreadWaits(; allowed = (:barrier,))
    found = ArchCheck.run(check, ctx)
    rows = wait_rows(found)
    expected = [
        ("dropped", :WaitJoins, "fetch", "fetch(task)", 3, :unread_wait),
        ("mapped", :WaitJoins, "passed", "map(fetch, tasks)", 20, :unread_wait),
        ("named", :WaitJoins, "passed", "foldl(+, tasks; init = fetch)", 32, :unread_wait),
        ("passed", :WaitJoins, "passed", "foreach(fetch, tasks)", 17, :unread_wait),
        ("synced", :WaitJoins, "sync", "@sync begin identity(1) end", 24, :unread_wait),
        ("waited", :WaitJoins, "wait", "wait(task)", 14, :unread_wait),
    ]
    @test rows == expected
end

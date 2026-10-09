# Each unread join form. A fetch whose value is read, and a method on the allowlist, stay quiet.

function waits_context(source)
    root = mktempdir()
    src = joinpath(root, "src")
    joins = joinpath(src, "joins")
    mkpath(joins)
    path = joinpath(joins, "Joins.jl")
    write(path, source)
    rank = Dict(:Joins => 1)
    dir2mod = Dict("joins" => :Joins)
    index = build_source_index(src, rank, dir2mod)
    ArchCheck.Context(index, Main, Module[])
end

function wait_rows(found)
    rows = Tuple{String,Symbol,String,String,Int,Symbol}[]
    for finding in found
        form = ev(finding, :form)
        call = ev(finding, :call)
        row = (finding.symbol, finding.mod, form, call, finding.line, finding.kind)
        push!(rows, row)
    end
    sort!(rows)
end

const JOINS_SOURCE = """
module Joins
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
end
"""

@testset "each unread join form fires, and a used fetch or an allowed method stays quiet" begin
    ctx = waits_context(JOINS_SOURCE)
    check = ArchCheck.UnreadWaits(; allowed = (:barrier,))
    found = ArchCheck.run(check, ctx)
    rows = wait_rows(found)
    expected = [
        ("dropped", :Joins, "fetch", "fetch(task)", 3, :unread_wait),
        ("mapped", :Joins, "passed", "map(fetch, tasks)", 20, :unread_wait),
        ("named", :Joins, "passed", "foldl(+, tasks; init = fetch)", 32, :unread_wait),
        ("passed", :Joins, "passed", "foreach(fetch, tasks)", 17, :unread_wait),
        ("synced", :Joins, "sync", "@sync begin identity(1) end", 24, :unread_wait),
        ("waited", :Joins, "wait", "wait(task)", 14, :unread_wait),
    ]
    @test rows == expected
end

# A task's result read with no element type is a finding: Base's `fetch`, `fetch.`, `map(fetch, ...)` and `asyncmap`
# whose value the code reads. An assertion on the call, a typed comprehension around it, a discarded `fetch` and a
# `fetch` that resolves to a local or to the package's own function are none

const TASK_RESULTS = load_package("TaskResults", """
include("own.jl")
include("results.jl")
""", [
    "own.jl" => """
    module Own
    fetch(x) = x
    end
    """,
    "results.jl" => """
    joined(task) = fetch(task)
    qualified(task) = Base.fetch(task)
    broadcast_joined(tasks) = fetch.(tasks)
    mapped(tasks) = map(fetch, tasks)
    spread(xs) = asyncmap(x -> x + 1, xs)
    function kept(task)
        value = fetch(task)
        value + 1
    end
    asserted(task) = fetch(task)::Int
    asserted_map(xs) = asyncmap(x -> x + 1, xs)::Vector{Int}
    collected(tasks) = Int[fetch(task) for task in tasks]
    filtered(tasks) = Int[fetch(task) for task in tasks if istaskdone(task)]
    function dropped(task)
        fetch(task)
        0
    end
    own(x) = Own.fetch(x)
    shadowed(fetch, x) = fetch(x)
    mapped_local(fetch, xs) = map(fetch, xs)
    summed(xs) = map(abs, xs)
    """,
])

@testset "a task's result read with no element type is a finding, a typed read none" begin
    ctx = case_context(TASK_RESULTS)
    found = ArchCheck.run(UntypedTaskResults(), ctx)
    rows = evidence_rows(found, :call)
    @test rows == [(:untyped_task_result, "broadcast_joined", "fetch.(tasks)"),
                   (:untyped_task_result, "joined", "fetch(task)"),
                   (:untyped_task_result, "kept", "fetch(task)"),
                   (:untyped_task_result, "mapped", "map(fetch, tasks)"),
                   (:untyped_task_result, "qualified", "Base.fetch(task)"),
                   (:untyped_task_result, "spread", "asyncmap(x -> x + 1, xs)")]
    kept = only(finding for finding in found if finding.symbol == "kept")
    @test (kept.file, kept.line) == (joinpath("src", "results.jl"), 7)
    @test (:untyped_task_result => :advisory) in ArchCheck.kinds(UntypedTaskResults())
end

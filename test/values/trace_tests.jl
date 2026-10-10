# Workload checks over a probe trace: repeated arguments, one value under two names, waits nobody reads.

const WAIT_FLOOR_S = 0.05

const SHARED_REF = load_package("SharedRef", """
    function left(x)
        Ref(x)
    end

    function right(x)
        Ref(x)
    end

    function twin(x)
        x
    end

    function twin_b(x)
        x
    end

    typed_zero(::Type{T}) where {T} = zero(T)

    function call_both(f, g, x, y)
        (f(x), g(y))
    end

    passed(x) = x

    function hand_on(x)
        value = left(x)
        passed(value)
    end
    """)

const NESTED_REPEAT = load_package("NestedRepeat", """
    const depth = Ref(0)
    function work(x)
        if depth[] > 0
            depth[] = depth[] - 1
            work(x)
        end
        x
    end

    function rerun(x)
        work(x)
        work(x)
    end
    """)

const UNREAD_RESULT = load_package("UnreadResult", """
    function produced()
        sleep(0.05)
        Ref(1)
    end

    function looked(value)
        value
    end

    function reads_result()
        task = Threads.@spawn produced()
        value = fetch(task)
        looked(value)
    end

    function drops_result()
        task = Threads.@spawn produced()
        fetch(task)
        looked(Ref(2))
    end

    function reads_broadcast()
        tasks = [Threads.@spawn produced() for _ in 1:1]
        values = fetch.(tasks)
        looked(values[1])
    end

    function drops_broadcast()
        tasks = [Threads.@spawn produced() for _ in 1:1]
        fetch.(tasks)
        looked(Ref(3))
    end

    function drops_each()
        tasks = [Threads.@spawn produced()]
        foreach(fetch, tasks)
        looked(Ref(4))
    end

    function drops_sync()
        @sync begin
            Threads.@spawn produced()
        end
        looked(Ref(5))
    end
    """)

@testset "the same arguments within one call of the caller fire once; across calls, at the root, and distinct stay quiet" begin
    checks = (Rebuilds(),)
    functions = (Probed.same, Probed.call_both)
    probes = Probes(; functions, slow_s = 0.0)
    repeated_call = () -> Probed.call_both(Probed.same, Probed.same, [1, 2, 3], [1, 2, 3])
    fired = gate_findings(Probed; checks, probes, workload = repeated_call)
    rows = evidence_rows(fired, :function, :caller, :repeats)
    @test rows == [(:rebuild, "same", "same", "call_both", "1")]
    # `same` sums the vector it is handed, which another call may change between two calls.
    mutable_read = only(fired)
    @test !any(pair -> pair.first === :consistent, mutable_read.evidence)

    across_calls = function ()
        Probed.call_both(Probed.same, Probed.same, [1, 2, 3], [1, 2, 4])
        Probed.call_both(Probed.same, Probed.same, [1, 2, 3], [1, 2, 4])
        Probed.same([1, 2, 3])
        Probed.same([1, 2, 3])
    end
    quiet = gate_findings(Probed; checks, probes, workload = across_calls)
    @test isempty(quiet)

    typed = SHARED_REF.pkg
    distinct_type = () -> typed.call_both(typed.typed_zero, typed.typed_zero, Int, Float64)
    type_probes = Probes(; functions = (typed.typed_zero, typed.call_both), slow_s = 0.0)
    type_quiet = gate_findings(typed; checks, probes = type_probes, workload = distinct_type)
    @test isempty(type_quiet)
end

@testset "a repeat inside an ambient call is set apart, and a channel-fed call is set apart" begin
    checks = (Rebuilds(),)
    covered_call = () -> Probed.call_both(Probed.around, Probed.around, 5, 5)
    covered_probes = Probes(; functions = (Probed.leaf, Probed.call_both), ambient = (Probed.around,), slow_s = 0.0)
    apart = gate_findings(Probed; checks, probes = covered_probes, workload = covered_call)
    @test isempty(apart)

    fed_channel = Channel{Int}(1)
    fed_call = () -> Probed.call_both(Probed.echo, Probed.echo, fed_channel, fed_channel)
    echo_probes = Probes(; functions = (Probed.echo, Probed.call_both), slow_s = 0.0)
    fed = gate_findings(Probed; checks, probes = echo_probes, workload = fed_call)
    @test isempty(fed)

    plain_call = () -> Probed.call_both(Probed.echo, Probed.echo, 1, 1)
    plain = gate_findings(Probed; checks, probes = echo_probes, workload = plain_call)
    rows = evidence_rows(plain, :function, :repeats, :consistent)
    @test rows == [(:rebuild, "echo", "echo", "1", "true")]
end

@testset "a recursive call is an invocation of its own, so recursion on one argument is no repeat" begin
    pkg = NESTED_REPEAT.pkg
    checks = (Rebuilds(),)
    probes = Probes(; functions = (pkg.work, pkg.rerun), slow_s = 0.0)
    recursive_call = function ()
        pkg.depth[] = 2
        pkg.work(1)
    end
    recursive = gate_findings(pkg; checks, probes, workload = recursive_call)
    @test isempty(recursive)

    rerun_call = function ()
        pkg.depth[] = 2
        pkg.rerun(1)
    end
    rerun = gate_findings(pkg; checks, probes, workload = rerun_call)
    rerun_rows = evidence_rows(rerun, :function, :caller, :repeats)
    @test rerun_rows == [(:rebuild, "work", "work", "rerun", "1")]
end

@testset "two producers of one value in one call of the caller fire, one passing its argument on is no producer, and one name twice is a rebuild" begin
    mod = SHARED_REF.pkg
    share_value = () -> mod.call_both(mod.left, mod.right, 1, 1)
    probes = Probes(; functions = (mod.left, mod.right, mod.twin, mod.twin_b, mod.call_both), slow_s = 0.0)
    fired = gate_findings(mod; checks = (TwoNames(),), probes, workload = share_value)
    rows = evidence_rows(fired, :functions, :values)
    @test rows == [
        (:two_names, "left", "left right", "2"),
        (:two_names, "right", "left right", "2"),
    ]

    at_root = function ()
        mod.left(1)
        mod.right(1)
    end
    root_quiet = gate_findings(mod; checks = (TwoNames(),), probes, workload = at_root)
    @test isempty(root_quiet)

    handed_on = () -> mod.hand_on(1)
    passing_probes = Probes(; functions = (mod.left, mod.passed, mod.hand_on), slow_s = 0.0)
    passed_quiet = gate_findings(mod; checks = (TwoNames(),), probes = passing_probes, workload = handed_on)
    @test isempty(passed_quiet)

    echo_refs = function ()
        first_ref = Ref(1)
        second_ref = Ref(1)
        Probed.call_both(Probed.echo, Probed.echo, first_ref, second_ref)
    end
    echo_probes = Probes(; functions = (Probed.echo, Probed.call_both), slow_s = 0.0)
    one_name = gate_findings(Probed; checks = (TwoNames(),), probes = echo_probes, workload = echo_refs)
    @test isempty(one_name)
    rebuilt = gate_findings(Probed; checks = (Rebuilds(),), probes = echo_probes, workload = echo_refs)
    rebuilt_rows = evidence_rows(rebuilt, :function, :repeats)
    @test rebuilt_rows == [(:rebuild, "echo", "echo", "1")]

    share_bits = () -> mod.call_both(mod.twin, mod.twin_b, 1, 1)
    bits = gate_findings(mod; checks = (TwoNames(),), probes, workload = share_bits)
    @test isempty(bits)
end

@testset "a result a later call reads is quiet, and a result nobody reads fires" begin
    mod = UNREAD_RESULT.pkg
    targets = (mod.produced, mod.looked, mod.reads_result, mod.drops_result, mod.reads_broadcast,
               mod.drops_broadcast, mod.drops_each, mod.drops_sync)
    checks = (Waits(),)
    probes = Probes(; functions = targets, slow_s = 0.0)
    quiet = gate_findings(mod; checks, probes, workload = mod.reads_result)
    @test isempty(quiet)
    broadcast_quiet = gate_findings(mod; checks, probes, workload = mod.reads_broadcast)
    @test isempty(broadcast_quiet)

    fired = gate_findings(mod; checks, probes, workload = mod.drops_result)
    rows = evidence_rows(fired, :consumer, :waited)
    @test rows == [(:wait, "produced", "drops_result", "produced")]
    finding = only(fired)
    seconds = ev(finding, :seconds)
    waited_s = parse(Float64, seconds)
    @test waited_s >= WAIT_FLOOR_S

    each = gate_findings(mod; checks, probes, workload = mod.drops_each)
    each_rows = evidence_rows(each, :waited)
    @test each_rows == [(:wait, "produced", "produced")]
    spread = gate_findings(mod; checks, probes, workload = mod.drops_broadcast)
    spread_rows = evidence_rows(spread, :waited)
    @test spread_rows == [(:wait, "produced", "produced")]
    synced = gate_findings(mod; checks, probes, workload = mod.drops_sync)
    synced_rows = evidence_rows(synced, :consumer, :waited)
    @test synced_rows == [(:wait, "produced", "drops_sync", "produced")]
end

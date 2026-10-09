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
    """)

const NESTED_REPEAT = load_package("NestedRepeat", """
    const depth = Ref(0)
    function work(x)
        sleep(0.02)
        if depth[] > 0
            depth[] = depth[] - 1
            work(x)
        end
        sleep(0.02)
        x
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

@testset "the same arguments fire once and distinct arguments stay quiet" begin
    checks = (Rebuilds(),)
    functions = (Probed.same,)
    repeated_call = function ()
        Probed.same([1, 2, 3])
        Probed.same([1, 2, 3])
    end
    probes = Probes(; functions, slow_s = 0.0)
    fired = gate_findings(Probed; checks, probes, workload = repeated_call)
    rows = evidence_rows(fired, :function, :caller, :repeats)
    @test rows == [(:rebuild, "same", "same", "", "1")]

    distinct_call = function ()
        Probed.same([1, 2, 3])
        Probed.same([1, 2, 4])
    end
    quiet = gate_findings(Probed; checks, probes, workload = distinct_call)
    @test isempty(quiet)
end

@testset "a repeat inside an ambient call is set apart, and a channel-fed call is set apart" begin
    checks = (Rebuilds(),)
    covered_call = function ()
        Probed.around(5)
        Probed.around(5)
    end
    covered_probes = Probes(; functions = (Probed.leaf,), ambient = (Probed.around,), slow_s = 0.0)
    apart = gate_findings(Probed; checks, probes = covered_probes, workload = covered_call)
    @test isempty(apart)

    fed_channel = Channel{Int}(1)
    fed_call = function ()
        Probed.echo(fed_channel)
        Probed.echo(fed_channel)
    end
    echo_probes = Probes(; functions = (Probed.echo,), slow_s = 0.0)
    fed = gate_findings(Probed; checks, probes = echo_probes, workload = fed_call)
    @test isempty(fed)

    plain_call = function ()
        Probed.echo(1)
        Probed.echo(1)
    end
    plain = gate_findings(Probed; checks, probes = echo_probes, workload = plain_call)
    rows = evidence_rows(plain, :function, :repeats)
    @test rows == [(:rebuild, "echo", "echo", "1")]
end

@testset "a nested repeat of the same arguments counts once" begin
    pkg = NESTED_REPEAT.pkg
    checks = (Rebuilds(),)
    functions = (pkg.work,)
    nested_call = function ()
        pkg.depth[] = 2
        pkg.work(1)
    end
    probes = Probes(; functions, slow_s = 0.0)
    nested = gate_findings(pkg; checks, probes, workload = nested_call)
    nested_rows = evidence_rows(nested, :function, :repeats)
    @test nested_rows == [(:rebuild, "work", "work", "1")]

    sequential_call = function ()
        pkg.depth[] = 0
        pkg.work(1)
        pkg.work(1)
        pkg.work(1)
    end
    sequential = gate_findings(pkg; checks, probes, workload = sequential_call)
    sequential_rows = evidence_rows(sequential, :function, :repeats)
    @test sequential_rows == [(:rebuild, "work", "work", "2")]
end

@testset "two producers of one value fire, and one name twice is a rebuild" begin
    mod = SHARED_REF.pkg
    share_value = function ()
        mod.left(1)
        mod.right(1)
    end
    probes = Probes(; functions = (mod.left, mod.right, mod.twin, mod.twin_b), slow_s = 0.0)
    fired = gate_findings(mod; checks = (TwoNames(),), probes, workload = share_value)
    rows = evidence_rows(fired, :functions, :values)
    @test rows == [
        (:two_names, "left", "left right", "2"),
        (:two_names, "right", "left right", "2"),
    ]

    echo_refs = function ()
        Probed.echo(Ref(1))
        Probed.echo(Ref(1))
    end
    echo_probes = Probes(; functions = (Probed.echo,), slow_s = 0.0)
    one_name = gate_findings(Probed; checks = (TwoNames(),), probes = echo_probes, workload = echo_refs)
    @test isempty(one_name)
    rebuilt = gate_findings(Probed; checks = (Rebuilds(),), probes = echo_probes, workload = echo_refs)
    rebuilt_rows = evidence_rows(rebuilt, :function, :repeats)
    @test rebuilt_rows == [(:rebuild, "echo", "echo", "1")]

    share_bits = function ()
        mod.twin(1)
        mod.twin_b(1)
    end
    bit_probes = Probes(; functions = (mod.twin, mod.twin_b), slow_s = 0.0)
    bits = gate_findings(mod; checks = (TwoNames(),), probes = bit_probes, workload = share_bits)
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

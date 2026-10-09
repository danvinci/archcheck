# Workload checks over a probe trace: repeated arguments, one value under two names, waits nobody reads.

const SPAN_S = 10.0
const REPEAT_START_S = 0.5
const REPEAT_STOP_S = 2.0
const NESTED_STOP_S = 1.0
const WAIT_FLOOR_S = 0.05
const WORK_HASH = UInt(7)

function traced_call(; name::Symbol, arguments::UInt, result::UInt = UInt(0), result_id::UInt = UInt(0),
        caller::Symbol = Symbol(""), enclosing = nothing, task::UInt = UInt(1), start_s::Float64 = 0.0,
        stop_s::Float64 = 1.0, reads = nothing, is_fed::Bool = false, file::String = "src/Probed.jl", line::Int = 1)
    names = isnothing(enclosing) ? Symbol[] : enclosing
    reached = isnothing(reads) ? UInt[] : reads
    site = (file, line)
    ProbeRecord(name, site, caller, names, task, start_s, stop_s, arguments, result, result_id, reached,
                is_fed, false)
end

function with_records(records; waits = WaitRecord[])
    base = probed_context()
    reached = Set{Method}()
    observed = Observation(reached, records, waits, 1.0)
    Context(base; observed)
end

function findings_of(check, records)
    ctx = with_records(records)
    ArchCheck.run(check, ctx)
end

function probe_records(body, functions; ambient = ())
    function run(_armed)
        body()
    end
    probing(run, functions; ambient, slow_s = 0.0)
end

@testset "rebuilds: the same arguments fire once and distinct arguments stay quiet" begin
    repeated = probe_records((Probed.same,)) do
        call(Probed.same, [1, 2, 3])
        call(Probed.same, [1, 2, 3])
    end
    fired = findings_of(Rebuilds(), repeated)
    finding = only(fired)
    @test finding.kind === :rebuild
    @test finding.symbol == "same"
    @test ev(finding, :function) == "same"
    @test ev(finding, :caller) == ""
    @test ev(finding, :repeats) == "1"
    seconds = ev(finding, :seconds)
    waited = parse(Float64, seconds)
    @test waited >= 0.0

    distinct = probe_records((Probed.same,)) do
        call(Probed.same, [1, 2, 3])
        call(Probed.same, [1, 2, 4])
    end
    quiet = findings_of(Rebuilds(), distinct)
    @test isempty(quiet)
end

@testset "rebuilds: a repeat inside an ambient call is set apart, and a channel-fed call is set apart" begin
    covered = probe_records((Probed.leaf,); ambient = (Probed.around,)) do
        call(Probed.around, 5)
        call(Probed.around, 5)
    end
    apart = findings_of(Rebuilds(), covered)
    @test isempty(apart)

    fed_channel = Channel{Int}(1)
    fed = probe_records((Probed.echo,)) do
        call(Probed.echo, fed_channel)
        call(Probed.echo, fed_channel)
    end
    fed_findings = findings_of(Rebuilds(), fed)
    @test isempty(fed_findings)

    plain = probe_records((Probed.echo,)) do
        call(Probed.echo, 1)
        call(Probed.echo, 1)
    end
    plain_findings = findings_of(Rebuilds(), plain)
    @test length(plain_findings) == 1
    plain_finding = only(plain_findings)
    @test ev(plain_finding, :function) == "echo"
end

@testset "rebuilds: a repeat inside another repeat's interval on one task counts once" begin
    original = traced_call(; name = :work, arguments = WORK_HASH, caller = :wrap, start_s = 0.0, stop_s = SPAN_S)
    outer = traced_call(; name = :work, arguments = WORK_HASH, caller = :wrap, start_s = REPEAT_START_S, stop_s = REPEAT_STOP_S)
    inner = traced_call(; name = :work, arguments = WORK_HASH, caller = :wrap, start_s = REPEAT_START_S, stop_s = NESTED_STOP_S)
    fired = findings_of(Rebuilds(), [original, outer, inner])
    finding = only(fired)
    @test ev(finding, :function) == "work"
    @test ev(finding, :caller) == "wrap"
    @test ev(finding, :repeats) == "1"
    @test ev(finding, :seconds) == "1.5"
end

@testset "two names: two producers of one value fire, and one name twice is a rebuild" begin
    source = """
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
    """
    loaded = indexed_module(:TwoNames, source)
    mod = loaded.mod
    probes = Probes(functions = (mod.left, mod.right, mod.twin, mod.twin_b), slow_s = 0.0)
    armed = ArchCheck.arm!(probes, loaded.ctx)
    local shared
    try
        Base.invokelatest(mod.left, 1)
        Base.invokelatest(mod.right, 1)
    finally
        shared = ArchCheck.disarm!(armed)
    end
    shared_ctx = with_records(shared.records)
    fired = ArchCheck.run(TwoNames(), shared_ctx)
    @test length(fired) == 2
    labels = [ev(finding, :functions) for finding in fired]
    @test sort(labels) == ["left right", "left right"]
    @test ev(fired[1], :values) == "2"
    symbols = [finding.symbol for finding in fired]
    @test sort(symbols) == ["left", "right"]
    kinds_match = all(finding -> finding.kind === :two_names, fired)
    @test kinds_match

    again = probe_records((Probed.echo,)) do
        call(Probed.echo, Ref(1))
        call(Probed.echo, Ref(1))
    end
    again_ctx = with_records(again)
    one_name = ArchCheck.run(TwoNames(), again_ctx)
    @test isempty(one_name)
    rebuilt = findings_of(Rebuilds(), again)
    @test length(rebuilt) == 1

    bits_probes = Probes(functions = (mod.twin, mod.twin_b), slow_s = 0.0)
    bits_armed = ArchCheck.arm!(bits_probes, loaded.ctx)
    local bits
    try
        Base.invokelatest(mod.twin, 1)
        Base.invokelatest(mod.twin_b, 1)
    finally
        bits = ArchCheck.disarm!(bits_armed)
    end
    bits_ctx = with_records(bits.records)
    bits_findings = ArchCheck.run(TwoNames(), bits_ctx)
    @test isempty(bits_findings)
end

@testset "waits: a result a later call reads is quiet, and a result nobody reads fires" begin
    source = """
    function produced()
        sleep($WAIT_FLOOR_S)
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
    """
    loaded = indexed_module(:WaitLink, source)
    mod = loaded.mod
    targets = (mod.produced, mod.looked, mod.reads_result, mod.drops_result, mod.reads_broadcast,
               mod.drops_broadcast, mod.drops_each, mod.drops_sync)
    probes = Probes(functions = targets, slow_s = 0.0)

    function waited(called)
        armed = ArchCheck.arm!(probes, loaded.ctx)
        local traced
        try
            Base.invokelatest(called)
        finally
            traced = ArchCheck.disarm!(armed)
        end
        ctx = with_records(traced.records; waits = traced.waits)
        ArchCheck.run(Waits(), ctx)
    end

    quiet = waited(mod.reads_result)
    @test isempty(quiet)
    broadcast_quiet = waited(mod.reads_broadcast)
    @test isempty(broadcast_quiet)

    fired = waited(mod.drops_result)
    finding = only(fired)
    @test finding.kind === :wait
    @test finding.symbol == "produced"
    @test ev(finding, :consumer) == "drops_result"
    @test ev(finding, :waited) == "produced"
    seconds = ev(finding, :seconds)
    waited_s = parse(Float64, seconds)
    @test waited_s >= WAIT_FLOOR_S

    each = waited(mod.drops_each)
    each_finding = only(each)
    @test ev(each_finding, :waited) == "produced"
    spread = waited(mod.drops_broadcast)
    spread_finding = only(spread)
    @test ev(spread_finding, :waited) == "produced"
    synced = waited(mod.drops_sync)
    synced_finding = only(synced)
    @test ev(synced_finding, :consumer) == "drops_sync"
    @test ev(synced_finding, :waited) == "produced"
end

@testset "trace checks are workload advisories" begin
    rebuilds = Rebuilds()
    two_names = TwoNames()
    waits = Waits()
    @test ArchCheck.phase(rebuilds) === :workload
    @test ArchCheck.phase(two_names) === :workload
    @test ArchCheck.phase(waits) === :workload
    @test ArchCheck.kinds(rebuilds) == (:rebuild => :advisory,)
    @test ArchCheck.kinds(two_names) == (:two_names => :advisory,)
    @test ArchCheck.kinds(waits) == (:wait => :advisory,)
end

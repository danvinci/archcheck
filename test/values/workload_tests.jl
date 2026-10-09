# What one workload run compiled, and that a throwing workload still propagates.

const COMPILED_METHODS = load_package("CompiledMethods", """
    hit(x::Int) = x + 1
    miss(x::Int) = x + 2
    function keyed(x::Int; extra = 0)
        x + extra
    end
    onlykw(; extra = 0) = extra + 1
    """)

const COMPILED_EARLY = load_package("CompiledEarly", """
    early(x::Int) = x + 3
    during(x::Int) = x + 4
    """)

const SHOWN_MARK = load_package("ShownMark", """
    struct Mark
    end
    Base.show(io::IO, ::Mark) = print(io, "mark")
    other(x::Int) = x + 1
    """)

@testset "reached is the package methods compiled so far, and records stay empty when nothing is probed" begin
    reached_pkg = COMPILED_METHODS.pkg
    call_reached = function ()
        reached_pkg.hit(1)
        reached_pkg.keyed(1; extra = 2)
        reached_pkg.onlykw(; extra = 4)
    end
    reached_run = observed_gate(reached_pkg; workload = call_reached)
    called = reached_run.observed
    hit = only(methods(reached_pkg.hit))
    keyed = only(methods(reached_pkg.keyed))
    onlykw = only(methods(reached_pkg.onlykw))
    @test called.reached == Set([hit, keyed, onlykw])
    @test isempty(called.records)

    shown_pkg = SHOWN_MARK.pkg
    show_method = which(Base.show, (IO, shown_pkg.Mark))
    quiet_run = observed_gate(shown_pkg; workload = () -> shown_pkg.other(1))
    quiet = quiet_run.observed
    show_mark = function ()
        buffer = IOBuffer()
        show(buffer, shown_pkg.Mark())
    end
    shown_run = observed_gate(shown_pkg; workload = show_mark)
    shown = shown_run.observed
    @test !(show_method in quiet.reached)
    @test show_method in shown.reached

    early_pkg = COMPILED_EARLY.pkg
    early_pkg.early(1)
    early = only(methods(early_pkg.early))
    early_run = observed_gate(early_pkg; workload = () -> early_pkg.during(1))
    compiled_before = early_run.observed
    @test early in compiled_before.reached
end

@testset "a throwing workload propagates out of the gate" begin
    err = ErrorException("workload failed")
    @test_throws err gate_findings(Nested; checks = (), workload = () -> throw(err))
end

@testset "a method in the root module of a package with submodules counts as reached" begin
    target = which(Nested.root_measure, (Int,))
    reached_run = observed_gate(Nested; workload = () -> Nested.root_measure(1))
    seen = reached_run.observed
    @test target in seen.reached
end

@testset "a probed submodule method is recorded, then restored to its file and body and counted as reached" begin
    squared = Nested.Geo.Cuts.squared
    probes = Probes(functions = (squared,), slow_s = 0.0)
    before = which(squared, (Int,))
    body_before = only(code_lowered(squared, (Int,)))
    probed_run = observed_gate(Nested; probes, workload = () -> squared(3))
    seen = probed_run.observed
    record = only(seen.records)
    @test record.name === :squared
    @test record.caller === Symbol("")
    after = which(squared, (Int,))
    @test after.file === before.file
    body_after = only(code_lowered(squared, (Int,)))
    @test string(body_after) == string(body_before)
    @test after in seen.reached
end

@testset "a probed keyword method counts as reached after its methods are restored" begin
    keyed = Probed.keyed
    probes = Probes(functions = (keyed,), slow_s = 0.0)
    checks = (UnreachedMethods(),)
    workload = () -> keyed(3; scale = 4)
    probed_run = observed_gate(Probed; checks, probes, workload)
    seen = probed_run.observed
    methods_of = Base.invokelatest(methods, keyed)
    restored = only(methods_of)
    @test restored in seen.reached
    rows = evidence_rows(probed_run.findings)
    @test !((:unreached_method, "keyed") in rows)
end

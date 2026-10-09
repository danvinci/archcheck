# A method the workload left uncompiled stays a finding. A call the method graph names accounts for one the run skipped.

const LEFT_UNCALLED = load_package("LeftUncalled", """
    called(x::Int) = x + 1
    uncalled(x::Int) = x + 2
    onlykw(; extra::Int = 0) = extra + 1
    edged(x::Int) = x + 3
    hidden(x::Int) = x + 4
    function route(x::Int, value)
        edged(x)
        hidden(value)
    end
    """)

const TWIN_CONSTRUCTOR = load_package("TwinConstructor", """
    struct Held
        n::Int
    end
    make(x::Int) = Held(x)
    spare(x::Int) = x + 1
    """)

const PARAMETRIC_BOX = load_package("ParametricBox", """
    struct Box{T}
        value::T
    end
    wrap(x::T) where {T} = Box{T}(x)
    make(x::Int) = wrap(x)
    spare(x::Int) = x + 1
    """)

const EXPORTED_SPARE = load_package("ExportedSpare", """
    export spare
    called(x::Int) = x + 1
    spare(x::Int) = x + 2
    hidden(x::Int) = x + 3
    """)

@testset "only the method nobody called and no graph name accounts for is unreached" begin
    pkg = LEFT_UNCALLED.pkg
    entry = (pkg.route, Tuple{Int,Any})
    reach_workload = function ()
        pkg.called(1)
        pkg.onlykw(; extra = 4)
    end
    checks = (UnreachedMethods(),)
    entries = (entry,)
    found = gate_findings(pkg; checks, workload = reach_workload, entries)
    hit = only(found)
    uncalled = only(methods(pkg.uncalled))
    @test hit.mod === :LeftUncalled
    @test hit.line == Int(uncalled.line)
    rows = evidence_rows(found, :module, :signature)
    signature = string(uncalled.sig)
    @test rows == [(:unreached_method, "uncalled", "LeftUncalled", signature)]
end

@testset "a compiler Any constructor beside a typed one stays quiet" begin
    pkg = TWIN_CONSTRUCTOR.pkg
    entry = (pkg.make, Tuple{Int})
    check = UnreachedMethods()
    workload = () -> pkg.make(1)
    entries = (entry,)
    found = gate_findings(pkg; checks = (check,), workload, entries)
    rows = evidence_rows(found)
    @test rows == [(:unreached_method, "spare")]
end

@testset "a called parametric constructor stays quiet" begin
    pkg = PARAMETRIC_BOX.pkg
    entry = (pkg.make, Tuple{Int})
    check = UnreachedMethods()
    workload = () -> pkg.make(1)
    entries = (entry,)
    found = gate_findings(pkg; checks = (check,), workload, entries)
    rows = evidence_rows(found)
    @test rows == [(:unreached_method, "spare")]
end

@testset "an exported uncalled method stays quiet when a public name is an entry" begin
    pkg = EXPORTED_SPARE.pkg
    entry = (pkg.called, Tuple{Int})
    workload = () -> pkg.called(1)
    entries = (entry,)
    open_check = UnreachedMethods()
    closed_check = UnreachedMethods(public_is_entry = true)
    open_found = gate_findings(pkg; checks = (open_check,), workload, entries)
    closed_found = gate_findings(pkg; checks = (closed_check,), workload, entries)
    open_rows = evidence_rows(open_found)
    closed_rows = evidence_rows(closed_found)
    @test open_rows == [(:unreached_method, "hidden"), (:unreached_method, "spare")]
    @test closed_rows == [(:unreached_method, "hidden")]
end

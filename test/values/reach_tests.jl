# A method the workload left uncompiled stays a finding. A call in the method graph that can land on it accounts for it.

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

# Four methods take an Int second, so inference leaves the router's call to runtime dispatch, and one of them alone
# calls the helper. The method taking two Strings fits no call.
const DYNAMIC_PLACE = load_package("DynamicPlace", """
    place(x::Int, n::Int) = deeper(x)
    place(x::Float64, n::Int) = x
    place(x::Symbol, n::Int) = x
    place(x::Char, n::Int) = x
    place(x::String, n::String) = x
    deeper(x::Int) = x + 1
    route(items::Vector{Any}) = place(items[1], 1)
    ready() = 0
    """)

# The handler table hides which function runs, so the call is left to runtime dispatch with an Int. The untyped relay
# it reaches calls `kind`, whose String method no call holding an Int lands on.
const DYNAMIC_RELAY = load_package("DynamicRelay", """
    kind(x::Int) = x
    kind(x::String) = x
    relay(x) = kind(x)
    const HANDLERS = Function[relay]
    route(n::Int) = HANDLERS[1](n)
    ready() = 0
    """)

const EXPORTED_SPARE = load_package("ExportedSpare", """
    export spare
    called(x::Int) = x + 1
    spare(x::Int) = x + 2
    hidden(x::Int) = x + 3
    """)

@testset "only the method nobody called and no graph call lands on is unreached" begin
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

@testset "a dynamic call reaches only the methods its types match, and the methods those call" begin
    pkg = DYNAMIC_PLACE.pkg
    entry = (pkg.route, Tuple{Vector{Any}})
    entries = (entry,)
    workload = () -> pkg.ready()
    found = gate_findings(pkg; checks = (UnreachedMethods(),), workload, entries)
    unmatched = which(pkg.place, Tuple{String,String})
    rows = evidence_rows(found, :signature)
    @test rows == [(:unreached_method, "place", string(unmatched.sig))]
end

@testset "a method a dynamic call reaches calls on with the types that call holds" begin
    pkg = DYNAMIC_RELAY.pkg
    entry = (pkg.route, Tuple{Int})
    entries = (entry,)
    workload = () -> pkg.ready()
    found = gate_findings(pkg; checks = (UnreachedMethods(),), workload, entries)
    unmatched = which(pkg.kind, Tuple{String})
    rows = evidence_rows(found, :signature)
    @test rows == [(:unreached_method, "kind", string(unmatched.sig))]
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

# A method the workload left uncompiled stays a finding. A call in the method graph that can land on it accounts for it.

# Its test suite calls two of its methods, as a package's own tests do before the gate at the end of runtests.jl.
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
    """, [
    "../test/runtests.jl" => """
    LeftUncalled.called(1)
    LeftUncalled.onlykw(; extra = 4)
    """,
])

const TWIN_CONSTRUCTOR = load_package("TwinConstructor", """
    struct Held
        n::Int
    end
    make(x::Int) = Held(x)
    spare(x::Int) = x + 1
    """)

const WALKED_BOX = load_package("WalkedBox", """
    struct Box{T}
        value::T
    end
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

# A macro outside the package. The method it builds is filed in this test file.
module ForeignMacro
    macro tally(name)
        quote
            $(esc(name))(x::Int) = x + 5
        end
    end
end

# `@enum` files the methods it builds at its call, where the source writes no definition of them. A struct's
# constructors are filed at its first field, here a macro call inside the written struct.
const MACRO_BUILT = load_package("MacroBuilt", """
    @enum Shade light dark
    Main.ForeignMacro.@tally tallied
    @inline kept(x::Int) = x + 6
    mutable struct Counter
        @atomic count::Int
    end
    spare(x::Int) = x + 1
    """)

@testset "after the package's own test suite, only the methods it left uncalled and no graph call lands on are unreached" begin
    pkg = LEFT_UNCALLED.pkg
    suite = joinpath(LEFT_UNCALLED.root, "test", "runtests.jl")
    Base.include(Main, suite)
    entry = (pkg.route, Tuple{Int,Any})
    checks = (UnreachedMethods(),)
    entries = (entry,)
    probes = Probes(functions = (pkg.called,))
    @test_throws ArgumentError gate_findings(pkg; checks, workload = PriorRun(), probes)
    found = gate_findings(pkg; checks, workload = PriorRun(), entries)
    uncalled = only(methods(pkg.uncalled))
    hit = only(finding for finding in found if finding.symbol == "uncalled")
    @test hit.mod === :LeftUncalled
    @test hit.line == Int(uncalled.line)
    rows = evidence_rows(found, :module, :signature)
    route_row = (:unreached_method, "route", "LeftUncalled", "Tuple{typeof(LeftUncalled.route), Int64, Any}")
    uncalled_row = (:unreached_method, "uncalled", "LeftUncalled", "Tuple{typeof(LeftUncalled.uncalled), Int64}")
    @test rows == [route_row, uncalled_row]
end

@testset "a method a macro builds where the source writes no definition of it stays quiet" begin
    pkg = MACRO_BUILT.pkg
    found = gate_findings(pkg; checks = (UnreachedMethods(),), workload = () -> nothing)
    rows = evidence_rows(found)
    @test rows == [(:unreached_method, "Counter"), (:unreached_method, "kept"), (:unreached_method, "spare")]
end

@testset "a dynamic call reaches only the methods its types match, and the methods those call" begin
    pkg = DYNAMIC_PLACE.pkg
    entry = (pkg.route, Tuple{Vector{Any}})
    entries = (entry,)
    workload = () -> pkg.ready()
    found = gate_findings(pkg; checks = (UnreachedMethods(),), workload, entries)
    rows = evidence_rows(found, :signature)
    place_row = (:unreached_method, "place", "Tuple{typeof(DynamicPlace.place), String, String}")
    route_row = (:unreached_method, "route", "Tuple{typeof(DynamicPlace.route), Array{Any, 1}}")
    @test rows == [place_row, route_row]
end

@testset "a method a dynamic call reaches calls on with the types that call holds" begin
    pkg = DYNAMIC_RELAY.pkg
    entry = (pkg.route, Tuple{Int})
    entries = (entry,)
    workload = () -> pkg.ready()
    found = gate_findings(pkg; checks = (UnreachedMethods(),), workload, entries)
    rows = evidence_rows(found, :signature)
    kind_row = (:unreached_method, "kind", "Tuple{typeof(DynamicRelay.kind), String}")
    route_row = (:unreached_method, "route", "Tuple{typeof(DynamicRelay.route), Int64}")
    @test rows == [kind_row, route_row]
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

@testset "a parametric constructor the graph only walks is unreached" begin
    pkg = WALKED_BOX.pkg
    entry = (pkg.Box{Int}, Tuple{Int})
    found = gate_findings(pkg; checks = (UnreachedMethods(),), workload = () -> nothing, entries = (entry,))
    rows = evidence_rows(found)
    @test rows == [(:unreached_method, "Box")]
end

@testset "an exported uncalled method stays quiet unless the package turns public entries off" begin
    pkg = EXPORTED_SPARE.pkg
    entry = (pkg.called, Tuple{Int})
    workload = () -> pkg.called(1)
    entries = (entry,)
    library_check = UnreachedMethods()
    application_check = UnreachedMethods(public_is_entry = false)
    library_found = gate_findings(pkg; checks = (library_check,), workload, entries)
    application_found = gate_findings(pkg; checks = (application_check,), workload, entries)
    library_rows = evidence_rows(library_found)
    application_rows = evidence_rows(application_found)
    @test library_rows == [(:unreached_method, "hidden")]
    @test application_rows == [(:unreached_method, "hidden"), (:unreached_method, "spare")]
end

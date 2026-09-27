# Self-tests for the architecture tool, over synthetic trees rather than any host project's tree.
using Test, JSON, Random
using ArchCheck

# The nested fixture loads as a package, so its modules carry the dotted names its source spine declares.
pushfirst!(LOAD_PATH, joinpath(@__DIR__, "fixtures"))
using Nested
popfirst!(LOAD_PATH)

# A synthetic tree has no parsed def index, so these tests declare its absence rather than omit it.
const NO_SITES = Dict{Tuple{Symbol,Symbol},Tuple{String,Int}}()

# synthetic modules for the reflection checks (duplicate-owner/sinkable), so their logic tests with no package load
module FakeLo
    struct LowType end
    pure_in_low(x::Int) = x + 1
end
module FakeMid
    struct MidType end
end
module FakeHi
    using ..FakeLo: LowType
    using ..FakeMid: MidType
    struct OwnType end
    sig_own(v::OwnType) = v
    pure_in_high(y::Float64) = y
    body_own() = sig_own(OwnType())
    takes_low(v::LowType) = v
    helper_low(v::LowType) = v
    calls_helper() = helper_low(LowType())
    spans_two(a::LowType, b::MidType) = (a, b)
end
module FOwnedDefs
    using ..FakeLo: LowType
    struct Concrete end
    abstract type Abstract end
    struct Parametric{T} end
    owned_function() = nothing
    const ImportedAlias = LowType
    const UnionAlias = Union{Concrete,LowType}
    const BottomAlias = Union{}
end
module FDupA; export dup; dup() = :a; end
module FDupB; export dup; dup() = :b; end
# `vanished` outlived its definition; `hidden` is defined but kept off the interface
module FIface
    export present, vanished
    present() = 1
    hidden() = 2
end
# shown is exported, offered is public-unexported, hidden is private
module FPub
    export shown
    public offered
    shown() = 1
    offered() = 2
    hidden() = 3
    value = 4
    struct Secret end
end
# abstract-field corpus: closed storage vs every open-dispatch shape the check names
module FAbs
    abstract type Abs end
    struct Closed
        xs::Vector{Float64}
        t::Type{Float64}
        u::Union{Float64,Nothing}
    end
    struct Open
        xs::Vector
        any::Vector{Any}
        absv::AbstractVector
        absf::AbstractVector{Float64}
        d::Dict
        da::Dict{Int,Any}
        s::Set
        map::Type{<:Integer}
        r::Real
        spec::Abs
    end
    struct Param{T}
        x::T
        ys::Vector
        zs::Vector{T}
        r::Real
    end
end
module FOpt
    stable_trapz(xs::Vector{Float64}, ys::Vector{Float64}) =
        sum((xs[k+1] - xs[k]) * (ys[k+1] + ys[k]) / 2 for k in 1:length(xs)-1)
    any_kernel(xs::Vector{Any}) = xs[1] + 1
    function boxed_total(xs::Vector{Float64})
        total = 0.0
        foreach(x -> total += x, xs)
        total
    end
end
# reader-set corpus: missing methods, a complete type, inherited generics, 2D vs 3D classify
module FReadMissing
    abstract type Comp end
    abstract type AbsOnly <: Comp end
    struct Point3D end
    struct Point2D end
    struct Bare <: Comp end
    struct Fam{T} <: Comp end
    struct Flat <: Comp end
    const Alias = Bare
    function classify end
    function section end
    function x_span end
    function triangles end
    classify(::Flat, ::Point2D) = :inside
    section(::Flat, ::Float64) = nothing
    x_span(::Flat) = nothing
    triangles(::Flat) = nothing
end
module FReadComplete
    abstract type Comp end
    struct Point3D end
    struct Full <: Comp end
    function classify end
    function section end
    function x_span end
    function triangles end
    classify(::Full, ::Point3D) = :inside
    section(::Full, ::Float64) = nothing
    x_span(::Full) = nothing
    triangles(::Full) = nothing
end
module FReadGeneric
    abstract type Comp end
    struct Point3D end
    struct Covered <: Comp end
    struct Param{T} <: Comp end
    function classify end
    function section end
    function x_span end
    function triangles end
    classify(::Comp, ::Point3D) = :inside
    section(::Comp, ::Float64) = nothing
    x_span(::Comp) = nothing
    triangles(::Comp) = nothing
end

# a parent holding one submodule its spine declares and one it does not
module FNest
    module Declared end
    module Stray end
end

# module-piracy corpus: two siblings and their parent, each adding methods to functions and types the others own
module FFam
    module SibA
        struct Leaf end
        spread(x::Int) = x
        Base.show(io::IO, ::Leaf) = print(io, "leaf")
    end
    module SibB
        using ..SibA
        struct Twig end
        SibA.spread(x::Twig) = x
        Base.show(io::IO, ::Twig) = print(io, "twig")
        Base.zero(::Type{Twig}) = Twig()
        const PIRATE_AT = @__LINE__() + 1
        SibA.spread(x::SibA.Leaf) = x
        SibA.spread(x::Float64) = x
        Base.length(::SibA.Leaf) = 1
        Base.one(::Type{SibA.Leaf}) = SibA.Leaf()
        SibA.spread(x::Union{Twig,Char}) = x
    end
    Base.length(::SibB.Twig) = 2
    SibA.spread(x::String; pad = 0) = x
end

# evidence is a fixed key/value vocabulary per kind, so tests read it by key, never by prose
ev(f, key) = only(v for (k, v) in f.evidence if k === key)

# every engine check at its declared severity, with no consumer promotion
function default_severity()
    engine = (CHECKS..., ReaderSet(Any, ()), ScanSeeds(()))
    ArchCheck.severities(engine)
end

@testset "finding record" begin
    fs = [Finding(:Geometry, :back_edge, "src/geometry/surface.jl", "point_at", "refs Aero (rank 7 > 6)"),
          Finding(:Geometry, :sinkable, "src/geometry/surface.jl", "basis_funs", "footprint Numerics; belongs there"),
          Finding(:Contracts, :contracts_logic, "src/contracts/types.jl", "helper", "function body in the spine")]

    # JSONL round-trips: each line parses; the fields and the applied severity survive
    io = IOBuffer()
    emit_jsonl(io, fs, default_severity())
    lines = split(strip(String(take!(io))), '\n')
    @test length(lines) == 3
    recs = JSON.parse.(lines)
    @test recs[1]["module"] == "Geometry" && recs[1]["kind"] == "back_edge"
    @test recs[1]["severity"] == "error"
    @test recs[2]["symbol"] == "basis_funs" && recs[2]["severity"] == "advisory"
end

# A consumer check whose declaration leaves out the kind its run emits.
module FConsumer
    using ArchCheck
    struct Undeclared <: ArchCheck.Check end
    ArchCheck.run(::Undeclared, ctx) = [Finding(:M, :uncounted_drop, "a.jl", "g", "guard")]
    ArchCheck.kinds(::Undeclared) = ()
end

@testset "severity: a kind its check does not declare is refused" begin
    @test_throws ArgumentError run_checks(nothing, (FConsumer.Undeclared(),))
end

@testset "severity: error_kinds promotes a consumer's kinds" begin
    report = joinpath(mktempdir(), "architecture.jsonl")
    checks = (ArchCheck.StaleExports(),)
    passed = ArchCheck.gate(Nested; report_path = report, io = IOBuffer(), checks)
    @test any(f -> f.kind === :stale_export, passed)
    @test_throws ErrorException ArchCheck.gate(Nested; report_path = report, io = IOBuffer(), checks,
                                                error_kinds = (:stale_export,))
    records = [JSON.parse(line) for line in eachline(report)]
    @test all(r -> r["severity"] == "error", records)
    # a kind no running check declares is a typo, so it throws
    @test_throws ArgumentError ArchCheck.gate(Nested; report_path = report, io = IOBuffer(), checks,
                                               error_kinds = (:stale_exprt,))
end

@testset "module graph" begin
    # tool correctness on synthetic inputs (independent oracle, no coupling to the real tree)
    mktemp() do path, io
        write(io, "include(\"aa/Aa.jl\"); using .Aa\ninclude(\"bb/Bb.jl\"); using .Bb\n")
        flush(io)
        rank, dir2mod = ArchCheck.parse_spine_order(path)
        @test rank == Dict(:Aa => 1, :Bb => 2)               # include order = rank
        @test dir2mod == Dict("aa" => :Aa, "bb" => :Bb)
    end
    # the module name comes from the paired `using`, so a wrapper filename may differ from it, and a
    # module may sit nested inside another module's directory
    mktemp() do path, io
        write(io, "include(\"aa/Entry.jl\")\nusing .Aa\ninclude(\"bb/inner/Inner.jl\")\nusing .Inner\n")
        flush(io)
        rank, dir2mod = ArchCheck.parse_spine_order(path)
        @test rank == Dict(:Aa => 1, :Inner => 2)
        @test dir2mod == Dict("aa" => :Aa, "bb/inner" => :Inner)
    end
    # a nested module owns its own files; the parent owns only what is not nested
    nested = Dict("bb" => :Bb, "bb/inner" => :Inner)
    @test ArchCheck.module_of("s/bb/inner/x.jl", "s", nested) === :Inner
    @test ArchCheck.module_of("s/bb/y.jl", "s", nested) === :Bb
    @test ArchCheck.module_of("s/zz/q.jl", "s", nested) === nothing
    # relative import = edge, qualified X.f = edge, external pkg skipped, self-ref dropped
    refs = scan_modrefs("using ..Aa, ..Bb, QuadGK\nq = Cc.foo(1)", :Aa, "x.jl", Set([:Aa, :Bb, :Cc]))
    @test Set((r.to, r.via) for r in refs) == Set([(:Bb, :using), (:Cc, :qualified)])
end

@testset "AST enforce checks (back-edge, cycle, contracts-logic)" begin
    # tool correctness on synthetic inputs
    rank = Dict(:Lo => [1], :Hi => [2])
    d2m = Dict("lo" => :Lo, "hi" => :Hi)
    @test isempty(check_backedges(ModuleGraph(rank, d2m, [ModRef(:Hi, :Lo, "f.jl", 0, :using)])))   # down: clean
    up = check_backedges(ModuleGraph(rank, d2m, [ModRef(:Lo, :Hi, "f.jl", 0, :using)]))              # up: flagged
    @test length(up) == 1 && up[1].kind === :back_edge && up[1].mod === :Lo

    @test isempty(find_cycles([:a, :b, :c], Dict(:a => [:b, :c], :b => [:c])))
    @test !isempty(find_cycles([:a, :b], Dict(:a => [:b], :b => [:a])))

    sc = scan_defs("struct S; x::Int; S(x) = new(x); end\nfoo(a) = a + 1\nfunction bar(b); b; end")
    @test Set(sc.funcs) == Set([:foo, :bar]) && :S in sc.types   # inner ctor excluded; S is a type
end

@testset "contracts-logic classification" begin
    src = """
    struct Composite end
    struct Nozzle end
    density(m::Composite) = m.density            # accessor: sole arg a contract type
    Nozzle() = Nozzle(0.98)                      # outer constructor: name is a type
    scale(m::Composite, k::Float64) = m.x * k    # logic: contract type mixed with a raw input
    freefn(x::Float64) = x + 1                   # logic: no contract type at all
    """
    sc = scan_defs(src)
    @test sc.argtypes[:density] == [:Composite]
    @test isempty(sc.argtypes[:Nozzle])
    @test sc.argtypes[:scale]  == [:Composite, :Float64]
    @test sc.argtypes[:freefn] == [:Float64]

    ctypes = Set(sc.types)
    @test ArchCheck.is_type_interface(:density, sc.argtypes, ctypes)      # accessor -> type surface
    @test ArchCheck.is_type_interface(:Nozzle,  sc.argtypes, ctypes)      # constructor -> type surface
    @test !ArchCheck.is_type_interface(:scale,  sc.argtypes, ctypes)      # contract + raw input -> logic
    @test !ArchCheck.is_type_interface(:freefn, sc.argtypes, ctypes)      # no contract type -> logic
end

@testset "reflection checks (duplicate-owner, sinkable)" begin
    @test Set(ArchCheck.owned_defs(FOwnedDefs)) ==
          Set([:Concrete, :Abstract, :Parametric, :owned_function])

    # sinkable on the synthetic hierarchy: a def whose whole footprint is one lower module is the
    # candidate. Callers place a def, so one its own module calls stays; a Base-only def names no
    # module at all, so it carries no evidence either way.
    bc = Dict(:FakeHi => Dict(:body_own => Set([:sig_own]), :calls_helper => Set([:helper_low])))
    repo = normpath(joinpath(@__DIR__, "..", ".."))
    sink = check_sinkable([FakeLo, FakeHi], Dict(:FakeLo => [1], :FakeHi => [2]), bc, NO_SITES; repo)
    syms = Set(f.symbol for f in sink)
    @test "takes_low" in syms                       # footprint is the lower module alone -> candidate
    @test !("helper_low" in syms)                   # same footprint, but called at home -> stays
    @test !("pure_in_high" in syms)                 # Base-only -> no evidence, no finding
    @test !("sig_own" in syms)                      # own type in signature -> stays
    @test !("body_own" in syms)                     # own module in body -> stays
    @test !("pure_in_low" in syms)                  # already in the substrate -> not flagged
    @test all(f -> f.kind === :sinkable, sink)
    flagged = only(f for f in sink if f.symbol == "takes_low")
    @test ev(flagged, :touches) == "FakeLo"
    @test ev(flagged, :sinks_to) == "FakeLo"                # one module in the footprint names it
    # no indexed site here, so this is the reflected fallback - it must carry a repo-relative path,
    # since `file` is part of the fingerprint that suppression and the new/fixed delta key on
    @test flagged.file == relpath(@__FILE__, repo)
    # a footprint spanning two modules names no destination: the def may belong in a shared module
    # nobody has written yet
    wide = check_sinkable([FakeLo, FakeMid, FakeHi], Dict(:FakeLo => [1], :FakeMid => [2], :FakeHi => [3]), bc, NO_SITES; repo)
    spanning = only(f for f in wide if f.symbol == "spans_two")
    @test ev(spanning, :touches) == "FakeLo FakeMid"
    @test !any(k === :sinks_to for (k, _) in spanning.evidence)

    # duplicate-owner: same name, different objects, two modules -> collision; single owner -> clean
    dup = check_dup_owners([FDupA, FDupB], Dict(:FDupA => [1], :FDupB => [2]))
    @test length(dup) == 1 && dup[1].kind === :duplicate_owner && dup[1].symbol == "dup"
    @test isempty(check_dup_owners([FDupA], Dict(:FDupA => [1])))
end

@testset "module piracy: a method on a foreign function needs an argument type its module owns" begin
    repo = normpath(joinpath(@__DIR__, ".."))
    here = relpath(@__FILE__, repo)
    found = check_module_piracy([FFam, FFam.SibA, FFam.SibB]; repo)
    @test all(f -> f.kind === :module_piracy, found)
    by_signature = Dict(ev(f, :signature) => f for f in found)
    flagged = Set((f.mod, ev(f, :signature)) for f in found)
    sig(parts...) = string(Tuple{parts...})
    sib_a = Symbol("FFam.SibA")
    sib_b = Symbol("FFam.SibB")
    Leaf = FFam.SibA.Leaf
    Twig = FFam.SibB.Twig
    spread = FFam.SibA.spread

    # a module's own function, or any function on a type the module owns
    @test !any(f -> f.mod === sib_a, found)
    @test !((sib_b, sig(typeof(spread), Twig)) in flagged)
    @test !((sib_b, sig(typeof(show), IO, Twig)) in flagged)
    @test !((sib_b, sig(typeof(zero), Type{Twig})) in flagged)
    # a parent owns the types of the modules nested in it
    @test !((:FFam, sig(typeof(length), Twig)) in flagged)

    # a foreign function on a sibling's type, on no owned type, and Base's function on a sibling's type
    @test (sib_b, sig(typeof(spread), Leaf)) in flagged
    @test (sib_b, sig(typeof(spread), Float64)) in flagged
    @test (sib_b, sig(typeof(length), Leaf)) in flagged
    # Type{T} belongs where T does; a Union that also claims a foreign type is foreign
    @test (sib_b, sig(typeof(one), Type{Leaf})) in flagged
    @test (sib_b, sig(typeof(spread), Union{Twig,Char})) in flagged
    # a keyword method is judged by the function it wraps
    @test (:FFam, sig(typeof(spread), String)) in flagged
    @test (:FFam, sig(typeof(Core.kwcall), NamedTuple, typeof(spread), String)) in flagged
    @test length(found) == 7

    # the finding sits at the method and names the function's owner
    on_leaf = by_signature[sig(typeof(spread), Leaf)]
    @test on_leaf.file == here && on_leaf.line == FFam.SibB.PIRATE_AT
    @test on_leaf.symbol == "spread"
    @test ev(on_leaf, :owner) == "Main.FFam.SibA"
    on_base = by_signature[sig(typeof(length), Leaf)]
    @test ev(on_base, :owner) == "Base"
end

@testset "abstract-field" begin
    found = check_abstract_fields([FAbs], NO_SITES)
    @test all(f -> f.kind === :abstract_field, found)
    syms = Set(f.symbol for f in found)

    @test "Open.xs" in syms && ev(only(f for f in found if f.symbol == "Open.xs"), :declared) == "Vector"
    @test "Open.any" in syms
    @test "Open.absv" in syms
    @test "Open.absf" in syms
    @test "Open.d" in syms && "Open.s" in syms
    @test "Open.da" in syms
    @test "Open.map" in syms
    @test "Open.r" in syms && "Open.spec" in syms

    @test !("Closed.xs" in syms)
    @test !("Closed.t" in syms)          # Type{Float64} holds that one type object
    @test !("Closed.u" in syms)          # small Union, lowering splits it

    @test !("Param.x" in syms) && !("Param.zs" in syms)   # names the parameter, closes on use
    @test "Param.ys" in syms && "Param.r" in syms         # independent of T, open on every instantiation
end

@testset "opt analysis (JET port)" begin
    # with no JET module the analysis declares no kinds, so error_kinds cannot name one that did not run
    @test isempty(ArchCheck.kinds(OptAnalysis()))

    if isnothing(Base.find_package("JET"))
        @test_skip "JET not on LOAD_PATH"
    else
        @eval using JET
        repo = @__DIR__
        dirty = check_opt_entries([OptEntry(FOpt.any_kernel, Tuple{Vector{Any}})];
                                  repo, target_modules = [FOpt])
        @test length(dirty) == 1 && only(dirty).kind === :runtime_dispatch
        @test occursin("any_kernel", only(dirty).symbol)
        @test parse(Int, ev(only(dirty), :dispatches)) >= 1

        clean = check_opt_entries([OptEntry(FOpt.stable_trapz, Tuple{Vector{Float64},Vector{Float64}})];
                                  repo, target_modules = [FOpt])
        @test isempty(clean)

        # a box inference finds is its own kind; the reflection check owns :boxed_capture
        boxed_entry = OptEntry(FOpt.boxed_total, Tuple{Vector{Float64}})
        boxed = check_opt_entries([boxed_entry]; repo, target_modules = [FOpt])
        boxed_kinds = Set(f.kind for f in boxed)
        @test :inferred_box in boxed_kinds && !(:boxed_capture in boxed_kinds)
    end
end

@testset "qualified methods retain their file dependencies" begin
    method_name = Symbol("Base.getindex")
    source = """
        function Base.getindex(shape::Shape{T}, helper, index = default_index()) where {T}
            helper(index)
            nested(value) = leaf(value)
            nested(shape)
        end
        """
    scan = scan_defs(source)
    @test get(scan.refs, method_name, Set{Symbol}()) == Set([:default_index, :leaf])
    @test isempty(scan.funcs)

    mktempdir() do root
        module_dir = joinpath(root, "m")
        mkpath(module_dir)
        wrapper = joinpath(module_dir, "M.jl")
        write(wrapper, "include(\"types.jl\")\ninclude(\"extension.jl\")\ninclude(\"late.jl\")\n")
        write(joinpath(module_dir, "types.jl"), "struct Shape{T} end\n")
        write(joinpath(module_dir, "extension.jl"), source)
        write(joinpath(module_dir, "late.jl"), "default_index() = 1\nleaf(value) = value\nhelper() = 2\n")
        rank = Dict(:M => 1)
        dir2mod = Dict("m" => :M)
        index = build_source_index(root, rank, dir2mod)
        graph = build_call_graph(index, :M)
        found = check_file_backedges(graph)
        edges = Set((basename(f.file), basename(f.symbol)) for f in found)
        @test edges == Set([("extension.jl", "late.jl")])
        @test !haskey(graph.files, method_name)
        @test isempty(graph.calls[:Shape])
        dead = Set(f.symbol for f in check_dead_code_static(index))
        @test dead == Set(["helper"])
    end
end

@testset "file-backedge: an imported verb belongs to the module that declares it" begin
    mktempdir() do root
        mkpath(joinpath(root, "iface"))
        mkpath(joinpath(root, "lofts"))
        write(joinpath(root, "iface", "Iface.jl"), "include(\"verbs.jl\")\n")
        write(joinpath(root, "iface", "verbs.jl"), "function breaks end\n")
        write(joinpath(root, "lofts", "Lofts.jl"),
              "import ..Iface: breaks\ninclude(\"early.jl\")\ninclude(\"cut.jl\")\ninclude(\"late.jl\")\n")
        write(joinpath(root, "lofts", "early.jl"), "measure(x) = breaks(x)\n")
        write(joinpath(root, "lofts", "cut.jl"), "struct Cut end\nbreaks(c::Cut) = refine(c)\n")
        write(joinpath(root, "lofts", "late.jl"), "refine(c) = c\n")
        rank = Dict(:Iface => 1, :Lofts => 2)
        dir2mod = Dict("iface" => :Iface, "lofts" => :Lofts)
        index = build_source_index(root, rank, dir2mod)
        graph = build_call_graph(index, :Lofts)
        found = check_file_backedges(graph)
        # a call to the verb reaches Iface; the method cut.jl adds carries that file's own edge
        edges = Set((basename(f.file), basename(f.symbol), ev(f, :via)) for f in found)
        @test edges == Set([("cut.jl", "late.jl", "breaks")])
    end
end

@testset "intra-module call graph (static)" begin
    # per-def calls, including a callee inside a closure (the reflection blind spot)
    sc = scan_defs("top() = mid() + leaf()\nmid() = leaf()\nbuild() = map(x -> deck(x), z)")
    @test :mid in sc.refs[:top] && :leaf in sc.refs[:top]     # both operands of the infix + captured
    @test :leaf in sc.refs[:mid] && :deck in sc.refs[:build]  # closure-internal ref captured

    mktempdir() do dir
        mkpath(joinpath(dir, "geo"))
        write(joinpath(dir, "geo", "Geo.jl"), "include(\"a.jl\")")
        write(joinpath(dir, "geo", "a.jl"), "f() = g()\ng() = 1")
        index = build_source_index(dir, Dict(:Geo => 1), Dict("geo" => :Geo))
        cg = build_call_graph(index, :Geo)
        @test Set(cg.funcs) == Set([:f, :g]) && cg.calls[:f] == Set([:g])
        @test endswith(cg.files[:f], "a.jl")
        @test :g in cg.refs[:f]        # raw refs kept alongside the intra-module edges
    end

    # a method-local assignment is not a call, and filtering it must not drop a real call
    # of the same name from a different overload
    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"), "include(\"a.jl\")\ninclude(\"b.jl\")")
        write(joinpath(dir, "m", "a.jl"), """
            struct Holder
                xs::Int
            end
            function Holder()
                helper()
            end
            function Holder(faces)
                items = Int[]
                helper = length(items)
                helper
            end
            """)
        write(joinpath(dir, "m", "b.jl"), "items() = 1\nhelper() = 1\n")
        index = build_source_index(dir, Dict(:M => 1), Dict("m" => :M))
        cg = build_call_graph(index, :M)
        @test :helper in cg.calls[:Holder]
        @test !(:items in cg.calls[:Holder])
    end

    @test :helper in scan_defs("""
        function owner()
            global helper
            helper = identity(helper)
            helper()
        end
        """).refs[:owner]
    @test :helper in scan_defs("""
        function owner()
            helper = 1
            callback = () -> begin
                global helper
                helper()
            end
            callback()
        end
        """).refs[:owner]

    # named-tuple field labels are not references; the RHS still is, including in a comprehension
    labeled = scan_defs("labeled() = (items = helper(),)\nnested() = [(items = helper(),) for _ in xs]")
    @test :helper in labeled.refs[:labeled] && !(:items in labeled.refs[:labeled])
    @test :helper in labeled.refs[:nested] && !(:items in labeled.refs[:nested])
    called = scan_defs("called() = (items = items(),)")
    @test :items in called.refs[:called]

    positional = scan_defs("owner(x = helper()) = x\nhelper() = 1")
    @test :helper in positional.refs[:owner]
    @test !(:x in positional.refs[:owner])
    keyworded = scan_defs("keyed(; knots = helper()) = knots\nhelper() = 1")
    @test :helper in keyworded.refs[:keyed]
    @test !(:knots in keyworded.refs[:keyed])
    same = scan_defs("same(helper = helper()) = helper\nhelper() = 1")
    @test :helper in same.refs[:same]
    later = scan_defs("later(x = helper(), helper = 1) = x\nhelper() = 1")
    @test :helper in later.refs[:later]
    earlier = scan_defs("earlier(helper = () -> 2, x = helper()) = x\nhelper() = 1")
    @test !(:helper in earlier.refs[:earlier])
    keyed_same = scan_defs("keyed_same(; helper = helper()) = helper\nhelper() = 1")
    @test :helper in keyed_same.refs[:keyed_same]
    hid = scan_defs("function hid(x = helper())\n    helper = 1\n    x\nend\nhelper() = 1")
    @test :helper in hid.refs[:hid]
    anon = scan_defs("anon(::Helper, x = Helper()) = x")
    @test :Helper in anon.refs[:anon]
    ctor = scan_defs("struct Owner\n    value::Int   # stored test value\n    Owner(x = helper()) = new(x)\nend\nhelper() = 1")
    @test :helper in ctor.refs[:Owner]
    destructured = scan_defs("f((helper, value), x = helper()) = x\nhelper() = 1")
    @test !(:helper in destructured.refs[:f])
    whered = scan_defs("f(x::T, y = zero(T)) where T = y")
    @test !(:T in whered.refs[:f])
    bounded = scan_defs("f(x::T, y = zero(T)) where {T<:Integer} = y")
    @test !(:T in bounded.refs[:f])

    named = scan_defs("struct Law end\nhelper() = leaf()\n(law::Law)(x) = helper()")
    @test :helper in named.refs[:Law]
    @test !(:Law in named.funcs)
    @test !(:helper in named.modrefs)
    early = scan_defs("(law::Law)(x) = helper()\nstruct Law end\nhelper() = 1")
    @test :helper in early.refs[:Law]
    @test :Law in early.types && !(:Law in early.funcs)
    extension = scan_defs("(law::Law)(x) = helper()\nhelper() = 1")
    @test :helper in extension.refs[:Law]
    @test !(:Law in extension.types) && !(:Law in extension.funcs)
    anon_call = scan_defs("(::Law)(x) = helper()")
    @test :helper in anon_call.refs[:Law]
    where_call = scan_defs("function (law::Law{T})(x = helper()) where {T}\n    law\nend")
    @test :helper in where_call.refs[:Law]
    @test !(:law in where_call.refs[:Law]) && !(:T in where_call.refs[:Law])
    foreign = scan_defs("function Base.getindex(a::Law, i)\n    helper()\nend\nhelper() = 1")
    @test :helper in foreign.refs[Symbol("Base.getindex")]
    @test !(:getindex in foreign.funcs)
    @test !haskey(foreign.refs, :Law) || !(:helper in foreign.refs[:Law])

    branched = scan_defs("function owner()\n    if true\n        helper = 1\n    end\n    helper\nend")
    @test !(:helper in branched.refs[:owner])
    trapped = scan_defs("function owner()\n    try\n        helper = 1\n        helper\n    catch\n    end\nend")
    @test !(:helper in trapped.refs[:owner])
    lambda = scan_defs("owner() = map(x -> helper(x), xs)")
    @test :helper in lambda.refs[:owner] && !(:x in lambda.refs[:owner])
    letted = scan_defs("function owner()\n    let helper = 1\n        helper\n    end\n    helper()\nend")
    @test :helper in letted.refs[:owner]
    nested_g = scan_defs("function owner()\n    helper = 1\n    callback = () -> begin\n        global helper\n        1\n    end\n    helper\n    callback()\nend")
    @test !(:helper in nested_g.refs[:owner])
    gen = scan_defs("owner() = [helper(x) for x in xs]")
    @test :helper in gen.refs[:owner] && !(:x in gen.refs[:owner])
    ordered = scan_defs("f(xs) = [leaf(j) for i in xs for j in produce(i)]")
    @test :leaf in ordered.refs[:f] && :produce in ordered.refs[:f]
    @test !(:i in ordered.refs[:f])
    @test !(:j in ordered.refs[:f])
    @test !(:xs in ordered.refs[:f])
    nested_def = scan_defs("f() = begin; inner(x = helper()) = x; inner(); end")
    @test :helper in nested_def.refs[:f]
    @test !(:inner in nested_def.refs[:f])
    @test !(:x in nested_def.refs[:f])
    indexed = scan_defs("f(values, i) = begin; store[i] = values; end")
    @test :store in indexed.refs[:f]
    @test !(:values in indexed.refs[:f])
    @test !(:i in indexed.refs[:f])
    typed = scan_defs("f() = begin; x::Marker = make(); x; end")
    @test :Marker in typed.refs[:f] && :make in typed.refs[:f]
    @test !(:x in typed.refs[:f])

    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"), "include(\"a.jl\")\ninclude(\"b.jl\")")
        write(joinpath(dir, "m", "a.jl"), "function owner()\n    if true\n        helper = 1\n    end\n    helper\nend\n")
        write(joinpath(dir, "m", "b.jl"), "helper() = 1\n")
        rank = Dict(:M => 1)
        dir2mod = Dict("m" => :M)
        index = build_source_index(dir, rank, dir2mod)
        cg = build_call_graph(index, :M)
        @test !(:helper in cg.calls[:owner])
    end
end

@testset "struct-field coupling (static)" begin
    # a struct's field types AND supertype are refs, so cross-file type coupling becomes a cycle edge
    sc = scan_defs("abstract type Shape end\nstruct S <: Shape; x::T; y::Vector{U}; end")
    @test :S in sc.types && :T in sc.refs[:S] && :U in sc.refs[:S] && :Shape in sc.refs[:S]

    # struct S (a.jl) fields on T (b.jl) -> an up-rank a->b edge visible ONLY via the struct field type
    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"), "include(\"a.jl\")\ninclude(\"b.jl\")")
        write(joinpath(dir, "m", "a.jl"), "struct S; x::T; end")
        write(joinpath(dir, "m", "b.jl"), "struct T end\nmake() = S()")
        index = build_source_index(dir, Dict(:M => 1), Dict("m" => :M))
        cg = build_call_graph(index, :M)
        @test :T in cg.calls[:S]                          # struct field-type edge
        @test !(:S in cg.funcs) && !(:T in cg.funcs)      # types contribute edges, are not sink candidates
        back = only(check_file_backedges(cg))
        @test ev(back, :via) == "S"                       # the struct itself carries the edge
    end
end

@testset "file-sinkable (advisory)" begin
    files = Dict(:helper => "x.jl", :a => "y.jl", :b => "y.jl")
    calls = Dict(:helper => Set([:a, :b]), :a => Set{Symbol}(), :b => Set{Symbol}())

    # helper in x.jl calls only into y.jl, which ranks BELOW it -> it belongs down there
    down = CallGraph(:M, [:helper, :a, :b], files, calls, calls, Dict("y.jl" => 1, "x.jl" => 2))
    fs = only(check_file_sinkable(down, NO_SITES))
    @test fs.symbol == "helper" && fs.kind === :file_sinkable
    @test ev(fs, :callees_in) == "y.jl"
    
    @test ev(fs, :files_using_it) == "1/2"             # only helper's file reaches y.jl
    @test ev(fs, :callers_in_own_file) == "0"               # nothing in x.jl calls helper

    # same calls, but y.jl ranks ABOVE x.jl: that is an up-rank edge, file_backedge's business, not a sink
    up = CallGraph(:M, [:helper, :a, :b], files, calls, calls, Dict("x.jl" => 1, "y.jl" => 2))
    @test isempty(check_file_sinkable(up, NO_SITES))
    @test length(check_file_backedges(up)) == 1        # reported once, by the check that owns it

    # callees spanning two files -> integrator, not sinkable
    spread = Dict(:h => Set([:a, :b]), :a => Set{Symbol}(), :b => Set{Symbol}())
    cg2 = CallGraph(:M, [:h, :a, :b], Dict(:h => "x.jl", :a => "y.jl", :b => "z.jl"), spread, spread,
                    Dict("y.jl" => 1, "z.jl" => 2, "x.jl" => 3))
    @test isempty(check_file_sinkable(cg2, NO_SITES))

    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"), "include(\"low.jl\")\ninclude(\"high.jl\")")
        write(joinpath(dir, "m", "low.jl"), "leaf(x) = x\n")
        write(joinpath(dir, "m", "high.jl"), """
            helper(x) = leaf(x)
            struct Long
                value::Int   # stored test value
                function Long(x)
                    new(helper(x))
                end
            end
            struct Short
                value::Int   # stored test value
                Short(x) = new(helper(x))
            end
            struct Parametric{T}
                value::T   # stored test value
                Parametric{T}(x) where {T} = new{T}(helper(x))
            end
            struct Shadow
                value::Int   # stored test value
                Shadow(helper) = new(helper(1))
            end
            """)
        index = build_source_index(dir, Dict(:M => 1), Dict("m" => :M))
        cg = build_call_graph(index, :M)
        for owner in (:Long, :Short, :Parametric)
            @test :helper in cg.calls[owner]
            @test !(owner in cg.funcs)
        end
        @test !(:helper in cg.calls[:Shadow])
        @test isempty(check_file_sinkable(cg, def_sites(index)))
    end

    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"), "include(\"low.jl\")\ninclude(\"high.jl\")")
        write(joinpath(dir, "m", "low.jl"), "struct Law end\nleaf(x) = x\n")
        write(joinpath(dir, "m", "high.jl"), """
            helper(x) = leaf(x)
            (law::Law)(x) = helper(x)
            stray(x) = leaf(x)
            """)
        rank = Dict(:M => 1)
        dir2mod = Dict("m" => :M)
        index = build_source_index(dir, rank, dir2mod)
        cg = build_call_graph(index, :M)
        @test :helper in cg.calls[:Law]
        @test !(:Law in cg.funcs)
        high = only(f.path for f in index.files if f.name == "high.jl")
        @test :helper in cg.site_refs[(:Law, high)]
        found = check_file_sinkable(cg, def_sites(index))
        @test !any(f -> f.symbol == "helper", found)
        stray = only(f for f in found if f.symbol == "stray")
        @test ev(stray, :callees_in) == "low.jl"
        @test ev(stray, :callers_in_own_file) == "0"
    end
end

@testset "extract-candidate (sinkable density)" begin
    sink = [Finding(:Geo, :sinkable, "surface.jl", "a", ""), Finding(:Geo, :sinkable, "surface.jl", "b", ""),
            Finding(:Geo, :sinkable, "surface.jl", "c", ""), Finding(:Geo, :sinkable, "resolve.jl", "d", "")]
    ec = only(check_extract_candidates(sink; min_defs = 3))
    @test ec.file == "surface.jl" && ec.kind === :extract_candidate
    @test ev(ec, :defs) == "3"
    # below threshold -> nothing
    @test isempty(check_extract_candidates([Finding(:Geo, :sinkable, "x.jl", "a", "")]; min_defs = 3))
end

@testset "dead-code (static, JuliaSyntax)" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "aa"))
        write(joinpath(dir, "aa", "Aa.jl"), "include(\"aa.jl\")")
        write(joinpath(dir, "aa", "aa.jl"), "keep() = 1\ngone() = 2\nentry() = keep()")
        index = build_source_index(dir, Dict(:Aa => 1), Dict("aa" => :Aa))
        dead = check_dead_code_static(index, Set([:entry]))
        syms = Set(f.symbol for f in dead)
        @test "gone" in syms                        # never called, not external -> dead
        @test !("keep" in syms) && !("entry" in syms)   # called / external
        @test all(f -> f.kind === :dead_code, dead)
    end
    mktempdir() do dir
        mkpath(joinpath(dir, "aa"))
        write(joinpath(dir, "aa", "Aa.jl"), "include(\"aa.jl\")")
        write(joinpath(dir, "aa", "aa.jl"), "owner(x = helper()) = x\nhelper() = 1")
        rank = Dict(:Aa => 1)
        dir2mod = Dict("aa" => :Aa)
        index = build_source_index(dir, rank, dir2mod)
        dead = Set(f.symbol for f in check_dead_code_static(index))
        @test !("helper" in dead)
        @test "owner" in dead
    end
    # entry-dir names keep a def alive: the same tree is dead without them, live with them
    mktempdir() do dir
        mkpath(joinpath(dir, "aa"))
        mkpath(joinpath(dir, "scripts"))
        write(joinpath(dir, "aa", "Aa.jl"), "include(\"aa.jl\")")
        write(joinpath(dir, "aa", "aa.jl"), "shipped() = 1")
        entry = joinpath(dir, "scripts")
        write(joinpath(entry, "run.jl"), "shipped()")

        lonely = build_source_index(dir, Dict(:Aa => 1), Dict("aa" => :Aa))
        @test "shipped" in Set(f.symbol for f in check_dead_code_static(lonely))

        withentry = build_source_index(dir, Dict(:Aa => 1), Dict("aa" => :Aa); entry_dirs = [entry])
        @test :shipped in withentry.external
        @test isempty(check_dead_code_static(withentry))
    end
    # a test/ entry dir does not keep a def alive: nothing production runs reaches it there
    mktempdir() do dir
        mkpath(joinpath(dir, "aa"))
        mkpath(joinpath(dir, "test"))
        write(joinpath(dir, "aa", "Aa.jl"), "include(\"aa.jl\")")
        write(joinpath(dir, "aa", "aa.jl"), "tested() = 1")
        entry = joinpath(dir, "test")
        write(joinpath(entry, "runtests.jl"), "tested()")

        index = build_source_index(dir, Dict(:Aa => 1), Dict("aa" => :Aa); entry_dirs = [entry])
        @test !(:tested in index.external)
        @test "tested" in Set(f.symbol for f in check_dead_code_static(index))
    end
    # a def's own export line is not a use: exported with no caller is still dead
    mktempdir() do dir
        mkpath(joinpath(dir, "bb"))
        write(joinpath(dir, "bb", "Bb.jl"), "export uncalled\ninclude(\"impl.jl\")")
        write(joinpath(dir, "bb", "impl.jl"), "uncalled() = 1")
        index = build_source_index(dir, Dict(:Bb => 1), Dict("bb" => :Bb))
        @test "uncalled" in Set(f.symbol for f in check_dead_code_static(index))
    end
    # a qualified call from another module counts as the use dead-code looks for
    mktempdir() do dir
        mkpath(joinpath(dir, "aa"))
        mkpath(joinpath(dir, "cc"))
        write(joinpath(dir, "aa", "Aa.jl"), "include(\"defs.jl\")")
        write(joinpath(dir, "aa", "defs.jl"), "helper() = 1")
        write(joinpath(dir, "cc", "Cc.jl"), "include(\"caller.jl\")")
        write(joinpath(dir, "cc", "caller.jl"), "user() = Aa.helper()")
        rank = Dict(:Aa => 1, :Cc => 2)
        dir2mod = Dict("aa" => :Aa, "cc" => :Cc)
        index = build_source_index(dir, rank, dir2mod)
        dead = Set(f.symbol for f in check_dead_code_static(index))
        @test !("helper" in dead)
    end
end

# Build a random module: n files, each with a few defs, referencing defs in other files at random, and a
# random include order. The generator knows the true reference set, so it is an oracle independent of the
# parser - unlike a fixture, whose inputs are whatever the implementer happened to think of.
function random_module(rng, dir)
    nfiles = rand(rng, 2:5)
    names = ["f$i.jl" for i in 1:nfiles]
    defs = Dict(n => ["d$(i)_$(j)" for j in 1:rand(rng, 1:3)] for (i, n) in enumerate(names))
    every = [(file, d) for file in names for d in defs[file]]

    bodies = Dict(n => String[] for n in names)
    truth = Set{Tuple{String,String}}()          # (from file, to file) the generator intended
    for file in names, def in defs[file]
        callees = String[]
        for _ in 1:rand(rng, 0:2)
            target_file, target_def = rand(rng, every)
            target_def in defs[file] && continue          # same-file calls are not cross-file edges
            push!(callees, target_def)
            push!(truth, (file, target_file))
        end
        body = isempty(callees) ? "1" : join(["$c()" for c in callees], " + ")
        push!(bodies[file], "$def() = $body")
    end

    order = shuffle(rng, names)
    mkpath(dir)
    write(joinpath(dir, "M.jl"), join(["include(\"$n\")" for n in order], "\n"))
    for n in names
        write(joinpath(dir, n), join(bodies[n], "\n"))
    end
    rank = Dict(n => i for (i, n) in enumerate(order))
    (truth = truth, rank = rank, files = names)
end

@testset "fuzz: back-edge parity against a generated oracle" begin
    for seed in 1:40
        rng = MersenneTwister(seed)
        mktempdir() do root
            spec = random_module(rng, joinpath(root, "m"))
            index = build_source_index(root, Dict(:M => 1), Dict("m" => :M))
            found = check_file_backedges(build_call_graph(index, :M))

            # the oracle: an edge is a back-edge exactly when the target is not strictly earlier
            expected = Set((from, to) for (from, to) in spec.truth
                           if from != to && spec.rank[to] >= spec.rank[from])
            got = Set((basename(f.file), basename(f.symbol)) for f in found)
            @test got == expected

            # and the invariant that motivates the check: zero back-edges iff the declared include
            # order is a topological order of the reference graph
            istopo = all(spec.rank[to] < spec.rank[from] for (from, to) in spec.truth if from != to)
            @test isempty(found) == istopo
        end
    end
end

@testset "fuzz: the index accounts for every file it walks" begin
    for seed in 1:20
        rng = MersenneTwister(seed)
        mktempdir() do root
            spec = random_module(rng, joinpath(root, "m"))
            broken = rand(rng, spec.files)
            write(joinpath(root, "m", broken), "function wrecked(x\n")   # never parses

            index = build_source_index(root, Dict(:M => 1), Dict("m" => :M))
            ondisk = length(spec.files) + 1                       # the member files plus the wrapper
            accounted = length(index.files) + length(index.unparsed)
            @test accounted == ondisk                             # nothing vanishes unrecorded
            @test any(p -> endswith(p[2], broken), index.unparsed)
            @test !isempty(check_corpus(index))
        end
    end
end

@testset "corpus accounting (no silent holes)" begin
    # a file nothing includes: unranked AND never loaded
    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"), "include(\"known.jl\")")
        write(joinpath(dir, "m", "known.jl"), "a() = 1")
        write(joinpath(dir, "m", "forgotten.jl"), "b() = 2")
        index = build_source_index(dir, Dict(:M => 1), Dict("m" => :M))
        corpus = check_corpus(index)
        @test length(corpus) == 1
        @test corpus[1].kind === :unranked_file && endswith(corpus[1].file, "forgotten.jl")
    end

    # an include of a path that is not a file: the opposite hole from forgotten.jl
    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"), "include(\"missing.jl\")")
        index = build_source_index(dir, Dict(:M => 1), Dict("m" => :M))
        corpus = check_corpus(index)
        hole = only(f for f in corpus if f.kind === :missing_include)
        @test hole.symbol == "missing.jl" && hole.line == 1
        @test endswith(hole.file, "M.jl")
    end

    # the package spine is not a module-owned file, and its includes still have to resolve
    mktempdir() do dir
        write(joinpath(dir, "Pkg.jl"), "include(\"missing.jl\")\n")
        index = build_source_index(dir, Dict{Symbol,Int}(), Dict{String,Symbol}())
        hole = only(check_corpus(index))
        @test hole.kind === :missing_include && hole.mod === :Pkg
        @test hole.symbol == "missing.jl"
    end

    # include whose argument is not a string literal cannot be placed in the DAG
    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"), "include(joinpath(@__DIR__, \"known.jl\"))\n")
        write(joinpath(dir, "m", "known.jl"), "a() = 1")
        index = build_source_index(dir, Dict(:M => 1), Dict("m" => :M))
        hole = only(f for f in check_corpus(index) if f.kind === :nonliteral_include)
        @test hole.line == 1
        @test endswith(hole.file, "M.jl")
    end

    # a comment or string that looks like a dynamic include is not a call
    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"),
              "include(\"known.jl\")\n# include(joinpath(@__DIR__, \"x.jl\"))\ns = \"include(joinpath(x))\"\n")
        write(joinpath(dir, "m", "known.jl"), "a() = 1")
        index = build_source_index(dir, Dict(:M => 1), Dict("m" => :M))
        @test isempty(filter(f -> f.kind === :nonliteral_include, check_corpus(index)))
    end

    # a file reached through a nested include takes its position from the depth-first load order - the
    # order Julia itself runs them - rather than being held apart as an unranked class
    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"), "include(\"known.jl\")")
        write(joinpath(dir, "m", "known.jl"), "include(\"deeper.jl\")\na() = 1")
        write(joinpath(dir, "m", "deeper.jl"), "b() = 2")
        index = build_source_index(dir, Dict(:M => 1), Dict("m" => :M))
        known = only(filter(f -> f.name == "known.jl", index.files))
        deeper = only(filter(f -> f.name == "deeper.jl", index.files))
        @test known.filerank == 1 && deeper.filerank == 2   # includer before the file it pulls in
        @test isempty(check_corpus(index))                  # both declared, so neither is a hole
    end

    # a literal include outside the mapped directory is still indexed under the module that executes it
    mktempdir() do dir
        geometry = joinpath(dir, "geometry")
        mkpath(geometry)
        write(joinpath(geometry, "Geometry.jl"),
              "module Geometry\ninclude(\"early.jl\")\ninclude(\"late.jl\")\ninclude(\"../shared.jl\")\nend\n")
        write(joinpath(geometry, "early.jl"), "struct Shape end\nBase.length(shape::Shape) = late_helper()\n")
        write(joinpath(geometry, "late.jl"), "late_helper() = 4\n")
        write(joinpath(dir, "shared.jl"), "shared_helper() = late_helper()\n")
        rank = Dict(:Geometry => 1)
        dir2mod = Dict("geometry" => :Geometry)
        index = build_source_index(dir, rank, dir2mod)
        @test any(f -> f.name == "shared.jl" && f.mod === :Geometry && f.filerank == 3, index.files)
        @test file_rank(geometry)["../shared.jl"] == 3
        @test isempty(index.missing) && isempty(index.nonliteral) && isempty(index.unparsed)
        @test isempty(check_corpus(index))
    end

    # a reference from an earlier file to an outside include is a file backedge on the real paths
    mktempdir() do dir
        geometry = joinpath(dir, "geometry")
        mkpath(geometry)
        write(joinpath(geometry, "Geometry.jl"), "include(\"early.jl\")\ninclude(\"../shared.jl\")\n")
        write(joinpath(geometry, "early.jl"), "climb() = shared_helper()")
        write(joinpath(dir, "shared.jl"), "shared_helper() = 1")
        rank = Dict(:Geometry => 1)
        dir2mod = Dict("geometry" => :Geometry)
        index = build_source_index(dir, rank, dir2mod)
        graph = build_call_graph(index, :Geometry)
        @test endswith(graph.files[:shared_helper], "shared.jl")
        back = only(check_file_backedges(graph))
        @test back.kind === :file_backedge
        @test endswith(back.file, "early.jl") && endswith(back.symbol, "shared.jl")
        @test ev(back, :via) == "climb" && ev(back, :include_order) == "1->2"
    end

    # missing, dynamic, and unparsed includes outside the mapped directory still report
    mktempdir() do dir
        geometry = joinpath(dir, "geometry")
        mkpath(geometry)
        write(joinpath(geometry, "Geometry.jl"),
              "include(\"../missing.jl\")\ninclude(joinpath(@__DIR__, \"../dyn.jl\"))\ninclude(\"../bad.jl\")\n")
        write(joinpath(dir, "bad.jl"), "function wrecked(x\n")
        rank = Dict(:Geometry => 1)
        dir2mod = Dict("geometry" => :Geometry)
        index = build_source_index(dir, rank, dir2mod)
        corpus = check_corpus(index)
        @test any(f -> f.kind === :missing_include && f.symbol == "../missing.jl", corpus)
        @test any(f -> f.kind === :nonliteral_include && endswith(f.file, "Geometry.jl"), corpus)
        @test any(f -> f.kind === :unparsed && endswith(f.file, "bad.jl"), corpus)
        @test !any(f -> f.name == "bad.jl", index.files)
    end

    # a cross-directory include owns the file under the module that executes it
    mktempdir() do dir
        mkpath(joinpath(dir, "a"))
        mkpath(joinpath(dir, "b"))
        write(joinpath(dir, "a", "A.jl"), "include(\"../b/shared.jl\")")
        write(joinpath(dir, "b", "B.jl"), "include(\"local.jl\")")
        write(joinpath(dir, "b", "shared.jl"), "shared_helper() = 1")
        write(joinpath(dir, "b", "local.jl"), "local_helper() = 1")
        rank = Dict(:A => 1, :B => 2)
        dir2mod = Dict("a" => :A, "b" => :B)
        index = build_source_index(dir, rank, dir2mod)
        @test Set(f.mod for f in index.files if f.name == "shared.jl") == Set([:A])
        @test any(f -> f.name == "local.jl" && f.mod === :B, index.files)
    end

    # the same source included by two modules keeps both execution contexts
    mktempdir() do dir
        mkpath(joinpath(dir, "a"))
        mkpath(joinpath(dir, "b"))
        write(joinpath(dir, "a", "A.jl"), "include(\"../b/shared.jl\")")
        write(joinpath(dir, "b", "B.jl"), "include(\"shared.jl\")")
        write(joinpath(dir, "b", "shared.jl"), "shared_helper() = 1")
        rank = Dict(:A => 1, :B => 2)
        dir2mod = Dict("a" => :A, "b" => :B)
        index = build_source_index(dir, rank, dir2mod)
        @test Set(f.mod for f in index.files if f.name == "shared.jl") == Set([:A, :B])
    end

    # same-line, begin, and split literal includes still load the named source
    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"),
              "include(\"early.jl\"); include(\"same.jl\")\nbegin\ninclude(\"inside.jl\")\nend\ninclude(\n\"split.jl\"\n)\n")
        write(joinpath(dir, "m", "early.jl"), "climb() = split_helper()")
        write(joinpath(dir, "m", "same.jl"), "same_helper() = 1")
        write(joinpath(dir, "m", "inside.jl"), "inside_helper() = 1")
        write(joinpath(dir, "m", "split.jl"), "split_helper() = 1")
        rank = Dict(:M => 1)
        dir2mod = Dict("m" => :M)
        index = build_source_index(dir, rank, dir2mod)
        names = Set(f.name for f in index.files)
        @test all(n -> n in names, ("early.jl", "same.jl", "inside.jl", "split.jl"))
        @test isempty(check_corpus(index))
        graph = build_call_graph(index, :M)
        @test endswith(graph.files[:split_helper], "split.jl")
        back = only(check_file_backedges(graph))
        @test endswith(back.file, "early.jl") && endswith(back.symbol, "split.jl")
    end

    # the wrapper is the one file its module never includes - not a hole
    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"), "include(\"known.jl\")")
        write(joinpath(dir, "m", "known.jl"), "a() = 1")
        index = build_source_index(dir, Dict(:M => 1), Dict("m" => :M))
        @test isempty(check_corpus(index))
        @test any(is_wrapper, index.files)
    end

    # the wrapper is the module dir's entry file, not the file whose name matches the module
    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "Entry.jl"), "include(\"known.jl\")")
        write(joinpath(dir, "m", "known.jl"), "a() = 1")
        rank = Dict(:M => 1)
        dir2mod = Dict("m" => :M)
        index = build_source_index(dir, rank, dir2mod)
        @test [f.name for f in index.files if is_wrapper(f)] == ["Entry.jl"]
        @test isempty(check_corpus(index))          # so it is not reported as an unranked hole
    end

    # two capitalized candidates: the one no sibling includes is the entry, whatever the sort order
    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"), "include(\"Helper.jl\")")
        write(joinpath(dir, "m", "Helper.jl"), "a() = 1")
        rank = Dict(:M => 1)
        dir2mod = Dict("m" => :M)
        index = build_source_index(dir, rank, dir2mod)
        @test [f.name for f in index.files if is_wrapper(f)] == ["M.jl"]
        @test isempty(check_corpus(index))
    end

    # two independent candidates: no entry is declared, so the module blocks rather than guessing one
    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "Aye.jl"), "a() = 1")
        write(joinpath(dir, "m", "Bee.jl"), "b() = 2")
        rank = Dict(:M => 1)
        dir2mod = Dict("m" => :M)
        index = build_source_index(dir, rank, dir2mod)
        @test !any(is_wrapper, index.files)
        corpus = check_corpus(index)
        @test Set(f.kind for f in corpus) == Set([:unranked_file])
    end

    # a src file that will not parse: it vanishes from the index, so its violations vanish with it
    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"), "include(\"good.jl\")\ninclude(\"bad.jl\")")
        write(joinpath(dir, "m", "good.jl"), "a() = 1")
        write(joinpath(dir, "m", "bad.jl"), "function wrecked(x\n  return x\n")
        index = build_source_index(dir, Dict(:M => 1), Dict("m" => :M))
        @test !any(f -> f.name == "bad.jl", index.files)     # gone from every check's view
        corpus = check_corpus(index)
        @test length(corpus) == 1 && corpus[1].kind === :unparsed
        @test endswith(corpus[1].file, "bad.jl")
    end

    # an entry dir is parsed but never loaded, so a broken script would silently shrink `external`
    # and turn defs used only from it into false dead-code findings
    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        mkpath(joinpath(dir, "scripts"))
        write(joinpath(dir, "m", "M.jl"), "include(\"a.jl\")")
        write(joinpath(dir, "m", "a.jl"), "shipped() = 1")
        entry = joinpath(dir, "scripts")
        write(joinpath(entry, "run.jl"), "shipped(\n")
        index = build_source_index(dir, Dict(:M => 1), Dict("m" => :M); entry_dirs = [entry])
        corpus = check_corpus(index)
        @test length(corpus) == 1 && corpus[1].kind === :unparsed && corpus[1].mod === :Entry
        @test "shipped" in Set(f.symbol for f in check_dead_code_static(index))   # the false finding
    end
end

@testset "git-tracked corpus (untracked files excluded, not just unranked)" begin
    # an untracked file never enters the index at all - absent, not reported as a hole
    mktempdir() do dir
        run(Cmd(`git init -q`; dir = dir))
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"), "include(\"known.jl\")")
        write(joinpath(dir, "m", "known.jl"), "a() = 1")
        write(joinpath(dir, "m", "scratch.jl"), "b() = 2")   # never `git add`ed
        run(Cmd(`git add m/M.jl m/known.jl`; dir = dir))
        index = build_source_index(dir, Dict(:M => 1), Dict("m" => :M))
        @test Set(f.name for f in index.files) == Set(["M.jl", "known.jl"])
        @test isempty(check_corpus(index))
    end

    # an untracked file the wrapper includes is still indexed under that module
    mktempdir() do dir
        run(Cmd(`git init -q`; dir = dir))
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"), "include(\"known.jl\")\ninclude(\"../shared.jl\")")
        write(joinpath(dir, "m", "known.jl"), "a() = 1")
        write(joinpath(dir, "shared.jl"), "b() = 2")
        run(Cmd(`git add m/M.jl m/known.jl`; dir = dir))
        rank = Dict(:M => 1)
        dir2mod = Dict("m" => :M)
        index = build_source_index(dir, rank, dir2mod)
        @test any(f -> f.name == "shared.jl" && f.mod === :M && f.filerank == 2, index.files)
        @test isempty(check_corpus(index))
    end

    # outside any git work tree, a synthetic corpus is not filtered at all
    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"), "include(\"known.jl\")")
        write(joinpath(dir, "m", "known.jl"), "a() = 1")
        @test ArchCheck.tracked_files(dir) === nothing
        index = build_source_index(dir, Dict(:M => 1), Dict("m" => :M))
        @test length(index.files) == 2
    end
end

@testset "file rank (the intra-module DAG)" begin
    # a module wrapper's include order ranks its files, exactly as the package spine ranks the modules
    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"), "include(\"low.jl\")\ninclude(\"high.jl\")   # trailing comment")
        @test file_rank(joinpath(dir, "m")) == Dict("low.jl" => 1, "high.jl" => 2)
    end

    # a rank is keyed by the path within the module, so equal basenames at different depths stay distinct
    mktempdir() do dir
        mkpath(joinpath(dir, "m", "eval"))
        mkpath(joinpath(dir, "m", "viz"))
        write(joinpath(dir, "m", "M.jl"), "include(\"eval/score.jl\")\ninclude(\"viz/score.jl\")")
        write(joinpath(dir, "m", "eval", "score.jl"), "a() = 1")
        write(joinpath(dir, "m", "viz", "score.jl"), "b() = 2")
        rank = Dict(:M => 1)
        dir2mod = Dict("m" => :M)
        index = build_source_index(dir, rank, dir2mod)
        scored = filter(f -> f.name == "score.jl", index.files)
        @test length(scored) == 2
        @test Set(f.filerank for f in scored) == Set([1, 2])   # two positions, not one shared rank
        @test isempty(check_corpus(index))
    end

    # the rank rule is the SAME predicate at both zooms: down is clean, up and sideways are back-edges
    rank = Dict("low.jl" => 1, "high.jl" => 2)
    @test !is_backedge(rank, "high.jl", "low.jl")   # down: clean
    @test is_backedge(rank, "low.jl", "high.jl")    # up: flagged
    @test is_backedge(rank, "low.jl", "low.jl")     # sideways (equal rank): flagged
    @test !is_backedge(rank, "low.jl", "absent.jl") # unranked: exempt, nothing declared its position

    # the finding names the defs carrying the edge - what you cut. (Which edges are back-edges at all is
    # the fuzz harness's job, over random trees rather than one I picked.)
    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"), "include(\"low.jl\")\ninclude(\"high.jl\")")
        write(joinpath(dir, "m", "low.jl"), "climber() = summit()")
        write(joinpath(dir, "m", "high.jl"), "summit() = 1")
        index = build_source_index(dir, Dict(:M => 1), Dict("m" => :M))
        back = only(check_file_backedges(build_call_graph(index, :M)))
        @test back.kind === :file_backedge
        @test ev(back, :via) == "climber" && ev(back, :include_order) == "1->2"
    end
end

@testset "tuple return (the unnamed data layer)" begin
    sc = scan_defs("""
    three() = (a, b, c)
    pair() = (a, b)
    named() = (x = a, y = b, z = c)
    blocky() = begin; q = 1; return (a, b, c, d); end
    """)
    # the scan records raw arity; the threshold is the check's policy, not the substrate's
    @test sc.tupletail[:three] == 3            # bare tuple tail, short form
    @test sc.tupletail[:blocky] == 4           # through a block and an explicit return
    @test sc.tupletail[:pair] == 2             # recorded, and filtered out downstream
    @test !haskey(sc.tupletail, :named)        # a NamedTuple names its slots - not anonymous

    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"), "include(\"a.jl\")")
        write(joinpath(dir, "m", "a.jl"), "wide() = (a, b, c)\nnarrow() = (a, b)")
        index = build_source_index(dir, Dict(:M => 1), Dict("m" => :M))
        tup = only(check_tuple_returns(index))
        @test tup.symbol == "wide" && tup.kind === :tuple_return
        @test tup.line == 1 && ev(tup, :slots) == "3"
    end
end

@testset "delta vs the previous run" begin
    old = [Finding(:Geo, :tuple_return, "a.jl", "wide", 10, "3 slots"),
           Finding(:Geo, :dead_code, "a.jl", "gone", 20, "unused")]
    # same finding, moved down the file: the line drifts, the fingerprint does not
    moved = Finding(:Geo, :tuple_return, "a.jl", "wide", 99, "3 slots")
    fresh = Finding(:Aero, :file_backedge, "solve.jl", "model.jl", 0, "up-rank")

    severity = default_severity()
    mktempdir() do dir
        path = joinpath(dir, "architecture.jsonl")
        @test previous_fingerprints(path) === nothing        # no previous run -> nothing is new

        open(io -> emit_jsonl(io, old, severity), path, "w")
        prev = previous_fingerprints(path)
        @test isempty(new_findings([moved], prev))       # same finding, drifted line -> not new

        # a kind the previous run never carried is a check that did not exist yet: its findings enter
        # as standing, so shipping a new check does not turn the next run red wholesale
        @test isempty(new_findings([fresh], prev))
        withknown = vcat(old, fresh)
        open(io -> emit_jsonl(io, withknown, severity), path, "w")
        prev2 = previous_fingerprints(path)
        later = Finding(:Aero, :file_backedge, "solve.jl", "influence.jl", 0, "up-rank")
        @test [f.symbol for f in new_findings([fresh, later], prev2)] == ["influence.jl"]

        current = Set(fingerprint(f) for f in [moved, fresh])
        @test length(setdiff(prev, current)) == 1        # dead_code disappeared -> fixed
    end

    # the report prints the delta in full and the standing set as counts
    io = IOBuffer()
    print_architecture(io, [moved, fresh], [fresh], 1, Dict(:Aero => [1], :Geo => [2]), severity)
    out = String(take!(io))
    @test occursin("new 1", out) && occursin("fixed 1", out) && occursin("standing 1", out)
    @test occursin("NEW", out) && occursin("solve.jl", out)   # new one named
    @test occursin("tuple_return 1", out) && !occursin("wide", out)   # standing counted, not listed
end

@testset "JuliaSyntax static scan" begin
    # closure-internal ref is seen (the reflection blind spot)
    sc = scan_defs("build() = map(x -> deck_call(x), xs)")
    @test :build in sc.funcs && :deck_call in sc.refs[:build] && :map in sc.refs[:build]

    # a nested def is a local, not top-level; its ref is still seen
    sc2 = scan_defs("outer() = (inner(x) = x + 1; inner(3))")
    @test :outer in sc2.funcs && !(:inner in sc2.funcs) && !(:inner in sc2.refs[:outer])

    # function forms, type separation, source line
    sc3 = scan_defs("function foo(x); x; end\nbar(y) = y\nstruct Baz end")
    @test Set(sc3.funcs) == Set([:foo, :bar]) && :Baz in sc3.types && sc3.line[:bar] == 2
end

@testset "interface" begin
    # blanket export: the wrapper republishes its whole namespace, so it declares no interface
    mktempdir() do dir
        mkpath(joinpath(dir, "geo"))
        write(joinpath(dir, "geo", "Geo.jl"),
              "include(\"a.jl\")\nfor n in names(@__MODULE__; all=true)\n    @eval export \$n\nend")
        write(joinpath(dir, "geo", "a.jl"), "f() = 1")
        index = build_source_index(dir, Dict(:Geo => 1), Dict("geo" => :Geo))
        found = check_blanket_exports(index)
        @test length(found) == 1
        @test found[1].kind === :blanket_export
    end

    # a comment that quotes the blanket form is not a call
    mktempdir() do dir
        mkpath(joinpath(dir, "geo"))
        write(joinpath(dir, "geo", "Geo.jl"),
              "include(\"a.jl\")\n# names(@__MODULE__; all=true)\n")
        write(joinpath(dir, "geo", "a.jl"), "f() = 1")
        index = build_source_index(dir, Dict(:Geo => 1), Dict("geo" => :Geo))
        @test isempty(check_blanket_exports(index))
    end

    # a wrapper with a real export list is clean
    mktempdir() do dir
        mkpath(joinpath(dir, "geo"))
        write(joinpath(dir, "geo", "Geo.jl"), "include(\"a.jl\")")
        write(joinpath(dir, "geo", "a.jl"), "export f\nf() = 1")
        index = build_source_index(dir, Dict(:Geo => 1), Dict("geo" => :Geo))
        @test isempty(check_blanket_exports(index))
    end

    # stale export: Julia accepts a name with no definition behind it
    stale = check_stale_exports([FIface])
    @test length(stale) == 1
    @test stale[1].symbol == "vanished"
    @test stale[1].kind === :stale_export
    @test isempty(check_stale_exports([FDupA]))

    # reaches-internal: a qualified reference to a name the owner kept private
    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"), "include(\"a.jl\")")
        write(joinpath(dir, "m", "a.jl"), "g() = 1")
        index = build_source_index(dir, Dict(:M => 1), Dict("m" => :M))
        entry = mktempdir()
        write(joinpath(entry, "probe.jl"), "a = FIface.hidden()\nb = FIface.present()\n")
        found = check_reaches_internal(index, [FIface]; entry_dirs = [entry])
        @test length(found) == 1
        @test found[1].symbol == "FIface.hidden"
        @test found[1].kind === :reaches_internal

        # a missing entry dir contributes nothing, as the index treats it
        absent = joinpath(dir, "absent")
        found = check_reaches_internal(index, [FIface]; entry_dirs = [absent, entry])
        @test [f.symbol for f in found] == ["FIface.hidden"]
    end

    # comments and strings are not references
    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"), "include(\"a.jl\")")
        write(joinpath(dir, "m", "a.jl"), "g() = 1")
        index = build_source_index(dir, Dict(:M => 1), Dict("m" => :M))
        entry = mktempdir()
        write(joinpath(entry, "probe.jl"),
              "# FIface.hidden()\ns = \"FIface.hidden()\"\nx = 1  # FIface.hidden\n")
        @test isempty(check_reaches_internal(index, [FIface]; entry_dirs = [entry]))
    end

    # public-unexported names are the declared interface; aliases and quotes follow the same rule
    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"), "include(\"a.jl\")")
        write(joinpath(dir, "m", "a.jl"), "g() = 1")
        rank = Dict(:M => 1)
        dir2mod = Dict("m" => :M)
        index = build_source_index(dir, rank, dir2mod)
        entry = mktempdir()
        probe = joinpath(entry, "probe.jl")
        write(probe,
              "const G = Main.FPub\nG.hidden()\nG.offered()\nFPub.hidden()\nFPub.offered()\nFPub.shown()\nMain.FPub.hidden()\nfunction wrap()\n    G = 1\n    G.hidden()\nend\nq = :(FPub.hidden())\nobj = (FPub = (hidden = 1,),)\nobj.FPub.hidden\n")
        found = check_reaches_internal(index, [FPub]; entry_dirs = [entry])
        @test Set(f.symbol for f in found) == Set(["FPub.hidden"])
        @test length(found) == 3
        write(probe, """
            const G = Main.FPub
            typed(x::G.Secret)::G.Secret = x
            bounded(x::T) where {T<:G.Secret} = x
            G.value = 4
            G.hidden(x) = x
            lambda = (x::G.Secret) -> x
            """)
        found = check_reaches_internal(index, [FPub]; entry_dirs = [entry, entry])
        @test sort([f.symbol for f in found]) ==
              [fill("FPub.Secret", 4); "FPub.hidden"; "FPub.value"]
    end
end

@testset "reader-set" begin
    missing_required = (
        (FReadMissing.classify, Tuple{FReadMissing.Point3D}),
        (FReadMissing.section, Tuple{Float64}),
        (FReadMissing.x_span, Tuple{}),
        (FReadMissing.triangles, Tuple{}),
    )
    missing = check_reader_set([FReadMissing], FReadMissing.Comp, missing_required; sites = NO_SITES)
    @test all(f -> f.kind === :reader_set, missing)
    syms = Set(f.symbol for f in missing)
    @test syms == Set(["Bare.classify", "Bare.section", "Bare.x_span", "Bare.triangles",
                      "Fam.classify", "Fam.section", "Fam.x_span", "Fam.triangles", "Flat.classify"])
    @test ev(only(f for f in missing if f.symbol == "Bare.classify"), :reader) == "classify"
    @test length(unique(fingerprint.(missing))) == length(missing)

    complete_required = (
        (FReadComplete.classify, Tuple{FReadComplete.Point3D}),
        (FReadComplete.section, Tuple{Float64}),
        (FReadComplete.x_span, Tuple{}),
        (FReadComplete.triangles, Tuple{}),
    )
    @test isempty(check_reader_set([FReadComplete], FReadComplete.Comp, complete_required; sites = NO_SITES))

    generic_required = (
        (FReadGeneric.classify, Tuple{FReadGeneric.Point3D}),
        (FReadGeneric.section, Tuple{Float64}),
        (FReadGeneric.x_span, Tuple{}),
        (FReadGeneric.triangles, Tuple{}),
    )
    @test isempty(check_reader_set([FReadGeneric], FReadGeneric.Comp, generic_required; sites = NO_SITES))
end

@testset "independent modules: no member of the set references another" begin
    src = joinpath(pkgdir(Nested), "src")
    graph = build_module_graph(src, joinpath(src, "Nested.jl"))
    edges(modules...) = run_checks((graph = graph,), (Independent(modules...),))
    curves = Symbol("Geo.Curves")
    cuts = Symbol("Geo.Cuts")

    # Geo reaches Low, which is outside the set; Contracts reaches nothing
    @test isempty(edges(:Contracts, :Geo))

    # Curves calls `Cuts.cut_only` by its qualified name
    between = edges(curves, cuts)
    qualified = only(f for f in between if ev(f, :via) == "qualified")
    @test qualified.kind === :sibling_edge && qualified.mod === curves
    @test (qualified.file, qualified.line) == ("src/geo/curves/curve.jl", 15)
    @test (ev(qualified, :from), ev(qualified, :to)) == ("Geo.Curves", "Geo.Cuts")

    # Geo.Curves imports Low from inside Geo, apart from Geo's own `using ..Low`
    through = edges(:Low, :Geo)
    inner = only(f for f in through if f.mod === curves && ev(f, :via) == "using")
    @test (inner.file, inner.line) == ("src/geo/curves/Curves.jl", 3)
    @test (ev(inner, :from), ev(inner, :to)) == ("Geo", "Low")
    # and Hi's `Geo.Curves._secret` reaches into Geo's tree
    into = edges(:Hi, :Geo)
    @test any(f -> f.symbol == "Geo.Curves" && ev(f, :to) == "Geo", into)

    # both reach Shared, which sits below the set
    rank = Dict(:Shared => [1], :A => [2], :B => [3])
    dir2mod = Dict("shared" => :Shared, "a" => :A, "b" => :B)
    refs = [ModRef(:A, :Shared, "src/a/a.jl", 1, :using), ModRef(:B, :Shared, "src/b/b.jl", 2, :qualified)]
    lower = ModuleGraph(rank, dir2mod, refs)
    @test isempty(run_checks((graph = lower,), (Independent(:A, :B),)))

    # a set that cannot constrain anything, or names a module the graph lacks, is refused
    @test_throws ArgumentError Independent(:Geo)
    @test_throws ArgumentError Independent(:Geo, curves)
    @test_throws ArgumentError edges(:Contracts, :Goe)
end

@testset "fixed sample seeds" begin
    mktempdir() do root
        geometry = joinpath(root, "geo")
        other = joinpath(root, "other")
        mkpath(geometry)
        mkpath(other)
        write(joinpath(geometry, "Geo.jl"), "include(\"counts.jl\")\ninclude(\"seeds.jl\")")
        write(joinpath(geometry, "counts.jl"), "const GRID_COUNT = 12\nconst ITER_CAP = 64")
        write(joinpath(geometry, "seeds.jl"), """
        by_const() = [k / GRID_COUNT for k in 0:GRID_COUNT]
        literal() = [k / 16 for k in 0:16]
        by_range() = range(0.0, 1.0; length=GRID_COUNT)
        by_linrange() = LinRange(0.0, 1.0, GRID_COUNT)
        span_grid(lo, hi) = range(lo, hi; length=GRID_COUNT)
        function local_grid()
            count = 32
            (0:count) ./ count
        end
        function step_grid()
            step = 1.0 / GRID_COUNT
            [k * step for k in 0:GRID_COUNT]
        end
        function adjacent_grid()
            count = 9
            [k / (count - 1) for k in 0:count-1]
        end
        caller_grid(count) = [k / count for k in 0:count]
        shadowed(GRID_COUNT) = [k / GRID_COUNT for k in 0:GRID_COUNT]
        native_breaks(knots) = [refine(knots[k], knots[k+1]) for k in 1:length(knots)-1]
        indices(vertices) = [vertices[k] for k in 1:3]
        capped(x) = [iterate(x) for _ in 1:ITER_CAP]
        midpoint(a, b) = (a + b) / 2
        function rebound(xs)
            count = 16
            count = length(xs)
            (0:count) ./ count
        end
        """)
        write(joinpath(other, "Other.jl"), "include(\"seeds.jl\")")
        write(joinpath(other, "seeds.jl"), """
        const OWN_COUNT = 20
        separate() = [k / OWN_COUNT for k in 0:OWN_COUNT]
        unknown() = [k / GRID_COUNT for k in 0:GRID_COUNT]
        """)
        index = build_source_index(root, Dict(:Geo => 1, :Other => 2),
                                   Dict("geo" => :Geo, "other" => :Other))
        found = check_scan_seeds(index; directories=(geometry,))
        expected = Set(["by_const", "literal", "by_range", "by_linrange", "span_grid",
                        "local_grid", "step_grid", "adjacent_grid"])
        @test Set(finding.symbol for finding in found) == expected
        @test all(finding -> finding.kind === :scan_seed, found)
        @test length(unique(fingerprint.(found))) == length(found)
        together = check_scan_seeds(index; directories=(geometry, other))
        @test Set(finding.symbol for finding in together) == union(expected, Set(["separate"]))
    end
end

# A random package nested two deep, each module one wrapper calling others by dotted name. The order the
# generator finishes modules in (each after everything it includes) is the back-edge oracle.
function random_package(rng, src)
    keys = String[]
    children = Dict{String,Vector{String}}("" => String[])
    function grow!(parent, name, depth)
        key = isempty(parent) ? name : "$parent.$name"
        push!(keys, key)
        push!(children[parent], key)
        children[key] = String[]
        depth < 2 || return
        for j in 1:rand(rng, 0:2)
            grow!(key, "$(name)s$j", depth + 1)
        end
    end
    for i in 1:rand(rng, 2:4)
        grow!("", "T$i", 0)
    end
    for kids in values(children)
        shuffle!(rng, kids)
    end

    finished = String[]
    function load!(key)
        foreach(load!, children[key])
        push!(finished, key)
    end
    foreach(load!, children[""])
    position = Dict(key => i for (i, key) in enumerate(finished))

    leaf(key) = String(last(split(key, '.')))
    function directory(key)
        segments = lowercase.(split(key, '.'))
        joinpath(src, segments...)
    end
    function include_lines(kids)
        lines = String[]
        for kid in kids
            name = leaf(kid)
            wrapper = joinpath(lowercase(name), name * ".jl")
            push!(lines, "include(\"$wrapper\")\nusing .$name")
        end
        join(lines, "\n")
    end
    mkpath(src)
    spine = "module Pkg\n" * include_lines(children[""]) * "\nend\n"
    write(joinpath(src, "Pkg.jl"), spine)

    truth = Set{Tuple{String,String}}()
    for key in keys
        calls = String[]
        for _ in 1:rand(rng, 0:3)
            target = rand(rng, keys)
            target == key && continue
            push!(calls, "$target.f()")
            push!(truth, (key, target))
        end
        body = isempty(calls) ? "1" : join(calls, " + ")
        nested = include_lines(children[key])
        mkpath(directory(key))
        wrapper = joinpath(directory(key), leaf(key) * ".jl")
        write(wrapper, "module $(leaf(key))\n$nested\nf() = $body\nend\n")
    end
    (keys = keys, truth = truth, position = position)
end

@testset "fuzz: nested module back-edges against the generated load order" begin
    for seed in 1:40
        rng = MersenneTwister(seed)
        mktempdir() do root
            src = joinpath(root, "src")
            spec = random_package(rng, src)
            rank, dir2mod = ArchCheck.parse_spine_order(joinpath(src, "Pkg.jl"))
            index = build_source_index(src, rank, dir2mod)
            @test Set(string.(keys(index.rank))) == Set(spec.keys)   # every declared module, at every depth

            found = check_backedges(build_module_graph(index))
            got = Set((string(f.mod), f.symbol) for f in found)
            # the oracle: a reference climbs exactly when its target finishes loading at or after its source
            expected = Set((from, to) for (from, to) in spec.truth if spec.position[to] >= spec.position[from])
            @test got == expected
        end
    end
end

@testset "submodules: every check reads the nested package" begin
    readers = ReaderSet(Nested.Geo.Curves.Shape, ((Nested.Geo.Curves.perimeter, Tuple{}),))
    report = joinpath(mktempdir(), "architecture.jsonl")
    blocked = try
        ArchCheck.gate(Nested; report_path = report, io = IOBuffer(), checks = (CHECKS..., readers))
        false
    catch err
        err isa ErrorException || rethrow()
        true
    end
    records = [JSON.parse(line) for line in eachline(report)]
    held(kind, mod, symbol) = any(r -> r["kind"] == kind && r["module"] == mod && r["symbol"] == symbol, records)

    # module zoom: a submodule sits at its parent's rank, then at its place in the parent's include order
    @test blocked
    back = only(r for r in records if r["kind"] == "back_edge")
    @test back["module"] == "Geo.Curves" && back["symbol"] == "Geo.Cuts"
    @test back["evidence"]["include_order"] == "3.1->3.2"
    @test !any(r -> r["kind"] == "unranked_module", records)

    # file zoom: a submodule's files rank by its own wrapper
    file_back = only(r for r in records if r["kind"] == "file_backedge")
    @test file_back["module"] == "Geo.Cuts"
    @test endswith(file_back["file"], "ring.jl") && endswith(file_back["symbol"], "measure.jl")

    # the reflection checks and the reader set see submodule definitions
    @test held("abstract_field", "Geo.Curves", "OpenBox.held")
    @test held("stale_export", "Geo.Curves", "vanished")
    @test held("reader_set", "Geo.Cuts", "Ring.perimeter")
    @test held("reaches_internal", "Geo.Curves", "Geo.Curves._secret")
    @test held("module_piracy", "Hi", "_lowpriv")
    # the root module is checked too: as the owner a submodule extends, and as the home extending a submodule
    @test held("module_piracy", "Hi", "root_measure")
    @test held("module_piracy", "Nested", "lowf")
    sink = only(r for r in records if r["kind"] == "sinkable" && r["symbol"] == "box_contents")
    @test sink["module"] == "Geo.Cuts" && sink["evidence"]["sinks_to"] == "Geo.Curves"

    # an import clause naming another module's underscore name, at either nesting, reports and lets the run pass
    private = filter(r -> r["kind"] == "private_import", records)
    @test Set((r["module"], r["symbol"]) for r in private) ==
          Set([("Geo.Curves", "Low._lowpriv"), ("Geo.Cuts", "Geo.Curves._secret")])
    @test all(r -> r["severity"] == "advisory", private)
end

@testset "submodules: a loaded submodule the spine does not declare" begin
    rank = Dict(:FNest => [1], Symbol("FNest.Declared") => [1, 1])
    stray = only(ArchCheck.check_module_corpus([FNest, FNest.Declared], rank))
    @test stray.kind === :unranked_module && stray.mod === :FNest && stray.symbol == "Stray"
end

@testset "private imports: the names an import clause binds" begin
    source = """
        import ..Aa: _hidden as shown, open
        import ..Aa._tail
        using ..Aa
        import Base: _private
        """
    refs = scan_modrefs(source, :Bb, "x.jl", Set([:Aa, :Bb]))
    @test Set(name for r in refs for name in r.names) == Set([:_hidden, :open, :_tail])
    @test all(r -> r.to === :Aa, refs)
end

@testset "declared names: a reference reaches only what the module it names declares" begin
    report = joinpath(mktempdir(), "architecture.jsonl")
    checks = (ArchCheck.DeclaredNames(), ArchCheck.PrivateImports())
    findings = ArchCheck.gate(Nested; report_path = report, io = IOBuffer(), checks)
    undeclared = filter(f -> f.kind === :undeclared_name, findings)
    # a name reached through Geo, which declares it for its callers, is declared along the written path;
    # Geo's own import of it from Curves, which keeps it private, is not
    @test Set((string(f.mod), f.symbol, ev(f, :via)) for f in undeclared) == Set([
        ("Geo", "Geo.Curves.calls_later", "import"),
        ("Geo.Curves", "Low._lowpriv", "import"),
        ("Geo.Cuts", "Geo.Curves._secret", "using"),
        ("Geo.Curves", "Geo.Cuts.cut_only", "qualified"),
        ("Hi", "Geo.Curves._secret", "qualified"),
        ("Hi", "Geo.Cuts.Ring", "qualified"),
        ("Hi", "Low._lowpriv", "extends"),
        ("Hi", "Geo.gauge", "extends"),
    ])
    # an underscore import is one case of an undeclared name
    private = filter(f -> f.kind === :private_import, findings)
    @test !isempty(private)
    @test all(p -> any(u -> u.file == p.file && u.line == p.line, undeclared), private)
end

@testset "declared extensions: a module extends only another module's documented public verb" begin
    report = joinpath(mktempdir(), "architecture.jsonl")
    checks = (ArchCheck.DeclaredExtensions(), ArchCheck.DeclaredNames(), ArchCheck.ReachesInternal())
    @test_throws ErrorException ArchCheck.gate(Nested; report_path = report, io = IOBuffer(), checks)
    records = [JSON.parse(line) for line in eachline(report)]
    extensions = filter(r -> r["kind"] == "private_extension", records)
    @test all(r -> r["severity"] == "error", extensions)
    # private, public but undocumented, and the root's private function; Low's documented `gauge` is clean
    extended = Set((r["module"], r["symbol"], r["evidence"]["public"], r["evidence"]["documented"])
                   for r in extensions)
    @test extended == Set([
        ("Hi", "Low._lowpriv", "false", "false"),
        ("Hi", "Geo.Curves.perimeter", "true", "false"),
        ("Hi", "Nested.root_measure", "false", "false"),
        ("Nested", "Low.lowf", "true", "false"),
    ])
    private = only(r for r in extensions if r["symbol"] == "Low._lowpriv")
    @test private["evidence"]["owner"] == "Low" && private["evidence"]["function"] == "_lowpriv"
    @test private["file"] == joinpath("src", "hi", "Hi.jl")

    # extending through Geo, which only passes Low's verb on, uses a name Geo does not declare
    relayed(kind) = only(r for r in records if r["kind"] == kind && r["symbol"] == "Geo.gauge")
    undeclared = relayed("undeclared_name")
    @test undeclared["module"] == "Hi" && undeclared["evidence"]["via"] == "extends"
    @test undeclared["evidence"]["owner"] == "Low"
    @test relayed("reaches_internal")["file"] == joinpath("src", "hi", "Hi.jl")
end

@testset "declared modules: a module reaches only the modules its wrapper names" begin
    report = joinpath(mktempdir(), "architecture.jsonl")
    checks = (ArchCheck.DeclaredModules(),)
    findings = ArchCheck.gate(Nested; report_path = report, io = IOBuffer(), checks)
    reached = Set((string(f.mod), f.symbol, ev(f, :via)) for f in findings)
    @test reached == Set([
        ("Geo.Curves", "Geo.Cuts", "qualified"),
        ("Hi", "Geo.Curves", "qualified"),
        ("Hi", "Geo.Curves", "extends"),
        ("Hi", "Geo.Cuts", "qualified"),
    ])

    # a path opening with the package's own name reaches the module below it
    source = "x = Pkg.Aa.f()\nimport ..Pkg\n"
    refs = scan_modrefs(source, :Bb, "x.jl", Set([:Aa, :Bb]); root = :Pkg)
    @test Set((r.to, r.via) for r in refs) == Set([(:Aa, :qualified), (:Pkg, :import)])
end

@testset "foreign fields: a field read on another module's struct" begin
    report = joinpath(mktempdir(), "architecture.jsonl")
    checks = (ArchCheck.ForeignFields(),)
    findings = ArchCheck.gate(Nested; report_path = report, io = IOBuffer(), checks)
    reads = Set((string(f.mod), f.symbol) for f in findings)
    # Span is public and documented: the field it documents is open, the field it leaves bare is not
    @test !(("Hi", "Low.Span.lo") in reads)
    @test ("Hi", "Low.Span.hi") in reads
    # Mark is public and documents its field but not itself, so Julia records no field docstring
    @test ("Hi", "Low.Mark.at") in reads
    # Ring documents itself and its field, but Cuts keeps it internal
    @test ("Hi", "Geo.Cuts.Ring.radius") in reads
    # OpenBox is public and documents nothing
    @test ("Geo.Cuts", "Geo.Curves.OpenBox.held") in reads
    # Tick is Low's own, read through receivers only inference types
    @test ("Hi", "Low.Tick.at") in reads
    # a receiver annotated with a Union reads the field on each member, owned by that member's module
    @test ("Hi", "Low.Notch.at") in reads
    @test ("Hi", "Geo.Cuts.Arc.at") in reads
    # a chain through a Union reads its next field on each member's declared field type
    @test ("Hi", "Low.Pin.depth") in reads
    @test ("Hi", "Geo.Cuts.Kerf.depth") in reads
    # no other read is flagged
    @test length(reads) == 9

    # Hi also reads documented fields (Span.lo, Ruler.ticks) and a contract type (Record): the analysis sees them,
    # the rule opens them
    hi_path = joinpath(pkgdir(Nested), "src", "hi", "Hi.jl")
    hi_tree = parse_file(read(hi_path, String), hi_path)
    hi_reads = ArchCheck.field_reads(hi_tree, Nested.Hi).reads
    member_reads = ((member, r.field) for r in hi_reads for member in Base.uniontypes(r.type))
    read_names = Set((nameof(member), field) for (member, field) in member_reads)
    @test read_names == Set([(:Ring, :radius), (:Record, :values), (:Span, :hi), (:Span, :lo), (:Mark, :at),
                             (:Ruler, :ticks), (:Tick, :at), (:Notch, :at), (:Arc, :at),
                             (:Groove, :bottom), (:Slot, :bottom), (:Pin, :depth), (:Kerf, :depth)])
end

@testset "foreign fields: receivers Julia infers" begin
    hi_path = joinpath(pkgdir(Nested), "src", "hi", "Hi.jl")
    hi_tree = parse_file(read(hi_path, String), hi_path)
    typed = Dict(r.receiver => r.type for r in ArchCheck.field_reads(hi_tree, Nested.Hi).reads)
    # a local bound from a call takes the one concrete type Julia infers for the call
    @test get(typed, "made", nothing) === Nested.Low.Tick
    # a loop variable over a declared field's vector takes the element type
    @test get(typed, "tick", nothing) === Nested.Low.Tick
    # an abstract or a Union result types nothing, so reads through it stay unchecked
    @test !haskey(typed, "face")
    @test !haskey(typed, "either")
end

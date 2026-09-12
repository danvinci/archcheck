# Self-tests for the architecture tool, over synthetic trees rather than any host project's tree.
using Test, JSON, Random
using ArchCheck

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
end

# evidence is a fixed key/value vocabulary per kind, so tests read it by key, never by prose
ev(f, key) = only(v for (k, v) in f.evidence if k === key)

@testset "finding record" begin
    fs = [Finding(:Geometry, :back_edge, "src/geometry/surface.jl", "point_at", "refs Aero (rank 7 > 6)"),
          Finding(:Geometry, :sinkable, "src/geometry/surface.jl", "basis_funs", "footprint Numerics; belongs there"),
          Finding(:Contracts, :contracts_logic, "src/contracts/types.jl", "helper", "function body in the spine")]

    # enforce/report split derives from the finding's tier, defaulted from engine kind tuples
    @test isblocking(fs[1])
    @test !isblocking(fs[2])
    @test count(isblocking, fs) == 2
    @test tier(fs[1]) === :enforce && tier(fs[2]) === :advice

    # engine kinds still map without constructing a Finding
    @test tier(:back_edge) === :enforce
    @test tier(:missing_include) === :enforce
    @test tier(:nonliteral_include) === :enforce
    @test tier(:file_backedge) === :structure
    @test tier(:dead_code) === :structure
    @test tier(:sinkable) === :advice
    @test tier_rank(fs[1]) < tier_rank(fs[2])

    # a consumer kind is advice unless the emitting check sets tier=
    @test tier(:uncounted_drop) === :advice
    @test tier(:time_truncation) === :advice
    own = Finding(:M, :uncounted_drop, "a.jl", "g", "guard"; tier = :structure)
    @test tier(own) === :structure && !isblocking(own)
    block = Finding(:M, :time_truncation, "a.jl", "g", "clamp"; tier = :enforce)
    @test isblocking(block) && tier(block) === :enforce

    # JSONL round-trips: each line parses, fields + blocking + tier survive
    io = IOBuffer(); emit_jsonl(io, fs)
    lines = split(strip(String(take!(io))), '\n')
    @test length(lines) == 3
    recs = JSON.parse.(lines)
    @test recs[1]["module"] == "Geometry" && recs[1]["kind"] == "back_edge" && recs[1]["blocking"]
    @test recs[1]["tier"] == "enforce"
    @test !recs[2]["blocking"] && recs[2]["symbol"] == "basis_funs" && recs[2]["tier"] == "advice"
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
    rank = Dict(:Lo => 1, :Hi => 2); d2m = Dict("lo" => :Lo, "hi" => :Hi)
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
    sink = check_sinkable([FakeLo, FakeHi], Dict(:FakeLo => 1, :FakeHi => 2), bc, NO_SITES; repo)
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
    wide = check_sinkable([FakeLo, FakeMid, FakeHi], Dict(:FakeLo => 1, :FakeMid => 2, :FakeHi => 3), bc, NO_SITES; repo)
    spanning = only(f for f in wide if f.symbol == "spans_two")
    @test ev(spanning, :touches) == "FakeLo FakeMid"
    @test !any(k === :sinks_to for (k, _) in spanning.evidence)

    # duplicate-owner: same name, different objects, two modules -> collision; single owner -> clean
    dup = check_dup_owners([FDupA, FDupB], Dict(:FDupA => 1, :FDupB => 2))
    @test length(dup) == 1 && dup[1].kind === :duplicate_owner && dup[1].symbol == "dup"
    @test isempty(check_dup_owners([FDupA], Dict(:FDupA => 1)))
end

@testset "abstract-field" begin
    found = check_abstract_fields([FAbs], NO_SITES)
    @test all(f -> f.kind === :abstract_field, found)
    @test all(f -> !isblocking(f), found)
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
    @test isempty(check_opt_entries(OptEntry[]; repo = ".", target_modules = Module[]))

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
        @test !isblocking(only(dirty))

        clean = check_opt_entries([OptEntry(FOpt.stable_trapz, Tuple{Vector{Float64},Vector{Float64}})];
                                  repo, target_modules = [FOpt])
        @test isempty(clean)
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
    @test :helper in foreign.modrefs
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
    @test ev(fs, :callees_in) == "y.jl" && !isblocking(fs)
    
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
    @test ev(ec, :defs) == "3" && !isblocking(ec)
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
        @test all(f -> f.kind === :dead_code && !isblocking(f), dead)
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
            @test !isempty(filter(isblocking, check_corpus(index)))
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
        @test isblocking(corpus[1])                 # a hole makes every other result untrustworthy
    end

    # an include of a path that is not a file: the opposite hole from forgotten.jl
    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"), "include(\"missing.jl\")")
        index = build_source_index(dir, Dict(:M => 1), Dict("m" => :M))
        corpus = check_corpus(index)
        hole = only(f for f in corpus if f.kind === :missing_include)
        @test hole.symbol == "missing.jl" && hole.line == 1 && isblocking(hole)
        @test endswith(hole.file, "M.jl")
    end

    # the package spine is not a module-owned file, and its includes still have to resolve
    mktempdir() do dir
        write(joinpath(dir, "Pkg.jl"), "include(\"missing.jl\")\n")
        index = build_source_index(dir, Dict{Symbol,Int}(), Dict{String,Symbol}())
        hole = only(check_corpus(index))
        @test hole.kind === :missing_include && hole.mod === :Pkg
        @test hole.symbol == "missing.jl" && isblocking(hole)
    end

    # include whose argument is not a string literal cannot be placed in the DAG
    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"), "include(joinpath(@__DIR__, \"known.jl\"))\n")
        write(joinpath(dir, "m", "known.jl"), "a() = 1")
        index = build_source_index(dir, Dict(:M => 1), Dict("m" => :M))
        hole = only(f for f in check_corpus(index) if f.kind === :nonliteral_include)
        @test hole.line == 1 && isblocking(hole)
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
        @test all(isblocking, corpus)
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
        @test endswith(corpus[1].file, "bad.jl") && isblocking(corpus[1])
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
        @test !isempty(filter(isblocking, corpus))   # which the corpus check makes loud
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
        @test !isblocking(back)       # a fact, but not one that blocks
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
        @test !isblocking(tup)
    end
end

@testset "delta vs the previous run" begin
    old = [Finding(:Geo, :tuple_return, "a.jl", "wide", 10, "3 slots"),
           Finding(:Geo, :dead_code, "a.jl", "gone", 20, "unused")]
    # same finding, moved down the file: the line drifts, the fingerprint does not
    moved = Finding(:Geo, :tuple_return, "a.jl", "wide", 99, "3 slots")
    fresh = Finding(:Aero, :file_backedge, "solve.jl", "model.jl", 0, "up-rank")

    mktempdir() do dir
        path = joinpath(dir, "architecture.jsonl")
        @test previous_fingerprints(path) === nothing        # no previous run -> nothing is new

        open(io -> emit_jsonl(io, old), path, "w")
        prev = previous_fingerprints(path)
        @test isempty(new_findings([moved], prev))       # same finding, drifted line -> not new

        # a kind the previous run never carried is a check that did not exist yet: its findings enter
        # as standing, so shipping a new check does not turn the next run red wholesale
        @test isempty(new_findings([fresh], prev))
        withknown = vcat(old, fresh)
        open(io -> emit_jsonl(io, withknown), path, "w")
        prev2 = previous_fingerprints(path)
        later = Finding(:Aero, :file_backedge, "solve.jl", "influence.jl", 0, "up-rank")
        @test [f.symbol for f in new_findings([fresh, later], prev2)] == ["influence.jl"]

        current = Set(fingerprint(f) for f in [moved, fresh])
        @test length(setdiff(prev, current)) == 1        # dead_code disappeared -> fixed
    end

    # the report prints the delta in full and the standing set as counts
    io = IOBuffer()
    print_architecture(io, [moved, fresh], [fresh], 1, Dict(:Aero => 1, :Geo => 2))
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
end

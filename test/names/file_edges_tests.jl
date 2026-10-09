# A file reaches only files the include order has already loaded.
@testset "qualified methods retain their file dependencies" begin
    source = """
        function Base.getindex(shape::Shape{T}, helper, index = default_index()) where {T}
            helper(index)
            nested(value) = leaf(value)
            nested(shape)
        end
        """

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
        index = ArchCheck.build_source_index(root, rank, dir2mod)
        graph = ArchCheck.build_call_graph(index, :M)
        found = ArchCheck.check_file_backedges(graph)
        edges = Set((basename(f.file), basename(f.symbol)) for f in found)
        @test edges == Set([("extension.jl", "late.jl")])
        dead = Set(f.symbol for f in ArchCheck.check_dead_code_static(index))
        @test dead == Set(["helper"])
    end
end

@testset "file-backedge: an imported verb belongs to the module that declares it" begin
    mktempdir() do root
        mkpath(joinpath(root, "iface"))
        mkpath(joinpath(root, "lofts"))
        write(joinpath(root, "iface", "Iface.jl"), "include(\"verbs.jl\")\n")
        write(joinpath(root, "iface", "verbs.jl"), "function breaks end\nfunction splits end\n")
        write(joinpath(root, "lofts", "Lofts.jl"),
              "import ..Iface: breaks, splits as divide\nimport Base: show\n" *
              "include(\"early.jl\")\ninclude(\"cut.jl\")\ninclude(\"late.jl\")\n")
        write(joinpath(root, "lofts", "early.jl"),
              "measure(x) = breaks(x)\npart(x) = divide(x)\ndescribe(io, x) = show(io, x)\n")
        write(joinpath(root, "lofts", "cut.jl"),
              "struct Cut end\nbreaks(c::Cut) = refine(c)\ndivide(c::Cut) = c\nshow(io::IO, c::Cut) = print(io, c)\n")
        write(joinpath(root, "lofts", "late.jl"), "refine(c) = c\n")
        rank = Dict(:Iface => 1, :Lofts => 2)
        dir2mod = Dict("iface" => :Iface, "lofts" => :Lofts)
        index = ArchCheck.build_source_index(root, rank, dir2mod)
        graph = ArchCheck.build_call_graph(index, :Lofts)
        found = ArchCheck.check_file_backedges(graph)
        # a call to the verb reaches its declaring module, whether a project module under its imported name
        # or an outside package; the method cut.jl adds carries that file's own edge
        edges = Set((basename(f.file), basename(f.symbol), ev(f, :via)) for f in found)
        @test edges == Set([("cut.jl", "late.jl", "breaks")])
    end
end

@testset "intra-module call graph (static)" begin
    # a method-local assignment is not a call, and filtering it must not drop a real call
    # of the same name from a different overload
    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"), "include(\"a.jl\")\ninclude(\"b.jl\")")
        write(joinpath(dir, "m", "a.jl"), """
            struct Holder
                xs::Int   # field type
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
        index = ArchCheck.build_source_index(dir, Dict(:M => 1), Dict("m" => :M))
        cg = ArchCheck.build_call_graph(index, :M)
        @test :helper in cg.calls[:Holder]
        @test !(:items in cg.calls[:Holder])
    end

    @test :helper in ArchCheck.scan_defs("""
        function owner()
            global helper
            helper = identity(helper)
            helper()
        end
        """).refs[:owner]
    @test :helper in ArchCheck.scan_defs("""
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
    labeled = ArchCheck.scan_defs("labeled() = (items = helper(),)\nnested() = [(items = helper(),) for _ in xs]")
    @test :helper in labeled.refs[:labeled] && !(:items in labeled.refs[:labeled])
    @test :helper in labeled.refs[:nested] && !(:items in labeled.refs[:nested])
    called = ArchCheck.scan_defs("called() = (items = items(),)")
    @test :items in called.refs[:called]

    keyworded = ArchCheck.scan_defs("keyed(; knots = helper()) = knots\nhelper() = 1")
    @test :helper in keyworded.refs[:keyed]
    @test !(:knots in keyworded.refs[:keyed])
    same = ArchCheck.scan_defs("same(helper = helper()) = helper\nhelper() = 1")
    @test :helper in same.refs[:same]
    later = ArchCheck.scan_defs("later(x = helper(), helper = 1) = x\nhelper() = 1")
    @test :helper in later.refs[:later]
    earlier = ArchCheck.scan_defs("earlier(helper = () -> 2, x = helper()) = x\nhelper() = 1")
    @test !(:helper in earlier.refs[:earlier])
    keyed_same = ArchCheck.scan_defs("keyed_same(; helper = helper()) = helper\nhelper() = 1")
    @test :helper in keyed_same.refs[:keyed_same]
    hid = ArchCheck.scan_defs("function hid(x = helper())\n    helper = 1\n    x\nend\nhelper() = 1")
    @test :helper in hid.refs[:hid]
    anon = ArchCheck.scan_defs("anon(::Helper, x = Helper()) = x")
    @test :Helper in anon.refs[:anon]
    ctor = ArchCheck.scan_defs("struct Owner\n    value::Int   # stored test value\n    Owner(x = helper()) = new(x)\nend\nhelper() = 1")
    @test :helper in ctor.refs[:Owner]
    destructured = ArchCheck.scan_defs("f((helper, value), x = helper()) = x\nhelper() = 1")
    @test !(:helper in destructured.refs[:f])
    whered = ArchCheck.scan_defs("f(x::T, y = zero(T)) where T = y")
    @test !(:T in whered.refs[:f])

    named = ArchCheck.scan_defs("struct Law end\nhelper() = leaf()\n(law::Law)(x) = helper()")
    @test :helper in named.refs[:Law]
    @test !(:Law in named.funcs)
    @test !(:helper in named.modrefs)
    early = ArchCheck.scan_defs("(law::Law)(x) = helper()\nstruct Law end\nhelper() = 1")
    @test :helper in early.refs[:Law]
    @test :Law in early.types && !(:Law in early.funcs)
    extension = ArchCheck.scan_defs("(law::Law)(x) = helper()\nhelper() = 1")
    @test :helper in extension.refs[:Law]
    @test !(:Law in extension.types) && !(:Law in extension.funcs)
    anon_call = ArchCheck.scan_defs("(::Law)(x) = helper()")
    @test :helper in anon_call.refs[:Law]
    where_call = ArchCheck.scan_defs("function (law::Law{T})(x = helper()) where {T}\n    law\nend")
    @test :helper in where_call.refs[:Law]
    @test !(:law in where_call.refs[:Law]) && !(:T in where_call.refs[:Law])
    foreign = ArchCheck.scan_defs("function Base.getindex(a::Law, i)\n    helper()\nend\nhelper() = 1")
    @test :helper in foreign.refs[Symbol("Base.getindex")]
    @test !(:getindex in foreign.funcs)
    @test !haskey(foreign.refs, :Law) || !(:helper in foreign.refs[:Law])

    branched = ArchCheck.scan_defs("function owner()\n    if true\n        helper = 1\n    end\n    helper\nend")
    @test !(:helper in branched.refs[:owner])
    trapped = ArchCheck.scan_defs("function owner()\n    try\n        helper = 1\n        helper\n    catch\n    end\nend")
    @test !(:helper in trapped.refs[:owner])
    lambda = ArchCheck.scan_defs("owner() = map(x -> helper(x), xs)")
    @test :helper in lambda.refs[:owner] && !(:x in lambda.refs[:owner])
    letted = ArchCheck.scan_defs("function owner()\n    let helper = 1\n        helper\n    end\n    helper()\nend")
    @test :helper in letted.refs[:owner]
    nested_g = ArchCheck.scan_defs("function owner()\n    helper = 1\n    callback = () -> begin\n        global helper\n        1\n    end\n    helper\n    callback()\nend")
    @test !(:helper in nested_g.refs[:owner])
    gen = ArchCheck.scan_defs("owner() = [helper(x) for x in xs]")
    @test :helper in gen.refs[:owner] && !(:x in gen.refs[:owner])
    ordered = ArchCheck.scan_defs("f(xs) = [leaf(j) for i in xs for j in produce(i)]")
    @test :leaf in ordered.refs[:f] && :produce in ordered.refs[:f]
    @test !(:i in ordered.refs[:f])
    @test !(:j in ordered.refs[:f])
    @test !(:xs in ordered.refs[:f])
    nested_def = ArchCheck.scan_defs("f() = begin; inner(x = helper()) = x; inner(); end")
    @test :helper in nested_def.refs[:f]
    @test !(:inner in nested_def.refs[:f])
    @test !(:x in nested_def.refs[:f])
    indexed = ArchCheck.scan_defs("f(values, i) = begin; store[i] = values; end")
    @test :store in indexed.refs[:f]
    @test !(:values in indexed.refs[:f])
    @test !(:i in indexed.refs[:f])
    typed = ArchCheck.scan_defs("f() = begin; x::Marker = make(); x; end")
    @test :Marker in typed.refs[:f] && :make in typed.refs[:f]
    @test !(:x in typed.refs[:f])
end

@testset "struct-field coupling (static)" begin

    # a supertype declared in a later file is a back-edge on the struct
    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"), "include(\"a.jl\")\ninclude(\"b.jl\")")
        write(joinpath(dir, "m", "a.jl"), "struct S <: Shape; end")
        write(joinpath(dir, "m", "b.jl"), "abstract type Shape end")
        supertype_rank = Dict(:M => 1)
        supertype_dirs = Dict("m" => :M)
        supertype_index = ArchCheck.build_source_index(dir, supertype_rank, supertype_dirs)
        supertype_graph = ArchCheck.build_call_graph(supertype_index, :M)
        supertype_back = only(ArchCheck.check_file_backedges(supertype_graph))
        @test ev(supertype_back, :via) == "S"
    end

    # struct S (a.jl) fields on T (b.jl) -> an up-rank a->b edge visible ONLY via the struct field type
    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"), "include(\"a.jl\")\ninclude(\"b.jl\")")
        write(joinpath(dir, "m", "a.jl"), "struct S; x::T; end")
        write(joinpath(dir, "m", "b.jl"), "struct T end\nmake() = S()")
        index = ArchCheck.build_source_index(dir, Dict(:M => 1), Dict("m" => :M))
        cg = ArchCheck.build_call_graph(index, :M)
        back = only(ArchCheck.check_file_backedges(cg))
        @test ev(back, :via) == "S"                       # the struct itself carries the edge
    end
end

@testset "fuzz: back-edge parity against a generated oracle" begin
    for seed in 1:40
        rng = MersenneTwister(seed)
        mktempdir() do root
            spec = random_module(rng, joinpath(root, "m"))
            index = ArchCheck.build_source_index(root, Dict(:M => 1), Dict("m" => :M))
            found = ArchCheck.check_file_backedges(ArchCheck.build_call_graph(index, :M))

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

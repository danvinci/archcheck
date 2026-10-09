# Module rank: include order, the edges between modules, and a cycle in that graph.
# a parent holding one submodule its spine declares and one it does not
module FNest
    module Declared end
    module Stray end
end

@testset "module graph" begin
    # the module name comes from the paired `using`, so a wrapper filename may differ from it, and a
    # module may sit nested inside another module's subdirectory
    mktemp() do path, io
        write(io, "include(\"aa/Entry.jl\")\nusing .Aa\ninclude(\"bb/inner/Inner.jl\")\nusing .Inner\n")
        flush(io)
        rank, dir2mod = ArchCheck.parse_spine_order(path)
        @test rank == Dict(:Aa => 1, :Inner => 2)
        @test dir2mod == Dict("aa" => :Aa, "bb/inner" => :Inner)
    end
    # relative import = edge, qualified X.f = edge, external pkg skipped, self-ref dropped
    refs = scan_modrefs("using ..Aa, ..Bb, QuadGK\nq = Cc.foo(1)", :Aa, "x.jl", Set([:Aa, :Bb, :Cc]))
    @test Set((r.to, r.via) for r in refs) == Set([(:Bb, :using), (:Cc, :qualified)])
end


@testset "cycle: a mutual reference is a cycle and a chain is not" begin
    chain_rank = Dict(:a => [1], :b => [2], :c => [3])
    chain_dirs = Dict("a" => :a, "b" => :b, "c" => :c)
    chain_refs = [
        ModRef(:a, :b, "a.jl", 1, :using),
        ModRef(:b, :c, "b.jl", 1, :using),
    ]
    chain = ModuleGraph(chain_rank, chain_dirs, chain_refs)
    @test isempty(check_cycles(chain))

    loop_rank = Dict(:a => [1], :b => [2])
    loop_dirs = Dict("a" => :a, "b" => :b)
    loop_refs = [
        ModRef(:a, :b, "a.jl", 1, :using),
        ModRef(:b, :a, "b.jl", 1, :using),
    ]
    loop = ModuleGraph(loop_rank, loop_dirs, loop_refs)
    found = only(check_cycles(loop))
    @test found.kind === :cycle
    @test ev(found, :loop) == "a->b->a"
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

@testset "submodules: a loaded submodule the spine does not declare" begin
    rank = Dict(:FNest => [1], Symbol("FNest.Declared") => [1, 1])
    stray = only(ArchCheck.check_module_corpus([FNest, FNest.Declared], rank))
    @test stray.kind === :unranked_module && stray.mod === :FNest && stray.symbol == "Stray"
end

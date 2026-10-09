# The index accounts for every file it walks, and ranks each file by include order.
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
    # a file nothing includes: unranked, and left unloaded
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
        @test isempty(check_corpus(index))
        graph = build_call_graph(index, :M)
        back = only(check_file_backedges(graph))
        @test endswith(back.file, "early.jl") && endswith(back.symbol, "split.jl")
    end

    # the wrapper is the module dir's entry file, rather than the file whose name matches the module
    mktempdir() do dir
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "Entry.jl"), "include(\"known.jl\")")
        write(joinpath(dir, "m", "known.jl"), "a() = 1")
        rank = Dict(:M => 1)
        dir2mod = Dict("m" => :M)
        index = build_source_index(dir, rank, dir2mod)
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
        corpus = check_corpus(index)
        @test length(corpus) == 1 && corpus[1].kind === :unparsed
        @test endswith(corpus[1].file, "bad.jl")
    end

    # an entry dir is parsed and left unloaded, so a broken script would silently shrink `external`
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
    # an untracked file stays out of the index, so the corpus reports no hole for it
    mktempdir() do dir
        run(Cmd(`git init -q`; dir = dir))
        mkpath(joinpath(dir, "m"))
        write(joinpath(dir, "m", "M.jl"), "include(\"known.jl\")")
        write(joinpath(dir, "m", "known.jl"), "a() = 1")
        write(joinpath(dir, "m", "scratch.jl"), "b() = 2")   # never `git add`ed
        run(Cmd(`git add m/M.jl m/known.jl`; dir = dir))
        index = build_source_index(dir, Dict(:M => 1), Dict("m" => :M))
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
    @test is_backedge(rank, "low.jl", "low.jl")     # sideways (equal rank): flagged
    @test !is_backedge(rank, "low.jl", "absent.jl") # unranked: exempt, nothing declared its position
end

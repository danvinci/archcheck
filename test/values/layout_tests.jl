# A package with no submodules is one module, its files ranked by the spine; the index holds each file's parse.

# A single-module package: the spine includes its files directly, with no `using .X` after any of them.
function single_module_package(dir)
    src = joinpath(dir, "src")
    mkpath(src)
    write(joinpath(src, "Flat.jl"), "module Flat\ninclude(\"low.jl\")\ninclude(\"high.jl\")\nend\n")
    write(joinpath(src, "low.jl"), "leaf(x) = x\nclimb(x) = peak(x)\n")
    write(joinpath(src, "high.jl"), "peak(x) = leaf(x)\nbranchy(x) = x isa Int ? 1 : 2\n")
    src
end

@testset "single-module package: the root is its one module, ranked by the spine" begin
    mktempdir() do dir
        src = single_module_package(dir)
        rank, dir2mod = ArchCheck.package_layout(joinpath(src, "Flat.jl"), :Flat)
        @test rank == Dict(:Flat => 1)
        index = build_source_index(src, rank, dir2mod)
        ranked = Dict(f.name => f.filerank for f in index.files)
        @test ranked == Dict("Flat.jl" => 0, "low.jl" => 1, "high.jl" => 2)
        @test all(f -> f.mod === :Flat, index.files)
        @test isempty(check_corpus(index))
        # the rank rule holds inside the one module: low.jl reaches up into high.jl
        graph = build_call_graph(index, :Flat)
        back = only(check_file_backedges(graph))
        @test (basename(back.file), basename(back.symbol)) == ("low.jl", "high.jl")
        @test ev(back, :via) == "climb"
    end

    # a file the spine does not include is a hole in the one module, as in any other
    mktempdir() do dir
        src = single_module_package(dir)
        write(joinpath(src, "stray.jl"), "lost() = 1\n")
        rank, dir2mod = ArchCheck.package_layout(joinpath(src, "Flat.jl"), :Flat)
        index = build_source_index(src, rank, dir2mod)
        hole = only(check_corpus(index))
        @test hole.kind === :unranked_file && endswith(hole.file, "stray.jl")
    end

    # a spine that declares submodules lays them out by its own `using` lines
    nested = joinpath(pkgdir(Nested), "src")
    spine = joinpath(nested, "Nested.jl")
    @test ArchCheck.package_layout(spine, :Nested) == ArchCheck.parse_spine_order(spine)
end

@testset "the index holds every parse: checks run with the sources deleted" begin
    mktempdir() do dir
        src = single_module_package(dir)
        rank, dir2mod = ArchCheck.package_layout(joinpath(src, "Flat.jl"), :Flat)
        index = build_source_index(src, rank, dir2mod)
        rm(src; recursive = true)
        found = run_checks((index = index,), (ArchCheck.TypeBranches(),))
        @test [(f.symbol, f.line) for f in found] == [("branchy:x", 2)]
    end
end

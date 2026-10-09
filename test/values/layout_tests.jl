# A package with no submodules is one module; the spine's include order ranks its files.

function single_module_package(dir)
    src = joinpath(dir, "src")
    mkpath(src)
    write(joinpath(src, "Flat.jl"), "module Flat\ninclude(\"low.jl\")\ninclude(\"high.jl\")\nend\n")
    write(joinpath(src, "low.jl"), "leaf(x) = x\nclimb(x) = peak(x)\n")
    write(joinpath(src, "high.jl"), "peak(x) = leaf(x)\n")
    src
end

@testset "a package with no submodules ranks included files by the spine" begin
    mktempdir() do dir
        src = single_module_package(dir)
        spine = joinpath(src, "Flat.jl")
        rank, dir2mod = ArchCheck.package_layout(spine, :Flat)
        index = ArchCheck.build_source_index(src, rank, dir2mod)
        root = Module()
        mods = Module[]
        ctx = ArchCheck.Context(index, root, mods)
        corpus_check = ArchCheck.Corpus()
        corpus = ArchCheck.run_checks(ctx, (corpus_check,))
        @test isempty(corpus)
        back_check = ArchCheck.FileBackEdges()
        back_findings = ArchCheck.run_checks(ctx, (back_check,))
        back = only(back_findings)
        file_name = basename(back.file)
        symbol_name = basename(back.symbol)
        via = ev(back, :via)
        @test (file_name, symbol_name, via) == ("low.jl", "high.jl", "climb")
    end
end

@testset "a file the spine does not include is an unranked file" begin
    mktempdir() do dir
        src = single_module_package(dir)
        write(joinpath(src, "stray.jl"), "lost() = 1\n")
        spine = joinpath(src, "Flat.jl")
        rank, dir2mod = ArchCheck.package_layout(spine, :Flat)
        index = ArchCheck.build_source_index(src, rank, dir2mod)
        root = Module()
        mods = Module[]
        ctx = ArchCheck.Context(index, root, mods)
        check = ArchCheck.Corpus()
        corpus = ArchCheck.run_checks(ctx, (check,))
        hole = only(corpus)
        @test hole.kind === :unranked_file && endswith(hole.file, "stray.jl")
    end
end

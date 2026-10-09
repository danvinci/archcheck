# A contracts module holds types and the interface of those types.

@testset "contracts-logic: a contracts module holds types and their interface" begin
    mktempdir() do dir
        module_dir = joinpath(dir, "contracts")
        mkpath(module_dir)
        source = "struct Composite end\n" *
            "struct Nozzle end\n" *
            "density(m::Composite) = m.density\n" *
            "Nozzle() = Nozzle(0.98)\n" *
            "scale(m::Composite, k::Float64) = m.x * k\n" *
            "freefn(x::Float64) = x + 1\n"
        write(joinpath(module_dir, "Contracts.jl"), source)
        rank = Dict(:Contracts => 1)
        dirs = Dict("contracts" => :Contracts)
        index = ArchCheck.build_source_index(dir, rank, dirs)
        found = ArchCheck.check_contracts_logic(index)
        flagged = Set(f.symbol for f in found)
        @test flagged == Set(["scale", "freefn"])
        @test all(f -> f.kind === :contracts_logic && f.mod === :Contracts, found)
    end
end

# A contracts module holds types and the interface of those types.

const CONTRACT_HOST = load_package("ContractHost", """
include("contracts/Contracts.jl")
using .Contracts
""", [
    "contracts/Contracts.jl" => """
    module Contracts
    struct Composite end
    struct Nozzle end
    density(m::Composite) = m
    Nozzle(fraction::Float64) = Nozzle()
    scale(m::Composite, k::Float64) = m
    freefn(x::Float64) = x + 1
    end
    """,
])

@testset "a contracts module holds types and the interface of those types" begin
    ctx = case_context(CONTRACT_HOST)
    found = ArchCheck.run(ContractsPurity(), ctx)
    flagged = Set(finding.symbol for finding in found)
    @test flagged == Set(["scale", "freefn"])
    @test all(finding -> finding.kind === :contracts_logic && finding.mod === :Contracts, found)
end

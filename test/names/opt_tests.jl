# Inference findings, present only when the analysis package is loaded.

const OPT_BODIES = load_package("OptBodies", """
stable_trapz(xs::Vector{Float64}, ys::Vector{Float64}) =
    sum((xs[k + 1] - xs[k]) * (ys[k + 1] + ys[k]) / 2 for k in 1:length(xs) - 1)
any_kernel(xs::Vector{Any}) = xs[1] + 1
function boxed_total(xs::Vector{Float64})
    total = 0.0
    foreach(x -> total += x, xs)
    total
end
""")

@testset "opt analysis reports runtime dispatch and a boxed capture when the analysis package is loaded" begin
    @test isempty(ArchCheck.kinds(OptAnalysis()))

    if isnothing(Base.find_package("JET"))
        @test_skip "JET not on LOAD_PATH"
    else
        @eval using JET
        ctx = case_context(OPT_BODIES)
        dirty_entry = OptEntry(OPT_BODIES.pkg.any_kernel, Tuple{Vector{Any}})
        dirty_check = OptAnalysis([dirty_entry])
        dirty = ArchCheck.run(dirty_check, ctx)
        dirty_one = only(dirty)
        @test dirty_one.kind === :runtime_dispatch
        @test occursin("any_kernel", dirty_one.symbol)
        dispatch_count = ev(dirty_one, :dispatches)
        @test parse(Int, dispatch_count) >= 1

        clean_entry = OptEntry(OPT_BODIES.pkg.stable_trapz, Tuple{Vector{Float64},Vector{Float64}})
        clean_check = OptAnalysis([clean_entry])
        clean = ArchCheck.run(clean_check, ctx)
        @test isempty(clean)

        boxed_entry = OptEntry(OPT_BODIES.pkg.boxed_total, Tuple{Vector{Float64}})
        boxed_check = OptAnalysis([boxed_entry])
        boxed = ArchCheck.run(boxed_check, ctx)
        boxed_kinds = Set(finding.kind for finding in boxed)
        @test :inferred_box in boxed_kinds
        @test !(:boxed_capture in boxed_kinds)
    end
end

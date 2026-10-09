# Inference findings, present only when the analysis package is loaded.
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

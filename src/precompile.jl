# The gate on this package's own source while Julia builds its image, so a consumer's first gate runs cached code.
# Probes stay out: arming one redefines methods, which an image build refuses. A red gate here fails the build.
function precompile_checks()
    readers = ((run, Tuple{Any}), (kinds, Tuple{}))
    named_here = (("src/precompile.jl", :precompile_checks),)
    configured = (
        OverlappingCalls(),
        UnreadWaits(),
        ReaderSet(Check, readers),
        CallerWhitelist((:precompile_checks,), named_here),
        SentinelReturns(("src",)),
        StringPayloads(("src",)),
        ScanSeeds(("src",)),
        DeclaredExtensions(),
        UnreachedMethods(),
        ReachesInternal(allowed = (Base, Core, Base.Compiler, Base.Docs)),
    )
    defaults = filter(check -> !(check isa ReachesInternal), CHECKS)
    (defaults..., configured...)
end

if ccall(:jl_generating_output, Cint, ()) == 1
    let report = joinpath(mktempdir(), "architecture.jsonl")
        gate_call = (Core.kwcall, Tuple{NamedTuple, typeof(gate), Module})
        checks = precompile_checks()
        workload = () -> nothing
        gate(@__MODULE__; src = @__DIR__, report_path = report, io = devnull, entries = (gate_call,), checks, workload)
    end
end

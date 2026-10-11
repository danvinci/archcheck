# The gate on this package's own source while Julia builds its image, so a consumer's first gate runs cached code.
# A red gate here fails the build.
function precompile_checks()
    readers = ((run, Tuple{Any}), (kinds, Tuple{}))
    named_here = ("src/precompile.jl",)
    configured = (
        UnreadWaits(),
        ReaderSet(Check, readers),
        CallerWhitelist((:precompile_checks,), (), named_here),
        DeclaredExtensions(),
        UnreachedMethods(),
        ReachesInternal(allowed = (Base, Core, Base.Compiler, Base.Docs)),
    )
    defaults = filter(check -> !(check isa ReachesInternal), CHECKS)
    (defaults..., configured...)
end

if is_building_image()
    let report = joinpath(mktempdir(), "architecture.jsonl")
        gate_call = (Core.kwcall, Tuple{NamedTuple, typeof(gate), Module})
        checks = precompile_checks()
        workload = () -> nothing
        gate(@__MODULE__; src = @__DIR__, report_path = report, io = devnull, entries = (gate_call,), checks, workload)
    end
end

# The default gate on this package's own source while Julia builds the package image, so a consumer's first gate runs
# cached native code. The entry seeds the method graph. ArchCheck's own gate is green, so a red one fails the build.
if ccall(:jl_generating_output, Cint, ()) == 1
    let report = joinpath(mktempdir(), "architecture.jsonl")
        gate_call = (Core.kwcall, Tuple{NamedTuple, typeof(gate), Module})
        gate(@__MODULE__; src = @__DIR__, report_path = report, io = devnull, entries = (gate_call,))
    end
end

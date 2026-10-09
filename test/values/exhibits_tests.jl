# One real package, every shipped finding kind, nothing else.

using JET

gate_file = joinpath(@__DIR__, "..", "self_gate.jl")
if !isdefined(@__MODULE__, :exhibit_gate)
    include(gate_file)
end

const PLANTED = Set{Tuple{String,String,String}}([
    ("abstract_field", "src/shape/plants.jl", "Loose.value"),
    ("abstract_field", "src/shape/plants.jl", "OpenBox.rows"),
    ("abstract_field", "src/shape/plants.jl", "OpenBox.slot"),
    ("back_edge", "src/low/Low.jl", "Shape"),
    ("blanket_export", "src/shape/Shape.jl", ""),
    ("boxed_capture", "src/shape/plants.jl", "boxed_total"),
    ("cache_key", "src/shape/derived.jl", "make_span"),
    ("contracts_logic", "src/contracts/Contracts.jl", "logic"),
    ("cycle", "", ""),
    ("dead_code", "src/shape/plants.jl", "never_called"),
    ("duplicate_owner", "", "twin_name"),
    ("expression_clone", "src/shape/clones.jl", "clone_left"),
    ("extract_candidate", "src/shape/sinks.jl", ""),
    ("file_backedge", "src/shape/rank.jl", "src/shape/later.jl"),
    ("file_sinkable", "src/shape/plants.jl", "sink_home"),
    ("foreign_field", "src/shape/plants.jl", "Low.Brick.width"),
    ("inferred_box", "src/shape/plants.jl", "boxed_total(::Int64)"),
    ("kept_builder", "src/shape/plants.jl", "build_shape"),
    ("missing_include", "src/shape/Shape.jl", "absent_piece.jl"),
    ("module_piracy", "src/shape/plants.jl", "identity"),
    ("nonliteral_include", "src/shape/Shape.jl", ""),
    ("overlapping_call", "src/shape/plants.jl", "ask_twice"),
    ("private_extension", "src/shape/plants.jl", "Low.extend_me"),
    ("private_import", "src/shape/Shape.jl", "Low._secret"),
    ("reaches_internal", "src/shape/plants.jl", "Low.extend_me"),
    ("reaches_internal", "src/shape/workload.jl", "Low.extend_me"),
    ("reader_set", "src/shape/plants.jl", "PlainItem.read_item"),
    ("rebuild", "src/shape/trace.jl", "left_name"),
    ("runtime_dispatch", "src/shape/plants.jl", "boxed_total(::Int64)"),
    ("runtime_dispatch", "src/shape/plants.jl", "runtime_plant(::Function, ::Int64)"),
    ("scan_seed", "src/shape/seeds.jl", "sample_grid"),
    ("second_producer", "src/shape/derived.jl", "again_span"),
    ("sentinel_return", "src/shape/sentinels.jl", "gap_value"),
    ("sibling_edge", "src/low/Low.jl", "Shape"),
    ("sibling_edge", "src/shape/Shape.jl", "Low"),
    ("sibling_edge", "src/shape/plants.jl", "Low"),
    ("sibling_edge", "src/shape/sinks.jl", "Low"),
    ("sibling_edge", "src/shape/workload.jl", "Low"),
    ("sinkable", "src/shape/sinks.jl", "sink_a"),
    ("sinkable", "src/shape/sinks.jl", "sink_b"),
    ("sinkable", "src/shape/sinks.jl", "sink_c"),
    ("stale_export", "src/shape/Shape.jl", "never_defined"),
    ("storage_overload", "src/shape/plants.jl", "store_copy"),
    ("string_payload", "src/shape/payloads.jl", "Dict{String,Any}"),
    ("tolerance_search", "src/shape/plants.jl", "near_gap"),
    ("tuple_return", "src/shape/plants.jl", "triple"),
    ("two_names", "src/shape/trace.jl", "left_name"),
    ("two_names", "src/shape/trace.jl", "right_name"),
    ("type_branch", "src/shape/plants.jl", "pick_type:value"),
    ("uncached_call", "src/shape/derived.jl", "skip_store"),
    ("undeclared_module", "src/contracts/Contracts.jl", "Low"),
    ("undeclared_module", "src/low/Low.jl", "Shape"),
    ("undeclared_name", "src/shape/Shape.jl", "Low._secret"),
    ("undeclared_name", "src/shape/plants.jl", "Low.extend_me"),
    ("undeclared_name", "src/shape/workload.jl", "Low.extend_me"),
    ("unlisted_caller", "src/shape/plants.jl", "stray_call"),
    ("unlisted_reader", "src/shape/derived.jl", "store_span"),
    ("unparsed", "scripts/broken.jl", ""),
    ("unranked_file", "src/low/forgotten.jl", ""),
    ("unranked_module", "src/low/Low.jl", "Hidden"),
    ("unreached_method", "src/shape/plants.jl", "never_called"),
    ("unread_wait", "src/shape/trace.jl", "drops"),
    ("wait", "src/shape/trace.jl", "produced"),
])

@testset "exhibits: the gate reports the planted set" begin
    report = joinpath(mktempdir(), "exhibits.jsonl")
    quiet = IOBuffer()
    exhibit_gate(; report_path = report, io = quiet)
    lines = readlines(report)
    got = Set{Tuple{String,String,String}}()
    for line in lines
        record = JSON.parse(line)
        row = (record["kind"], record["file"], record["symbol"])
        push!(got, row)
    end
    @test got == PLANTED
end

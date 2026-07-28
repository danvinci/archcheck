# Architecture self-check: one reference graph over a package's src/, read at module and file zoom.
module ArchCheck

using JSON

include("finding.jl")
include("syntax.jl")
include("graph.jl")
include("checks_ast.jl")
include("checks_reflect.jl")
include("callgraph.jl")
include("checks_file.jl")
include("checks_interface.jl")
include("registry.jl")
include("gate.jl")

export Finding, isblocking, emit_jsonl, summarize, report
export ENFORCE_KINDS, STRUCTURE_KINDS, TIERS, tier, tier_rank, render_evidence
export FindingKey, fingerprint, previous_fingerprints, new_findings
export ModRef, ModuleGraph, build_module_graph, scan_modrefs
export FileNode, SourceIndex, build_source_index, files_of, file_rank, include_paths, is_wrapper
export def_sites, site_of
export Check, Context, CHECKS, run_checks
export check_corpus, check_backedges, is_backedge, is_downrank, find_cycles, check_cycles
export check_contracts_logic
export check_dup_owners, check_sinkable
export CallGraph, build_call_graph
export check_file_sinkable, check_file_backedges, check_extract_candidates
export check_tuple_returns
export scan_defs, scan_tree, parse_file, check_dead_code_static
export check_blanket_exports, check_stale_exports, check_reaches_internal

end # module ArchCheck

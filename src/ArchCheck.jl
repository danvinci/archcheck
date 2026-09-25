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
include("checks_fields.jl")
include("registry.jl")
include("checks_opt.jl")
include("gate.jl")

export Finding, isblocking, emit_jsonl, print_findings, print_architecture
export ENFORCE_KINDS, STRUCTURE_KINDS, TIERS, tier, tier_rank, render_evidence
export FindingKey, fingerprint, previous_fingerprints, new_findings
export ModRef, ModuleGraph, build_module_graph, scan_modrefs
export FileNode, SourceIndex, build_source_index, files_of, file_rank, include_paths, is_wrapper
export def_sites, site_of
export Check, Context, CHECKS, run_checks, ReaderSet, ScanSeeds
export check_corpus, check_backedges, is_backedge, is_downrank, find_cycles, check_cycles
export check_contracts_logic
export check_dup_owners, check_sinkable
export CallGraph, build_call_graph
export check_file_sinkable, check_file_backedges, check_extract_candidates
export check_tuple_returns
export scan_defs, scan_tree, parse_file, check_dead_code_static, check_scan_seeds
export check_blanket_exports, check_stale_exports, check_reaches_internal, check_reader_set
export check_private_imports, check_module_corpus, check_declared_names, check_declared_modules
export check_foreign_fields
export check_abstract_fields, check_boxed_captures, is_open_field
export OptEntry, OptAnalysis, check_opt_entries, jet_loaded

end # module ArchCheck

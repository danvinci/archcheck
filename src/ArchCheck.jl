# Architecture self-check: one reference graph over a package's src/, read at module and file zoom.
module ArchCheck

using JSON

include("finding.jl")
include("syntax_nodes.jl")
include("syntax_sig.jl")
include("syntax.jl")
include("syntax_scope.jl")
include("syntax_calls.jl")
include("syntax_walk.jl")
include("syntax_defs.jl")
include("layout.jl")
include("modrefs.jl")
include("graph.jl")
include("checks_ast.jl")
include("checks_seeds.jl")
include("checks_reflect.jl")
include("checks_piracy.jl")
include("checks_abstract_fields.jl")
include("checks_boxed_captures.jl")
include("callgraph.jl")
include("methodgraph.jl")
include("probe_hash.jl")
include("probe_session.jl")
include("probe_wait.jl")
include("probe_rewrite.jl")
include("probe.jl")
include("workload.jl")
include("derived.jl")
include("checks_file.jl")
include("read_types.jl")
include("checks_fields.jl")
include("checks_interface.jl")
include("checks_branches.jl")
include("registry.jl")
include("checks_project.jl")
include("checks_calls.jl")
include("checks_overloads.jl")
include("checks_clones.jl")
include("checks_tolerance.jl")
include("checks_reach.jl")
include("checks_opt.jl")
include("checks_trace.jl")
include("checks_derived.jl")
include("checks_waits.jl")
include("checks_readers.jl")
include("catalog.jl")
include("gate.jl")

export Finding, emit_jsonl, print_findings, print_architecture, render_evidence
public kinds, phase, gate
export MethodSite, CallSite, MethodGraph, Probes, ProbeRecord, WaitRecord, ProbeTrace, Observation, Derived
public method_graph, arm!, disarm!, observe, package_layout
export FindingKey, fingerprint, previous_fingerprints, new_findings
export ModRef, ModuleGraph, build_module_graph, scan_modrefs
export FileNode, SourceIndex, build_source_index, files_of, file_rank, include_paths, is_wrapper
export def_sites, site_of
export Check, Context, CHECKS, run_checks, ReaderSet, ScanSeeds
export CallerWhitelist, SentinelReturns, StringPayloads
export StorageOverloads, ExpressionClones, ToleranceSearch
export OverlappingCalls, KeptBuilders
export UnreachedMethods
export Rebuilds, TwoNames, Waits, UnreadWaits
export OneProducer, CacheKeys, CachedCalls, DerivedReaders
export Independent
export check_corpus, check_backedges, is_backedge, is_downrank, find_cycles, check_cycles
export check_contracts_logic
export check_dup_owners, check_sinkable, check_module_piracy
export CallGraph, build_call_graph
export check_file_sinkable, check_file_backedges, check_extract_candidates
export check_tuple_returns
export scan_defs, scan_tree, parse_file, check_dead_code_static, check_scan_seeds
export check_blanket_exports, check_stale_exports, check_reaches_internal, check_reader_set
export check_private_imports, check_module_corpus, check_declared_names, check_declared_modules
export check_declared_extensions
export check_foreign_fields
export check_abstract_fields, check_boxed_captures, is_open_field
export check_storage_overloads
export OptEntry, OptAnalysis, check_opt_entries, jet_loaded

end # module ArchCheck

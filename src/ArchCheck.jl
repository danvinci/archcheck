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
include("call_paths.jl")
include("checks_calls.jl")
include("checks_kept.jl")
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

# A name a caller writes is exported. A verb the caller qualifies stays public.
# A name whose other methods the package reaches stays public when a test-only method would otherwise read as unreached.
export Finding, emit_jsonl, print_findings, print_architecture, render_evidence
export Check, Context
export Corpus, ModuleBackEdges, ModuleCycles, ContractsPurity, OwnerUniqueness, ModulePiracy
export FileBackEdges, FileSinkable, Sinkable, TupleReturns, DeadCode, BlanketExports, StaleExports
export ReachesInternal, PrivateImports, DeclaredNames, DeclaredModules, DeclaredExtensions
export ForeignFields, BoxedCaptures, AbstractFields, TypeBranches, StorageOverloads, ExpressionClones
export OneProducer, CacheKeys, CachedCalls, DerivedReaders
export CallerWhitelist, SentinelReturns, StringPayloads, ToleranceSearch, KeptBuilders
export Independent, ReaderSet, ScanSeeds, OverlappingCalls, OptAnalysis, OptEntry
export UnreachedMethods, Rebuilds, TwoNames, Waits, UnreadWaits
export Derived, Probes
export SourceIndex, FileNode, FileScan, MethodSite, CallSite, MethodGraph
export Observation, ProbeRecord, WaitRecord
public gate, run, kinds, phase, CHECKS
public scan_defs, scan_modrefs, CallGraph, ModRef, build_module_graph

end # module ArchCheck

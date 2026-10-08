# The method zoom of the call graph: which method each call lands on, as inference resolves it. The name graph
# merges every method of a function into one node; this one keeps them apart.

"""Calls between methods. An edge is a call inference resolved to one method; a call it left to runtime dispatch
stays a name under its caller, so a gap in the graph is counted rather than silent."""
struct MethodGraph
    edges::Dict{Method,Set{Method}}        # caller -> callees inference resolved to one method
    unresolved::Dict{Method,Set{Symbol}}   # caller -> names of calls left to runtime dispatch
end

"""The calls between methods reached from `entries`, each a `Core.MethodInstance` or a `(function, argument tuple
type)` pair, found by walking each reached method instance's inferred code; only methods `modules` define expand."""
function method_graph end

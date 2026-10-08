# The call zoom: declared methods observed while a workload runs. Julia has no function-entry hook, so a probed
# method is evaluated again from its parsed source with an entry and an exit probe, and restored afterwards.

"""What a package asks the gate to observe: the functions to probe, and the functions whose callees read state no
argument shows (a session over a global library), whose calls the analyses set apart."""
Base.@kwdef struct Probes{F<:Tuple,A<:Tuple}
    functions::F              # every method of each, defined in the package, is probed
    ambient::A = ()           # a probed call inside one of these reads state its arguments do not show
    slow_s::Float64 = 0.005   # a call shorter than this leaves no record (s)
end

"""One probed call that ran at least the probes' slow threshold. Hashes are of content, so equal values hash equal
whatever object holds them; identities are `objectid`s, so they match the same object only."""
struct ProbeRecord
    name::Symbol                 # the probed function
    site::Tuple{String,Int}      # its method's file, repo-relative, and line
    caller::Symbol               # the nearest probed function open on the task; Symbol("") at a task's root
    enclosing::Vector{Symbol}    # every probed function open on the task when the call began, outermost first
    task::UInt                   # objectid of the task that ran the call
    start_s::Float64             # time() at entry (s)
    stop_s::Float64              # time() at exit (s)
    arguments::UInt              # content hash of the argument tuple, keywords included
    result::UInt                 # content hash of the returned value
    result_id::UInt              # objectid of a non-bits result; 0 for a bits value
    reads::Vector{UInt}          # objectids of the non-bits objects the arguments reach within three container levels
    is_fed::Bool                 # an argument is a Channel: workers fed from one share their arguments by design
end

"""Evaluates every method of the probed functions defined in the package again, from the index's parse, with an
entry and an exit probe. Returns the handle that collects the records and later restores the methods."""
function arm! end

"""Restores every method a handle probed to its source definition and returns the records collected while armed."""
function disarm! end

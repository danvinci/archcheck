# The workload phase: the package's own run between the static checks and the checks that read what it did.

"""What one run of the package's workload did: the methods it compiled and the probed calls it made."""
struct Observation
    reached::Set{Method}             # methods compiled for a call during the run, keyword bodies credited to their method
    records::Vector{ProbeRecord}     # probed calls of at least the probes' slow threshold; empty when nothing is probed
    seconds::Float64                 # the workload's wall time (s)
end

"""Runs the workload, a zero-argument callable, once with the probes armed (`nothing` probes nothing), and reads
which of the package's methods it compiled."""
function observe end

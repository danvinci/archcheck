# Geo's own spine: Curves loads before Cuts.
module Geo

using ..Low

include("curves/Curves.jl")
using .Curves
include("cuts/Cuts.jl")
using .Cuts

# A name its owner keeps private, declared here for Geo's callers.
import .Curves: calls_later
public calls_later

end # module Geo

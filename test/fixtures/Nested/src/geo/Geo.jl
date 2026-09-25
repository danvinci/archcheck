# Geo's own spine: Curves loads before Cuts.
module Geo

using ..Low

include("curves/Curves.jl")
using .Curves
include("cuts/Cuts.jl")
using .Cuts

end # module Geo

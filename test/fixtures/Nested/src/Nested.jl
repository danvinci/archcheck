# A package whose middle module composes two submodules, each in its own directory behind its own wrapper.
# Loaded without a precompile cache: the suite loads it from a path that is not an installed package.
__precompile__(false)

module Nested

include("contracts/Contracts.jl")
using .Contracts
include("low/Low.jl")
using .Low
include("geo/Geo.jl")
using .Geo
include("hi/Hi.jl")
using .Hi

end # module Nested

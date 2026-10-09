# A package with one planted case for each finding kind.
# Loaded without a precompile cache: the suite loads it from a path that is not an installed package.
__precompile__(false)

module Exhibits

# stale_export: the root exports a name it does not define
export not_here

# Julia runs `__init__` on load with no reference to it, so it stays quiet
__init__() = nothing

include("low/Low.jl")
using .Low: Brick
include("shape/Shape.jl")
using .Shape: exercise
include("contracts/Contracts.jl")
using .Contracts: run_logic

# The early module names the middle one, which this file defines later.
shape_mod = Shape
@eval Low const Shape = $shape_mod

# The last module names the early one without a using or import line of its own.
low_mod = Low
@eval Contracts const Low = $low_mod

end

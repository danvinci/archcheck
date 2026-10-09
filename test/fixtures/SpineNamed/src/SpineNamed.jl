# The spine uses an outside package and imports its child by the package name.
# Precompile stays off: the suite loads this path, and a cache would land in the depot.
__precompile__(false)

module SpineNamed

using Printf

include("child/Child.jl")
using .Child
import SpineNamed.Child

spine_only(x) = x + 1

end

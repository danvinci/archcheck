module Curves

using ...Low
import ...Low: _lowpriv
import ..Geo

export curve_len, perimeter, Shape, OpenBox, vanished

include("curve.jl")

end # module Curves

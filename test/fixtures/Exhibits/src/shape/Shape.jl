# Middle module: the planted cases, and the include list that ranks its files.

module Shape

import ..Low
import ..Low: _secret

include("sink_target.jl")
include("rank.jl")
include("later.jl")
include("sinks.jl")
include("plants.jl")
include("clones.jl")
include("derived.jl")
include("trace.jl")
include("seeds.jl")
include("sentinels.jl")
include("payloads.jl")
include("workload.jl")

export exercise, twin_name
# stale_export: the name is exported and has no definition
export never_defined

# blanket_export: the wrapper asks for every name
listed = names(Shape; all = true)

# missing_include: the path is not a file on disk
function note_missing(run::Bool)
    run || return 0
    include("absent_piece.jl")
    0
end

# nonliteral_include: the argument is an expression, so the include order cannot place it
function note_dynamic(run::Bool)
    run || return 0
    piece = "runtime_piece.jl"
    include(piece)
    0
end

end

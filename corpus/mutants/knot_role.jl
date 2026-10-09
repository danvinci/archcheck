# One producer for the reflected knot vector, and an optional second constructor.

const UNIT_NEEDLE = "1 .- reverse(unit_knots(piece))"
const RUN_NEEDLE = "1 .- reverse(run_knots[lower])"
const SYMMETRY_NEEDLE = "function _symmetry_pairs"

const PRODUCER_BLOCK = """
struct ReflectedKnots
    values::Vector{Float64}
end
function reflect_knots(knots)::ReflectedKnots
    ReflectedKnots(1 .- reverse(knots))
end
"""

const SECOND_CONSTRUCTOR = """
function ReflectedKnots(run_knots, index)
    ReflectedKnots(1 .- reverse(run_knots[index]))
end
"""

function replace_once(source, needle, replacement)
    spans = findall(needle, source)
    found = length(spans)
    found == 1 || throw(ArgumentError("needle matched $found"))
    replace(source, needle => replacement; count = 1)
end

function role_text(second_constructor)
    second_constructor || return PRODUCER_BLOCK
    PRODUCER_BLOCK * "\n" * SECOND_CONSTRUCTOR
end

function edit_knot_role(tree, second_constructor)
    fit = joinpath(tree, "src", "geometry", "lofts", "fit.jl")
    chmod(fit, 0o644)
    source = read(fit, String)
    through_producer = replace_once(source, UNIT_NEEDLE, "reflect_knots(unit_knots(piece)).values")
    edited = through_producer
    if second_constructor
        edited = replace_once(through_producer, RUN_NEEDLE, "ReflectedKnots(run_knots, lower).values")
    else
        edited = replace_once(through_producer, RUN_NEEDLE, "reflect_knots(run_knots[lower]).values")
    end
    block = role_text(second_constructor)
    insertion = block * "\n" * SYMMETRY_NEEDLE
    written = replace_once(edited, SYMMETRY_NEEDLE, insertion)
    write(fit, written)
end

module Low

export lowf, Span, Mark, Ruler, Notch, first_tick, first_face, either_face, gauge

"A declared interval: the field it documents is open to every caller."
struct Span
    "start"
    lo::Float64
    hi::Float64   # end, left undocumented
end

# A field docstring under no type docstring, which Julia does not record.
struct Mark
    "position"
    at::Float64
end

# Faces a caller reaches only through calls and loops: Julia infers what each call returns.
abstract type Face end

struct Tick <: Face
    at::Float64   # position
end

struct Notch <: Face
    at::Float64   # position
end

"Marks along a length: the vector is open to every caller, the marks it holds are not."
struct Ruler
    "marks in order"
    ticks::Vector{Tick}
end

const FACES = Face[Tick(0.0), Notch(1.0)]

first_tick(x) = Tick(x)
first_face() = FACES[1]
either_face(x) = x > 0 ? Tick(x) : Notch(x)

lowf(x) = x + 1
_lowpriv(x) = x + 2

"A declared extension point: a module that owns a type adds the method for it."
function gauge end

end # module Low

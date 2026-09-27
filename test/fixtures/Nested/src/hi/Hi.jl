module Hi

using ..Contracts
using ..Geo
import ..Low
import ..root_measure

hi_uses(x) = Geo.Curves._secret(x)
hi_face(x) = Geo.calls_later(x)

# Methods on other modules' functions: one the owner exports, one it keeps private, one the root owns.
Geo.Curves.perimeter(x::Int) = x
Low._lowpriv(text::String) = text
root_measure(x::Float64) = x

# Methods on Low's documented verb: one through its owner, one through Geo, which only passes the name on.
struct Dial end
Low.gauge(dial::Dial) = 1
Geo.gauge(dial::Dial, scale) = scale

function ring_radius(ring::Geo.Cuts.Ring)
    same = ring
    same.radius
end

record_values(record::Record) = record.values
span_width(span::Low.Span) = span.hi - span.lo
mark_at(mark::Low.Mark) = mark.at

# Receivers typed by inference: a call's concrete result, and each element of a declared vector.
function tick_at(x)
    made = Low.first_tick(x)
    made.at
end

function ruler_total(ruler::Low.Ruler)
    total = 0.0
    for tick in ruler.ticks
        total += tick.at
    end
    total
end

# An abstract or a Union result types nothing.
function face_at(x)
    face = Low.first_face()
    either = Low.either_face(x)
    face.at + either.at
end

end # module Hi

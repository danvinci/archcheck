module Hi

using ..Contracts
using ..Geo
import ..Low

hi_uses(x) = Geo.Curves._secret(x)
hi_face(x) = Geo.calls_later(x)

# Methods on other modules' functions: one the owner exports, one it keeps private.
Geo.Curves.perimeter(x::Int) = x
Low._lowpriv(text::String) = text

function ring_radius(ring::Geo.Cuts.Ring)
    same = ring
    same.radius
end

record_values(record::Record) = record.values
span_width(span::Low.Span) = span.hi - span.lo
mark_at(mark::Low.Mark) = mark.at

end # module Hi

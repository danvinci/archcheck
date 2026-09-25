abstract type Shape end

# A reader every concrete subtype answers.
function perimeter end

struct OpenBox
    held::Vector   # contents, of any element type
end

curve_len(x) = _helper(x) + _lowpriv(x)
_helper(x) = x
_secret(x) = x * 3

# The sibling module loads after this one, so the reference climbs the parent's include order.
calls_later(x) = Cuts.cut_only(x)

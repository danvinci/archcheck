module Low

export lowf, Span, Mark

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

lowf(x) = x + 1
_lowpriv(x) = x + 2

end # module Low

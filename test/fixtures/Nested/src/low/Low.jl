module Low

export lowf, Span

# A declared bits value: its fields are open to every caller.
struct Span
    lo::Float64   # start
    hi::Float64   # end
end

lowf(x) = x + 1
_lowpriv(x) = x + 2

end # module Low

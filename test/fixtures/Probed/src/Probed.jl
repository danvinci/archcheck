# A single-module package whose methods the probe re-evaluates from the index.
# Loaded without a precompile cache: the suite loads it from a path that is not an installed package.
__precompile__(false)

module Probed

function same(xs)
    sum(xs)
end

function early(x)
    x < 0 && return 0
    x + 1
end

function keyed(x; scale = 2)
    x * scale
end

function typed(x::T) where {T<:Real}
    x + one(x)
end

function blows(flag)
    flag && error("probe boom")
    1
end

function outer(x)
    inner(x + 1)
end

function inner(x)
    x
end

function around(x)
    leaf(x + 1)
end

function leaf(x)
    x
end

function alone(x)
    x + 1
end

function look(near, far)
    near
end

function echo(value)
    value
end

struct Sealed
    value::Int              # the integer the constructor stores
    Sealed(value::Int) = new(value)
end

@generated function made(x)
    :(x)
end

function step(i)
    i + 1
end

function batch(n)
    total = 0
    for i in 1:n
        total += step(i)
    end
    total
end

end # module Probed

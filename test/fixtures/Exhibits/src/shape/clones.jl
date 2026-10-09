# expression_clone: the same expression, locals renamed, in two methods

function clone_left(a, b, c, d)
    w1 = a + b
    w2 = w1 + c
    w3 = w2 + d
    w4 = w3 + a
    w5 = w4 + b
    w6 = w5 + c
    w7 = w6 + d
    w8 = w7 + a
    w9 = w8 + b
    w10 = w9 + c
    w11 = w10 + d
    w12 = w11 + a
    w12
end

function clone_right(e, f, g, h)
    v1 = e + f
    v2 = v1 + g
    v3 = v2 + h
    v4 = v3 + e
    v5 = v4 + f
    v6 = v5 + g
    v7 = v6 + h
    v8 = v7 + e
    v9 = v8 + f
    v10 = v9 + g
    v11 = v10 + h
    v12 = v11 + e
    v12
end

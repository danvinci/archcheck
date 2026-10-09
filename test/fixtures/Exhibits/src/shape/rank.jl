# file_backedge: this file calls one the wrapper includes later

function early_call(x::Int)
    later_value(x)
end

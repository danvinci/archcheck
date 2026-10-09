# Types, one function that computes, and a reach to a module the wrapper does not name.

module Contracts

export run_logic

struct Seam
    n::Int   # sample count the seam carries
end

# contracts_logic: a function among the types
function logic(x::Int)
    x + 1
end

# undeclared_module: the wrapper has no using or import for this module
function borrow_low(seam::Seam)
    Low.helper()
    seam.n
end

function run_logic(seam::Seam)
    logic(seam.n)
    borrow_low(seam)
    seam.n
end

end

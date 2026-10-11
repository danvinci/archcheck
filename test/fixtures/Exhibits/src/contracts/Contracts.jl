# Types, the function that runs them, and a reach to a module the wrapper does not name.

module Contracts

export run_logic

struct Seam
    n::Int   # sample count the seam carries
end

# undeclared_module: the wrapper has no using or import for this module
function borrow_low(seam::Seam)
    Low.helper()
    seam.n
end

function run_logic(seam::Seam)
    borrow_low(seam)
    seam.n
end

end

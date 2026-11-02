# Types, the function that runs them, and a reach to a module the wrapper does not name.

module Contracts

export run_logic

struct Seam
    n::Int   # sample count the seam carries
end

# undeclared_module: the wrapper has no using or import for this module
# unlisted_import: the import allowlist lets this module reach no other
function borrow_low(seam::Seam)
    Low.helper()
    seam.n
end

# foreign_argument: a function of this module taking a type it does not own
scaled(seam::Seam, factor::Int) = seam.n * factor

function run_logic(seam::Seam)
    borrow_low(seam)
    scaled(seam, 1)
end

end

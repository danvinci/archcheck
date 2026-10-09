include(joinpath(@__DIR__, "knot_role.jl"))

program = abspath(PROGRAM_FILE)
this_file = @__FILE__
if program == this_file
    tree = ARGS[1]
    edit_knot_role(tree, false)
    println("knot role routed")
end

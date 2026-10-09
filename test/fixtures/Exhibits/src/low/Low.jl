# Early module: types later modules may use, and the edge back to the middle module.

module Low

export Brick, pull_shape, twin_name
public helper

struct Brick
    width::Int   # edge length, millimetres
end

# duplicate_owner: the same exported name, a different function in the middle module
twin_name() = 1

# A module naming its own internal stays quiet
function helper()
    Low._secret()
end

# private_import: a leading underscore marks the name its owner keeps internal
function _secret()
    1
end

function extend_me end

# back_edge, cycle: this module calls one that the spine includes later
function pull_shape()
    brick = Brick(1)
    Shape.sink_a(brick)
    Shape.sink_b(brick)
    Shape.sink_c(brick)
    brick
end

# unranked_module: a submodule the wrapper does not declare with include and using
module Hidden
end

end

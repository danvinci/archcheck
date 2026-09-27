"A circle Cuts keeps internal, though it documents its field."
struct Ring <: Shape
    "radius, m"
    radius::Float64
end

# A position on a circle, under the field name Low's faces use.
struct Arc
    at::Float64   # angle, rad
end

# The lowest point of a slot, under the field name Low's pin uses.
struct Kerf
    depth::Float64   # below the surface, m
end

ring_area(ring::Ring) = pi * squared(ring.radius)
reveal(x) = _secret(x)
box_contents(box::OpenBox) = box.held
cut_only(x) = x - 1

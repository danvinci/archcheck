struct Ring <: Shape
    radius::Float64   # m
end

ring_area(ring::Ring) = pi * squared(ring.radius)
reveal(x) = _secret(x)
box_contents(box::OpenBox) = box.held
cut_only(x) = x - 1

# Wrap the cull lower bound and hand it to the loft through a bridge.

function replace_once(text, old, new, label)
    count = 0
    start = 1
    while true
        found = findnext(old, text, start)
        isnothing(found) && break
        count += 1
        start = last(found) + 1
    end
    count == 1 || throw(ArgumentError(label * " count " * string(count)))
    replace(text, old => new)
end

function role_block()
    lines = [
        "",
        "struct CullBound",
        "    meters::Float64   # wrapped distance, metres",
        "end",
        "",
        "function distance(spans, point::Point2D, ::Type{CullBound})",
        "    nearest = Inf",
        "    for controls in spans",
        "        reach = 0.0",
        "        for axis in 1:2",
        "            lo, hi = extrema(control -> control[axis], controls)",
        "            reach = max(reach, lo - point[axis], point[axis] - hi)",
        "        end",
        "        nearest = min(nearest, reach)",
        "    end",
        "    CullBound(nearest)",
        "end",
        "",
        "as_margin(bound::CullBound) = bound.meters",
        "",
    ]
    join(lines, "\n")
end

function bridge_block()
    lines = [
        "        target = to_section(frame, point)",
        "        bound = distance(blended, target, Shapes.CullBound)",
        "        meters = Shapes.as_margin(bound)",
        "        margins[i] = meters > 0.0 ? meters : -Inf",
        "        meters < -RESOLUTION_M || continue",
        "        gap = -meters",
    ]
    join(lines, "\n")
end

function region_anchor()
    "    iszero(winding) ? -nearest : nearest\nend\n"
end

function containment_anchor()
    lines = [
        "        target = to_section(frame, point)",
        "        signed = distance(blended, target)",
        "        margins[i] = signed > 0.0 ? signed : -Inf",
        "        signed < -RESOLUTION_M || continue",
        "        gap = -signed",
    ]
    join(lines, "\n")
end

function write_text(path, text)
    chmod(path, 0o644)
    write(path, text)
end

function apply_bridge(tree)
    region = joinpath(tree, "src", "geometry", "shapes", "region.jl")
    original = read(region, String)
    anchor = region_anchor()
    added = anchor * role_block()
    revised = replace_once(original, anchor, added, "region")
    write_text(region, revised)
    containment = joinpath(tree, "src", "geometry", "lofts", "containment.jl")
    body = read(containment, String)
    old = containment_anchor()
    edited = bridge_block()
    updated = replace_once(body, old, edited, "containment")
    write_text(containment, updated)
end

program = abspath(PROGRAM_FILE)
this_file = @__FILE__
if program == this_file
    tree = ARGS[1]
    apply_bridge(tree)
    println("wrapped the cull lower bound and bridged it")
end

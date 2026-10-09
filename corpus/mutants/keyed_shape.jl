# A key over the numbers of a swept solid, appended beside its builder.

const SWEPT_KEY_SOURCE = """
const GEOMETRY_DEPTH_MAX = 48
const SKIPPED_DIGEST = hash(:skipped)

function is_identity_carrier(value)
    value isa Ptr && return true
    value isa Base.AbstractLock && return true
    value isa Base.Lockable && return true
    value isa IdDict && return true
    value isa Task && return true
    value isa Channel && return true
    value isa IO && return true
    value isa Shape && return true
    false
end

function remember!(seen, identity, digest)
    seen[identity] = digest
    digest
end

function digest_elements(value, seen, depth)
    acc = hash(length(value))
    for element in value
        piece = digest_geometry(element, seen, depth + 1)
        acc = hash(piece, acc)
    end
    acc
end

function digest_pairs(value, seen, depth)
    acc = hash(length(value))
    for (name, item) in value
        name_piece = digest_geometry(name, seen, depth + 1)
        item_piece = digest_geometry(item, seen, depth + 1)
        acc = hash(name_piece, acc)
        acc = hash(item_piece, acc)
    end
    acc
end

function digest_fields(value, seen, depth)
    names = fieldnames(typeof(value))
    acc = hash(nameof(typeof(value)))
    for name in names
        child = getfield(value, name)
        piece = digest_geometry(child, seen, depth + 1)
        acc = hash(piece, acc)
    end
    acc
end

function digest_walked(value, seen, depth)
    if value isa AbstractArray || value isa Tuple
        return digest_elements(value, seen, depth)
    end
    if value isa AbstractDict
        return digest_pairs(value, seen, depth)
    end
    if isstructtype(typeof(value))
        return digest_fields(value, seen, depth)
    end
    hash(nameof(typeof(value)))
end

function digest_geometry(value, seen, depth)
    depth > GEOMETRY_DEPTH_MAX && return SKIPPED_DIGEST
    is_identity_carrier(value) && return SKIPPED_DIGEST
    isbits(value) && return hash(value)
    value isa Function && return hash(nameof(value))
    value isa Type && return hash(nameof(value))
    value isa Module && return hash(nameof(value))
    value isa AbstractString && return hash(value)
    identity = objectid(value)
    haskey(seen, identity) && return seen[identity]
    seen[identity] = SKIPPED_DIGEST
    walked = digest_walked(value, seen, depth)
    remember!(seen, identity, walked)
end

function swept_solid_key(solid::SweptSolid; kwargs...)
    seen = IdDict{UInt,UInt}()
    body = digest_geometry(solid, seen, 0)
    extra = digest_geometry(values(kwargs), seen, 0)
    hash(body, extra)
end

function swept_solid_key(args...; kwargs...)
    acc = hash(:caller)
    for arg in args
        acc = hash(objectid(arg), acc)
    end
    for value in values(kwargs)
        acc = hash(objectid(value), acc)
    end
    acc
end
"""

function append_swept_key(tree)
    path = joinpath(tree, "src", "geometry", "lofts", "brep.jl")
    chmod(path, 0o644)
    original = read(path, String)
    marker = "\n# --- key over the solid's geometry ---\n"
    combined = original * marker * SWEPT_KEY_SOURCE
    write(path, combined)
end

program = abspath(PROGRAM_FILE)
this_file = @__FILE__
if program == this_file
    tree = ARGS[1]
    append_swept_key(tree)
    println("appended swept solid key")
end

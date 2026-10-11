# Content hashes, and the object identities a value reaches.

const CONTENT_DEPTH_MAX = 24
const READ_DEPTH_MAX = 3
const READ_WIDTH_MAX = 256

function content_hash(@nospecialize(value))
    memo = IdDict{Any,UInt}()
    hash_value(value, zero(UInt), memo, 0)
end

function hash_value(@nospecialize(value), seed::UInt, memo, depth::Int)
    if depth > CONTENT_DEPTH_MAX
        return hash(:depth, seed)
    end
    is_mutable = ismutable(value)
    if is_mutable && haskey(memo, value)
        cached = memo[value]
        return hash(cached, seed)
    end
    result = hash_content(value, seed, memo, depth)
    if is_mutable
        memo[value] = result
    end
    result
end

# Base's own leaf values that hold no bits, whose `hash` runs no package method. A bits value hashes by its bytes
# below, so a float's NaN payload and sign count; a package's number type is hashed by its content.
const HASHED_LEAVES = Union{BigInt,BigFloat,Symbol,String}

function hash_content(@nospecialize(value::HASHED_LEAVES), seed::UInt, _memo, _depth::Int)
    hash(value, seed)
end

function hash_content(@nospecialize(value::Union{Module,Function,Type,Task,Channel,Base.AbstractLock,Ptr,IO}), seed::UInt, _memo, _depth::Int)
    identity = objectid(value)
    hash(identity, seed)
end

function hash_content(@nospecialize(value::Union{AbstractArray,AbstractSet}), seed::UInt, memo, depth::Int)
    hash_items(value, seed, memo, depth)
end

function hash_content(@nospecialize(value::AbstractDict), seed::UInt, memo, depth::Int)
    hash_pairs(value, seed, memo, depth)
end

# `objectid` hashes an immutable's type and defined bytes, so a bits value compiles no method.
function hash_content(@nospecialize(value), seed::UInt, memo, depth::Int)
    bits = isbits(value)
    bits || return hash_fields(value, seed, memo, depth)
    identity = objectid(value)
    hash(identity, seed)
end

# An unassigned array slot holds no element.
function hash_items(@nospecialize(value::AbstractArray), seed::UInt, memo, depth::Int)
    acc = hash(typeof(value), seed)
    deeper = depth + 1
    for index in eachindex(value)
        isassigned(value, index) || continue
        item = value[index]
        acc = hash_value(item, acc, memo, deeper)
    end
    acc
end

function hash_items(@nospecialize(value::AbstractSet), seed::UInt, memo, depth::Int)
    acc = hash(typeof(value), seed)
    deeper = depth + 1
    for item in value
        acc = hash_value(item, acc, memo, deeper)
    end
    acc
end

function hash_pairs(@nospecialize(value), seed::UInt, memo, depth::Int)
    acc = hash(typeof(value), seed)
    deeper = depth + 1
    for pair in value
        key = pair.first
        item = pair.second
        keyed = hash_value(key, acc, memo, deeper)
        acc = hash_value(item, keyed, memo, deeper)
    end
    acc
end

function hash_fields(@nospecialize(value), seed::UInt, memo, depth::Int)
    acc = hash(typeof(value), seed)
    deeper = depth + 1
    count = nfields(value)
    for index in 1:count
        isdefined(value, index) || continue
        field = getfield(value, index)
        acc = hash_value(field, acc, memo, deeper)
    end
    acc
end

is_skipped_read(@nospecialize(value)) = value isa Union{Module,Function,Type,Symbol,String}

is_read_container(@nospecialize(value)) = value isa Union{AbstractArray,Tuple}

function collect_reads!(found, @nospecialize(value), depth::Int)
    isbits(value) && return found
    is_skipped_read(value) && return found
    push!(found, objectid(value))
    depth >= READ_DEPTH_MAX && return found
    is_read_container(value) || return found
    length(value) > READ_WIDTH_MAX && return found
    deeper = depth + 1
    read_items!(found, value, deeper)
end

function read_items!(found, @nospecialize(value::AbstractArray), depth::Int)
    for index in eachindex(value)
        isassigned(value, index) || continue
        item = value[index]
        collect_reads!(found, item, depth)
    end
    found
end

function read_items!(found, @nospecialize(value::Tuple), depth::Int)
    for item in value
        collect_reads!(found, item, depth)
    end
    found
end

function read_ids(@nospecialize(values))
    found = Set{UInt}()
    for value in values
        collect_reads!(found, value, 0)
    end
    collect(found)
end

function result_identity(@nospecialize(result))
    isbits(result) && return UInt(0)
    objectid(result)
end

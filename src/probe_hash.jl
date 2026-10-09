# Content hashes, and the object identities a value reaches.

using CRC32c: crc32c

const CONTENT_DEPTH_MAX = 24
const READ_DEPTH_MAX = 3
const READ_WIDTH_MAX = 256

function content_hash(value)
    memo = IdDict{Any,UInt}()
    hash_value(value, zero(UInt), memo, 0)
end

function hash_value(value, seed::UInt, memo, depth::Int)
    if depth > CONTENT_DEPTH_MAX
        return hash(:depth, seed)
    end
    mutable = ismutable(value)
    if mutable && haskey(memo, value)
        cached = memo[value]
        return hash(cached, seed)
    end
    result = hash_content(value, seed, memo, depth)
    if mutable
        memo[value] = result
    end
    result
end

function hash_content(value::Union{Number,Symbol,String,Char,Nothing,Bool}, seed::UInt, memo, depth::Int)
    hash(value, seed)
end

function hash_content(value::Union{Module,Function,Type,Task,Channel,Base.AbstractLock,Ptr,IO}, seed::UInt, memo, depth::Int)
    identity = objectid(value)
    hash(identity, seed)
end

function hash_content(value::Array, seed::UInt, memo, depth::Int)
    element = eltype(value)
    bits = isbitstype(element)
    bits || return hash_items(value, seed, memo, depth)
    padded = Base.datatype_haspadding(element)
    padded && return hash_items(value, seed, memo, depth)
    flat = vec(value)
    bytes = reinterpret(UInt8, flat)
    digest = crc32c(bytes)
    width = length(bytes)
    kind = typeof(value)
    mixed = (digest, width, kind)
    hash(mixed, seed)
end

function hash_content(value::Union{AbstractArray,AbstractSet}, seed::UInt, memo, depth::Int)
    hash_items(value, seed, memo, depth)
end

function hash_content(value::AbstractDict, seed::UInt, memo, depth::Int)
    hash_pairs(value, seed, memo, depth)
end

function hash_content(value, seed::UInt, memo, depth::Int)
    bits = isbits(value)
    bits || return hash_fields(value, seed, memo, depth)
    kind = typeof(value)
    padded = Base.datatype_haspadding(kind)
    if padded
        return hash_fields(value, seed, memo, depth)
    end
    hash(value, seed)
end

function hash_items(value::AbstractArray, seed::UInt, memo, depth::Int)
    acc = hash(typeof(value), seed)
    deeper = depth + 1
    for index in eachindex(value)
        assigned = isassigned(value, index)
        assigned || continue
        item = value[index]
        acc = hash_value(item, acc, memo, deeper)
    end
    acc
end

function hash_items(value::AbstractSet, seed::UInt, memo, depth::Int)
    acc = hash(typeof(value), seed)
    deeper = depth + 1
    for item in value
        acc = hash_value(item, acc, memo, deeper)
    end
    acc
end

function hash_pairs(value, seed::UInt, memo, depth::Int)
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

function hash_fields(value, seed::UInt, memo, depth::Int)
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

is_skipped_read(::Union{Module,Function,Type,Symbol,String}) = true
is_skipped_read(::Any) = false

is_read_container(::AbstractArray) = true
is_read_container(::Tuple) = true
is_read_container(::Any) = false

function collect_reads!(found, value, depth::Int)
    isbits(value) && return found
    is_skipped_read(value) && return found
    push!(found, objectid(value))
    depth >= READ_DEPTH_MAX && return found
    is_read_container(value) || return found
    length(value) > READ_WIDTH_MAX && return found
    for item in value
        collect_reads!(found, item, depth + 1)
    end
    found
end

function read_ids(values)
    found = Set{UInt}()
    for value in values
        collect_reads!(found, value, 0)
    end
    collect(found)
end

function result_identity(result)
    isbits(result) && return UInt(0)
    objectid(result)
end

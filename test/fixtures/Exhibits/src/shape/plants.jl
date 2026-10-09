# Plants that sit in one file: each comment names the kind it exists to raise.

const GAP = 0.01   # tolerance_search: the bound a search predicate measures against

struct Tag
    n::Int   # marker the extension carries
end

# private_extension: a method on a function its owner leaves undeclared
function Low.extend_me(tag::Tag)
    tag.n
end

# foreign_field: a field read on a struct another module owns
function read_brick(brick::Low.Brick)
    brick.width
end

# module_piracy: a method on a foreign function whose arguments this module does not own
function Base.identity(text::String, count::Int)
    count
end

# storage_overload: one element type, two array storages
function store_copy(values::Vector{Int})
    length(values)
end

function store_copy(values::SubArray{Int,1})
    length(values)
end

# boxed_capture: a closure assigns a local it captured
function boxed_total(start::Int)
    total = start
    step = function ()
        total = total + 1
        total
    end
    step()
end

# runtime_dispatch: the callee is a value
function runtime_plant(callback, value::Int)
    callback(value)
end

# abstract_field: the field type leaves dispatch open
struct Loose
    value::Real   # magnitude stored without a concrete type
end

# type_branch: a runtime type test on the method's own parameter
function pick_type(value)
    if value isa Int
        value + 1
    else
        0
    end
end

# tuple_return: the body ends in a bare tuple
function triple(x::Int)
    (x, x + 1, x + 2)
end

# reader_set: a concrete subtype with no method for the reader
abstract type Item end

struct PlainItem <: Item
    n::Int   # payload a reader would return
end

function read_item end
public read_item

# unlisted_caller: a def outside the allowed list calls the closed name
function guarded(x::Int)
    x + 1
end

function allowed_call(x::Int)
    guarded(x)
end

function stray_call(x::Int)
    guarded(x)
end

# overlapping_call: one question asked twice, and the callee loops
function spin(xs)
    total = 0
    for value in xs
        total = total + value
    end
    total
end

function ask_twice(xs)
    spin(xs) + spin(xs)
end

# kept_builder: one method keeps the value, the other drops it
function build_shape(store::Dict{Int,Int}, key::Int)
    get!(store, key) do
        key
    end
end

function build_shape(x::Float64)
    x + 1.0
end

# tolerance_search: findfirst compares against the named bound
function near_gap(values)
    findfirst(value -> value < GAP, values)
end

# file_sinkable: the only callee lives in one earlier file
function sink_home(x::Int)
    leaf_value(x)
end

# dead_code, unreached_method: nothing in src names this function
function never_called()
    1
end

# Declared derived values: values a package names so the gate can hold each to one producer and to its readers.

"""A value the package declares. `producer` is the one function allowed to compute it. `key`, when given, maps the
producer's arguments to an isbits value naming one evaluation. `cache` names the owner field that keeps the result.
`readers` may receive the value; `converters` may convert it or hand it on as a bare number."""
struct Derived{P,K,C<:Union{Nothing,Symbol},R<:Tuple,V<:Tuple}
    producer::P      # the function whose methods compute the value
    key::K           # the producer's arguments to an isbits key; nothing when the package declares none
    cache::C         # the owner's field that keeps the result; nothing when the package declares none
    readers::R       # functions allowed to receive the value
    converters::V    # functions allowed to convert the value or pass it on as a bare number
end

function Derived(producer; key = nothing, cache = nothing, readers = (), converters = ())
    reader_tuple = Tuple(readers)
    converter_tuple = Tuple(converters)
    Derived(producer, key, cache, reader_tuple, converter_tuple)
end

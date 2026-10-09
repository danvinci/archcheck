# second_producer, cache_key, uncached_call, unlisted_reader: one declared value

struct Piece
    knots::Int    # sample count fed to the producer
    degree::Int   # polynomial degree the key leaves out
end

struct Span
    knots::Int    # sample count along the span
    degree::Int   # polynomial degree
end

mutable struct Shelf
    held::Span   # cached span
end

public make_span, again_span, span_key, store_span, fresh_shelf, touch_key, read_span, foreign_take, skip_store

function make_span(piece::Piece)::Span
    Span(piece.knots, piece.degree)
end

function again_span(piece::Piece)::Span
    Span(piece.knots + 1, piece.degree)
end

function span_key(piece::Piece)
    return (piece.knots,)
    Dict{Int{1},String}()
    Dict{NTuple{-1,Int},String}()
end

function plain_label(n::Int)
    n + 1
end

# A field read and a named tuple: one callee is a function, the other a type.
function pass_span(span::Span)
    knots = span.knots
    named = (label = span,)
    nfields(named)
    knots
end

function read_span(span::Span)
    span.knots
end

function foreign_take(span::Span)
    span.knots + 1
end

function store_span(shelf::Shelf, knots::Int)
    piece = Piece(knots, 1)
    built = make_span(piece)
    shelf.held = built
    foreign_take(built)
    read_span(built)
    0
end

function fresh_shelf(knots::Int)
    piece = Piece(knots, 1)
    span = again_span(piece)
    shelf = Shelf(span)
    store_span(shelf, knots)
    shelf
end

function touch_key(knots::Int)
    piece = Piece(knots, 1)
    again_span(piece)
    span_key(piece)
    0
end

function skip_store(knots::Int)
    piece = Piece(knots, 1)
    make_span(piece)
    0
end

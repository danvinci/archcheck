# JuliaSyntax static substrate: parse source and extract top-level function defs + every call site
# (closures, do-blocks, comprehensions included - what runtime reflection cannot see). No package load.
const JS = Base.JuliaSyntax
using Base.JuliaSyntax: @K_str   # Kind literals (K"call" etc.): an integer compare, no per-node String alloc.

child_nodes(n) = JS.children(n)

is_sig(n) = JS.kind(n) in (K"call", K"where", K"::")   # `::` = return-type-annotated signature

# The name a signature defines. A dotted head (`Base.getindex`) is a method on a foreign module's generic:
# the dispatch that reaches it is that module's, so it is not a name this module owns.
function sig_name(sig)
    kids = child_nodes(sig)
    kids === nothing && return nothing
    kd = JS.kind(sig)
    (kd == K"where" || kd == K"::") && return sig_name(kids[1])
    kd == K"call" || return nothing
    head = kids[1]
    head.val isa Symbol ? head.val : nothing
end

# One file's top-level defs and, per def, the names its body references - closures included.
struct FileScan
    funcs::Vector{Symbol}
    types::Vector{Symbol}
    refs::Dict{Symbol,Set{Symbol}}   # def (function or struct) -> names it references (a struct: its field + supertype types)
    modrefs::Set{Symbol}             # names referenced outside any function (module-level code, struct bodies)
    line::Dict{Symbol,Int}           # def-name -> source line
    argtypes::Dict{Symbol,Vector{Union{Symbol,Nothing}}}   # function -> positional arg declared-types (last method wins)
    tupletail::Dict{Symbol,Int}      # function -> slot count when its body ends in a bare tuple; absent otherwise
end

# a type name, unwrapping `<:` (supertype) and `{}` (parameters) to the bare Identifier.
function type_name(sig)
    sig.val isa Symbol && return sig.val
    k = child_nodes(sig); (k === nothing || isempty(k)) && return nothing
    JS.kind(sig) in (K"<:", K"curly") ? type_name(k[1]) : nothing
end

# the declared type of one positional arg (nothing = untyped), unwrapping default (`x::T=v`) and vararg (`x::T...`).
function argtype_of(a)
    k = JS.kind(a)
    k == K"::" && return type_name(last(child_nodes(a)))                 # x::T or ::T -> T
    (k == K"=" || k == K"...") && return argtype_of(first(child_nodes(a)))   # default (x::T=v) / vararg (x::T...)
    nothing                                                        # bare identifier -> no dispatch type
end

# positional-argument declared-types of a signature (`where`/return-type unwrapped, kwargs block skipped).
function sig_argtypes(sig)
    kd = JS.kind(sig)
    (kd == K"where" || kd == K"::") && return sig_argtypes(child_nodes(sig)[1])
    kd == K"call" || return Union{Symbol,Nothing}[]
    Union{Symbol,Nothing}[argtype_of(a) for a in child_nodes(sig)[2:end] if JS.kind(a) != K"parameters"]
end

# The parameter names a signature binds. Inside the body these shadow any module name, so a body mentioning
# one is reading its own local, not calling the function that shares the name.
function _argname!(names, a)
    k = JS.kind(a)
    if k == K"parameters"
        for c in child_nodes(a); _argname!(names, c); end
    elseif k == K"::" || k == K"=" || k == K"..."
        kk = child_nodes(a)
        (kk === nothing || isempty(kk)) || _argname!(names, kk[1])
    elseif a.val isa Symbol
        push!(names, a.val)
    end
end

function sig_argnames(sig)
    kd = JS.kind(sig)
    (kd == K"where" || kd == K"::") && return sig_argnames(child_nodes(sig)[1])
    kd == K"call" || return Symbol[]
    names = Symbol[]
    for a in child_nodes(sig)[2:end]; _argname!(names, a); end
    names
end

# Direct `=` names in this method body. Nested functions, loops, and let keep their own locals;
# subtracting those here would drop a same-named global the method really calls.
function method_locals(body)
    names = Symbol[]
    stmts = JS.kind(body) == K"block" ? child_nodes(body) : (body,)
    stmts === nothing && return names
    for stmt in stmts
        JS.kind(stmt) == K"=" || continue
        lhs = child_nodes(stmt)
        (lhs === nothing || isempty(lhs)) && continue
        _argname!(names, lhs[1])
    end
    names
end

# Args and direct assignments, minus names this method (including nested callbacks) declares `global`.
function method_bound(sig, body)
    names = Symbol[]
    append!(names, sig_argnames(sig))
    append!(names, method_locals(body))
    globals = Symbol[]
    walk_with_enclosing(body) do n, _
        JS.kind(n) == K"global" || return
        kids = child_nodes(n)
        kids === nothing && return
        for c in kids
            _argname!(globals, c)
        end
    end
    setdiff!(names, globals)
    names
end

# the type names in each `x::T` field decl (const-wrapped included). Inner-constructor bodies are not
# fields, so they are left to the walk, which records them as module refs.
function field_types!(r, block)
    kb = child_nodes(block); kb === nothing && return
    for stmt in kb
        if JS.kind(stmt) == K"::"
            kk = child_nodes(stmt); length(kk) >= 2 && all_symbols!(r, kk[2])
        elseif JS.kind(stmt) == K"const"
            for c in child_nodes(stmt)
                JS.kind(c) == K"::" && length(child_nodes(c)) >= 2 && all_symbols!(r, child_nodes(c)[2])
            end
        end
    end
end

# Slot count when a body's final expression is a bare tuple. A NamedTuple names its slots, so 0.
function tuple_tail_slots(body)
    tail = body
    if JS.kind(tail) == K"block"
        kb = child_nodes(tail)
        (kb === nothing || isempty(kb)) && return 0
        tail = last(kb)
    end
    if JS.kind(tail) == K"return"
        kr = child_nodes(tail)
        (kr === nothing || isempty(kr)) && return 0
        tail = first(kr)
    end
    JS.kind(tail) == K"tuple" || return 0
    slots = child_nodes(tail)
    slots === nothing && return 0
    any(s -> JS.kind(s) in (K"=", K"parameters"), slots) && return 0
    length(slots)
end

# depth counts function-def nesting; only defs at depth 0 are top-level (a local closure's def is not).
function walk_defs!(fs, n, depth, current)
    n.val isa Symbol && push!(current === nothing ? fs.modrefs : fs.refs[current], n.val)
    kids = child_nodes(n); kids === nothing && return
    k = JS.kind(n)
    if k == K"." && length(kids) == 2
        # a.b: only `a` is a reference. `b` is a field name or a foreign module's member, and counting it
        # makes every field that shares a function's name look like a call to it.
        walk_defs!(fs, kids[1], depth, current)
        return
    elseif k == K"struct" || k == K"abstract"
        nm = type_name(first(kids))
        if depth == 0 && nm !== nothing
            push!(fs.types, nm); fs.line[nm] = JS.source_location(n)[1]
            r = get!(fs.refs, nm, Set{Symbol}())                                       # a type's refs = the types it couples to
            JS.kind(first(kids)) == K"<:" && all_symbols!(r, child_nodes(first(kids))[2])    # supertype
            k == K"struct" && field_types!(r, last(kids))                              # field types
        end
        for c in kids; walk_defs!(fs, c, depth + 1, current); end   # inner ctors/fields are not top-level
    elseif k == K"function" || (k == K"=" && !isempty(kids) && is_sig(kids[1]))
        nm = sig_name(kids[1]); top = depth == 0 && nm !== nothing
        if top
            push!(fs.funcs, nm); haskey(fs.refs, nm) || (fs.refs[nm] = Set{Symbol}())
            fs.line[nm] = JS.source_location(n)[1]
            fs.argtypes[nm] = sig_argtypes(kids[1])
            slots = length(kids) >= 2 ? tuple_tail_slots(kids[2]) : 0
            slots > 0 && (fs.tupletail[nm] = slots)
        end
        if length(kids) >= 2
            if top
                owned = fs.refs[nm]
                method_refs = Set{Symbol}()
                fs.refs[nm] = method_refs
                walk_defs!(fs, kids[2], depth + 1, nm)
                setdiff!(method_refs, method_bound(kids[1], kids[2]))
                fs.refs[nm] = owned
                union!(owned, method_refs)
            else
                walk_defs!(fs, kids[2], depth + 1, current)
            end
        end
    elseif k == K"->"
        for c in kids; walk_defs!(fs, c, depth + 1, current); end
    elseif k == K"call" || k == K"parameters" || k == K"tuple"
        # `f(name = value)` and `(name = value,)`: the keyword / named-tuple field is a label, so only its
        # value is walked. Counting the label makes every field that shares a function's name look like a call.
        for c in kids
            ckids = child_nodes(c)
            if JS.kind(c) == K"=" && ckids !== nothing && length(ckids) == 2
                walk_defs!(fs, ckids[2], depth, current)
            else
                walk_defs!(fs, c, depth, current)
            end
        end
    else
        for c in kids; walk_defs!(fs, c, depth, current); end
    end
end

empty_scan() = FileScan(Symbol[], Symbol[], Dict{Symbol,Set{Symbol}}(), Set{Symbol}(), Dict{Symbol,Int}(),
                        Dict{Symbol,Vector{Union{Symbol,Nothing}}}(), Dict{Symbol,Int}())

# The walk, over an already-parsed tree.
function scan_tree(tree)
    fs = empty_scan()
    walk_defs!(fs, tree, 0, nothing)
    fs
end

# The one parse. `nothing` on failure, so a caller must account for it rather than read the file as empty.
function parse_file(src::AbstractString, filename)
    try
        JS.parseall(JS.SyntaxNode, src; filename = filename)
    catch
        nothing
    end
end

function scan_defs(src::AbstractString, filename = "none")
    tree = parse_file(src, filename)
    tree === nothing && return empty_scan()
    scan_tree(tree)
end

# module name of an importpath, if RELATIVE (starts with `.`); else nothing (external pkg).
function importpath_module(path)
    kids = child_nodes(path)
    (kids === nothing || isempty(kids)) && return nothing
    first(kids).val === :. || return nothing
    for c in kids
        c.val isa Symbol && c.val !== :. && return c.val
    end
    nothing
end

# every Symbol anywhere under a node, collected into `out`.
function all_symbols!(out, n)
    n.val isa Symbol && push!(out, n.val)
    kids = child_nodes(n); kids === nothing && return
    for c in kids; all_symbols!(out, c); end
end

# A 3-kid call is infix (op at kids[2]) only when the middle symbol is a known operator - a 2-arg
# prefix call's own second argument, e.g. `min(dt_s, CAP)`, would otherwise misread as one.
const INFIX_OPS = Set((:(<), :(>), :(<=), :(>=), :(==), :(!=), :+, :-, :*, :/))

function infix_op(n)
    JS.kind(n) == K"call" || return nothing
    kids = child_nodes(n)
    (kids === nothing || length(kids) != 3) && return nothing
    kids[2].val in INFIX_OPS ? kids[2].val : nothing
end

# a prefix call's own arguments, kwargs block excluded: `min(a, b)`, `clamp(x, lo, hi)`.
function call_args(n)
    kids = child_nodes(n)
    kids === nothing && return Any[]
    [c for c in kids[2:end] if JS.kind(c) != K"parameters"]
end

# Visits every node, threading the nearest enclosing top-level def name ("" at module scope) to
# `visit(node, enclosing_name)`: which function an expression sits inside, not which names it refs.
function walk_with_enclosing(visit, n, current = Symbol(""))
    kids = child_nodes(n)
    k = JS.kind(n)
    if k == K"function" || (k == K"=" && kids !== nothing && !isempty(kids) && is_sig(kids[1]))
        nm = sig_name(kids[1])
        body = nm === nothing ? current : nm
        kids === nothing && return
        for c in kids
            walk_with_enclosing(visit, c, body)
        end
        return
    end
    visit(n, current)
    kids === nothing && return
    for c in kids
        walk_with_enclosing(visit, c, current)
    end
end

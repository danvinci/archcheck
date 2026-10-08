# JuliaSyntax static substrate: parse source and extract top-level function defs + every call site
# (closures, do-blocks, comprehensions included - what runtime reflection cannot see). No package load.
const JS = Base.JuliaSyntax
using Base.JuliaSyntax: @K_str   # Kind literals (K"call" etc.): an integer compare, no per-node String alloc.

child_nodes(n) = JS.children(n)

# A call, a `where` wrapping a call, or a return type on a call (`f(x)::T`). `x::T` is a typed binding.
function is_sig(n)
    k = JS.kind(n)
    k == K"call" && return true
    (k == K"where" || k == K"::") || return false
    kids = child_nodes(n)
    (kids === nothing || isempty(kids)) && return false
    is_sig(kids[1])
end

# A struct body allows inner constructors only: a `function` form, or a short-form method (`S(x) = ...`).
# A typed field default (`x::T = v`) is a signature-shaped assignment but not a constructor.
function is_inner_constructor(n)
    k = JS.kind(n)
    k == K"function" && return true
    k == K"=" || return false
    kids = child_nodes(n)
    (kids === nothing || isempty(kids) || !is_sig(kids[1])) && return false
    sig_name(kids[1]) !== nothing
end

# The name a signature defines. A dotted head (`Base.getindex`) is a method on a foreign module's generic:
# the dispatch that reaches it is that module's, so it is not a name this module owns.
function sig_name(sig)
    kids = child_nodes(sig)
    kids === nothing && return nothing
    kd = JS.kind(sig)
    (kd == K"where" || kd == K"::") && return sig_name(kids[1])
    kd == K"call" || return nothing
    head = kids[1]
    head.val isa Symbol && return head.val
    JS.kind(head) == K"curly" ? type_name(head) : nothing   # S{T}(x) names S
end

# A qualified generic identifies a method site without declaring a locally owned function.
function qualified_method_name(sig)
    kd = JS.kind(sig)
    if kd == K"where" || kd == K"::"
        return qualified_method_name(child_nodes(sig)[1])
    end
    kd == K"call" || return nothing
    head = first(child_nodes(sig))
    JS.kind(head) == K"." || return nothing
    Symbol(JS.sourcetext(head))
end

# Receiver type of `(x::T)(...)` and `(::T)(...)`.
function callable_receiver(sig)
    kd = JS.kind(sig)
    (kd == K"where" || kd == K"::") && return callable_receiver(child_nodes(sig)[1])
    kd == K"call" || return nothing
    kids = child_nodes(sig)
    (kids === nothing || isempty(kids)) && return nothing
    head = kids[1]
    JS.kind(head) == K"::" || return nothing
    hk = child_nodes(head)
    (hk === nothing || isempty(hk)) && return nothing
    type_name(last(hk))
end

"One method's definition in its file: the name it defines, as `FileScan.refs` keys it, and the line it starts on."
struct MethodSite
    name::Symbol   # the def name, a qualified method name (`Base.show`) or a callable's receiver type
    line::Int      # source line of the definition
end

"""One call written in a method's body, closures and comprehensions included. Two calls with equal text in one
method ask one question: the text is the source as written, whitespace collapsed, with no name resolved."""
struct CallSite
    callee::Symbol       # the called name: `f` in `f(x)`, `g` in `M.g(x)`
    qualifier::String    # the module path written before the name, `M` in `M.g(x)`; "" for a bare call
    arguments::String    # positional argument source text in order, whitespace collapsed
    keywords::String     # keyword argument source text sorted by name, whitespace collapsed
    line::Int            # source line of the call
    loop_depth::Int      # loops, comprehensions and generators enclosing the call within its method
end

# One file's top-level defs and, per def, the names its body references - closures included.
struct FileScan
    funcs::Vector{Symbol}
    types::Vector{Symbol}
    refs::Dict{Symbol,Set{Symbol}}   # definition or qualified method -> referenced names; structs include field types and constructors
    modrefs::Set{Symbol}             # names referenced outside any function (module-level code, field names)
    line::Dict{Symbol,Int}           # def-name -> source line
    argtypes::Dict{Symbol,Vector{Union{Symbol,Nothing}}}   # function -> positional arg declared-types (last method wins)
    tupletail::Dict{Symbol,Int}      # function -> slot count when its body ends in a bare tuple; absent otherwise
    imports::Set{Symbol}             # names this file's `import` clauses bind: a path's last name, or its `as` alias
    callsites::Dict{MethodSite,Vector{CallSite}}   # each method -> the calls its body writes, in source order
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
    if k == K"parameters" || k == K"tuple" || k == K"braces"
        kids = child_nodes(a)
        kids === nothing && return
        for c in kids; _argname!(names, c); end
    elseif k == K"::"
        kk = child_nodes(a)
        (kk === nothing || length(kk) < 2) && return   # `::T` binds nothing; `x::T` names x
        _argname!(names, kk[1])
    elseif k == K"<:" || k == K">:"
        kk = child_nodes(a)
        (kk === nothing || isempty(kk)) && return
        _argname!(names, kk[1])
    elseif k == K"=" || k == K"..."
        kk = child_nodes(a)
        (kk === nothing || isempty(kk)) || _argname!(names, kk[1])
    elseif a.val isa Symbol
        push!(names, a.val)
    end
end

# Type variables on `where` clauses, including nested and bounded (`T<:Integer`) forms.
function where_vars!(names, sig)
    kd = JS.kind(sig)
    kd == K"::" && return where_vars!(names, child_nodes(sig)[1])
    kd == K"where" || return
    kids = child_nodes(sig)
    kids === nothing && return
    where_vars!(names, kids[1])
    for v in kids[2:end]; _argname!(names, v); end
end

# A callable's receiver, `(x::T)(...)`, binds `x` the way an argument does.
function bind_receiver!(names, head)
    JS.kind(head) == K"::" || return
    _argname!(names, head)
end

function sig_argnames(sig)
    names = Symbol[]
    where_vars!(names, sig)
    kd = JS.kind(sig)
    while kd == K"where" || kd == K"::"
        sig = child_nodes(sig)[1]
        kd = JS.kind(sig)
    end
    kd == K"call" || return names
    kids = child_nodes(sig)
    kids === nothing && return names
    bind_receiver!(names, kids[1])
    for a in kids[2:end]; _argname!(names, a); end
    names
end

function is_method_form(n)
    k = JS.kind(n)
    k == K"function" && return true
    k == K"=" || return false
    kids = child_nodes(n)
    kids !== nothing && !isempty(kids) && is_sig(kids[1])
end

# A node whose children are values: a call's arguments, a parameter list's defaults, a tuple's members.
function holds_values(kind)
    kind == K"call" || kind == K"parameters" || kind == K"tuple"
end

function is_nested_scope(n)
    k = JS.kind(n)
    k == K"->" || k == K"do" || k == K"let" || k == K"for" || k == K"while" ||
        k == K"try" || k == K"generator" || k == K"comprehension" || is_method_form(n)
end

# Assignments and nested method names in this scope. Nested function/let/loop/try/comprehension keep theirs.
function collect_scope_assigns!(bound, n)
    if is_method_form(n)
        nm = sig_name(child_nodes(n)[1])
        nm !== nothing && push!(bound, nm)
        return
    end
    is_nested_scope(n) && return
    k = JS.kind(n)
    kids = child_nodes(n)
    if k == K"="
        (kids === nothing || isempty(kids)) && return
        _argname!(bound, kids[1])
        length(kids) >= 2 && collect_scope_assigns!(bound, kids[2])
        return
    elseif k == K"local"
        kids === nothing && return
        for c in kids; _argname!(bound, c); end
        return
    elseif holds_values(k)
        walk_value_children!(c -> collect_scope_assigns!(bound, c), n)
        return
    end
    kids === nothing && return
    for c in kids
        collect_scope_assigns!(bound, c)
    end
end

function collect_scope_globals!(names, n)
    is_nested_scope(n) && return
    k = JS.kind(n)
    kids = child_nodes(n)
    if k == K"global"
        kids === nothing && return
        for c in kids; _argname!(names, c); end
        return
    end
    kids === nothing && return
    for c in kids
        collect_scope_globals!(names, c)
    end
end

function nested_bound(outer, extra, body)
    bound = copy(outer)
    union!(bound, extra)
    collect_scope_assigns!(bound, body)
    globals = Symbol[]
    collect_scope_globals!(globals, body)
    setdiff!(bound, globals)
    bound
end

# One scope of the source walk: which def the refs belong to, and which method the calls belong to.
struct ScanScope
    target::Symbol                    # refs key for the body being walked
    bound::Set{Symbol}                # names bound in this scope
    depth::Int                        # function-def nesting
    loop_depth::Int                   # repeating for, while and generator scopes around the node
    site::Union{Nothing,MethodSite}   # method the calls belong to; nothing on a name-resolution walk
end

function with_bound(scope::ScanScope, bound)
    ScanScope(scope.target, bound, scope.depth, scope.loop_depth, scope.site)
end

function deeper(scope::ScanScope)
    ScanScope(scope.target, scope.bound, scope.depth + 1, scope.loop_depth, scope.site)
end

function enter_closure(scope::ScanScope, bound)
    ScanScope(scope.target, bound, scope.depth + 1, scope.loop_depth, scope.site)
end

function enter_loop(scope::ScanScope, bound)
    ScanScope(scope.target, bound, scope.depth, scope.loop_depth + 1, scope.site)
end

function retarget(scope::ScanScope, target, bound)
    ScanScope(target, bound, scope.depth + 1, scope.loop_depth, scope.site)
end

function walk_iteration!(fs, n, scope, on_qualified = nothing)
    k = JS.kind(n)
    kids = child_nodes(n)
    kids === nothing && return
    if k == K"in" || k == K"="
        if length(kids) >= 2
            walk_scoped!(fs, kids[2], scope, on_qualified)
        end
        _argname!(scope.bound, kids[1])
        return
    end
    for c in kids
        walk_iteration!(fs, c, scope, on_qualified)
    end
end

function walk_dot_base!(walk, n)
    kids = child_nodes(n)
    (kids === nothing || length(kids) != 2) && return false
    walk(kids[1])
    true
end

function walk_value_children!(walk, n)
    kids = child_nodes(n)
    kids === nothing && return
    for c in kids
        ck = child_nodes(c)
        if JS.kind(c) == K"=" && ck !== nothing && length(ck) == 2
            walk(ck[2])
        else
            walk(c)
        end
    end
end

# Bindings stay silent; index targets, type annotations and property bases are references.
function walk_assign_lhs!(fs, n, scope, on_qualified = nothing)
    k = JS.kind(n)
    kids = child_nodes(n)
    kids === nothing && return
    if k == K"::"
        if length(kids) >= 2
            walk_scoped!(fs, last(kids), scope, on_qualified)
        end
        if length(kids) == 1
            walk_scoped!(fs, kids[1], scope, on_qualified)
        end
    elseif k == K"."
        walk_scoped!(fs, n, scope, on_qualified)
    elseif k == K"=" || k == K"..."
        if !isempty(kids)
            walk_assign_lhs!(fs, kids[1], scope, on_qualified)
        end
    elseif k == K"ref" || k == K"call" || k == K"dotcall"
        walk_scoped!(fs, n, scope, on_qualified)
    elseif k == K"tuple" || k == K"parameters"
        for c in kids
            walk_assign_lhs!(fs, c, scope, on_qualified)
        end
    end
end

function source_line(node)
    location = JS.source_location(node)
    Int(location[1])
end

function needs_token_collapse(text)
    for char in text
        if char == '#' || char == '"' || char == '\'' || char == '`'
            return true
        end
    end
    false
end

function already_collapsed(text)
    isempty(text) && return true
    if isspace(first(text)) || isspace(last(text))
        return false
    end
    previous_space = false
    for char in text
        if isspace(char)
            if previous_space || char != ' '
                return false
            end
            previous_space = true
        else
            previous_space = false
        end
    end
    true
end

function collapse_plain(text)
    buffer = IOBuffer()
    pending_space = false
    started = false
    for char in text
        if isspace(char)
            if started
                pending_space = true
            end
        else
            if pending_space
                print(buffer, ' ')
                pending_space = false
            end
            print(buffer, char)
            started = true
        end
    end
    String(take!(buffer))
end

function collapsed_tokens(text)
    buffer = IOBuffer()
    pending_space = false
    started = false
    for token in JS.tokenize(text)
        kind = JS.kind(token)
        if kind == K"Comment"
            continue
        end
        if kind == K"Whitespace" || kind == K"NewlineWs"
            if started
                pending_space = true
            end
            continue
        end
        if pending_space
            print(buffer, ' ')
            pending_space = false
        end
        piece = JS.untokenize(token, text)
        print(buffer, piece)
        started = true
    end
    String(take!(buffer))
end

function collapse_source(text)::String
    if needs_token_collapse(text)
        return collapsed_tokens(text)
    end
    if already_collapsed(text)
        return String(text)
    end
    collapse_plain(text)
end

function operator_token(node)
    value = node.val
    value isa Symbol && Base.isoperator(value)
end

# Infix and prefix operators are calls. A trailing operator is the postfix form.
function is_operator_call(node)
    JS.is_infix_op_call(node) && return true
    JS.is_prefix_op_call(node) && return true
    JS.is_prefix_call(node) && return false
    kids = child_nodes(node)
    (kids === nothing || isempty(kids)) && return false
    operator_token(last(kids))
end

struct WrittenCallee
    callee::Symbol      # called name
    qualifier::String   # module path written before the name; empty when the call is bare
end

# Callee text exists for a bare name, a type application (`S{T}`) and a dotted name.
function name_of_head(head)
    if head.val isa Symbol
        return WrittenCallee(head.val, "")
    end
    kind = JS.kind(head)
    if kind == K"curly"
        name = type_name(head)
        isnothing(name) && return nothing
        return WrittenCallee(name, "")
    end
    kind == K"." || return nothing
    kids = child_nodes(head)
    kids === nothing && return nothing
    if length(kids) == 1
        member = kids[1]
        member.val isa Symbol || return nothing
        return WrittenCallee(member.val, "")
    end
    length(kids) == 2 || return nothing
    member = kids[2]
    member.val isa Symbol || return nothing
    raw = JS.sourcetext(kids[1])
    qualifier = collapse_source(raw)
    WrittenCallee(member.val, qualifier)
end

function keyword_name(node)
    value = node.val
    value isa Symbol && return value
    kind = JS.kind(node)
    names_a_child = kind == K"=" || kind == K"..." || kind == K"::" || kind == K"<:" || kind == K">:"
    names_a_child || return nothing
    kids = child_nodes(node)
    (kids === nothing || isempty(kids)) && return nothing
    keyword_name(kids[1])
end

function arguments_text(kids, op_form::Bool)
    parts = String[]
    for index in eachindex(kids)
        child = kids[index]
        if index == 1 && !op_form
            continue
        end
        if JS.kind(child) == K"parameters"
            continue
        end
        if op_form && operator_token(child)
            continue
        end
        raw = JS.sourcetext(child)
        push!(parts, collapse_source(raw))
    end
    join(parts, ", ")
end

function keywords_text(kids)
    index = findfirst(child -> JS.kind(child) == K"parameters", kids)
    isnothing(index) && return ""
    params = kids[index]
    pkids = child_nodes(params)
    pkids === nothing && return ""
    named = Pair{Symbol,String}[]
    for param in pkids
        name = keyword_name(param)
        isnothing(name) && continue
        raw = JS.sourcetext(param)
        text = collapse_source(raw)
        push!(named, name => text)
    end
    ordered = sort(named; by = first)
    texts = String[]
    for pair in ordered
        push!(texts, pair.second)
    end
    join(texts, ", ")
end

function operator_callee(node)
    kids = child_nodes(node)
    kids === nothing && return nothing
    if JS.is_prefix_op_call(node)
        head = first(kids)
        head.val isa Symbol || return nothing
        return head.val
    end
    for child in kids
        if operator_token(child)
            return child.val
        end
    end
    nothing
end

function push_call!(callsites, site, call)
    calls = get!(Vector{CallSite}, callsites, site)
    push!(calls, call)
end

function record_written!(fs, callee::Symbol, qualifier::String, kids, op_form::Bool, node, scope)
    arguments = arguments_text(kids, op_form)
    keywords = keywords_text(kids)
    line = source_line(node)
    call = CallSite(callee, qualifier, arguments, keywords, line, scope.loop_depth)
    push_call!(fs.callsites, scope.site, call)
end

function record_operator!(fs, node, scope)
    callee = operator_callee(node)
    isnothing(callee) && return
    kids = child_nodes(node)
    kids === nothing && return
    record_written!(fs, callee, "", kids, true, node, scope)
end

function record_named!(fs, node, scope)
    kids = child_nodes(node)
    (kids === nothing || isempty(kids)) && return
    naming = name_of_head(kids[1])
    isnothing(naming) && return
    record_written!(fs, naming.callee, naming.qualifier, kids, false, node, scope)
end

function record_call!(fs, node, scope)
    isnothing(scope.site) && return
    if is_operator_call(node)
        record_operator!(fs, node, scope)
    else
        record_named!(fs, node, scope)
    end
end

# A filter's iterator stays in `scope`. Its predicate is walked in `body`.
function walk_gen_spec!(fs, n, scope, body, on_qualified = nothing)
    if JS.kind(n) != K"filter"
        walk_iteration!(fs, n, scope, on_qualified)
        return
    end
    kids = child_nodes(n)
    kids === nothing && return
    for child in kids
        kind = JS.kind(child)
        if kind == K"iteration" || kind == K"in" || kind == K"="
            walk_iteration!(fs, child, scope, on_qualified)
        else
            walk_scoped!(fs, child, body, on_qualified)
        end
    end
end

function walk_scoped!(fs, n, scope, on_qualified = nothing)
    k = JS.kind(n)
    kids = child_nodes(n)
    if k == K"quote" && !isnothing(on_qualified)
        return
    elseif k == K"." && walk_dot_base!(c -> walk_scoped!(fs, c, scope, on_qualified), n)
        member = kids[2].val
        if member isa Symbol
            push!(fs.refs[scope.target], member)
            if !isnothing(on_qualified)
                line = source_line(n)
                on_qualified(kids[1], member, line, scope.bound)
            end
        end
        return
    elseif is_method_form(n)
        (kids === nothing || isempty(kids)) && return
        receiver = callable_receiver(kids[1])
        if receiver !== nothing && length(kids) >= 2
            inner = retarget(scope, receiver, Set{Symbol}())
            absorb_method!(fs, kids[1], kids[2], inner, on_qualified)
            return
        end
        if length(kids) >= 2
            inner = deeper(scope)
            absorb_method!(fs, kids[1], kids[2], inner, on_qualified)
        end
        return
    elseif k == K"->" || k == K"do"
        (kids === nothing || length(kids) < 2) && return
        if !isnothing(on_qualified)
            walk_assign_lhs!(fs, kids[1], scope, on_qualified)
        end
        extra = Symbol[]
        _argname!(extra, kids[1])
        body = kids[2]
        inner = nested_bound(scope.bound, extra, body)
        closed = enter_closure(scope, inner)
        walk_scoped!(fs, body, closed, on_qualified)
        return
    elseif k == K"let"
        kids === nothing && return
        nested = copy(scope.bound)
        here = with_bound(scope, nested)
        for (i, c) in enumerate(kids)
            ck = child_nodes(c)
            if JS.kind(c) == K"=" && ck !== nothing && length(ck) >= 2
                walk_scoped!(fs, ck[2], here, on_qualified)
                _argname!(nested, ck[1])
            elseif i == length(kids)
                collect_scope_assigns!(nested, c)
                globals = Symbol[]
                collect_scope_globals!(globals, c)
                setdiff!(nested, globals)
                walk_scoped!(fs, c, here, on_qualified)
            else
                walk_scoped!(fs, c, here, on_qualified)
            end
        end
        return
    elseif k == K"for" || k == K"while"
        # The header runs at this depth. The body is one level deeper.
        (kids === nothing || isempty(kids)) && return
        nested = copy(scope.bound)
        body = last(kids)
        header = with_bound(scope, nested)
        if k == K"for"
            for spec in kids[1:end-1]
                walk_iteration!(fs, spec, header, on_qualified)
            end
        else
            walk_scoped!(fs, kids[1], scope, on_qualified)
        end
        collect_scope_assigns!(nested, body)
        globals = Symbol[]
        collect_scope_globals!(globals, body)
        setdiff!(nested, globals)
        body_scope = enter_loop(scope, nested)
        walk_scoped!(fs, body, body_scope, on_qualified)
        return
    elseif k == K"try"
        kids === nothing && return
        for c in kids
            nested = copy(scope.bound)
            ck = child_nodes(c)
            if JS.kind(c) == K"catch" && ck !== nothing && !isempty(ck)
                JS.kind(ck[1]) != K"block" && _argname!(nested, ck[1])
            end
            collect_scope_assigns!(nested, c)
            globals = Symbol[]
            collect_scope_globals!(globals, c)
            setdiff!(nested, globals)
            clause = with_bound(scope, nested)
            walk_scoped!(fs, c, clause, on_qualified)
        end
        return
    elseif k == K"comprehension"
        (kids === nothing || isempty(kids)) && return
        walk_scoped!(fs, kids[1], scope, on_qualified)
        return
    elseif k == K"generator"
        # One scope. The wrapper around a generator adds none, and the first iterator stays outside.
        (kids === nothing || isempty(kids)) && return
        nested = copy(scope.bound)
        header = with_bound(scope, nested)
        inside = enter_loop(scope, nested)
        specs = kids[2:end]
        if !isempty(specs)
            walk_gen_spec!(fs, specs[1], header, inside, on_qualified)
        end
        for spec in specs[2:end]
            walk_gen_spec!(fs, spec, inside, inside, on_qualified)
        end
        walk_scoped!(fs, kids[1], inside, on_qualified)
        return
    elseif k == K"global" || k == K"local"
        kids === nothing && return
        for declaration in kids
            if JS.kind(declaration) == K"="
                walk_scoped!(fs, declaration, scope, on_qualified)
            else
                walk_assign_lhs!(fs, declaration, scope, on_qualified)
            end
        end
        return
    elseif k == K"=" && kids !== nothing && length(kids) >= 2 && !is_sig(kids[1])
        walk_assign_lhs!(fs, kids[1], scope, on_qualified)
        walk_scoped!(fs, kids[2], scope, on_qualified)
        return
    elseif k == K"call" || k == K"dotcall" || k == K"parameters" || k == K"tuple"
        if k == K"call" || k == K"dotcall"
            record_call!(fs, n, scope)
        end
        n.val isa Symbol && !(n.val in scope.bound) && push!(fs.refs[scope.target], n.val)
        walk_value_children!(c -> walk_scoped!(fs, c, scope, on_qualified), n)
        return
    end
    n.val isa Symbol && !(n.val in scope.bound) && push!(fs.refs[scope.target], n.val)
    kids === nothing && return
    for c in kids
        walk_scoped!(fs, c, scope, on_qualified)
    end
end

# the type names in each `x::T` field decl (const-wrapped included). Inner-constructor bodies are not
# fields: the struct walk attaches them to this type's refs, same owner as the field types.
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

# Default RHS refs in signature order: positionals, then keyword `parameters`.
# Each value is filtered by where-typevars plus the names of arguments to its left.
function absorb_defaults!(fs, sig, scope, on_qualified = nothing)
    prefix = copy(scope.bound)
    where_vars!(prefix, sig)
    annotation_bound = copy(prefix)
    noted = with_bound(scope, annotation_bound)
    valued = with_bound(scope, prefix)
    kd = JS.kind(sig)
    while kd == K"where" || kd == K"::"
        if !isnothing(on_qualified)
            for annotation in child_nodes(sig)[2:end]
                walk_scoped!(fs, annotation, noted, on_qualified)
            end
        end
        sig = child_nodes(sig)[1]
        kd = JS.kind(sig)
    end
    kd == K"call" || return
    kids = child_nodes(sig)
    kids === nothing && return
    if !isnothing(on_qualified)
        walk_scoped!(fs, kids[1], noted, on_qualified)
    end
    bind_receiver!(prefix, kids[1])
    for a in kids[2:end]
        args = JS.kind(a) == K"parameters" ? child_nodes(a) : (a,)
        args === nothing && continue
        for arg in args
            if !isnothing(on_qualified)
                walk_assign_lhs!(fs, arg, noted, on_qualified)
            end
            if JS.kind(arg) == K"="
                rhs = child_nodes(arg)
                if rhs !== nothing && length(rhs) >= 2
                    walk_scoped!(fs, rhs[2], valued, on_qualified)
                end
            end
            _argname!(prefix, arg)
        end
    end
end

# Body refs minus this method's bindings, union default-value refs.
function absorb_method!(fs, sig, body, scope, on_qualified = nothing)
    get!(fs.refs, scope.target, Set{Symbol}())
    bound = copy(scope.bound)
    union!(bound, sig_argnames(sig))
    collect_scope_assigns!(bound, body)
    globals = Symbol[]
    collect_scope_globals!(globals, body)
    setdiff!(bound, globals)
    absorb_defaults!(fs, sig, scope, on_qualified)
    body_scope = with_bound(scope, bound)
    walk_scoped!(fs, body, body_scope, on_qualified)
end

# depth counts function-def nesting; only defs at depth 0 are top-level (a local closure's def is not).
function walk_defs!(fs, n, depth, current)
    n.val isa Symbol && push!(current === nothing ? fs.modrefs : fs.refs[current], n.val)
    kids = child_nodes(n); kids === nothing && return
    k = JS.kind(n)
    if k == K"." && walk_dot_base!(c -> walk_defs!(fs, c, depth, current), n)
        member = kids[2].val
        member isa Symbol && push!(current === nothing ? fs.modrefs : fs.refs[current], member)
        return
    elseif k == K"export" || k == K"public"
        return   # a listed name, not a call, a value read, or a qualified access
    elseif k == K"import"
        # `import A: f, g as h` lists its items after the path; `import A.f` and `import A.f as h` are the item.
        # An item's last child is the name it binds: a path's last segment, or the `as` alias.
        for clause in kids
            items = JS.kind(clause) == K":" ? child_nodes(clause)[2:end] : [clause]
            for item in items
                parts = child_nodes(item)
                bound = last(parts).val
                bound isa Symbol && push!(fs.imports, bound)
            end
        end
        for c in kids; walk_defs!(fs, c, depth, current); end
    elseif k == K"struct" || k == K"abstract"
        nm = type_name(first(kids))
        if depth == 0 && nm !== nothing
            push!(fs.types, nm); fs.line[nm] = JS.source_location(n)[1]
            r = get!(fs.refs, nm, Set{Symbol}())                                       # a type's refs = the types it couples to
            JS.kind(first(kids)) == K"<:" && all_symbols!(r, child_nodes(first(kids))[2])    # supertype
            k == K"struct" && field_types!(r, last(kids))                              # field types
        end
        for c in kids
            if JS.kind(c) == K"block" && depth == 0 && nm !== nothing
                stmts = child_nodes(c)
                stmts === nothing && continue
                for stmt in stmts
                    owner = is_inner_constructor(stmt) ? nm : current
                    walk_defs!(fs, stmt, depth + 1, owner)
                end
            else
                walk_defs!(fs, c, depth + 1, current)
            end
        end
    elseif k == K"function" || (k == K"=" && !isempty(kids) && is_sig(kids[1]))
        nm = sig_name(kids[1])
        top = depth == 0 && nm !== nothing
        def_line = source_line(n)
        if top
            push!(fs.funcs, nm)
            if !haskey(fs.refs, nm)
                fs.refs[nm] = Set{Symbol}()
            end
            fs.line[nm] = def_line
            fs.argtypes[nm] = sig_argtypes(kids[1])
            slots = 0
            if length(kids) >= 2
                slots = tuple_tail_slots(kids[2])
            end
            if slots > 0
                fs.tupletail[nm] = slots
            end
        end
        if length(kids) >= 2
            receiver = callable_receiver(kids[1])
            qualified = qualified_method_name(kids[1])
            if top
                site = MethodSite(nm, def_line)
                opened = ScanScope(nm, Set{Symbol}(), depth + 1, 0, site)
                absorb_method!(fs, kids[1], kids[2], opened)
            elseif !isnothing(qualified)
                site = MethodSite(qualified, def_line)
                opened = ScanScope(qualified, Set{Symbol}(), depth + 1, 0, site)
                absorb_method!(fs, kids[1], kids[2], opened)
            elseif receiver !== nothing
                site = MethodSite(receiver, def_line)
                opened = ScanScope(receiver, Set{Symbol}(), depth + 1, 0, site)
                absorb_method!(fs, kids[1], kids[2], opened)
            elseif current !== nothing && current in fs.types
                site = MethodSite(current, def_line)
                opened = ScanScope(current, Set{Symbol}(), depth + 1, 0, site)
                absorb_method!(fs, kids[1], kids[2], opened)
            else
                walk_defs!(fs, kids[2], depth + 1, current)
            end
        end
    elseif k == K"->"
        for c in kids; walk_defs!(fs, c, depth + 1, current); end
    elseif holds_values(k)
        walk_value_children!(c -> walk_defs!(fs, c, depth, current), n)
    else
        for c in kids; walk_defs!(fs, c, depth, current); end
    end
end

empty_scan() = FileScan(Symbol[], Symbol[], Dict{Symbol,Set{Symbol}}(), Set{Symbol}(), Dict{Symbol,Int}(),
                        Dict{Symbol,Vector{Union{Symbol,Nothing}}}(), Dict{Symbol,Int}(), Set{Symbol}(),
                        Dict{MethodSite,Vector{CallSite}}())

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

# Visits every node with the name of the nearest enclosing top-level def ("" at module scope):
# `visit(node, enclosing_name)` answers which function an expression sits inside.
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

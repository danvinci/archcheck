# A declared derived value reaches only its readers and its converters: a wrapper struct on the typed code of the
# method graph, a bare number on the parse inside one method, and the wrapper's fields and constructor on the parse.

"""Runs in `CHECKS`. With no declared derived value it is quiet. A declared value reaches a function outside its readers and converters. A wrapper value needs `entries` on the gate."""
struct DerivedReaders <: Check end

kinds(::DerivedReaders) = (:unlisted_reader => :advisory,)

const MOVED_CALLEES = (
    :getfield, :getproperty, :setfield!, :setproperty!, :tuple,
    :apply_type, :typeassert, :isa, :typeof, :nfields, :fieldtype,
)

struct DerivedItem{P,R<:Tuple,V<:Tuple}
    producer::P                         # function that computes the value
    readers::R                          # functions allowed to receive the value
    converters::V                       # functions allowed to convert the value
    wrapper::Union{Nothing,DataType}    # struct returned; nothing for a number
    home::Symbol                        # module key of the producer's module
    label::String                       # producer name recorded in evidence
    findings::Vector{Finding}           # findings for this value
end

# One method's walk: what stays fixed while the walk descends its body.
struct MethodWalk{I<:DerivedItem}
    item::I                             # the declared value under check
    file::FileNode                      # file holding the method
    site::MethodSite                    # method the findings name
    known::Base.IdSet{JS.SyntaxNode}    # forms walked from their own sites
    home::Union{Nothing,Module}         # loaded module the file's names resolve in
    limits::Vector{Finding}             # exits that count only when no converter receives the value
end

struct HeldStep
    held::Set{Symbol}   # locals holding the value
    bridged::Bool       # a converter received the value in this method
end

function run(::DerivedReaders, ctx)
    findings = Finding[]
    for derived in ctx.derived
        shape = producer_shape(derived.producer)
        wrapper = shape.wrapper
        isnothing(wrapper) && !shape.numeric && continue
        if !isnothing(wrapper) && isnothing(ctx.methods)
            producer_name = nameof(derived.producer)
            throw(ArgumentError("DerivedReaders has no method graph entries for $producer_name"))
        end
        item = derived_item(derived, wrapper)
        isnothing(wrapper) || read_typed!(item, ctx)
        read_source!(item, ctx)
        append!(findings, item.findings)
    end
    findings
end

function producer_shape(producer)
    returns = Base.return_types(producer)
    numeric = false
    for candidate in returns
        for member in Base.uniontypes(candidate)
            body = Base.unwrap_unionall(member)
            if struct_body(body)
                return (wrapper = body, numeric = false)
            end
            numeric = numeric || number_body(body)
        end
    end
    (wrapper = nothing, numeric = numeric)
end

struct_body(@nospecialize(body)) = false

function struct_body(body::DataType)
    isconcretetype(body) || return false
    isstructtype(body) || return false
    !(body <: Number)
end

number_body(@nospecialize(body)) = false
number_body(body::DataType) = body <: Number

function derived_item(derived, wrapper)
    producer = derived.producer
    home = module_key(parentmodule(producer))
    label = string(nameof(producer))
    DerivedItem(producer, derived.readers, derived.converters, wrapper, home, label, Finding[])
end

function reached_methods(graph)
    methods = Set{Method}()
    for (caller, callees) in graph.edges
        push!(methods, caller)
        union!(methods, callees)
    end
    union!(methods, keys(graph.unresolved))
    methods
end

function read_typed!(item, ctx)
    seen = Set{NTuple{4,String}}()
    repo = ctx.index.repo
    for method in reached_methods(ctx.methods)
        root = Base.moduleroot(method.module)
        (root === Core || root === Base) && continue
        listed = Base.code_typed_by_type(method.sig; optimize = false)
        for entry in listed
            info = code_info_of(entry)
            isnothing(info) && continue
            for stmt in info.code
                scan_expr!(item, info, stmt, seen, method, repo)
            end
        end
    end
end

code_info_of(item::Pair{Core.CodeInfo}) = item.first
code_info_of(item::Core.CodeInfo) = item
code_info_of(@nospecialize(item)) = nothing

function scan_expr!(item, code, expr::Expr, seen, method, repo)
    head = expr.head
    args = expr.args
    if head === :invoke && length(args) >= 2
        read_args!(item, code, args[2:end], seen, method, repo)
    elseif head === :call
        read_args!(item, code, args, seen, method, repo)
    end
    for arg in args
        scan_expr!(item, code, arg, seen, method, repo)
    end
end

scan_expr!(item, code, @nospecialize(expr), seen, method, repo) = nothing

# `kwcall` names its callee in argument 3; `throw_methoderror` names it in argument 2 and its arguments follow.
function read_args!(item, code, args, seen, method, repo)
    isempty(args) && return
    head = resolve_callee(code, args[1])
    callee_at = 1
    carry_from = 2
    if head === Core.kwcall
        callee_at = 3
    elseif head isa Function && nameof(head) === :throw_methoderror
        callee_at = 2
        carry_from = 3
    end
    length(args) < max(callee_at, carry_from) && return
    carried = false
    for index in carry_from:length(args)
        kind = value_type_of(code, args[index])
        carried = carried || carries_type(kind, item.wrapper)
    end
    carried || return
    real = resolve_callee(code, args[callee_at])
    isnothing(real) && return
    skipped_callee(real) && return
    real in item.readers && return
    real in item.converters && return
    callee = callee_name(real)
    symbol = written_name(method.name)
    key = (symbol, callee, "code_typed", item.label)
    key in seen && return
    push!(seen, key)
    file, line = method_site(method, repo)
    owner = module_key(method.module)
    detail = "the producer's result is an argument of " * callee
    push_finding!(owner, file, symbol, line, item.label, callee, "code_typed", detail, item.findings)
end

skipped_callee(@nospecialize(value)) = false
skipped_callee(::Core.Builtin) = true
skipped_callee(::Core.IntrinsicFunction) = true
skipped_callee(value::Function) = nameof(value) in MOVED_CALLEES

function skipped_callee(@nospecialize(value::Type))
    body = Base.unwrap_unionall(value)
    body isa DataType && body.name.name === :NamedTuple
end

carries_type(@nospecialize(type), wrapper) = type === wrapper
carries_type(type::Union, wrapper) = carries_type(type.a, wrapper) || carries_type(type.b, wrapper)

function carries_type(@nospecialize(type::Type), wrapper)
    type === wrapper && return true
    body = Base.unwrap_unionall(type)
    body isa DataType || return false
    tuple_like = body <: Tuple
    named = body.name.name === :NamedTuple
    tuple_like || named || return false
    for param in body.parameters
        carries_type(param, wrapper) && return true
    end
    false
end

listed_type(types::Vector, index) = index in eachindex(types) ? types[index] : Any
listed_type(@nospecialize(types), index) = Any
slot_type(code, index) = isdefined(code, :slottypes) ? listed_type(code.slottypes, index) : Any
value_type_of(code, value::Core.SSAValue) = listed_type(code.ssavaluetypes, value.id)
value_type_of(code, value::Core.Argument) = slot_type(code, value.n)
value_type_of(code, value::Core.SlotNumber) = slot_type(code, value.id)
value_type_of(code, value::Core.Const) = typeof(value.val)
value_type_of(code, value::QuoteNode) = typeof(value.value)
value_type_of(code, @nospecialize(value)) = typeof(value)

function resolve_callee(code, head::Core.SSAValue)
    kind = listed_type(code.ssavaluetypes, head.id)
    kind isa Core.Const ? kind.val : nothing
end

resolve_callee(code, head::GlobalRef) = isdefined(head.mod, head.name) ? getfield(head.mod, head.name) : nothing
resolve_callee(code, head::Core.Const) = head.val
resolve_callee(code, head::QuoteNode) = head.value
resolve_callee(code, head::Function) = head
resolve_callee(code, head::Type) = head
resolve_callee(code, @nospecialize(head)) = nothing

callee_name(value::Function) = string(nameof(value))
callee_name(@nospecialize(value)) = string(value)

function callee_name(@nospecialize(value::Type))
    body = Base.unwrap_unionall(value)
    body isa DataType ? string(body.name.name) : string(body)
end

function push_finding!(mod, file, symbol, line, label, callee, via, detail, dest)
    evidence = Pair{Symbol,String}[:derived => label, :callee => callee, :via => via]
    finding = Finding(mod, :unlisted_reader, file, symbol, line, detail, evidence)
    push!(dest, finding)
end

function place!(walk, node, callee, via, detail, dest)
    line = source_line(node)
    symbol = string(walk.site.name)
    file = walk.file
    push_finding!(file.mod, file.path, symbol, line, walk.item.label, callee, via, detail, dest)
end

function note_field!(walk, node, callee)
    place!(walk, node, callee, "field", "a field of the struct is read", walk.item.findings)
end

function note_limit!(walk, node, callee)
    detail = "the producer's result leaves the method at a " * callee
    place!(walk, node, callee, "parse", detail, walk.limits)
end

# The value a dotted path names from `mod`; nothing when a segment is missing or an inner one is no module.
function resolve_path(mod::Module, segments)
    isempty(segments) && return mod
    name = segments[1]
    isdefined(mod, name) || return nothing
    next = getfield(mod, name)
    rest = segments[2:end]
    isempty(rest) && return next
    resolve_path(next, rest)
end

resolve_path(@nospecialize(value), segments) = nothing

function file_home(root, key)
    segments = key_segments(key)
    found = resolve_path(root, segments)
    found isa Module ? found : nothing
end

function resolve_name(home, written)
    isnothing(home) && return nothing
    isnothing(written) && return nothing
    segments = Symbol[]
    qualifier = written.qualifier
    if !isempty(qualifier)
        append!(segments, key_segments(Symbol(qualifier)))
    end
    push!(segments, written.callee)
    resolve_path(home, segments)
end

function read_source!(item, ctx)
    for file in ctx.index.files
        home = file_home(ctx.root, file.mod)
        forms = values(file.scan.forms)
        known = Base.IdSet{JS.SyntaxNode}(forms)
        for (site, form) in file.scan.forms
            walk = MethodWalk(item, file, site, known, home, Finding[])
            walk_body!(walk, form, Set{Symbol}())
        end
    end
end

# Walks a method's body; its limits count only when no converter received the value there.
function walk_body!(walk, form, outer)
    body = method_body(form)
    isnothing(body) && return
    bound = child_locals(form, 2, outer)
    held = seeded_held(walk.item, form)
    stepped = walk_node(walk, body, bound, held)
    stepped.bridged || append!(walk.item.findings, walk.limits)
end

function seeded_held(item, form)
    held = Set{Symbol}()
    wrapper = item.wrapper
    isnothing(wrapper) && return held
    struct_name = nameof(wrapper)
    kids = child_nodes(form)
    (isnothing(kids) || isempty(kids)) && return held
    call = signature_call(kids[1])
    isnothing(call) && return held
    args = child_nodes(call)
    isnothing(args) && return held
    for arg in args
        argtype_of(arg) === struct_name || continue
        name = bound_name(arg)
        isnothing(name) || push!(held, name)
    end
    held
end

function bound_name(node)
    names = Symbol[]
    _argname!(names, node)
    isempty(names) && return nothing
    first(names)
end

symbol_held(node, held) = node.val isa Symbol && node.val in held

function callee_of(node)
    kids = child_nodes(node)
    (isnothing(kids) || isempty(kids)) && return nothing
    name_of_head(kids[1])
end

function keeps_held(walk, rhs, held)
    rhs.val isa Symbol && return rhs.val in held
    JS.kind(rhs) == K"call" || return false
    written = callee_of(rhs)
    isnothing(written) && return false
    resolved = resolve_name(walk.home, written)
    resolved === walk.item.producer
end

# Outside the producer's module, building the wrapper or reading a field with `getfield` is a finding.
function note_struct_call!(walk, node, written, held)
    wrapper = walk.item.wrapper
    isnothing(wrapper) && return false
    walk.file.mod === walk.item.home && return false
    isnothing(written) && return false
    if written.callee === nameof(wrapper)
        note_field!(walk, node, string(written.callee))
        return true
    end
    written.callee === :getfield || return false
    for value in passed_values(node)
        symbol_held(value, held) || continue
        note_field!(walk, node, "getfield")
        return true
    end
    false
end

# Returns whether the callee is a converter, which bridges the method's limits.
function note_receive!(walk, node, resolved, written)
    isnothing(written) && return false
    item = walk.item
    !isnothing(resolved) && resolved in item.converters && return true
    !isnothing(resolved) && resolved in item.readers && return false
    callee = string(written.callee)
    detail = "the producer's result is an argument of " * callee
    place!(walk, node, callee, "parse", detail, item.findings)
    false
end

function walk_node(walk, node, bound, held)
    if is_method_form(node)
        return walk_local_method(walk, node, bound, held)
    end
    kind = JS.kind(node)
    kids = child_nodes(node)
    isnothing(kids) && return HeldStep(held, false)
    kind == K"=" && return walk_assign(walk, node, kids, bound, held)
    (kind == K"return" || kind == K"...") && return walk_leave(walk, node, kids, bound, held)
    kind == K"dotcall" && return walk_broadcast(walk, node, kids, bound, held)
    kind == K"call" && return walk_call(walk, node, bound, held)
    if kind == K"."
        read = walk_field(walk, node, kids, held)
        isnothing(read) || return read
    end
    walk_scope(walk, node, kids, bound, held)
end

# A local method holds its own locals and limits; a form recorded on its own site is walked from there.
function walk_local_method(walk, node, bound, held)
    node in walk.known && return HeldStep(held, false)
    inner = MethodWalk(walk.item, walk.file, walk.site, walk.known, walk.home, Finding[])
    walk_body!(inner, node, bound)
    HeldStep(held, false)
end

function walk_assign(walk, node, kids, bound, held)
    length(kids) < 2 && return HeldStep(held, false)
    lhs = kids[1]
    rhs = kids[end]
    rhs_bound = child_locals(node, length(kids), bound)
    stepped = walk_node(walk, rhs, rhs_bound, held)
    if JS.kind(lhs) == K"."
        symbol_held(rhs, held) && note_limit!(walk, node, "field")
        return HeldStep(held, stepped.bridged)
    end
    name = bound_name(lhs)
    isnothing(name) && return HeldStep(held, stepped.bridged)
    next = setdiff(held, (name,))
    keeps_held(walk, rhs, held) && push!(next, name)
    HeldStep(next, stepped.bridged)
end

function walk_leave(walk, node, kids, bound, held)
    isempty(kids) && return HeldStep(held, false)
    inner = kids[1]
    if symbol_held(inner, held)
        leave = JS.kind(node) == K"return" ? "return" : "splat"
        note_limit!(walk, node, leave)
        return HeldStep(held, false)
    end
    inner_bound = child_locals(node, 1, bound)
    walk_node(walk, inner, inner_bound, held)
end

function walk_broadcast(walk, node, kids, bound, held)
    bridged = false
    hit = false
    for index in eachindex(kids)
        child = kids[index]
        if symbol_held(child, held)
            hit = true
            continue
        end
        child_bound = child_locals(node, index, bound)
        stepped = walk_node(walk, child, child_bound, held)
        bridged = bridged || stepped.bridged
    end
    hit && note_limit!(walk, node, "broadcast")
    HeldStep(held, bridged)
end

function walk_call(walk, node, bound, held)
    written = callee_of(node)
    resolved = resolve_name(walk.home, written)
    handled = note_struct_call!(walk, node, written, held)
    bridged = false
    for value in passed_values(node)
        if symbol_held(value, held) && !handled
            bridged = note_receive!(walk, node, resolved, written) || bridged
        else
            stepped = walk_node(walk, value, bound, held)
            bridged = bridged || stepped.bridged
        end
    end
    HeldStep(held, bridged)
end

function walk_field(walk, node, kids, held)
    item = walk.item
    isnothing(item.wrapper) && return nothing
    walk.file.mod === item.home && return nothing
    length(kids) < 2 && return nothing
    symbol_held(kids[1], held) || return nothing
    member = kids[2]
    member.val isa Symbol || return nothing
    note_field!(walk, node, string(member.val))
    HeldStep(held, false)
end

# A block passes each statement's held set to the next; a let passes its bindings into its body. A name a child
# binds itself, or that its scope introduces, shadows the held local there.
function walk_scope(walk, node, kids, bound, held)
    kind = JS.kind(node)
    bridged = false
    current = held
    last_index = length(kids)
    for index in eachindex(kids)
        child_bound = child_locals(node, index, bound)
        names = child_bindings(node, index)
        if !(kind == K"let" && index == last_index)
            introduced = setdiff(child_bound, bound)
            union!(names, introduced)
        end
        child_held = setdiff(current, names)
        stepped = walk_node(walk, kids[index], child_bound, child_held)
        bridged = bridged || stepped.bridged
        if kind == K"block" || (kind == K"let" && index < last_index)
            current = stepped.held
        end
    end
    if kind == K"let" || kind == K"->" || kind == K"do" || kind == K"for"
        return HeldStep(held, bridged)
    end
    HeldStep(current, bridged)
end

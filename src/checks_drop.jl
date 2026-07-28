# Uncounted silent drop: a validity guard (UPPER_SNAKE threshold trip, or an _ok/_sane/_valid call)
# discarding input via return/continue with no counter, fault, or reason code anywhere to say so.

const VALIDITY_COMPARISONS = Set((:(<), :(>), :(<=), :(>=), :(==), :(!=)))
const INSTRUMENTED_MARKERS = r"warn|error|counter|fault|record"i

function is_upper_const_name(sym::Symbol)
    name = string(sym)
    occursin(r"^[A-Z][A-Z0-9_]*$", name) && occursin('_', name)
end

# No generic is*-prefix match on purpose: a per-element `isnan(x) && continue` is routine float
# hygiene rather than an input-validity fault, and it is the largest single guard source in most code.
const VALIDITY_SUFFIXES = ("_ok", "_sane", "_valid")

function is_validity_predicate_name(sym::Symbol)
    lowered = lowercase(string(sym))
    any(suffix -> endswith(lowered, suffix), VALIDITY_SUFFIXES)
end

# peel a leading unary `!`, so `!ok(x)` and `ok(x)` inspect the same call.
function unwrap_not(n)
    JS.kind(n) == K"call" || return n
    kids = child_nodes(n)
    (kids !== nothing && length(kids) == 2 && kids[1].val === :!) ? kids[2] : n
end

# a threshold trip (comparison naming an UPPER_SNAKE constant), or a call to a project-defined
# _ok/_sane/_valid predicate.
function is_validity_guard(n)
    op = infix_op(n)
    if op in VALIDITY_COMPARISONS
        kids = child_nodes(n)
        operand_before = kids[1]
        operand_after = kids[3]
        before_is_threshold = operand_before.val isa Symbol && is_upper_const_name(operand_before.val)
        after_is_threshold = operand_after.val isa Symbol && is_upper_const_name(operand_after.val)
        return before_is_threshold || after_is_threshold
    end
    target = unwrap_not(n)
    JS.kind(target) == K"call" || return false
    kids = child_nodes(target)
    (kids === nothing || isempty(kids)) && return false
    head = kids[1].val
    head isa Symbol && is_validity_predicate_name(head)
end

# A def's own parameters (`counters::FaultCounters`) are how it gains fault access, so this scans
# every node itself rather than reusing FileScan.refs, which excludes a def's own parameter names.
function marked_functions(tree)
    marked = Set{Symbol}()
    walk_with_enclosing(tree) do n, enclosing
        n.val isa Symbol || return
        name = string(n.val)
        occursin(INSTRUMENTED_MARKERS, name) && push!(marked, enclosing)
    end
    marked
end

# a threaded reason code: returning a struct that names an UPPER_SNAKE cause traces WHY even with no
# counter alongside it, unlike a bare `return` / `return nothing` / `return last_value`.
function carries_reason_code(action)
    JS.kind(action) == K"return" || return false
    kids = child_nodes(action)
    (kids === nothing || isempty(kids)) && return false
    names = Symbol[]
    all_symbols!(names, kids[1])
    any(is_upper_const_name, names)
end

# A guard whose "already valid" branch returns one of the def's own parameters unchanged is a fast
# path for good input, not a drop.
function is_passthrough_return(action, own_params)
    JS.kind(action) == K"return" || return false
    kids = child_nodes(action)
    (kids === nothing || isempty(kids)) && return false
    value = kids[1]
    value.val isa Symbol && value.val in own_params
end

# Every def's own parameter names, for the pass-through-return check above. Recurses through macro
# wrappers (`@inline function foo(...)`), which sit one level above the def itself.
function function_params(n, params = Dict{Symbol,Set{Symbol}}())
    kids = child_nodes(n)
    k = JS.kind(n)
    if k == K"function" || (k == K"=" && kids !== nothing && !isempty(kids) && is_sig(kids[1]))
        sig = kids[1]
        nm = sig_name(sig)
        nm === nothing || (params[nm] = Set(sig_argnames(sig)))
    end
    kids === nothing && return params
    for c in kids
        function_params(c, params)
    end
    params
end

is_drop_statement(n) = JS.kind(n) in (K"return", K"continue")

# the return/continue among a block's own direct statements: `if cond; @warn(...); continue; end`.
function drop_action_of(block)
    is_drop_statement(block) && return block
    JS.kind(block) == K"block" || return nothing
    kids = child_nodes(block)
    kids === nothing && return nothing
    idx = findfirst(is_drop_statement, kids)
    idx === nothing ? nothing : kids[idx]
end

# `cond || return` / `cond && continue` (terse guard clause), or `if cond ... return/continue end`
# (block form): the two idioms for a validity-guarded early exit.
function guard_shape(n)
    kind = JS.kind(n)
    kids = child_nodes(n)
    if kind == K"||" || kind == K"&&"
        (kids === nothing || length(kids) != 2) && return nothing
        cond = kids[1]
        action = kids[2]
        is_drop_statement(action) ? (cond, action) : nothing
    elseif kind == K"if"
        (kids === nothing || length(kids) < 2) && return nothing
        cond = kids[1]
        then_block = kids[2]
        action = drop_action_of(then_block)
        action === nothing ? nothing : (cond, action)
    else
        nothing
    end
end

function check_drop_guard!(findings, f, enclosing, marked, params, n)
    shape = guard_shape(n)
    shape === nothing && return
    cond, action = shape
    is_validity_guard(cond) || return
    carries_reason_code(action) && return
    own_params = get(params, enclosing, Set{Symbol}())
    is_passthrough_return(action, own_params) && return
    enclosing in marked && return
    line = JS.source_location(n)[1]
    detail = "a validity guard discards its input with no counter increment or fault " *
             "emission anywhere in $(enclosing)"
    owner = string(enclosing)
    push!(findings, Finding(f.mod, :uncounted_drop, f.path, owner, line, detail))
end

function check_uncounted_drop(index::SourceIndex)
    findings = Finding[]
    for f in index.files
        path = joinpath(index.repo, f.path)
        isfile(path) || continue
        tree = parse_file(read(path, String), f.path)
        tree === nothing && continue
        marked = marked_functions(tree)
        params = function_params(tree)
        walk_with_enclosing(tree) do n, enclosing
            check_drop_guard!(findings, f, enclosing, marked, params, n)
        end
    end
    findings
end

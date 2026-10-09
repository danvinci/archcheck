# A call as it is written: the callee, the argument text, and where the value goes.

function operator_token(node)
    value = node.val
    value isa Symbol && Base.isoperator(value)
end

# Infix and prefix operators are calls. A trailing operator is the postfix form.
function is_operator_call(node)
    JS.is_infix_op_call(node) && return true
    JS.is_prefix_op_call(node) && return true
    JS.is_prefix_call(node) && return false
    children = child_nodes(node)
    missing = isnothing(children) || isempty(children)
    missing && return false
    operator_token(last(children))
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
    children = child_nodes(head)
    isnothing(children) && return nothing
    if length(children) == 1
        member = children[1]
        member.val isa Symbol || return nothing
        return WrittenCallee(member.val, "")
    end
    length(children) == 2 || return nothing
    member = children[2]
    member.val isa Symbol || return nothing
    raw = JS.sourcetext(children[1])
    qualifier = collapse_source(raw)
    WrittenCallee(member.val, qualifier)
end

# The node naming what a call calls: its operator token, the member of a dotted name, a type application's type,
# or the bare name. Every other identifier in the call is a value it passes.
function callee_node(call)
    children = child_nodes(call)
    (isnothing(children) || isempty(children)) && return nothing
    if is_operator_call(call)
        JS.is_prefix_op_call(call) && return first(children)
        index = findfirst(operator_token, children)
        return isnothing(index) ? nothing : children[index]
    end
    head = first(children)
    kind = JS.kind(head)
    (kind == K"curly" || kind == K".") || return head
    parts = child_nodes(head)
    isnothing(parts) && return head
    kind == K"curly" ? first(parts) : last(parts)
end

function keyword_name(node)
    value = node.val
    value isa Symbol && return value
    kind = JS.kind(node)
    names_a_child = kind == K"=" || kind == K"..." || kind == K"::"
    names_a_child = names_a_child || kind == K"<:" || kind == K">:"
    names_a_child || return nothing
    children = child_nodes(node)
    missing = isnothing(children) || isempty(children)
    missing && return nothing
    keyword_name(children[1])
end

# The positional arguments a call passes. The callee, the keyword block and an operator token stay out.
function positional_arguments(call)
    is_operator = is_operator_call(call)
    found = JS.SyntaxNode[]
    children = child_nodes(call)
    for (index, child) in enumerate(children)
        JS.kind(child) == K"parameters" && continue
        keep = index > 1
        if is_operator
            keep = !operator_token(child)
        end
        keep && push!(found, child)
    end
    found
end

# The value a keyword passes. A bare `=` has no value child, so the keyword node stands for it.
function keyword_value(param)
    value_child(param)
end

# Every value a call passes: its positional arguments, then each keyword's value.
function passed_values(call)
    passed = positional_arguments(call)
    children = child_nodes(call)
    for child in children
        JS.kind(child) == K"parameters" || continue
        params = child_nodes(child)
        isnothing(params) && continue
        for param in params
            push!(passed, keyword_value(param))
        end
    end
    passed
end

function arguments_text(call)
    parts = String[]
    arguments = positional_arguments(call)
    for argument in arguments
        raw = JS.sourcetext(argument)
        text = collapse_source(raw)
        push!(parts, text)
    end
    join(parts, ", ")
end

function keywords_text(call)
    children = child_nodes(call)
    index = findfirst(child -> JS.kind(child) == K"parameters", children)
    isnothing(index) && return ""
    params = children[index]
    keywords = child_nodes(params)
    isnothing(keywords) && return ""
    named = Pair{Symbol,String}[]
    for param in keywords
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
    children = child_nodes(node)
    isnothing(children) && return nothing
    if JS.is_prefix_op_call(node)
        head = first(children)
        head.val isa Symbol || return nothing
        return head.val
    end
    for child in children
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

function record_written!(scan, callee::Symbol, qualifier::String, node, scope)
    arguments = arguments_text(node)
    keywords = keywords_text(node)
    line = source_line(node)
    is_used = !scope.discarded
    call = CallSite(callee, qualifier, arguments, keywords, line, scope.loop_depth, is_used)
    push_call!(scan.callsites, scope.site, call)
end

# The name a call calls: its operator, or the callee its head writes.
function called_name(call)
    if is_operator_call(call)
        callee = operator_callee(call)
        isnothing(callee) && return nothing
        return WrittenCallee(callee, "")
    end
    children = child_nodes(call)
    missing = isnothing(children) || isempty(children)
    missing && return nothing
    name_of_head(children[1])
end

function record_call!(scan, node, scope)
    isnothing(scope.site) && return
    naming = called_name(node)
    isnothing(naming) && return
    record_written!(scan, naming.callee, naming.qualifier, node, scope)
end

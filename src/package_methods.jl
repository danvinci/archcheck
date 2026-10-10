# The package's methods, read from the method table once per context and shared by every check that reflects on them.

# `jl_method_t.dispatch_status` bit set while a method is the one `which` returns for its own signature (julia.h);
# a method overwritten by a later definition of the same signature loses it.
const METHOD_SIG_LATEST_WHICH = 0x01

is_latest(method::Method) = method.dispatch_status & METHOD_SIG_LATEST_WHICH != 0

# Every live method a checked module defines, on any function, in source order.
function project_methods(mods)
    project = Set(mods)
    defined = Method[]
    Base.visit(Core.methodtable) do method
        method.module in project || return
        is_latest(method) && push!(defined, method)
    end
    sort!(defined, by = method -> (string(method.file), method.line))
end

# The function a method belongs to; nothing for a keyword method, a callable struct, or an abstract callee.
function method_function(method::Method)
    signature = Base.unwrap_unionall(method.sig)
    signature isa DataType || return nothing
    callee = signature.parameters[1]
    callee isa DataType || return nothing
    isdefined(callee, :instance) || return nothing
    value = callee.instance
    value isa Function || return nothing
    value === Core.kwcall && return nothing
    value
end

# The defined methods grouped by their function, each group in source order.
function methods_by_function(defined)
    grouped = IdDict{Function,Vector{Method}}()
    for method in defined
        value = method_function(method)
        isnothing(value) && continue
        group = get!(Vector{Method}, grouped, value)
        push!(group, method)
    end
    grouped
end

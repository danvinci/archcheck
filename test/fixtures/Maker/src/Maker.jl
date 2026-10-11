# Macros that make a module where they are called: one fills it with code of its own, one wraps the caller's code.
# Precompile stays off: the suite loads this path, and a cache would land in the depot.
__precompile__(false)

module Maker

export @made_module, @wrapped_module

macro made_module(name)
    body = quote
        made_value() = 1
    end
    made = Expr(:module, true, esc(name), body)
    Expr(:toplevel, made)
end

macro wrapped_module(name, body)
    caller_code = esc(body)
    wrapped = Expr(:module, true, esc(name), caller_code)
    Expr(:toplevel, wrapped)
end

end

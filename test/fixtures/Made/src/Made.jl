# Modules another package's macros make: one holds only the macro's code, one wraps code written here.
# Precompile stays off: the suite loads this path, and a cache would land in the depot.
__precompile__(false)

module Made

using Maker

@made_module Generated

@wrapped_module Wrapped begin
    held() = 2
end

end

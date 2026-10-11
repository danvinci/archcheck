# The Julia internals ArchCheck reads where 1.13.1 offers no public form. Each operation states the contract it rests
# on; the self-gate's `internal_sites` pins every internal call to this file.

# The bit of a method's dispatch status Julia sets while the method is the one `which` returns for its own signature
# (julia.h); a method a later definition of the same signature overwrote loses it.
const METHOD_SIG_LATEST_WHICH = 0x01

is_latest(method::Method) = method.dispatch_status & METHOD_SIG_LATEST_WHICH != 0

# `Base.visit` over `Core.methodtable` calls its function once for every method of every function Julia holds.
function each_loaded_method(action)
    Base.visit(action, Core.methodtable)
    nothing
end

"""The method instances Julia has made of a method, compiled or inferred, from `Base.specializations`; a method
nothing called and nothing inferred has none."""
method_instances(method::Method) = Base.specializations(method)

"""Lowering names every binding the source does not write itself (a closure, a keyword body, a gensym, a function's
type) with a leading `#`; a written identifier holds one only through `var"#..."`."""
is_generated_name(name::Symbol) = startswith(string(name), "#")

"""The name a source wrote for a binding lowering made: a keyword body of `f` is named `#f#N`, so the written name is
the first `#`-separated segment. A written name comes back as it is."""
function written_name(name::Symbol)
    text = string(name)
    is_generated_name(name) || return text
    parts = split(text, "#"; keepempty = false)
    isempty(parts) ? text : String(first(parts))
end

"""Whether a function type belongs to a function lowering made: Julia names a function's type `#` and the function's
name, and a keyword body, closure or local function has a generated name, so its type's name holds a second `#`."""
function is_generated_function_type(function_type::DataType)
    label = string(nameof(function_type))
    startswith(label, "#") || return false
    rest = chop(label; head = 1, tail = 0)
    occursin('#', rest)
end

"""The DataType a type names under its where-clauses, its variables free; nothing for a union, `Union{}`, a type
variable or a value that is no type. Each `UnionAll` holds the type its where-clause binds in `body`."""
function declared_datatype(@nospecialize(type))
    type isa Type || return nothing
    body = type
    while body isa UnionAll
        body = body.body
    end
    body isa DataType ? body : nothing
end

"""The types a method signature lists, the function's own slot first, its where-variables free; empty for a
signature that names no tuple."""
function signature_types(@nospecialize(signature))
    body = declared_datatype(signature)
    isnothing(body) && return Core.svec()
    body.parameters
end

"""The module that owns the function a method belongs to. The signature's first parameter is the function's type,
and that type's name records the defining module. Nothing when the first parameter is no datatype."""
function function_type_module(method::Method)
    body = declared_datatype(method.sig)
    isnothing(body) && return nothing
    parameters = body.parameters
    isempty(parameters) && return nothing
    callee = parameters[1]
    callee isa DataType || return nothing
    datatype = callee::DataType
    datatype.name.module
end

"""The type a `Type{T}` names under any where-clauses, the `T`; nothing for any other type. `Base.isType` tells
`Type{T}` from a plain DataType."""
function type_object_held(@nospecialize(type))
    body = declared_datatype(type)
    isnothing(body) && return nothing
    Base.isType(body) || return nothing
    only(body.parameters)
end

# Whether a binding's value is a union type under its where-clauses: a union names no single module.
function is_union_type(@nospecialize(value))
    value isa Type || return false
    body = Base.unwrap_unionall(value)
    body isa Union
end

"""Each member type a union holds; a type that is no union is its own one member. `Base.uniontypes` flattens nested
unions."""
union_members(@nospecialize(type)) = Base.uniontypes(type)

"""Whether a type holds a type variable no where-clause inside it binds; such a type names no values of its own.
`Base.has_free_typevars` walks the type's parameters for one."""
has_free_variables(@nospecialize(type)) = Base.has_free_typevars(type)

"""`type` under the where-clauses of `outer` that bind a variable it holds free, outermost first, so it names values
again. `Base.rewrap_unionall` binds each of `outer`'s variables in turn."""
under_clauses_of(@nospecialize(type), @nospecialize(outer)) = Base.rewrap_unionall(type, outer)

# Inference gives Any for a call more methods than this match (`max_methods` of the default inference parameters).
const INFERENCE_METHODS_MAX = Base.Compiler.InferenceParams().max_methods

"""The type inference gives calling `f` with arguments of these types, joined over every method that matches.
`Base.infer_return_type` infers in the current world."""
inferred_return_type(f, signature) = Base.infer_return_type(f, signature)

"""The type inference gives each method of `f` at its declared signature, one per method. `Base.return_types`
infers in the current world."""
inferred_return_types(f) = Base.return_types(f)

"""A fresh interpreter with the default inference parameters in the current world; frames inferred with one share its
cache."""
inference_interpreter() = Base.Compiler.NativeInterpreter()

# `argextype` accepts a non-expression and these expression heads in argument position (Compiler/src/optimize.jl).
function can_read_argument(@nospecialize(arg))
    arg isa Expr || return true
    head = arg.head
    head === :static_parameter && return true
    head === :boundscheck && return true
    head === :copyast
end

"""The widened type of an argument `Core.Compiler.argextype` reads, with `widenconst` dropping a constant
(Compiler/src/optimize.jl). Nothing for an expression that function rejects, such as a nested call."""
function widened_argument_type(code, sptypes, @nospecialize(arg))
    can_read_argument(arg) || return nothing
    inferred = Core.Compiler.argextype(arg, code, sptypes)
    Core.Compiler.widenconst(inferred)
end

"""Every method the current world matches for `signature`, however many there are. `Base._methods_by_ftype` lists
them at `Base.get_world_counter`, and a negative limit asks for every match."""
function matching_methods(@nospecialize(signature))
    world = Base.get_world_counter()
    Base._methods_by_ftype(signature, -1, world)::Vector
end

"""The method instance of calling `func` with arguments of type `argtypes` in the current world; nothing when no
method matches. `Base.method_instance` specializes the method the call would pick."""
method_instance_at(func, @nospecialize(argtypes)) = Base.method_instance(func, argtypes)

"""The instance of `method` at the part of `signature` the method admits, type variables it leaves open kept free.
`jl_type_intersection_with_env` computes that intersection and `specialize_method` builds the instance."""
function instance_at(method::Method, @nospecialize(signature))
    intersection = ccall(:jl_type_intersection_with_env, Any, (Any, Any), signature, method.sig)::Core.SimpleVector
    spec_types = intersection[1]
    static_params = intersection[2]
    Core.Compiler.specialize_method(method, spec_types, static_params)
end

"""Whether a method's body is produced by a generator. `Base.hasgenerator` reads that flag."""
is_generated_method(method::Method) = Base.hasgenerator(method)

"""Whether `type` is the vararg tail of a tuple. `Base.isvarargtype` reads that marker."""
is_vararg_type(@nospecialize(type)) = Base.isvarargtype(type)

"""The file and line a statement of `instance`'s code records, innermost scope last as `Base.IRShow.buildLineInfoNode`
expands its debug info; an empty file and line 0 when it records none. A macro's expansion keeps its call's line."""
function statement_location(debuginfo, instance, position)
    stack = Base.IRShow.buildLineInfoNode(debuginfo, instance, position)
    isempty(stack) && return (Symbol(""), 0)
    node = last(stack)
    (node.file, Int(node.line))
end

"""The method instance a statement was inlined from; nothing when the statement is the caller's own.
`Base.IRShow.getdebugidx` gives the statement's edge index into the debug info's `edges`; 0 names none."""
function inlined_instance(debuginfo, position)
    location = Base.IRShow.getdebugidx(debuginfo, position)
    edge_index = Int(location[2])
    edge_index == 0 && return nothing
    inlined = debuginfo.edges[edge_index].def
    inlined isa Core.MethodInstance || return nothing
    inlined
end

# `Base.kwarg_decl` lists the keywords a method declares, read from the keyword sorter lowering made for it.
declares_keywords(method::Method) = !isempty(Base.kwarg_decl(method))

"""The function holding the body of a method that declares keywords; nothing for any other method. `Base.bodyfunction`
reads the body's name out of the keyword sorter's lowered code."""
function body_function(method::Method)
    declares_keywords(method) || return nothing
    Base.bodyfunction(method)
end

# A keyword body is the function lowering names `#name#N`. Julia 1.13.1 records no flag for it. `bodyfunction`
# points from the written method to that function, so the body is known by this name.
const KEYWORD_BODY = r"^#[^#]+#[0-9]+$"

"""Whether a function or method name is a keyword body lowering built: `#name#N`."""
is_keyword_body_name(name::Symbol) = occursin(KEYWORD_BODY, string(name))

is_keyword_body(method::Method) = is_keyword_body_name(method.name)

# `Base.method_argnames` lists the name lowering gave each argument slot, the function's own slot first.
argument_names(method::Method) = Base.method_argnames(method)

# The arguments a method leaves unspecialized: bit `k` of `Method.nospecialize` marks the argument in slot `k + 2`,
# past the function's own slot (julia.h), wherever `@nospecialize` wrote it.
function unspecialized_names(method::Method)
    mask = method.nospecialize
    names = Symbol[]
    mask == 0 && return names
    slots = argument_names(method)
    for position in 2:length(slots)
        bit = position - 2
        bit < 32 || break
        marked = (mask >> bit) & 1 == 1
        marked && push!(names, slots[position])
    end
    names
end

# The keyword method `Core.kwcall` holds for a method that declares keywords.
function keyword_method(method::Method)
    declares_keywords(method) || return nothing
    params = signature_types(method.sig)
    tail = params[2:end]
    owner = params[1]
    bare = Tuple{NamedTuple, owner, tail...}
    # The method's where-clause binds the parameters of the query.
    query = under_clauses_of(bare, method.sig)
    which(Core.kwcall, query)
end

"""Removes a method and its keyword method from the table. `Base.delete_method` makes a new world in which the method
is gone, so a later definition of the same signature is a fresh method."""
function drop_method!(method::Method)
    keyword = keyword_method(method)
    if !isnothing(keyword)
        Base.delete_method(keyword)
    end
    Base.delete_method(method)
    nothing
end

# Types print as seen from a module holding only the standard imports, so what `Main` holds changes no text.
const TYPE_SCOPE = Module(:TypeText)

"""A type as evidence prints it: qualified as a fresh process's `Main` sees it, whatever the running `Main` holds.
Without `:compact`, `show` spells the type out and skips its search for an alias, about ten times the cost."""
function type_text(@nospecialize(type))
    context = (:module => TYPE_SCOPE, :compact => false)
    sprint(show, type; context)
end

"""A path loaded code recorded, repo-relative like an indexed site. A system image records a stdlib's files at the
build machine's path; `Base.fixup_stdlib_path` maps them to this installation."""
function recorded_path(file, repo)
    local_path = Base.fixup_stdlib_path(string(file))
    # Code evaluated without line information records `none`, which names no file.
    isabspath(local_path) || return local_path
    relpath(local_path, repo)
end

"""The repo-relative path of each file the package's loaded methods record, converted once per context: thousands of
methods share a few hundred files. A method recorded elsewhere, as another package's, converts where it is read."""
struct RecordedPaths
    repo::String                 # the root every path is relative to
    paths::Dict{Symbol,String}   # file a method records -> its repo-relative path
end

# Each file the method lists record, converted to its repo-relative path once.
function recorded_paths(repo::String, method_lists)
    paths = Dict{Symbol,String}()
    for methods in method_lists, method in methods
        haskey(paths, method.file) && continue
        paths[method.file] = recorded_path(method.file, repo)
    end
    RecordedPaths(repo, paths)
end

function site_path(recorded::RecordedPaths, file::Symbol)
    held = get(recorded.paths, file, nothing)
    isnothing(held) || return held
    recorded_path(file, recorded.repo)
end

method_site(method::Method, recorded::RecordedPaths) = (site_path(recorded, method.file), Int(method.line))

# Where a module's `module` line sits. `Base.moduleloc` reads the location Julia recorded when it defined the module.
function module_site(mod::Module, repo)
    location = Base.moduleloc(mod)
    (recorded_path(location.file, repo), location.line)
end

"""The docstrings `home` records for its binding `name`; nothing when it records none. `Base.Docs.meta` with
`autoinit = false` leaves a module with no docs uninitialised."""
function recorded_docs(home::Module, name::Symbol)
    docs = Base.Docs.meta(home; autoinit = false)
    isnothing(docs) && return nothing
    binding = Base.Docs.Binding(home, name)
    get(docs, binding, nothing)
end

# The uuid a package's root module was loaded under, from `Base.PkgId`; nothing for the language's own modules.
function package_uuid(package::Module)
    id = Base.PkgId(package)
    id.uuid
end

# Every top-level module this Julia has loaded, by name, from `Base.loaded_modules`. A name two loaded packages share
# names neither.
function top_modules()
    by_name = Dict{Symbol,Module}()
    shared = Set{Symbol}()
    for loaded in values(Base.loaded_modules)
        name = nameof(loaded)
        held = get(by_name, name, loaded)
        held === loaded || push!(shared, name)
        by_name[name] = loaded
    end
    for name in shared
        delete!(by_name, name)
    end
    by_name
end

"""The loaded root module of the package `name` names from `home`'s environment; nothing when the environment names
none or the package is not loaded. `Base.maybe_root_module` reads the loaded root without loading it."""
function loaded_dependency(home::Module, name::String)
    id = Base.identify_package(home, name)
    isnothing(id) && return nothing
    Base.maybe_root_module(id)
end

"""The modules `home` brings in whole with a bare `using`, Base and Core included, as the module itself records them
(`jl_module_usings`, julia.h)."""
function used_modules(home::Module)
    ccall(:jl_module_usings, Any, (Any,), home)::Vector{Any}
end

"""The module in which the binding of `name` in `home` was created. `which` returns that module. Nothing when `which`
raises `ErrorException`: the name is undefined, or the same constant was imported from more than one module."""
function binding_owner(home::Module, name::Symbol)::Union{Module,Nothing}
    try
        return which(home, name)::Module
    catch err
        err isa ErrorException || rethrow()
        return nothing
    end
end

"""Each file the load of `package` included, in start order, with its module path below `package`; nothing without a
cache file or once a file changed. `Base.pkgorigins` names the cache, `Base.parse_cache_header` its sources."""
function recorded_includes(package::Module)
    id = Base.PkgId(package)
    origin = get(Base.pkgorigins, id, nothing)
    isnothing(origin) && return nothing
    cachefile = origin.cachepath
    isnothing(cachefile) && return nothing
    _, (_, sources, _) = Base.parse_cache_header(cachefile)
    found = Tuple{String,Vector{String}}[]
    for source in sources
        # The entry file carries the empty `PkgId`; the load reads it before any include.
        isempty(source.id.name) && continue
        is_unchanged(source) || return nothing
        path = normpath(source.filename)
        push!(found, (path, source.modpath))
    end
    found
end

# A cached source is the file on disk when its size and CRC-32C match; `Base._crc32c` is the checksum loading uses.
function is_unchanged(source)
    isfile(source.filename) || return false
    filesize(source.filename) == source.fsize || return false
    checksum = open(Base._crc32c, source.filename)
    checksum == source.hash
end

# Whether this process is building a package image, from `Base.generating_output`; code run then is cached.
is_building_image() = Base.generating_output()

# The root module of the loaded package of this name, from `Base.loaded_modules`; nothing when none is loaded.
function loaded_package(name::String)
    for (id, mod) in Base.loaded_modules
        id.name == name && return mod
    end
    nothing
end

"""The packages the project in `repo` lists under [deps]. `Base.env_project_file` finds the project file Julia would
read for that directory, and `Base.parsed_toml` reads it through the loader's cache."""
function project_dependencies(repo)
    dependencies = Set{Base.UUID}()
    project = Base.env_project_file(repo)
    project isa String || return dependencies
    parsed = Base.parsed_toml(project)
    listed = get(parsed, "deps", nothing)
    isnothing(listed) && return dependencies
    for uuid in values(listed)
        text = uuid::String
        push!(dependencies, Base.UUID(text))
    end
    dependencies
end

# The local `@sync` binds its task list to, `Base.sync_varname`; an `@async` inside the block pushes its task there.
sync_binding() = Base.sync_varname

"""The native code Julia compiled for `instance`. An instance's `cache` chains its `CodeInstance`s through `next`;
the native one has no `owner`, which an external interpreter's entries set."""
function native_code(instance::Core.MethodInstance)
    isdefined(instance, :cache) || return nothing
    code = instance.cache
    while !isnothing(code.owner)
        isdefined(code, :next) || return nothing
        code = code.next
    end
    code
end

"""Whether the native code compiled for `signature` is unconditionally consistent; nothing when none is compiled. A
`CodeInstance` keeps its effects in `ipo_purity_bits`, which `Compiler.decode_effects` reads (Compiler/src/effects.jl)."""
function compiled_consistency(signature::Type)
    instance = Base.method_instance(signature)
    isnothing(instance) && return nothing
    code = native_code(instance)
    isnothing(code) && return nothing
    effects = Core.Compiler.decode_effects(code.ipo_purity_bits)
    Core.Compiler.is_consistent(effects)
end

"""The methods `instance`'s native code calls, by its edges; `ForwardToBackedgeIterator` (Compiler/src/typeinfer.jl)
names the method of a resolved call or an invoke, and none for a method-table lookup or a binding."""
function compiled_edge_methods(instance::Core.MethodInstance)
    code = native_code(instance)
    isnothing(code) && return Method[]
    edges = code.edges
    edges isa Core.SimpleVector || return Method[]
    found = Method[]
    backedges = Core.Compiler.ForwardToBackedgeIterator(edges)
    for landed in backedges
        item = landed[2]
        item isa Core.MethodInstance || continue
        method = item.def
        method isa Method || continue
        push!(found, method)
    end
    found
end

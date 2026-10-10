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

function keep_project_method!(defined, method::Method, project)
    method.module in project || return
    is_latest(method) && push!(defined, method)
    nothing
end

# Every live method a checked module defines, on any function, in source order. A context reads the table once.
function project_methods(mods)
    project = Set(mods)
    defined = Method[]
    each_loaded_method() do method
        keep_project_method!(defined, method, project)
    end
    sort!(defined, by = method -> (string(method.file), method.line))
end

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

# `Base.kwarg_decl` lists the keywords a method declares, read from the keyword sorter lowering made for it.
declares_keywords(method::Method) = !isempty(Base.kwarg_decl(method))

"""The function holding the body of a method that declares keywords; nothing for any other method. `Base.bodyfunction`
reads the body's name out of the keyword sorter's lowered code."""
function body_function(method::Method)
    declares_keywords(method) || return nothing
    Base.bodyfunction(method)
end

# `Base.method_argnames` lists the name lowering gave each argument slot, the function's own slot first.
argument_names(method::Method) = Base.method_argnames(method)

# The keyword method `Core.kwcall` holds for a method that declares keywords.
function keyword_method(method::Method)
    declares_keywords(method) || return nothing
    body = Base.unwrap_unionall(method.sig)
    params = body.parameters
    tail = params[2:end]
    owner = params[1]
    bare = Tuple{NamedTuple, owner, tail...}
    # The method's where-clause binds the parameters of the query.
    query = Base.rewrap_unionall(bare, method.sig)
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

# A bits type whose layout leaves bytes no field covers, from `Base.datatype_haspadding`; those bytes hold no value.
has_padding(type::DataType) = Base.datatype_haspadding(type)

# The local `@sync` binds its task list to, `Base.sync_varname`; an `@async` inside the block pushes its task there.
sync_binding() = Base.sync_varname

"""Whether the native code compiled for `signature` is unconditionally consistent; nothing when none is compiled. A
`CodeInstance` keeps its effects in `ipo_purity_bits`, which `Compiler.decode_effects` reads (Compiler/src/effects.jl)."""
function compiled_consistency(signature::Type)
    instance = Base.method_instance(signature)
    isnothing(instance) && return nothing
    isdefined(instance, :cache) || return nothing
    code = instance.cache
    while !isnothing(code.owner)
        isdefined(code, :next) || return nothing
        code = code.next
    end
    effects = Core.Compiler.decode_effects(code.ipo_purity_bits)
    Core.Compiler.is_consistent(effects)
end

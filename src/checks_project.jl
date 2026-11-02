# A parameterized check a package configures: who may reference a name.

"""Configured through `gate(...; checks)` with the names, the definitions allowed to reference them, and directories to skip. A reference from any other definition is a finding, cited at its first such reference, and so is one in load-time code outside every definition; an allowed definition that references none of the names is a stale allowance. A macro is a definition named with its `@`."""
struct CallerAllowlist{C<:NTuple{N,Symbol} where N, A<:NTuple{M,Tuple{String,Symbol}} where M, E<:NTuple{K,String} where K} <: Check
    callees::C       # function names a body may reference only from an allowed def
    allowed::A       # (repo-relative path, def name) pairs that may reference them
    exempt_dirs::E   # path prefixes skipped entirely
end

# The (repo-relative path, definition name) pairs a check is configured with, as it stores them
function definition_pairs(written)
    ntuple(length(written)) do position
        pair = written[position]
        (String(pair[1]), Symbol(pair[2]))
    end
end

function CallerAllowlist(callees, allowed, exempt_dirs = ())
    names = ntuple(position -> Symbol(callees[position]), length(callees))
    pairs = definition_pairs(allowed)
    prefixes = ntuple(position -> String(exempt_dirs[position]), length(exempt_dirs))
    CallerAllowlist(names, pairs, prefixes)
end

kinds(::CallerAllowlist) = (:unlisted_caller => :error, :stale_allowance => :error)

# A path sits in a directory when it is that directory or a file inside it.
function is_under(path, directory)
    path == directory && return true
    prefix = endswith(directory, "/") ? directory : directory * "/"
    startswith(path, prefix)
end

# The index lists files under src, so a directory outside it has no file.
function require_covered(index, directory)
    for file in index.files
        is_under(file.path, directory) && return
    end
    message = "no indexed file under " * directory
    throw(ArgumentError(message))
end

# Each guarded name each definition's code reads, a member read through any module included (`JS.parseall` calls
# `parseall`), with the line of its first read there.
function definition_reads(scan::FileScan, names)
    found = Dict{Symbol,Dict{Symbol,Int}}()
    for read in scan.reads
        read.in_signature && continue
        is_local_read(read) && continue
        isnothing(read.def) && continue
        read.name in names || continue
        lines = get!(Dict{Symbol,Int}, found, read.def)
        get!(lines, read.name, read.line)
    end
    found
end

# Each guarded name a file's load-time code reads outside every definition, with the line of its first read there. A
# clause or a definition names a function without reading it, so neither counts; a bound reference does.
function load_time_reads(scan::FileScan, names)
    found = Dict{Symbol,Int}()
    for read in scan.reads
        isnothing(read.def) || continue
        read.is_quoted && continue
        read.is_naming && continue
        read.name in names || continue
        get!(found, read.name, read.line)
    end
    found
end

# The check judges a reference, a call or a bound value alike. Load-time code is the empty symbol: no definition, so
# no allowed pair covers it.
function unlisted_finding(file, symbol, line, referenced)
    ordered = sort!(collect(referenced); by = string)
    listed = join(ordered, " ")
    prose = join(ordered, ", ")
    place = isempty(symbol) ? "load-time code" : symbol
    detail = place * " references " * prose
    evidence = [:references => listed]
    Finding(file.mod, :unlisted_caller, file.path, symbol, line, detail, evidence)
end

# An allowed (path, definition) pair the code does not use: its file is missing or skipped, or the definition does
# none of what the pair allows. A file the index lacks is cited under the package's own module
function stale_finding(index, root, pair, detail, evidence)
    path, def = pair
    held = findfirst(file -> file.path == path, index.files)
    mod = isnothing(held) ? nameof(root) : index.files[held].mod
    symbol = string(def)
    Finding(mod, :stale_allowance, path, symbol, 0, detail, evidence)
end

function stale_caller_finding(index, root, pair, callees)
    names = sort!([string(name) for name in callees])
    symbol = string(pair[2])
    detail = symbol * " is allowed to reference " * join(names, ", ") * " and references none"
    evidence = [:callees => join(names, " ")]
    stale_finding(index, root, pair, detail, evidence)
end

function run(check::CallerAllowlist, ctx)
    findings = Finding[]
    for prefix in check.exempt_dirs
        require_covered(ctx.index, prefix)
    end
    names = Set(check.callees)
    allowed = Set(check.allowed)
    referencing = Set{Tuple{String,Symbol}}()
    for file in ctx.index.files
        any(prefix -> is_under(file.path, prefix), check.exempt_dirs) && continue
        for (def, lines) in definition_reads(file.scan, names)
            pair = (file.path, def)
            if pair in allowed
                push!(referencing, pair)
                continue
            end
            first_line = minimum(values(lines))
            finding = unlisted_finding(file, string(def), first_line, keys(lines))
            push!(findings, finding)
        end
        loaded = load_time_reads(file.scan, names)
        isempty(loaded) && continue
        first_line = minimum(values(loaded))
        finding = unlisted_finding(file, "", first_line, keys(loaded))
        push!(findings, finding)
    end
    for pair in check.allowed
        pair in referencing && continue
        push!(findings, stale_caller_finding(ctx.index, ctx.root, pair, check.callees))
    end
    findings
end

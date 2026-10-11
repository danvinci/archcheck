# A parameterized check a package configures: who may reference a name.

"""Configured through `gate(...; checks)` with the names, the definitions allowed to reference them, and directories to skip. A reference from any other definition is a finding, and so is one in load-time code outside every definition."""
struct CallerWhitelist{C<:NTuple{N,Symbol} where N, A<:NTuple{M,Tuple{String,Symbol}} where M, E<:NTuple{K,String} where K} <: Check
    callees::C       # function names a body may reference only from an allowed def
    allowed::A       # (repo-relative path, def name) pairs that may reference them
    exempt_dirs::E   # path prefixes skipped entirely
end

function CallerWhitelist(callees, allowed, exempt_dirs = ())
    names = Tuple(Symbol(name) for name in callees)
    pairs = Tuple((String(pair[1]), Symbol(pair[2])) for pair in allowed)
    prefixes = Tuple(String(prefix) for prefix in exempt_dirs)
    CallerWhitelist(names, pairs, prefixes)
end

kinds(::CallerWhitelist) = (:unlisted_caller => :error,)

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

# Each name a def's code writes, a member read through any module included: `JS.parseall` calls `parseall`.
function written_names(scan::FileScan)
    written = Dict{Symbol,Set{Symbol}}()
    for read in scan.reads
        read.in_signature && continue
        is_local_read(read) && continue
        isnothing(read.def) && continue
        names = get!(Set{Symbol}, written, read.def)
        push!(names, read.name)
    end
    written
end

# Each guarded name a file's load-time code reads outside every definition, with the line of its first read there. A
# clause or a definition names a function without reading it, so neither counts; a bound reference does.
function load_time_reads(scan::FileScan, names)
    found = Dict{Symbol,Int}()
    for read in scan.reads
        isnothing(read.def) || continue
        read.is_quoted && continue
        read.in_export && continue
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

function run(check::CallerWhitelist, ctx)
    findings = Finding[]
    for prefix in check.exempt_dirs
        require_covered(ctx.index, prefix)
    end
    names = Set(check.callees)
    allowed = Set(check.allowed)
    for file in ctx.index.files
        any(prefix -> is_under(file.path, prefix), check.exempt_dirs) && continue
        written = written_names(file.scan)
        for (def, used) in written
            referenced = intersect(used, names)
            isempty(referenced) && continue
            pair = (file.path, def)
            pair in allowed && continue
            line = Int(get(file.scan.line, def, 0))
            finding = unlisted_finding(file, string(def), line, referenced)
            push!(findings, finding)
        end
        loaded = load_time_reads(file.scan, names)
        isempty(loaded) && continue
        first_line = minimum(values(loaded))
        finding = unlisted_finding(file, "", first_line, keys(loaded))
        push!(findings, finding)
    end
    findings
end

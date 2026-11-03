# tuple-return: a body ending in a bare tuple is a data layer that never got a type.
const TUPLE_SLOTS_MIN = 3

function check_tuple_returns(index)
    findings = Finding[]
    for f in index.files, (name, slots) in f.scan.tupletail
        slots >= TUPLE_SLOTS_MIN || continue
        line = f.scan.line[name]
        push!(findings, Finding(f.mod, :tuple_return, f.path, string(name), line,
                                "body ends in a bare tuple", [:slots => string(slots)]))
    end
    findings
end

# Defs in a file that reference a name: (name, the file of the reference) -> count.
function caller_counts(cg)
    callers = Dict{Tuple{Symbol,String},Int}()
    for ((caller, file), callees) in cg.site_refs
        for callee in callees
            caller == callee && continue
            site = (callee, file)
            callers[site] = get(callers, site, 0) + 1
        end
    end
    callers
end

function sink_finding(cg, home, name, line, target, athome)
    evidence = [:callees_in => basename(target),
                :callers_in_own_file => string(athome)]
    Finding(cg.mod, :file_sinkable, home, string(name), line,
            "every callee lives in one lower-ranked file", evidence)
end

"""The files a definition could move to and still read every name it reads: the load's bindings, and the free names
each method form reads, its signature's annotations included"""
struct SinkFloor
    judge::LateJudge   # where the load first binds each name
    "(definition, file) -> each method's line -> the free names it reads, each flagged when its signature reads it"
    reads::Dict{Tuple{Symbol,String},Dict{Int,Set{Tuple{Symbol,Bool}}}}
end

function SinkFloor(ctx)
    judge = LateJudge(ctx.index, ctx.mods, ctx.root)
    reads = Dict{Tuple{Symbol,String},Dict{Int,Set{Tuple{Symbol,Bool}}}}()
    for file in ctx.index.files, read in file.scan.reads
        def = read.def
        form = read.method
        (isnothing(def) || isnothing(form)) && continue
        is_skipped = is_local_read(read) || is_member(read) || read.is_quoted || read.is_naming
        is_skipped && continue
        read.name === def && continue
        site = (def, file.path)
        by_line = get!(Dict{Int,Set{Tuple{Symbol,Bool}}}, reads, site)
        line = source_line(form)
        held = get!(Set{Tuple{Symbol,Bool}}, by_line, line)
        push!(held, (read.name, read.in_signature))
    end
    SinkFloor(judge, reads)
end

# The free names the definition's method at `line` of `home` reads, or all its methods there for line 0
function floor_reads(floor::SinkFloor, name, home, line)
    none = Set{Tuple{Symbol,Bool}}()
    by_line = get(floor.reads, (name, home), nothing)
    isnothing(by_line) && return none
    iszero(line) || return get(by_line, line, none)
    union(none, values(by_line)...)
end

# A signature runs where its method is defined, so the load must have made the binding before `target` ends
function is_bound_after(floor::SinkFloor, key, name, end_tick)
    bound = get(floor.judge.names, key, nothing)
    isnothing(bound) && return false
    binding = get(bound, name, nothing)
    isnothing(binding) && return false
    binding.is_import && return false
    binding.tick > end_tick
end

# Whether the definition's method at `line` of `home`, moved to the end of `target`, would read a name the load binds
# only later
function reads_late(floor::SinkFloor, key, name, home, line, target)
    files = floor.judge.index.files
    position = findfirst(file -> file.path == target, files)
    isnothing(position) && return true
    load = floor.judge.index.loads[position]
    target_end = last(load.steps)
    for (read, is_signature) in floor_reads(floor, name, home, line)
        binding = late_binding(floor.judge, key, read, target_end.started)
        isnothing(binding) || return true
        is_signature && is_bound_after(floor, key, read, target_end.tick) && return true
    end
    false
end

# `form_line` is the judged method's line, or 0 when every method of the name is judged as one
function sink_verdict(cg, home, name, line, targets, callers, floor, form_line)
    length(targets) == 1 || return nothing
    target = only(targets)
    target == home && return nothing
    is_downrank(cg.rank, home, target) || return nothing
    athome = get(callers, (name, home), 0)
    athome > 0 && return nothing
    reads_late(floor, cg.mod, name, home, form_line, target) && return nothing
    sink_finding(cg, home, name, line, target, athome)
end

# file-sinkable: every intra-module function a def calls lives in one lower-ranked file, by whose end the load has bound every name it reads.
# Types and published names place nothing; file-backedge owns the up-rank direction
function check_file_sinkable(cg::CallGraph, sites, vocabulary, floor::SinkFloor)
    callers = caller_counts(cg)
    findings = Finding[]
    for name in cg.funcs
        callees = cg.calls[name]
        targets = String[]
        for callee in callees
            callee in vocabulary && continue
            push!(targets, cg.files[callee])
        end
        unique!(targets)
        home = cg.files[name]
        located = site_of(sites, cg.mod, name, (home, 0))
        line = located[2]
        finding = sink_verdict(cg, home, name, line, targets, callers, floor, 0)
        isnothing(finding) || push!(findings, finding)
    end
    findings
end

# Methods of this module's functions, each at the file and line the loader recorded.
function judged_methods(cg, methods, recorded::RecordedPaths)
    owned = Set(cg.funcs)
    judged = Tuple{Method,String,Int}[]
    for caller in keys(methods.edges)
        caller.name in owned || continue
        located = method_site(caller, recorded)
        home = located[1]
        haskey(cg.rank, home) || continue
        line = located[2]
        push!(judged, (caller, home, line))
    end
    judged
end

function covered_names(judged)
    names = Set{Symbol}()
    for placed in judged
        caller = placed[1]
        push!(names, caller.name)
    end
    names
end

# A closure's body callee files belong to the caller. A method on a function the module does not own, such as
# `Base.iterate`, has no file here and places nothing.
function add_callee_target!(targets, cg, caller_name, callee, walk)
    if !haskey(cg.files, callee.name)
        is_closure = is_generated_name(callee.name)
        is_closure && add_body_targets!(targets, cg, caller_name, callee, walk)
        return
    end
    callee.name in walk.vocabulary && return
    located = method_site(callee, walk.recorded)
    path = located[1]
    haskey(cg.rank, path) || return
    callee.name === caller_name && return
    push!(targets, path)
end

function add_body_targets!(targets, cg, caller_name, method, walk)
    method in walk.seen && return
    push!(walk.seen, method)
    callees = get(walk.methods.edges, method, nothing)
    isnothing(callees) && return
    for callee in callees
        add_callee_target!(targets, cg, caller_name, callee, walk)
    end
end

# What one method's target walk reads: the graph, the paths its sites read, the vocabulary that places nothing, and
# the methods already walked.
struct TargetWalk
    methods::MethodGraph        # calls between methods
    recorded::RecordedPaths     # repo-relative path of each file a method records
    vocabulary::Set{Symbol}     # names a call to which places nothing
    seen::Set{Method}           # methods this walk has expanded
end

function add_method_targets!(targets, cg, method, methods, recorded, vocabulary)
    caller_name = method.name
    seen = Set{Method}()
    walk = TargetWalk(methods, recorded, vocabulary, seen)
    add_body_targets!(targets, cg, caller_name, method, walk)
end

function method_findings(cg, methods, judged, recorded, vocabulary, floor)
    callers = caller_counts(cg)
    findings = Finding[]
    for placed in judged
        caller = placed[1]
        home = placed[2]
        line = placed[3]
        targets = Set{String}()
        add_method_targets!(targets, cg, caller, methods, recorded, vocabulary)
        finding = sink_verdict(cg, home, caller.name, line, targets, callers, floor, line)
        isnothing(finding) || push!(findings, finding)
    end
    findings
end

# With a method graph, each method is judged on the methods its calls can land on.
# A function with no method in the graph keeps the name-level verdict.
function check_file_sinkable(cg::CallGraph, sites, methods::MethodGraph, recorded, vocabulary, floor::SinkFloor)
    judged = judged_methods(cg, methods, recorded)
    named = check_file_sinkable(cg, sites, vocabulary, floor)
    per_method = method_findings(cg, methods, judged, recorded, vocabulary, floor)
    covered = covered_names(judged)
    kept = Finding[]
    for finding in named
        name = Symbol(finding.symbol)
        name in covered && continue
        push!(kept, finding)
    end
    append!(kept, per_method)
    kept
end

check_file_sinkable(cg::CallGraph, sites, ::Nothing, _recorded, vocabulary, floor::SinkFloor) =
    check_file_sinkable(cg, sites, vocabulary, floor)

# extract-candidate: the density view of sinkable - a file holding several such defs.
const EXTRACT_DEFS_MIN = 3

function check_extract_candidates(sinkables; min_defs = EXTRACT_DEFS_MIN)
    byfile = Dict{String,Tuple{Symbol,Vector{String}}}()
    for f in sinkables
        (f.kind === :sinkable && !isempty(f.file)) || continue
        _, syms = get!(byfile, f.file, (f.mod, String[]))
        push!(syms, f.symbol)
    end
    [Finding(m, :extract_candidate, file, "", 0, "holds several defs that only touch lower-ranked modules",
             [:defs => string(length(syms)), :names => join(sort(syms), " ")])
     for (file, (m, syms)) in byfile if length(syms) >= min_defs]
end

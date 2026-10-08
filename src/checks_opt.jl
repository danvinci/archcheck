# Opt-analysis port: a corpus of concrete calls run through JET.report_opt. No-op until JET is loaded.

struct OptEntry{F<:Function, A<:Tuple}
    f::F                                # the function the corpus names
    argtypes::Type{A}                   # concrete argument types, one specialization
    symbol::String                      # Finding.symbol; includes the signature so Dual and Float64 stay distinct
end

function entry_symbol(f, ::Type{T}) where {T <: Tuple}
    args = join(("::" * string(p) for p in T.parameters), ", ")
    "$(nameof(f))($args)"
end

function OptEntry(f::F, argtypes::Type{A}) where {F<:Function, A<:Tuple}
    symbol = entry_symbol(f, argtypes)
    OptEntry{F,A}(f, argtypes, symbol)
end

struct OptAnalysis{E} <: Check
    entries::Vector{E}                  # corpus calls, each one specialization
end
OptAnalysis() = OptAnalysis(OptEntry[])

function jet_loaded()
    for (id, mod) in Base.loaded_modules
        id.name == "JET" && return mod
    end
    nothing
end

function entry_location(entry::OptEntry, repo)
    m = which(entry.f, entry.argtypes)
    mod = module_key(m.module)
    method_file = string(m.file)
    file = relpath(method_file, repo)
    line = Int(m.line)
    (mod = mod, file = file, line = line)
end

function analyze_entries(jet::Module, entries, repo, target_modules)
    findings = Finding[]
    mods = Tuple(target_modules)
    RuntimeDispatchReport = jet.RuntimeDispatchReport
    CapturedVariableReport = jet.CapturedVariableReport
    for entry in entries
        result = Base.invokelatest(jet.report_opt, entry.f, entry.argtypes; target_modules = mods)
        reports = Base.invokelatest(jet.get_reports, result)
        n_dispatch = count(r -> r isa RuntimeDispatchReport, reports)
        n_box = count(r -> r isa CapturedVariableReport, reports)
        (n_dispatch == 0 && n_box == 0) && continue
        mod, file, line = entry_location(entry, repo)
        if n_dispatch > 0
            push!(findings, Finding(mod, :runtime_dispatch, file, entry.symbol, line,
                  "runtime dispatch in the inferred graph of this entry",
                  [:dispatches => string(n_dispatch)]))
        end
        if n_box > 0
            push!(findings, Finding(mod, :inferred_box, file, entry.symbol, line,
                  "a captured local is boxed in the inferred graph of this entry",
                  [:boxes => string(n_box)]))
        end
    end
    findings
end

function check_opt_entries(entries; repo, target_modules)
    isempty(entries) && return Finding[]
    jet = jet_loaded()
    isnothing(jet) && return Finding[]
    analyze_entries(jet, entries, repo, target_modules)
end

run(check::OptAnalysis, ctx) =
    check_opt_entries(check.entries; repo = ctx.index.repo, target_modules = ctx.mods)

# Without JET the analysis cannot run, so it declares no kinds and a JET-less run claims none of them clean.
function kinds(::OptAnalysis)
    isnothing(jet_loaded()) && return ()
    (:runtime_dispatch => :advisory, :inferred_box => :advisory)
end

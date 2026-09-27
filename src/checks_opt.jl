# Opt-analysis port: a corpus of concrete calls run through JET.report_opt. No-op until JET is loaded.

struct OptEntry
    f::Function                         # the function the corpus names
    argtypes::Type{<:Tuple}             # concrete argument types, one specialization
    symbol::String                      # Finding.symbol; includes the signature so Dual and Float64 stay distinct
end

function entry_symbol(f, ::Type{T}) where {T <: Tuple}
    args = join(("::" * string(p) for p in T.parameters), ", ")
    "$(nameof(f))($args)"
end

OptEntry(f::Function, argtypes::Type{<:Tuple}) = OptEntry(f, argtypes, entry_symbol(f, argtypes))

struct OptAnalysis <: Check
    entries::Vector{OptEntry}
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
    (module_key(m.module), relpath(string(m.file), repo), Int(m.line))
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

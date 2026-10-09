# Score each row and print the table.

const KIND_WEIGHT = 4
const FILE_WEIGHT = 2
const SYMBOL_WEIGHT = 1
const FULL_MATCH = KIND_WEIGHT + FILE_WEIGHT + SYMBOL_WEIGHT

struct RowResult
    expectation::Expectation           # the row that was scored
    got::String                        # fired, quiet, "not built", or error
    finding::String                    # the matched finding, or the nearest one
    seconds::Float64                   # the state's wall time (s)
end

function match_score(found, expectation)
    score = 0
    if found.kind == expectation.kind
        score += KIND_WEIGHT
    end
    if endswith(found.file, expectation.file_suffix)
        score += FILE_WEIGHT
    end
    if occursin(expectation.symbol, found.symbol)
        score += SYMBOL_WEIGHT
    end
    score
end

function best_finding(findings, expectation)
    chosen = nothing
    best = -1
    for found in findings
        score = match_score(found, expectation)
        if score > best
            chosen = found
            best = score
        end
    end
    chosen
end

function got_for(expectation, state)
    if expectation.check in state.missing
        return "not built"
    end
    if expectation.check in state.failed || state.errored
        return "error"
    end
    for found in state.findings
        match_score(found, expectation) == FULL_MATCH && return "fired"
    end
    "quiet"
end

function finding_text(expectation, state, got)
    got == "not built" && return "-"
    got == "error" && return "-"
    chosen = best_finding(state.findings, expectation)
    isnothing(chosen) && return "-"
    string(chosen.file, ":", chosen.line, ":", chosen.symbol)
end

function score_rows(host, runs)
    rows = RowResult[]
    for expectation in host.expectations
        state = runs[expectation.state]
        got = got_for(expectation, state)
        text = finding_text(expectation, state, got)
        push!(rows, RowResult(expectation, got, text, state.seconds))
    end
    rows
end

function print_table(io, rows)
    headers = ["case", "check", "state", "expected", "got", "finding", "seconds"]
    lines = [headers]
    for row in rows
        rounded = round(row.seconds; digits = 3)
        seconds = string(rounded)
        expectation = row.expectation
        cells = [
            expectation.case,
            expectation.check,
            expectation.state,
            expectation.expect,
            row.got,
            row.finding,
            seconds,
        ]
        push!(lines, cells)
    end
    print_cells(io, lines)
end

function is_failure(row)
    row.got == "error" && return true
    row.got == "not built" && return false
    if row.expectation.expect == "fire"
        return row.got != "fired"
    end
    row.got != "quiet"
end

function print_failure(io, row)
    expectation = row.expectation
    println(io, "FAIL ", expectation.case, " ", expectation.check, " ", expectation.state,
            " expected ", expectation.expect, " got ", row.got)
end

function failure_count(rows)
    failures = 0
    for row in rows
        is_failure(row) && (failures += 1)
    end
    failures
end

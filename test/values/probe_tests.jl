# Call zoom: methods re-evaluated from the index, records of the calls a workload actually makes.

const FLOAT_SAMPLE = 2.0
const FLOAT_RESULT = 3.0
const BOX_FROM_FLOAT = 2.4
const BOX_RESTORED_FLOAT = 3.0

function caught(f, args...; options...)
    try
        Base.invokelatest(f, args...; options...)
        nothing
    catch err
        err
    end
end

function same_exception(left, right)
    same_type = typeof(left) === typeof(right)
    left_text = sprint(showerror, left)
    right_text = sprint(showerror, right)
    same_type && left_text == right_text
end

function lowered_text(f, types)
    lowered = Base.invokelatest(code_lowered, f, types)
    sprint(show, only(lowered))
end

struct Pad
    a::UInt8                # first stored byte, so the next field is aligned past a gap
    b::UInt64               # the value stored after that gap
end

function raw_bytes(value::Pad)
    stored = Ref(value)
    count = sizeof(Pad)
    bytes = Vector{UInt8}(undef, count)
    GC.@preserve stored begin
        source = Base.unsafe_convert(Ptr{Pad}, stored)
        source_bytes = Ptr{UInt8}(source)
        dest = pointer(bytes)
        unsafe_copyto!(dest, source_bytes, count)
    end
    bytes
end

function pad_with(fill_byte::UInt8)
    slack = sizeof(Pad) + 16
    block = Vector{UInt8}(undef, slack)
    empty = Pad(0, 0)
    loaded = Ref{Pad}(empty)
    GC.@preserve block begin
        raw = pointer(block)
        address = UInt(raw)
        align = UInt(8)
        remainder = address % align
        shift = remainder == 0 ? UInt(0) : align - remainder
        start = raw + shift
        fill!(block, fill_byte)
        byte_slot = Ptr{UInt8}(start)
        unsafe_store!(byte_slot, UInt8(1))
        offset = fieldoffset(Pad, 2)
        slot = start + offset
        wide_slot = Ptr{UInt64}(slot)
        unsafe_store!(wide_slot, UInt64(2))
        wide = Ptr{Pad}(start)
        loaded[] = unsafe_load(wide)
    end
    loaded[]
end

const PARENT_LINK = load_package("ParentLink", """
    function parent(x)
        task = Threads.@spawn child(x)
        fetch(task)
    end

    function child(x)
        x + 1
    end
    """)

const SCALED_KEYWORD = load_package("ScaledKeyword", """
    function scaled(xs::Vector{T}; scale::T = one(T)) where {T<:Real}
        xs .* scale
    end
    """)

const BOXED_VALUE = load_package("BoxedValue", """
    struct Boxed
        value::Int
        Boxed(value::Int, scale::Int) = new(value * scale)
    end

    "A box from a float, rounded."
    Boxed(value::Float64) = Boxed(round(Int, value), 1)

    "Twice the boxed value."
    twice(box::Boxed) = 2 * box.value
    """)

@testset "equal values share an argument hash and a result hash, and the record names the method" begin
    method = only(methods(Probed.same))
    site = (joinpath("src", "Probed.jl"), method.line)
    same_values = function ()
        Probed.same([1, 2, 3])
        Probed.same([1, 2, 3])
        Probed.same([1, 2, 4])
    end
    probes = Probes(; functions = (Probed.same,), slow_s = 0.0)
    seen = observed_gate(Probed; workload = same_values, probes)
    records = seen.observed.records
    @test length(records) == 3
    matched = records[1]
    repeated = records[2]
    differed = records[3]
    names_method = matched.name === :same && repeated.name === :same && differed.name === :same
    @test names_method
    sites_method = matched.site == site && repeated.site == site && differed.site == site
    @test sites_method
    @test matched.arguments == repeated.arguments
    @test matched.result == repeated.result
    @test differed.arguments != matched.arguments
end

@testset "an armed method keeps its result and the restored method keeps its body" begin
    cases = (
        (; called = Probed.early, args = (-3,), kwargs = (;), expected = 0, record_name = :early),
        (; called = Probed.early, args = (4,), kwargs = (;), expected = 5, record_name = :early),
        (; called = Probed.keyed, args = (3,), kwargs = (;), expected = 6, record_name = :keyed),
        (; called = Probed.keyed, args = (3,), kwargs = (; scale = 4), expected = 12, record_name = :keyed),
        (; called = Probed.typed, args = (2,), kwargs = (;), expected = 3, record_name = :typed),
        (; called = Probed.typed, args = (FLOAT_SAMPLE,), kwargs = (;), expected = FLOAT_RESULT, record_name = :typed),
    )
    counted = unique(case.called for case in cases)
    method_counts = map(counted) do called
        methods_of = methods(called)
        method_count = length(methods_of)
        (called, method_count)
    end
    before = lowered_text(Probed.early, (Int,))
    functions = (Probed.early, Probed.keyed, Probed.typed)
    exercise_cases = function ()
        for case in cases
            got = Base.invokelatest(case.called, case.args...; case.kwargs...)
            @test got == case.expected
        end
        for (called, method_count) in method_counts
            methods_of = methods(called)
            @test length(methods_of) == method_count
        end
    end
    probes = Probes(; functions, slow_s = 0.0)
    seen = observed_gate(Probed; workload = exercise_cases, probes)
    records = seen.observed.records
    seen_names = [record.name for record in records]
    @test length(seen_names) == length(cases)
    record_names = unique(case.record_name for case in cases)
    for record_name in record_names
        expected = count(case -> case.record_name === record_name, cases)
        found = count(isequal(record_name), seen_names)
        @test found == expected
    end
    restored = lowered_text(Probed.early, (Int,))
    @test restored == before
    for case in cases
        got = Base.invokelatest(case.called, case.args...; case.kwargs...)
        @test got == case.expected
    end
    for (called, method_count) in method_counts
        methods_of = methods(called)
        @test length(methods_of) == method_count
    end
end

@testset "a throw keeps the exception and the next call is a root" begin
    unprobed = caught(Probed.blows, true)
    throw_then_root = function ()
        thrown = caught(Probed.blows, true)
        @test same_exception(thrown, unprobed)
        Probed.alone(1)
    end
    probes = Probes(; functions = (Probed.blows, Probed.alone), slow_s = 0.0)
    seen = observed_gate(Probed; workload = throw_then_root, probes)
    records = seen.observed.records
    alone = [record for record in records if record.name === :alone]
    root = only(alone)
    @test root.caller === Symbol("")
end

@testset "calls on spawned tasks are roots of distinct tasks" begin
    spawned_calls = function ()
        left = Threads.@spawn Base.invokelatest(Probed.alone, 1)
        right = Threads.@spawn Base.invokelatest(Probed.alone, 2)
        fetch(left)
        fetch(right)
    end
    probes = Probes(; functions = (Probed.alone,), slow_s = 0.0)
    seen = observed_gate(Probed; workload = spawned_calls, probes)
    records = seen.observed.records
    @test length(records) == 2
    both_roots = records[1].caller === Symbol("") && records[2].caller === Symbol("")
    @test both_roots
    @test records[1].task != records[2].task
end

@testset "a nested call names the method that called it" begin
    nested_call = function ()
        got = Probed.outer(10)
        @test got == 11
    end
    probes = Probes(; functions = (Probed.outer, Probed.inner), slow_s = 0.0)
    seen = observed_gate(Probed; workload = nested_call, probes)
    nested = seen.observed.records
    inner = [record for record in nested if record.name === :inner]
    outer = [record for record in nested if record.name === :outer]
    inner_record = only(inner)
    outer_record = only(outer)
    @test inner_record.caller === :outer
    @test inner_record.enclosing == [:outer]
    @test outer_record.caller === Symbol("")
    @test isempty(outer_record.enclosing)
end

@testset "a call inside an ambient function names that function and stays a root" begin
    ambient_call = function ()
        got = Probed.around(5)
        @test got == 6
    end
    probes = Probes(; functions = (Probed.leaf,), ambient = (Probed.around,), slow_s = 0.0)
    seen = observed_gate(Probed; workload = ambient_call, probes)
    records = seen.observed.records
    leaves = [record for record in records if record.name === :leaf]
    leaf_record = only(leaves)
    @test :around in leaf_record.enclosing
    @test leaf_record.caller === Symbol("")
end

@testset "reads walk three containers out from the arguments and stop before the fourth" begin
    marker = Ref(1)
    buried = Ref(2)
    three = (((marker,),),)
    four = ((((buried,),),),)
    look_depths = function ()
        Probed.look(three, four)
    end
    probes = Probes(; functions = (Probed.look,), slow_s = 0.0)
    seen = observed_gate(Probed; workload = look_depths, probes)
    records = seen.observed.records
    record = only(records)
    marker_id = objectid(marker)
    buried_id = objectid(buried)
    @test marker_id in record.reads
    @test !(buried_id in record.reads)
end

@testset "a channel argument is fed and a plain argument is not" begin
    fed = Channel{Int}(1)
    echo_channel = function ()
        Probed.echo(fed)
        Probed.echo(1)
    end
    probes = Probes(; functions = (Probed.echo,), slow_s = 0.0)
    seen = observed_gate(Probed; workload = echo_channel, probes)
    records = seen.observed.records
    echoes = [record for record in records if record.name === :echo]
    fed_records = [record for record in echoes if record.is_fed]
    plain_records = [record for record in echoes if !record.is_fed]
    @test length(fed_records) == 1
    @test length(plain_records) == 1
end

@testset "a generated method and a method with no source are refused" begin
    before = lowered_text(Probed.echo, (Int,))
    generated_probes = Probes(; functions = (Probed.echo, Probed.made), slow_s = 0.0)
    generated = caught(gate_findings, Probed; workload = () -> nothing, probes = generated_probes)
    @test generated isa ArgumentError
    generated_text = sprint(showerror, generated)
    @test occursin("made", generated_text)
    @test occursin("generated", generated_text)
    restored = lowered_text(Probed.echo, (Int,))
    @test restored == before
    made_result = Base.invokelatest(Probed.made, 7)
    @test made_result == 7
    Core.eval(Probed, :(synthed(x) = x + 1))
    unsourced_probes = Probes(; functions = (Probed.synthed,), slow_s = 0.0)
    unsourced = caught(gate_findings, Probed; workload = () -> nothing, probes = unsourced_probes)
    @test unsourced isa ArgumentError
    unsourced_text = sprint(showerror, unsourced)
    @test occursin("synthed", unsourced_text)
    @test occursin("no source site", unsourced_text)
    synthed_result = Base.invokelatest(Probed.synthed, 4)
    @test synthed_result == 5
end

@testset "a spawned task's probed call names its parent" begin
    pkg = PARENT_LINK.pkg
    probes = Probes(; functions = (pkg.parent, pkg.child), slow_s = 0.0)
    returned = Ref{Any}(nothing)
    workload = function ()
        returned[] = pkg.parent(3)
    end
    seen = observed_gate(pkg; workload, probes)
    @test returned[] == 4
    records = seen.observed.records
    children = [record for record in records if record.name === :child]
    child_record = only(children)
    @test child_record.caller === :parent
    restored = Base.invokelatest(pkg.parent, 3)
    @test restored == 4
end

@testset "a parametric keyword method is armed and restored" begin
    pkg = SCALED_KEYWORD.pkg
    sample = [1.0]
    expected = sample .* FLOAT_SAMPLE
    probes = Probes(; functions = (pkg.scaled,), slow_s = 0.0)
    returned = Ref{Any}(nothing)
    workload = function ()
        returned[] = pkg.scaled(sample; scale = FLOAT_SAMPLE)
    end
    warn_path = tempname()
    quiet_run = open(warn_path, "w") do warn_io
        redirect_stderr(warn_io) do
            seen = observed_gate(pkg; workload, probes)
            methods_of = Base.invokelatest(methods, pkg.scaled)
            method = only(methods_of)
            body = Base.bodyfunction(method)
            (; seen, body)
        end
    end
    warn_text = read(warn_path, String)
    warned = occursin("WARNING:", warn_text) || occursin("Warning:", warn_text)
    @test !warned
    @test !isnothing(quiet_run.body)
    records = quiet_run.seen.observed.records
    names = [record.name for record in records]
    @test names == [:scaled]
    @test returned[] == expected
    restored = Base.invokelatest(pkg.scaled, sample; scale = FLOAT_SAMPLE)
    @test restored == expected
    methods_of = Base.invokelatest(methods, pkg.scaled)
    method = only(methods_of)
    source_file = String(method.file)
    @test endswith(source_file, "ScaledKeyword.jl")
end

@testset "a struct's outer constructor and a documented method are probed" begin
    pkg = BOXED_VALUE.pkg
    probes = Probes(; functions = (pkg.Boxed, pkg.twice), slow_s = 0.0)
    returned = Ref{Any}(nothing)
    workload = function ()
        box = pkg.Boxed(BOX_FROM_FLOAT)
        returned[] = pkg.twice(box)
    end
    seen = observed_gate(pkg; workload, probes)
    @test returned[] == 4
    records = seen.observed.records
    names = [record.name for record in records]
    @test sort(names) == [:Boxed, :twice]
    restored = Base.invokelatest(pkg.Boxed, BOX_RESTORED_FLOAT)
    @test restored.value == 3
end

@testset "padding bytes stay out of an argument hash" begin
    low = pad_with(0x00)
    high = pad_with(0xff)
    low_bytes = raw_bytes(low)
    high_bytes = raw_bytes(high)
    @test low_bytes != high_bytes
    echo_pads = function ()
        Probed.echo(low)
        Probed.echo(high)
    end
    probes = Probes(; functions = (Probed.echo,), slow_s = 0.0)
    seen = observed_gate(Probed; workload = echo_pads, probes)
    records = seen.observed.records
    @test length(records) == 2
    @test records[1].arguments == records[2].arguments
end

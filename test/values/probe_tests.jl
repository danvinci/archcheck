# Call zoom: methods re-evaluated from the index, records of the calls a workload actually makes.

pushfirst!(LOAD_PATH, joinpath(@__DIR__, "..", "fixtures"))
using Probed
popfirst!(LOAD_PATH)

const FLOAT_SAMPLE = 2.0
const FLOAT_RESULT = 3.0

function probed_context()
    src = joinpath(pkgdir(Probed), "src")
    root = nameof(Probed)
    spine = joinpath(src, string(root) * ".jl")
    layout = ArchCheck.package_layout(spine, root)
    rank = layout[1]
    dir2mod = layout[2]
    index = build_source_index(src, rank, dir2mod; root)
    Context(index, Probed, [Probed])
end

call(f, args...; kwargs...) = Base.invokelatest(f, args...; kwargs...)

function caught(f, args...)
    try
        Base.invokelatest(f, args...)
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

function caught_arm(functions)
    probes = Probes(; functions, slow_s = 0.0)
    ctx = probed_context()
    local armed
    try
        armed = ArchCheck.arm!(probes, ctx)
    catch err
        return err
    end
    ArchCheck.disarm!(armed)
    nothing
end

function probing(body, functions; ambient = (), slow_s = 0.0)
    probes = Probes(; functions, ambient, slow_s)
    ctx = probed_context()
    armed = ArchCheck.arm!(probes, ctx)
    local records
    try
        body(armed)
    finally
        traced = ArchCheck.disarm!(armed)
        records = traced.records
    end
    records
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
        shift = align - remainder
        remainder == 0 && (shift = UInt(0))
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

@testset "probes: equal values share a hash and the record names the method" begin
    method = only(methods(Probed.same))
    site = (joinpath("src", "Probed.jl"), method.line)
    records = probing((Probed.same,)) do armed
        call(Probed.same, [1, 2, 3])
        call(Probed.same, [1, 2, 3])
        call(Probed.same, [1, 2, 4])
    end
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

@testset "probes: an armed method keeps its result and disarm restores it" begin
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
    records = probing((Probed.early, Probed.keyed, Probed.typed)) do armed
        for case in cases
            got = call(case.called, case.args...; case.kwargs...)
            @test got == case.expected
        end
        for (called, method_count) in method_counts
            methods_of = methods(called)
            @test length(methods_of) == method_count
        end
    end
    seen = [record.name for record in records]
    @test length(seen) == length(cases)
    record_names = unique(case.record_name for case in cases)
    for record_name in record_names
        expected = count(case -> case.record_name === record_name, cases)
        found = count(isequal(record_name), seen)
        @test found == expected
    end
    restored = lowered_text(Probed.early, (Int,))
    @test restored == before
    for case in cases
        got = call(case.called, case.args...; case.kwargs...)
        @test got == case.expected
    end
    for (called, method_count) in method_counts
        methods_of = methods(called)
        @test length(methods_of) == method_count
    end
end

@testset "probes: a throw keeps the exception and the next call is a root" begin
    unprobed = caught(Probed.blows, true)
    records = probing((Probed.blows, Probed.alone)) do armed
        thrown = caught(Probed.blows, true)
        @test same_exception(thrown, unprobed)
        call(Probed.alone, 1)
    end
    alone = [record for record in records if record.name === :alone]
    root = only(alone)
    @test root.caller === Symbol("")
end

@testset "probes: calls on spawned tasks are roots of distinct tasks" begin
    records = probing((Probed.alone,)) do armed
        left = Threads.@spawn Base.invokelatest(Probed.alone, 1)
        right = Threads.@spawn Base.invokelatest(Probed.alone, 2)
        fetch(left)
        fetch(right)
    end
    @test length(records) == 2
    both_roots = records[1].caller === Symbol("") && records[2].caller === Symbol("")
    @test both_roots
    @test records[1].task != records[2].task
end

@testset "probes: a nested call names the method that called it" begin
    nested = probing((Probed.outer, Probed.inner)) do armed
        @test call(Probed.outer, 10) == 11
    end
    inner = [record for record in nested if record.name === :inner]
    outer = [record for record in nested if record.name === :outer]
    inner_record = only(inner)
    outer_record = only(outer)
    @test inner_record.caller === :outer
    @test inner_record.enclosing == [:outer]
    @test outer_record.caller === Symbol("")
    @test isempty(outer_record.enclosing)
end

@testset "probes: a call inside an ambient function names that function and stays a root" begin
    records = probing((Probed.leaf,); ambient = (Probed.around,)) do armed
        @test call(Probed.around, 5) == 6
    end
    leaves = [record for record in records if record.name === :leaf]
    leaf_record = only(leaves)
    @test :around in leaf_record.enclosing
    @test leaf_record.caller === Symbol("")
end

@testset "probes: reads walk three containers out from the arguments and stop before the fourth" begin
    marker = Ref(1)
    buried = Ref(2)
    three = (((marker,),),)
    four = ((((buried,),),),)
    records = probing((Probed.look,)) do armed
        call(Probed.look, three, four)
    end
    record = only(records)
    marker_id = objectid(marker)
    buried_id = objectid(buried)
    @test marker_id in record.reads
    @test !(buried_id in record.reads)
end

@testset "probes: a channel argument is fed and a plain argument is not" begin
    fed = Channel{Int}(1)
    records = probing((Probed.echo,)) do armed
        call(Probed.echo, fed)
        call(Probed.echo, 1)
    end
    echoes = [record for record in records if record.name === :echo]
    fed_records = [record for record in echoes if record.is_fed]
    plain_records = [record for record in echoes if !record.is_fed]
    @test length(fed_records) == 1
    @test length(plain_records) == 1
end

@testset "probes: a generated method and a method with no source are refused" begin
    before = lowered_text(Probed.echo, (Int,))
    generated = caught_arm((Probed.echo, Probed.made))
    @test generated isa ArgumentError
    generated_text = sprint(showerror, generated)
    @test occursin("made", generated_text)
    @test occursin("generated", generated_text)
    restored = lowered_text(Probed.echo, (Int,))
    @test restored == before
    @test call(Probed.made, 7) == 7
    Core.eval(Probed, :(synthed(x) = x + 1))
    unsourced = caught_arm((Probed.synthed,))
    @test unsourced isa ArgumentError
    unsourced_text = sprint(showerror, unsourced)
    @test occursin("synthed", unsourced_text)
    @test occursin("no source site", unsourced_text)
    @test call(Probed.synthed, 4) == 5
end

function indexed_module(name::Symbol, source::String)
    directory = mktempdir()
    src = joinpath(directory, "src")
    mkdir(src)
    file_name = string(name) * ".jl"
    path = joinpath(src, file_name)
    write(path, source)
    mod = Module(name)
    Base.include(mod, path)
    layout = ArchCheck.package_layout(path, name)
    rank = layout[1]
    dir2mod = layout[2]
    index = build_source_index(src, rank, dir2mod; root = name)
    ctx = Context(index, mod, Module[mod])
    (; mod, ctx)
end

@testset "probes: a spawned task's probed call names its parent" begin
    source = """
    function parent(x)
        task = Threads.@spawn child(x)
        fetch(task)
    end

    function child(x)
        x + 1
    end
    """
    loaded = indexed_module(:ParentLink, source)
    probes = Probes(functions = (loaded.mod.parent, loaded.mod.child), slow_s = 0.0)
    armed = ArchCheck.arm!(probes, loaded.ctx)
    local records
    try
        got = Base.invokelatest(loaded.mod.parent, 3)
        @test got == 4
    finally
        traced = ArchCheck.disarm!(armed)
        records = traced.records
    end
    children = [record for record in records if record.name === :child]
    child_record = only(children)
    @test child_record.caller === :parent
end

@testset "probes: a parametric keyword method is armed and restored" begin
    source = """
    function scaled(xs::Vector{T}; scale::T = one(T)) where {T<:Real}
        xs .* scale
    end
    """
    loaded = indexed_module(:ScaledKw, source)
    probes = Probes(functions = (loaded.mod.scaled,), slow_s = 0.0)
    armed = ArchCheck.arm!(probes, loaded.ctx)
    sample = [1.0]
    local traced
    try
        got = Base.invokelatest(loaded.mod.scaled, sample; scale = 2.0)
        @test got == [2.0]
    finally
        traced = ArchCheck.disarm!(armed)
    end
    names = [record.name for record in traced.records]
    @test names == [:scaled]
    restored = loaded.mod.scaled(sample; scale = 2.0)
    @test restored == [2.0]
    method = only(methods(loaded.mod.scaled))
    source_file = String(method.file)
    @test endswith(source_file, "ScaledKw.jl")
end

@testset "probes: a struct's outer constructor and a documented method are probed" begin
    source = """
    struct Boxed
        value::Int
        Boxed(value::Int, scale::Int) = new(value * scale)
    end

    "A box from a float, rounded."
    Boxed(value::Float64) = Boxed(round(Int, value), 1)

    "Twice the boxed value."
    twice(box::Boxed) = 2 * box.value
    """
    loaded = indexed_module(:BoxedCase, source)
    mod = loaded.mod
    probes = Probes(functions = (mod.Boxed, mod.twice), slow_s = 0.0)
    armed = ArchCheck.arm!(probes, loaded.ctx)
    local traced
    try
        box = Base.invokelatest(mod.Boxed, 2.4)
        doubled = Base.invokelatest(mod.twice, box)
        @test doubled == 4
    finally
        traced = ArchCheck.disarm!(armed)
    end
    names = [record.name for record in traced.records]
    @test sort(names) == [:Boxed, :twice]
    restored = Base.invokelatest(mod.Boxed, 3.0)
    @test restored.value == 3
end

@testset "probes: padding bytes stay out of an argument hash" begin
    low = pad_with(0x00)
    high = pad_with(0xff)
    low_bytes = raw_bytes(low)
    high_bytes = raw_bytes(high)
    @test low_bytes != high_bytes
    records = probing((Probed.echo,)) do armed
        call(Probed.echo, low)
        call(Probed.echo, high)
    end
    @test length(records) == 2
    @test records[1].arguments == records[2].arguments
end

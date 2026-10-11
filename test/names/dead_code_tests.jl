# A definition no root reaches through names is dead. A script entry keeps a name alive. A test entry does not.

function dead_findings(case; entry_dirs = String[], options...)
    check = DeadCode(; options...)
    ctx = case_context(case; entry_dirs)
    found = ArchCheck.run(check, ctx)
    Dict(finding.symbol => finding for finding in found)
end

dead_symbols(case; options...) = Set(keys(dead_findings(case; options...)))

const DEAD_ENTRY_DIR = mktempdir()
write(joinpath(DEAD_ENTRY_DIR, "run.jl"), "entry()\n")
const DEAD_AND_CALLED = load_package("DeadAndCalled", """
include("body.jl")
""", ["body.jl" => """
keep() = 1
gone() = 2
entry() = keep()
chain_head() = chain_tail()
chain_tail() = 3
ping() = pong()
pong() = ping()
spin(n) = n > 0 ? spin(n - 1) : 0
macro emitted()
    :(expanded())
end
expanded() = 4
"""])

const DEFAULT_HELPER = load_package("DefaultHelper", """
owner(x = helper()) = x
helper() = 1
""")

const SCRIPT_ENTRY_DIR = mktempdir()
write(joinpath(SCRIPT_ENTRY_DIR, "run.jl"), "shipped()\n")
const SCRIPT_ENTRY = load_package("ScriptEntry", """
include("body.jl")
""", ["body.jl" => "shipped() = 1\n"])

const TEST_DIRECTORY = load_package("TestDirectory", """
include("body.jl")
""", ["body.jl" => "tested() = 1\n"])
const TEST_DIRECTORY_DIR = joinpath(TEST_DIRECTORY.root, "test")
mkpath(TEST_DIRECTORY_DIR)
write(joinpath(TEST_DIRECTORY_DIR, "runtests.jl"), "tested()\n")

const EXPORTED_NAME = load_package("ExportedName", """
export uncalled
public visible
include("impl.jl")
for name in names(@__MODULE__; all = true)
    startswith(string(name), "loop_api") && @eval export \$name
end
""", ["impl.jl" => "uncalled() = 1\nvisible() = 2\nhidden() = 3\nloop_api() = loop_helper()\nloop_helper() = 4\n"])

const QUALIFIED_CALL = load_package("QualifiedCall", """
include("aa/Aa.jl")
using .Aa
include("cc/Cc.jl")
using .Cc
""", [
    "aa/Aa.jl" => "module Aa\ninclude(\"defs.jl\")\nend\n",
    "aa/defs.jl" => "helper() = 1\n",
    "cc/Cc.jl" => "module Cc\ninclude(\"caller.jl\")\nend\n",
    "cc/caller.jl" => "user() = Aa.helper()\n",
])

const LOCAL_BINDING_BODY = """
struct PosMark end
struct PosCallLaw end
struct PosWhereLaw{T} end
struct PosIndexLaw end
struct PosMarker end
struct PosOwner
    value::Int
    PosOwner(x = pos_ctor_helper()) = new(x)
end

labeled_owner() = (neg_label = pos_labeled_helper(),)
neg_label() = 1
pos_labeled_helper() = 1
nested_label_owner() = [(neg_nested_label = pos_nested_helper(),) for _ in (1,)]
neg_nested_label() = 1
pos_nested_helper() = 1
called_label_owner() = (pos_field = pos_items(),)
pos_items() = 1

keyed_owner(; knots = pos_keyed_helper()) = knots
pos_keyed_helper() = 1
same_owner(pos_same_helper = pos_same_helper()) = pos_same_helper
pos_same_helper() = 1
later_owner(x = pos_later_helper(), pos_later_helper = 1) = x
pos_later_helper() = 1
earlier_owner(neg_earlier_helper = () -> 2, x = neg_earlier_helper()) = x
neg_earlier_helper() = 1
keyed_same_owner(; pos_keyed_same_helper = pos_keyed_same_helper()) = pos_keyed_same_helper
pos_keyed_same_helper() = 1
function hid_owner(x = pos_hid_helper())
    pos_hid_helper = 1
    x
end
pos_hid_helper() = 1
anon_owner(::PosMark, x = pos_anon_helper()) = x
pos_anon_helper() = PosMark()
pos_ctor_helper() = 1
destruct_owner((neg_destruct_helper, value), x = neg_destruct_helper()) = x
neg_destruct_helper() = 1
where_owner(x::neg_tee) where neg_tee = x
neg_tee() = 1

pos_law_helper() = pos_leaf()
pos_leaf() = 1
(law::PosCallLaw)(x) = pos_law_helper()
function (law::PosWhereLaw{T})(x = pos_where_helper()) where {T}
    law
end
pos_where_helper() = 1
function Base.getindex(row::PosIndexLaw, index)
    pos_foreign_helper()
end
pos_foreign_helper() = 1
Some{T}(marker::PosMarker) where {T} = marker

function global_owner()
    global pos_global_helper
    pos_global_helper()
end
pos_global_helper() = 1
function callback_owner()
    pos_callback_helper = 1
    callback = () -> begin
        global pos_callback_helper
        pos_callback_helper()
    end
    callback()
end
pos_callback_helper() = 1
function branch_owner()
    if true
        neg_branch_helper = 1
    end
    neg_branch_helper
end
neg_branch_helper() = 1
function try_owner()
    try
        neg_try_helper = 1
        neg_try_helper
    catch
        0
    end
end
neg_try_helper() = 1
lambda_owner() = map(x -> pos_lambda_helper(x), (1,))
pos_lambda_helper(x) = x
function let_owner()
    let neg_let_shadow = 1
        neg_let_shadow
    end
    pos_let_helper()
end
neg_let_shadow() = 1
pos_let_helper() = 1
function nested_global_owner()
    neg_nested_helper = 1
    callback = () -> begin
        global neg_nested_helper
        1
    end
    neg_nested_helper
    callback()
end
neg_nested_helper() = 1
gen_owner() = [pos_gen_helper(x) for x in (1,)]
pos_gen_helper(x) = x
ordered_owner(values) = [pos_leaf_j(neg_loop_j) for neg_loop_i in values for neg_loop_j in pos_produce(neg_loop_i)]
pos_leaf_j(j) = j
pos_produce(i) = (i,)
neg_loop_i() = 1
neg_loop_j() = 1
function nest_owner()
    inner(x = pos_inner_helper()) = x
    inner()
end
pos_inner_helper() = 1
function indexed_owner(values, index)
    pos_store[index] = values
end
pos_store() = 1
function typed_owner()
    neg_typed_local::PosMarker = pos_make()
    neg_typed_local
end
neg_typed_local() = 1
pos_make() = PosMarker()
"""

# Exported, so each owner is a root and a name its code reads stays live.
const LOCAL_BINDING_OWNERS = (
    "labeled_owner", "nested_label_owner", "called_label_owner", "keyed_owner", "same_owner", "later_owner",
    "earlier_owner", "keyed_same_owner", "hid_owner", "anon_owner", "destruct_owner", "where_owner",
    "global_owner", "callback_owner", "branch_owner", "try_owner", "lambda_owner", "let_owner",
    "nested_global_owner", "gen_owner", "ordered_owner", "nest_owner", "indexed_owner", "typed_owner",
)

const LOCAL_BINDINGS = load_package("LocalBindings", """
export $(join(LOCAL_BINDING_OWNERS, ", "))
include("types.jl")
include("body.jl")
include("ext.jl")
""", [
    "types.jl" => "struct PosExtLaw end\n",
    "body.jl" => LOCAL_BINDING_BODY,
    "ext.jl" => "(law::PosExtLaw)(x) = pos_ext_helper()\npos_ext_helper() = 1\n",
])

const LOCAL_BINDING_DEAD = (
    "neg_label", "neg_nested_label", "neg_earlier_helper", "neg_destruct_helper", "neg_tee",
    "neg_branch_helper", "neg_try_helper", "neg_let_shadow", "neg_nested_helper",
    "neg_loop_i", "neg_loop_j", "neg_typed_local",
)
const LOCAL_BINDING_LIVE = (
    "pos_labeled_helper", "pos_nested_helper", "pos_items", "pos_keyed_helper", "pos_same_helper",
    "pos_later_helper", "pos_keyed_same_helper", "pos_hid_helper", "pos_anon_helper", "pos_ctor_helper",
    "pos_law_helper", "pos_leaf", "pos_ext_helper", "pos_where_helper", "pos_foreign_helper",
    "pos_lambda_helper", "pos_let_helper", "pos_gen_helper", "pos_leaf_j", "pos_produce",
    "pos_inner_helper", "pos_store", "pos_make", "pos_global_helper", "pos_callback_helper",
)

@testset "a definition only dead code names is dead, and its evidence names them" begin
    dead = dead_findings(DEAD_AND_CALLED; entry_dirs = [DEAD_ENTRY_DIR])
    @test Set(keys(dead)) == Set(["gone", "chain_head", "chain_tail", "ping", "pong", "spin"])
    @test isempty(dead["gone"].evidence)
    @test isempty(dead["chain_head"].evidence)
    @test ev(dead["chain_tail"], :named_by) == "chain_head"
    @test ev(dead["ping"], :named_by) == "pong"
    @test ev(dead["pong"], :named_by) == "ping"
    @test ev(dead["spin"], :named_by) == "spin"
end

@testset "a default argument's call names its helper" begin
    dead = dead_findings(DEFAULT_HELPER)
    @test isempty(dead["owner"].evidence)
    @test ev(dead["helper"], :named_by) == "owner"
end

@testset "a script entry or an unloaded extension keeps a definition and a directory named test does not" begin
    lonely = dead_symbols(SCRIPT_ENTRY)
    @test "shipped" in lonely
    shipped = dead_symbols(SCRIPT_ENTRY; entry_dirs = [SCRIPT_ENTRY_DIR])
    @test !("shipped" in shipped)
    tested = dead_symbols(TEST_DIRECTORY; entry_dirs = [TEST_DIRECTORY_DIR])
    @test "tested" in tested
    hosted = dead_symbols(HOSTED)
    @test !("_absent_only" in hosted)
end

@testset "an exported or public name is an entry unless the package turns that off, a load-time export included" begin
    library = dead_symbols(EXPORTED_NAME)
    @test library == Set(["hidden"])
    application = dead_symbols(EXPORTED_NAME; public_is_entry = false)
    @test application == Set(["uncalled", "visible", "hidden", "loop_api", "loop_helper"])
end

@testset "a qualified call from another module names the definition" begin
    dead = dead_findings(QUALIFIED_CALL)
    @test isempty(dead["user"].evidence)
    @test ev(dead["helper"], :named_by) == "user"
end

const FIELD_READS = load_package("FieldReads", """
include("aa/Aa.jl")
using .Aa
include("body.jl")
""", [
    "aa/Aa.jl" => "module Aa\npos_qualified() = 1\npos_renamed() = 1\nend\n",
    "body.jl" => """
    argument_owner(x) = x.neg_argument_field
    neg_argument_field() = 1
    nested_owner(x) = x.inner.neg_nested_field
    neg_nested_field() = 1
    call_owner() = Ref(1).neg_call_field
    neg_call_field() = 1
    function loop_owner(items)
        for item in items
            item.neg_loop_field
        end
    end
    neg_loop_field() = 1
    const TOP_VALUE = (; neg_top_field = 1).neg_top_field
    neg_top_field() = 1
    qualified_owner() = Aa.pos_qualified()
    const RENAMED = Aa
    renamed_owner() = RENAMED.pos_renamed()
    foreign_owner() = Base.neg_foreign_member()
    neg_foreign_member() = 1
    if false
        Base.neg_foreign_top()
    end
    neg_foreign_top() = 1
    const SELF = @__MODULE__
    spliced_owner() = :(\$SELF.pos_spliced())
    pos_spliced() = 1
    macro_owner() = (@__MODULE__).pos_macro_qualified()
    pos_macro_qualified() = 1
    """,
])

@testset "a field read or another package's member is not a reference to the function it shares a name with" begin
    dead = dead_findings(FIELD_READS)
    unread = ("neg_argument_field", "neg_nested_field", "neg_call_field", "neg_loop_field", "neg_top_field",
              "neg_foreign_member", "neg_foreign_top")
    for name in unread
        @test isempty(dead[name].evidence)
    end
    named = ("pos_qualified" => "qualified_owner", "pos_renamed" => "renamed_owner",
             "pos_spliced" => "spliced_owner", "pos_macro_qualified" => "macro_owner")
    for (name, owner) in named
        @test ev(dead[name], :named_by) == owner
    end
end

# `colon` adds methods to `Base.:(:)`, and `@recipe` keeps no function `plotted`, so what each reads stays live;
# `@inline` keeps its definition.
const LOADED_FUNCTION = load_package("LoadedFunction", """
macro recipe(ex)
    :(nothing)
end
include("ranges.jl")
""", ["ranges.jl" => """
struct Span
    lo::Int   # first value
end
const colon = Base.:(:)
colon(a::Span, b::Span) = span_range(a, b)
span_range(a, b) = a.lo:b.lo
@recipe function plotted(x::Int)
    erased_helper()
end
erased_helper() = 1
@inline function inlined_unused()
    1
end
unused_helper() = 1
"""])

@testset "a definition is judged as the function its loaded method belongs to" begin
    dead = dead_symbols(LOADED_FUNCTION)
    @test dead == Set(["inlined_unused", "unused_helper"])
end

@testset "a local binding is not a call and a real call of another name still counts" begin
    dead = dead_symbols(LOCAL_BINDINGS)
    for name in LOCAL_BINDING_DEAD
        @test name in dead
    end
    for name in LOCAL_BINDING_LIVE
        @test !(name in dead)
    end
    @test !("PosCallLaw" in dead)
    @test !("Some" in dead)
end

# `f ≀ x` adds a method of `≀`. The left name is an argument.
const INFIX_DEFINITION = load_package("InfixDefinition", """
include("body.jl")
""", ["body.jl" => """
f ≀ x = infix_helper()
infix_helper() = 1
"""])

@testset "an infix definition is judged as the operator its loaded method belongs to" begin
    dead = dead_symbols(INFIX_DEFINITION)
    @test dead == Set(["infix_helper", "≀"])
end

# The fallback include parses the extension, and this Julia skips that branch. The extension's trigger is absent.
const FALLBACK_INCLUDE = load_package("FallbackInclude", """
kept_by_extension() = 1
if !isdefined(Base, :get_extension)
    include("../ext/FallbackIncludeAbsentExt.jl")
end
""", [
    "../ext/FallbackIncludeAbsentExt.jl" => """
    module FallbackIncludeAbsentExt
    using FallbackInclude
    caller() = FallbackInclude.kept_by_extension()
    end
    """,
], """
[weakdeps]
Absent = "4d5c8b1e-0f3a-4e6b-9c2d-7a1b3c5d7e9f"

[extensions]
FallbackIncludeAbsentExt = "Absent"
""")

@testset "a fallback include of an unloaded extension keeps the definition that extension reads" begin
    dead = dead_symbols(FALLBACK_INCLUDE)
    @test !("kept_by_extension" in dead)
end

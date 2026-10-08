# Heap-array polynomial routines appended beside the fixed-size copies.
const VECTOR_KERNELS = 6

function signature_of(ex)
    head = ex.args[1]
    if head isa Expr && head.head === :where
        return head.args[1]
    end
    head
end

function is_vector_kernel(::Any)
    false
end

function is_vector_kernel(ex::Expr)
    ex.head === :function || return false
    signature = signature_of(ex)
    signature isa Expr || return false
    signature.head === :call || return false
    name = signature.args[1]
    name === :bernstein_to_monomial && return false
    text = string(signature)
    occursin("Vector{Float64}", text)
end

function vector_kernel_blocks(source)
    parsed = Meta.parseall(source)
    blocks = String[]
    for ex in parsed.args
        is_vector_kernel(ex) || continue
        cleaned = Base.remove_linenums!(ex)
        push!(blocks, string(cleaned))
    end
    blocks
end

function append_kernels(tree, blocks)
    kernels = joinpath(tree, "src", "numerics", "kernels.jl")
    chmod(kernels, 0o644)
    original = read(kernels, String)
    marker = "\n# --- second copy, Vector storage ---\n"
    body = join(blocks, "\n\n")
    combined = original * marker * body * "\n"
    write(kernels, combined)
end

program = abspath(PROGRAM_FILE)
this_file = @__FILE__
if program == this_file
    tree = ARGS[1]
    repo = ARGS[2]
    commit = ARGS[3]
    shown = read(`git -C $repo show $commit^:src/numerics/kernels.jl`, String)
    blocks = vector_kernel_blocks(shown)
    count = length(blocks)
    count == VECTOR_KERNELS || throw(ArgumentError("vector kernels: $count"))
    append_kernels(tree, blocks)
    println("appended ", count, " Vector kernels")
end

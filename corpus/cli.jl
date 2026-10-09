# A runner's command line: the ArchCheck tree, the arguments, and the result table.

function archcheck_root()
    project = Base.active_project()
    isnothing(project) && throw(ArgumentError("activate the package project first"))
    dirname(project)
end

# The config's file name labels its directory in the cache.
function take_args(args, usage)
    config = ""
    cache = joinpath(homedir(), ".cache", "archcheck-corpus")
    index = 1
    while index <= length(args)
        arg = args[index]
        if arg == "--cache"
            cache = args[index + 1]
            index += 2
        else
            config = arg
            index += 1
        end
    end
    isempty(config) && throw(ArgumentError(usage))
    file_name = basename(config)
    label = splitext(file_name)[1]
    (config = config, cache = cache, label = label)
end

# The first line is the header; each column pads to its widest cell.
function print_cells(io, lines)
    column_count = length(first(lines))
    widths = Int[]
    for index in 1:column_count
        longest = 0
        for line in lines
            longest = max(longest, length(line[index]))
        end
        push!(widths, longest)
    end
    for line in lines
        padded = String[]
        for index in 1:column_count
            cell = rpad(line[index], widths[index])
            push!(padded, cell)
        end
        text = join(padded, "  ")
        println(io, text)
    end
end

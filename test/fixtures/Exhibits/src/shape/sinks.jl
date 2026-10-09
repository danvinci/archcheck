# sinkable, extract_candidate: three defs whose signature and body touch only an earlier module

public sink_a, sink_b, sink_c

function sink_a(brick::Low.Brick)
    Low.helper()
    0
end

function sink_b(brick::Low.Brick)
    Low.helper()
    1
end

function sink_c(brick::Low.Brick)
    Low.helper()
    2
end

# rebuild, two_names, wait, unread_wait: probed calls and a dropped join

const shared_mark = Ref(0)

const PRODUCE_WAIT_S = 0.05   # pause so the wait has a measurable duration, seconds

function left_name(x::Int)
    shared_mark
end

function right_name(x::Int)
    shared_mark
end

function produced()
    sleep(PRODUCE_WAIT_S)
    Ref(1)
end

function looked(value)
    value
end

function drops()
    task = Threads.@spawn produced()
    fetch(task)
    looked(Ref(2))
    0
end

# unread_wait: a join whose result the method throws away

function produced()
    Ref(1)
end

function drops()
    task = Threads.@spawn produced()
    fetch(task)
    0
end

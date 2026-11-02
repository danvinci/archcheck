# unread_wait: a join whose result the method throws away

function produced()
    Ref(1)
end

function drops()
    task = Threads.@spawn produced()
    fetch(task)
    0
end

# untyped_task_result: a join whose result the method reads with no element type
function joined()
    task = Threads.@spawn produced()
    fetch(task)
end

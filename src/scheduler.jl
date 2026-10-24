## The ready queue
##
## `tar_make` takes targets from a queue of those whose selected dependencies
## have all finished, in declaration order. With one job at a time this is
## exactly the pipeline's build order; it is also what lets independent targets
## run concurrently.

"""
    ReadyQueue(p, selected)

Scheduling state for the `selected` targets of `p`: how many unfinished
selected dependencies each target still waits for, and the targets that are
ready, ordered by declaration.
"""
struct ReadyQueue
    index::Dict{Symbol, Int}
    waiting::Dict{Symbol, Int}
    dependents::Dict{Symbol, Vector{Symbol}}
    ready::Vector{Symbol}
end

function ReadyQueue(p::Pipeline, selected)
    chosen = Set{Symbol}(selected)
    waiting = Dict{Symbol, Int}()
    dependents = Dict{Symbol, Vector{Symbol}}(name => Symbol[] for name in chosen)
    for name in chosen
        deps = unique(filter(in(chosen), get_target(p, name).deps))
        waiting[name] = length(deps)
        foreach(d -> push!(dependents[d], name), deps)
    end
    q = ReadyQueue(p.index, waiting, dependents, Symbol[])
    foreach(name -> waiting[name] == 0 && push_ready!(q, name), chosen)
    return q
end

function push_ready!(q::ReadyQueue, name::Symbol)
    i = searchsortedfirst(q.ready, name; by = n -> q.index[n])
    insert!(q.ready, i, name)
    return q
end

has_ready(q::ReadyQueue) = !isempty(q.ready)
peek_ready(q::ReadyQueue) = first(q.ready)
pop_ready!(q::ReadyQueue) = popfirst!(q.ready)

"Mark `name` finished and queue the dependents that no longer wait for anything."
function finish!(q::ReadyQueue, name::Symbol)
    for d in q.dependents[name]
        q.waiting[d] -= 1
        q.waiting[d] == 0 && push_ready!(q, d)
    end
    return q
end

"Drain the queue one target at a time, calling `f(name)` for each."
function drain!(f, q::ReadyQueue)
    while has_ready(q)
        name = pop_ready!(q)
        f(name)
        finish!(q, name)
    end
    return nothing
end

@testitem "the ready queue yields the build order one job at a time" begin
    using Targets: ReadyQueue, drain!, selected_order
    p = tar_pipeline(
        target(:c, (a, b) -> 1),
        target(:a, () -> 1),
        target(:b, a -> 1),
        target(:x, () -> 1),
        target(:y, (x, c) -> 1),
    )
    order(names) = (out = Symbol[]; drain!(n -> push!(out, n), ReadyQueue(p, names)); out)
    @test order(p.order) == p.order
    sub = selected_order(p, [:c])
    @test order(sub) == sub
end

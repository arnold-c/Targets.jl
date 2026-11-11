## The ready queue
##
## `tar_make` takes targets from a queue of those whose selected dependencies
## have all finished, in declaration order. With one job at a time this is
## exactly the pipeline's build order; it is also what lets independent targets
## run concurrently.

"""
    ReadyQueue(p, selected; priority = Dict{Symbol, Float64}())

Scheduling state for the `selected` targets of `p`: how many unfinished
selected dependencies each target still waits for, and the targets that are
ready, ordered by `priority` (highest first) and then by declaration.
"""
struct ReadyQueue
    index::Dict{Symbol, Int}
    priority::Dict{Symbol, Float64}
    waiting::Dict{Symbol, Int}
    dependents::Dict{Symbol, Vector{Symbol}}
    ready::Vector{Symbol}
end

function ReadyQueue(p::Pipeline, selected; priority = Dict{Symbol, Float64}())
    chosen = Set{Symbol}(selected)
    waiting = Dict{Symbol, Int}()
    dependents = Dict{Symbol, Vector{Symbol}}(name => Symbol[] for name in chosen)
    for name in chosen
        deps = unique(filter(in(chosen), get_target(p, name).deps))
        waiting[name] = length(deps)
        foreach(d -> push!(dependents[d], name), deps)
    end
    q = ReadyQueue(p.index, priority, waiting, dependents, Symbol[])
    foreach(name -> waiting[name] == 0 && push_ready!(q, name), chosen)
    return q
end

function push_ready!(q::ReadyQueue, name::Symbol)
    i = searchsortedfirst(q.ready, name; by = n -> ready_order(q, n))
    insert!(q.ready, i, name)
    return q
end

ready_order(q::ReadyQueue, name::Symbol) = (-get(q.priority, name, 0.0), q.index[name])

has_ready(q::ReadyQueue) = !isempty(q.ready)
peek_ready(q::ReadyQueue) = first(q.ready)
pop_ready!(q::ReadyQueue) = popfirst!(q.ready)
remove_ready!(q::ReadyQueue, name::Symbol) = deleteat!(
    q.ready,
    findfirst(==(name), q.ready),
)

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

"""
    critical_path(p, selected, seconds)

For each selected target, the longest total time (by `seconds`, the last
recorded build times) from the start of that target to the end of the build.
Preferring targets on the longest remaining path keeps the build short.
"""
function critical_path(p::Pipeline, selected, seconds::AbstractDict{Symbol, <:Real})
    chosen = Set{Symbol}(selected)
    path = Dict{Symbol, Float64}()
    for name in Iterators.reverse(selected)
        # dependents come first
        downstream = [path[d] for d in descendants_of(p, name) if d in chosen]
        path[name] = get(seconds, name, 0.0) + maximum(downstream; init = 0.0)
    end
    return path
end

"Direct dependents of `name` in `p`."
descendants_of(p::Pipeline, name::Symbol) = [
    p.targets[j].name
    for j in outneighbors(p.graph, p.index[name])
]

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

@testitem "the ready queue prefers targets on the critical path" begin
    using Targets: ReadyQueue, drain!, critical_path
    p = tar_pipeline(
        target(:quick, () -> 1),
        target(:slow, () -> 1),
        target(:after_slow, slow -> 1),
    )
    path = critical_path(p, p.order, Dict(:quick => 1.0, :slow => 5.0, :after_slow => 2.0))
    @test path == Dict(:quick => 1.0, :slow => 7.0, :after_slow => 2.0)
    out = Symbol[]
    drain!(n -> push!(out, n), ReadyQueue(p, p.order; priority = path))
    @test out == [:slow, :after_slow, :quick]
    @test critical_path(p, p.order, Dict{Symbol, Float64}()) ==
        Dict(n => 0.0 for n in p.order)
end

## Drawing the pipeline
##
## The layout is computed here, by layers, so that the Graphviz export and the
## Makie plot (an extension) share it and no layout package is needed.

const _descendants = descendants   # the `descendants` keyword below shadows the function

"""
    graph_nodes(p, names, with_descendants)

Targets to draw, in build order: all of them, or `names` with their ancestors
(and, if asked, everything downstream of them).
"""
function graph_nodes(p::Pipeline, names, with_descendants::Bool)
    names === nothing && return copy(p.order)
    keep = Set(ancestors(p, names))
    with_descendants && union!(keep, _descendants(p, names))
    return filter(n -> n in keep, p.order)
end

"""
    GraphLayout

`layers[i]` lists the targets in layer `i - 1` from top to bottom, and
`positions[name] = (x, y)` places layers left to right.
"""
struct GraphLayout
    layers::Vector{Vector{Symbol}}
    positions::Dict{Symbol,Tuple{Float64,Float64}}
end

"""
    graph_layout(p, nodes)

Layer each target by its longest path from a root within `nodes`, then order
targets within a layer by the mean position of their neighbours (to reduce
crossings), falling back to declaration order for ties.
"""
function graph_layout(p::Pipeline, nodes::Vector{Symbol})
    shown = Set(nodes)
    deps(n) = [d for d in get_target(p, n).deps if d in shown]
    dependents = Dict(n => Symbol[] for n in nodes)
    for n in nodes, d in deps(n)
        push!(dependents[d], n)
    end
    layer_of = Dict{Symbol,Int}()
    for n in nodes   # build order: dependencies come first
        layer_of[n] = isempty(deps(n)) ? 0 : 1 + maximum(layer_of[d] for d in deps(n))
    end
    depth = isempty(nodes) ? 0 : maximum(values(layer_of)) + 1
    layers = [filter(n -> layer_of[n] == i - 1, nodes) for i in 1:depth]
    declared = Dict(n => p.index[n] for n in nodes)

    position = Dict(n => Float64(i) for layer in layers for (i, n) in enumerate(layer))
    function reorder!(layer, neighbours)
        key(n) = begin
            ns = neighbours(n)
            (isempty(ns) ? position[n] : sum(position[m] for m in ns) / length(ns), declared[n])
        end
        sort!(layer; by = key)
        for (i, n) in enumerate(layer)
            position[n] = Float64(i)
        end
    end
    for _ in 1:2
        foreach(i -> reorder!(layers[i], deps), 2:depth)
        foreach(i -> reorder!(layers[i], n -> dependents[n]), (depth - 1):-1:1)
    end
    positions = Dict{Symbol,Tuple{Float64,Float64}}()
    for (i, layer) in enumerate(layers), (j, n) in enumerate(layer)
        positions[n] = (Float64(i - 1), (length(layer) + 1) / 2 - j)
    end
    return GraphLayout(layers, positions)
end

"""
    node_statuses(p, nodes; store, root)

`:uptodate`, `:outdated`, `:errored` or `:unbuilt` for each target, computed
from the current code and store (nothing is stored).
"""
function node_statuses(p::Pipeline, nodes; store, root)
    reasons = Dict(r.name => r.reason for r in tar_outdated(p; names = nodes, store, root))
    status(reason) =
        reason === nothing ? :uptodate :
        reason == :missing ? :unbuilt : reason == :errored ? :errored : :outdated
    return Dict(n => status(get(reasons, n, nothing)) for n in nodes)
end

const STATUS_COLORS = Dict(
    :uptodate => "#a6dba0",
    :outdated => "#fdb863",
    :errored => "#e66101",
    :unbuilt => "#d9d9d9",
)

node_label(::Pipeline, t::Target) = string(t.name)

"""
    tar_dot(p::Pipeline; names = nothing, descendants = false, status = true,
            store = default_store_path(), root = nothing)

Graphviz DOT text for the pipeline, laid out left to right and coloured by
status (up to date, outdated, errored, not built). With `names`, only those
targets and their ancestors are drawn; `descendants = true` adds everything
downstream of them. File targets are drawn as boxes. `status = false` draws the
structure only, without consulting the store.
"""
function tar_dot(
    p::Pipeline;
    names = nothing,
    descendants::Bool = false,
    status::Bool = true,
    store::Union{Store,AbstractString} = default_store_path(),
    root::Union{Nothing,AbstractString} = nothing,
)
    nodes = graph_nodes(p, names, descendants)
    layout = graph_layout(p, nodes)
    statuses = status ? node_statuses(p, nodes; store, root) : nothing
    io = IOBuffer()
    println(io, "digraph targets {")
    println(io, "  rankdir=LR;")
    println(io, "  node [style=filled, fontname=\"Helvetica\"];")
    for n in nodes
        t = get_target(p, n)
        color = statuses === nothing ? "#ffffff" : STATUS_COLORS[statuses[n]]
        shape = t.format == :file ? "box" : "ellipse"
        println(io, "  \"$n\" [label=\"$(node_label(p, t))\", shape=$shape, fillcolor=\"$color\"];")
    end
    shown = Set(nodes)
    for n in nodes, d in get_target(p, n).deps
        d in shown && println(io, "  \"$d\" -> \"$n\";")
    end
    for layer in layout.layers
        println(io, "  { rank=same; ", join(("\"$n\";" for n in layer), " "), " }")
    end
    println(io, "}")
    return String(take!(io))
end
tar_dot(; script::AbstractString = default_script(), kwargs...) =
    tar_dot(load_pipeline(script); kwargs...)

"""
    tar_visnetwork(p::Pipeline; names = nothing, descendants = false, ...)

Plot the pipeline with the same layout, colours and subgraph selection as
[`tar_dot`](@ref). Needs GraphMakie and a Makie backend: `using GraphMakie, CairoMakie`
(or `GLMakie`). Returns a Makie `Figure`.
"""
function tar_visnetwork(args...; kwargs...)
    error(
        "tar_visnetwork needs GraphMakie and a Makie backend; load them first, " *
        "e.g. `using GraphMakie, CairoMakie`",
    )
end
tar_visnetwork(; script::AbstractString = default_script(), kwargs...) =
    tar_visnetwork(load_pipeline(script); kwargs...)

@testmodule GraphFixtures begin
    using Targets
    export diamond

    "raw -> {left, right} -> both, plus an unrelated target `other` and a file target."
    diamond() = tar_pipeline(
        target(:raw, () -> 1),
        target(:left, raw -> raw + 1),
        target(:right, raw -> raw + 2),
        target(:both, (left, right) -> left + right),
        target(:other, () -> 5),
    )
end

@testitem "graph_layout layers by longest path and orders within layers" setup = [GraphFixtures] begin
    using Targets: graph_layout
    p = diamond()
    layout = graph_layout(p, copy(p.order))
    @test layout.layers == [[:raw, :other], [:left, :right], [:both]]
    @test layout.positions[:raw][1] == 0 && layout.positions[:both][1] == 2
    # within a layer the order is top to bottom
    @test layout.positions[:left][2] > layout.positions[:right][2]
    # a longer path pushes a target further right than its shortest dependency suggests
    q = tar_pipeline(
        target(:a, () -> 1),
        target(:b, a -> 1),
        target(:c, b -> 1),
        target(:d, (a, c) -> 1),
    )
    @test graph_layout(q, copy(q.order)).layers == [[:a], [:b], [:c], [:d]]
    @test graph_layout(p, Symbol[]).layers == []
end

@testitem "graph_nodes selects ancestors, optionally with descendants" setup = [GraphFixtures] begin
    using Targets: graph_nodes
    p = diamond()
    @test graph_nodes(p, nothing, false) == p.order
    @test graph_nodes(p, [:left], false) == [:raw, :left]
    @test graph_nodes(p, [:left], true) == [:raw, :left, :both]
    @test graph_nodes(p, [:other], true) == [:other]
end

@testitem "tar_dot draws nodes, edges, ranks and subgraphs" setup = [GraphFixtures] begin
    p = diamond()
    dot = tar_dot(p; status = false)
    @test startswith(dot, "digraph targets {")
    @test occursin("\"raw\" -> \"left\";", dot)
    @test occursin("\"left\" -> \"both\";", dot)
    @test occursin("{ rank=same; \"left\"; \"right\"; }", dot)
    @test !occursin("\"other\" ->", dot)
    sub = tar_dot(p; names = [:left], status = false)
    @test occursin("\"raw\" -> \"left\";", sub)
    @test !occursin("right", sub) && !occursin("both", sub)
    @test occursin("\"both\"", tar_dot(p; names = [:left], descendants = true, status = false))
    @test_throws "did you mean `left`" tar_dot(p; names = [:lft], status = false)
end

@testitem "tar_dot colours targets by status as code and the store change" setup = [SourceFixtures] begin
    mktempdir() do dir
        code(clean) = """
        p = tar_pipeline(
            target(:raw, () -> 10),
            target(:clean, raw -> $clean),
            target(:model, clean -> clean * 2),
        )
        """
        green, orange, gray = "#a6dba0", "#fdb863", "#d9d9d9"
        dot(code) = begin
            m, _ = load_source(code; dir)
            p = Base.invokelatest(getproperty, m, :p)
            tar_dot(p; store = joinpath(dir, "_targets"), root = dir)
        end
        function colour(d, name)
            line = only(filter(l -> startswith(strip(l), "\"$name\" ["), split(d, '\n')))
            return match(r"fillcolor=\"(#\w+)\"", line).captures[1]
        end
        d0 = dot(code("raw + 1"))
        @test [colour(d0, n) for n in (:raw, :clean, :model)] == [gray, orange, orange]
        build_source(code("raw + 1"), dir)
        d1 = dot(code("raw + 1"))
        @test [colour(d1, n) for n in (:raw, :clean, :model)] == [green, green, green]
        d2 = dot(code("raw + 2"))     # an edit: clean and its descendant are outdated
        @test [colour(d2, n) for n in (:raw, :clean, :model)] == [green, orange, orange]
    end
end

@testitem "tar_visnetwork explains how to enable plotting" setup = [GraphFixtures] begin
    @test_throws "GraphMakie" tar_visnetwork(diamond())
end

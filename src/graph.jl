## Drawing the pipeline
##
## The layout is computed here, by layers, so that the Graphviz export and the
## Makie plot (an extension) share it and no layout package is needed.

const _descendants = descendants # the `descendants` keyword below shadows the function

"""
    graph_nodes(p, names, with_descendants)

Targets to draw, in build order: all of them, or `names` with their ancestors
(and, if asked, everything downstream of them).
"""
function graph_nodes(p::Pipeline, names, with_descendants::Bool)
    names = as_names(names)
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
    positions::Dict{Symbol, Tuple{Float64, Float64}}
end

"""
    layer_numbers(p, nodes)

Each target's layer: the length of the longest path to it from a root within
`nodes`, which must be in build order (dependencies first).
"""
function layer_numbers(p::Pipeline, nodes::Vector{Symbol})
    layer_of = Dict{Symbol, Int}()
    for n in nodes
        upstream = [layer_of[d] for d in get_target(p, n).deps if haskey(layer_of, d)]
        layer_of[n] = isempty(upstream) ? 0 : 1 + maximum(upstream)
    end
    return layer_of
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
    layer_of = layer_numbers(p, nodes)
    depth = isempty(nodes) ? 0 : maximum(values(layer_of)) + 1
    layers = [filter(n -> layer_of[n] == i - 1, nodes) for i in 1:depth]
    declared = Dict(n => p.index[n] for n in nodes)

    position = Dict(n => Float64(i) for layer in layers for (i, n) in enumerate(layer))
    function reorder!(layer, neighbours)
        key(n) = begin
            ns = neighbours(n)
            (
                isempty(ns) ? position[n] : sum(position[m] for m in ns) / length(ns),
                declared[n],
            )
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
    positions = Dict{Symbol, Tuple{Float64, Float64}}()
    for (i, layer) in enumerate(layers), (j, n) in enumerate(layer)
        positions[n] = (Float64(i - 1), (length(layer) + 1) / 2 - j)
    end
    return GraphLayout(layers, positions)
end

"""
    node_statuses(p, nodes; store, root)

`:uptodate`, `:outdated`, `:errored` or `:unbuilt` for each target, computed
from the current code and store (nothing is stored), or `:running` while a
build in progress (by its events) is running it.
"""
function node_statuses(p::Pipeline, nodes; store, root)
    reasons = Dict(r.name => r.reason for r in tar_outdated(p; names = nodes, store, root))
    running = running_targets(as_store(store))
    status(reason) = reason === nothing ?
        :uptodate :
        reason == :missing ? :unbuilt : reason == :errored ? :errored : :outdated
    return Dict(
        n => n in running ? :running : status(get(reasons, n, nothing))
        for n in nodes
    )
end

const STATUS_COLORS = Dict(
    :uptodate => "#a6dba0",
    :outdated => "#fdb863",
    :errored => "#e66101",
    :unbuilt => "#d9d9d9",
    :running => "#80b1d3",
)

"Status => description, in the order statuses are listed."
const STATUS_LABELS = (
    uptodate = "Up to date",
    outdated = "Outdated",
    errored = "Errored",
    unbuilt = "Not built",
    running = "Running",
)

"How many branches each branching target has in the store (absent if not built)."
function branch_counts(p::Pipeline, nodes, store)
    s = as_store(store)
    counts = Dict{Symbol, Int}()
    for n in nodes
        get_target(p, n).pattern === nothing && continue
        record = read_meta(s, n)
        record === nothing || (counts[n] = length(record.branches))
    end
    return counts
end

node_label(t::Target, counts::AbstractDict) = haskey(counts, t.name) ?
    "$(t.name) [$(counts[t.name])]" :
    string(t.name)

"""
    DotGraph

Graphviz DOT text returned by [`tar_dot`](@ref). Prints as the DOT text, renders as
SVG where rich display is available and Graphviz is installed, and converts with
`string`. `write(path, g)` saves the DOT file.
"""
struct DotGraph
    dot::String
end

Base.string(g::DotGraph) = g.dot
Base.show(io::IO, ::MIME"text/plain", g::DotGraph) = print(io, g.dot)
Base.show(io::IO, g::DotGraph) = print(io, "DotGraph(", count(==('\n'), g.dot), " lines)")
Base.write(io::IO, g::DotGraph) = write(io, g.dot)
Base.write(path::AbstractString, g::DotGraph) = write(path, g.dot)

graphviz() = Sys.which("dot")
Base.showable(::MIME"image/svg+xml", ::DotGraph) = graphviz() !== nothing
function Base.show(io::IO, ::MIME"image/svg+xml", g::DotGraph)
    exe = graphviz()
    exe === nothing && error("rendering DOT as SVG needs Graphviz's `dot` on the PATH")
    print(io, read(pipeline(IOBuffer(g.dot), `$exe -Tsvg`), String))
end

"""
    tar_dot(p::Pipeline; names = nothing, descendants = false, status = true,
            store = default_store_path(), root = nothing)

A [`DotGraph`](@ref): Graphviz DOT for the pipeline, laid out left to right and coloured by
status (up to date, outdated, errored, not built). With `names`, only those
targets and their ancestors are drawn; `descendants = true` adds everything
downstream of them. File targets are drawn as boxes. `status = false` draws the
structure only, without consulting the store.

At the REPL it prints the DOT text; in notebooks and VS Code it renders as an SVG
when Graphviz (`dot`) is installed. `write("pipeline.dot", tar_dot())` saves it,
and `string(tar_dot())` gives the text.
"""
function tar_dot(
    p::Pipeline;
    names = nothing,
    descendants::Bool = false,
    status::Bool = true,
    store::Union{Store, AbstractString} = default_store_path(),
    root::Union{Nothing, AbstractString} = nothing,
)
    nodes = graph_nodes(p, names, descendants)
    layout = graph_layout(p, nodes)
    statuses = status ? node_statuses(p, nodes; store, root) : nothing
    counts = status ? branch_counts(p, nodes, store) : Dict{Symbol, Int}()
    io = IOBuffer()
    println(io, "digraph targets {")
    println(io, "  rankdir=LR;")
    println(io, "  node [style=filled, fontname=\"Helvetica\"];")
    for n in nodes
        t = get_target(p, n)
        color = statuses === nothing ? "#ffffff" : STATUS_COLORS[statuses[n]]
        shape = t.format == :file ? "box" : "ellipse"
        println(
            io,
            "  \"$n\" [label=\"$(node_label(t, counts))\", shape=$shape, fillcolor=\"$color\"];",
        )
    end
    shown = Set(nodes)
    for n in nodes, d in get_target(p, n).deps
        d in shown && println(io, "  \"$d\" -> \"$n\";")
    end
    for layer in layout.layers
        println(io, "  { rank=same; ", join(("\"$n\";" for n in layer), " "), " }")
    end
    println(io, "}")
    return DotGraph(String(take!(io)))
end
tar_dot(; script::AbstractString = default_script(), kwargs...) = tar_dot(
    load_pipeline(script);
    kwargs...,
)

"""
    NetworkData

Everything needed to draw a pipeline, independent of how it is plotted: node
names, labels, positions (from [`graph_layout`](@ref)), fill colours, whether each
node is a file target, edges as index pairs `(dependency, dependent)`, each
node's [`tar_list`](@ref) section and, unless drawn without status, its status.
"""
struct NetworkData
    nodes::Vector{Symbol}
    labels::Vector{String}
    positions::Vector{Tuple{Float64, Float64}}
    colors::Vector{String}
    is_file::Vector{Bool}
    edges::Vector{Tuple{Int, Int}}
    sections::Vector{Symbol}
    statuses::Union{Nothing, Vector{Symbol}}
end

function network_data(p::Pipeline; names, descendants::Bool, status::Bool, store, root)
    nodes = graph_nodes(p, names, descendants)
    layout = graph_layout(p, nodes)
    index = Dict(n => i for (i, n) in enumerate(nodes))
    statuses = status ? node_statuses(p, nodes; store, root) : nothing
    counts = status ? branch_counts(p, nodes, store) : Dict{Symbol, Int}()
    targets = [get_target(p, n) for n in nodes]
    return NetworkData(
        nodes,
        [node_label(t, counts) for t in targets],
        [layout.positions[n] for n in nodes],
        [statuses === nothing ? "#ffffff" : STATUS_COLORS[statuses[n]] for n in nodes],
        [t.format == :file for t in targets],
        [
            (index[d], index[n])
            for n in nodes
            for d in get_target(p, n).deps
            if haskey(index, d)
        ],
        [list_section(t) for t in targets],
        statuses === nothing ? nothing : [statuses[n] for n in nodes],
    )
end

const MAKIE_ID = Base.PkgId(Base.UUID("ee78f7c6-11fb-53f2-987a-cfe4a2b5a57a"), "Makie")

"""
    network_figure(data; figure_size, interactive = false) -> (figure, axis, state)

An undecorated Makie figure and axis for `data`, with the pipeline drawn into it
from the Observables in `state` (positions, selection, hidden targets); with
`interactive = true`, targets can be dragged, selected and hidden. Defined by
TargetsMakieExt.
"""
function network_figure end

"""
    open_interactive(figure) -> figure

Display `figure` with an interactive Makie backend (GLMakie or WGLMakie), or
explain how to load one. Defined by TargetsMakieExt.
"""
function open_interactive end

"""
    interactive_backend() -> Bool

Whether the active Makie backend can show an interactive figure (GLMakie or
WGLMakie). Defined by TargetsMakieExt.
"""
function interactive_backend end

"""
    tar_visnetwork(p::Pipeline; names = nothing, descendants = false, status = true,
                   store = default_store_path(), root = nothing, figure_size = (900, 500),
                   interactive = nothing)

Plot the pipeline with the same layout, colours and subgraph selection as
[`tar_dot`](@ref), returning a Makie `Figure`. Needs a Makie backend
(`using CairoMakie`, `GLMakie` or `WGLMakie`). File targets are squares, branching
targets show their branch count, and colours show status.

An interactive figure opens in a window (GLMakie) or fills a browser tab
(WGLMakie), resizing with it (`figure_size` is only its starting size), and can
be rearranged there:

- drag a target to move it (its edges and label follow); dragging a selected
  target moves the whole selection;
- click a target to select it, shift-click to add it to the selection (or remove
  it), shift-drag to select every target in an area, and click the background
  to clear the selection;
- drag the background or use the right mouse button to pan, scroll to zoom, and
  ctrl-click to reset the view.

A side panel hides targets: uncheck a kind (constants, input files,
computations, output files) or a status (up to date, outdated, ...) to hide
those targets, use "Hide selected" to hide the selection or "Show only selected"
to hide everything else, and "Show all" to undo all hiding. Under "Also show",
switch on "Dependencies" or "Descendants" to bring back everything upstream or
downstream of the targets still shown, however it was hidden (e.g. after hiding
a selection, to restore the targets the rest need). What a switch shows is
fixed when it goes on and does not count what the other one shows; switching it
off hides those targets again. Edges to hidden
targets are hidden too.

By default (`interactive = nothing`) the figure is interactive exactly when
GLMakie or WGLMakie is the active backend.
`interactive = false` always gives a static figure, and `interactive = true`
errors under any other backend.
"""
function tar_visnetwork(
    p::Pipeline;
    names = nothing,
    descendants::Bool = false,
    status::Bool = true,
    store::Union{Store, AbstractString} = default_store_path(),
    root::Union{Nothing, AbstractString} = nothing,
    figure_size = (900, 500),
    interactive::Union{Nothing, Bool} = nothing,
)
    haskey(Base.loaded_modules, MAKIE_ID) ||
        error(
            "tar_visnetwork needs a Makie backend; load one first, e.g. `using CairoMakie`",
        )
    hasmethod(network_figure, Tuple{NetworkData}) ||
        error(
            "Makie is loaded but Targets' plotting extension is not. The active environment's " *
                "Manifest.toml may record out-of-date extension information for Targets (common when " *
                "Targets is `dev`ed by path): run `import Pkg; Pkg.resolve()` and restart Julia.",
        )
    data = network_data(p; names, descendants, status, store, root)
    interactive = something(interactive, interactive_backend())
    fig, _ = network_figure(data; figure_size, interactive)
    return interactive ? open_interactive(fig) : fig
end
tar_visnetwork(; script::AbstractString = default_script(), kwargs...) = tar_visnetwork(
    load_pipeline(script);
    kwargs...,
)

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

@testitem "graph_layout layers by longest path and orders within layers" setup = [
    GraphFixtures,
] begin
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

@testitem "graph_nodes selects ancestors, optionally with descendants" setup = [
    GraphFixtures,
] begin
    using Targets: graph_nodes
    p = diamond()
    @test graph_nodes(p, nothing, false) == p.order
    @test graph_nodes(p, [:left], false) == [:raw, :left]
    @test graph_nodes(p, [:left], true) == [:raw, :left, :both]
    @test graph_nodes(p, [:other], true) == [:other]
end

@testitem "tar_dot draws nodes, edges, ranks and subgraphs" setup = [GraphFixtures] begin
    p = diamond()
    dot = string(tar_dot(p; status = false))
    @test startswith(dot, "digraph targets {")
    @test occursin("\"raw\" -> \"left\";", dot)
    @test occursin("\"left\" -> \"both\";", dot)
    @test occursin("{ rank=same; \"left\"; \"right\"; }", dot)
    @test !occursin("\"other\" ->", dot)
    sub = string(tar_dot(p; names = [:left], status = false))
    @test occursin("\"raw\" -> \"left\";", sub)
    @test !occursin("right", sub) && !occursin("both", sub)
    @test occursin(
        "\"both\"",
        string(tar_dot(p; names = [:left], descendants = true, status = false)),
    )
    @test_throws "did you mean `left`" tar_dot(p; names = [:lft], status = false)
end

@testitem "tar_dot colours targets by status as code and the store change" setup = [
    SourceFixtures,
] begin
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
            string(tar_dot(p; store = joinpath(dir, "_targets"), root = dir))
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
        d2 = dot(code("raw + 2")) # an edit: clean and its descendant are outdated
        @test [colour(d2, n) for n in (:raw, :clean, :model)] == [green, orange, orange]
    end
end

@testitem "tar_visnetwork explains how to enable plotting" setup = [GraphFixtures] begin
    # (a shared test process may already have loaded Makie; then there is nothing to explain)
    if !haskey(Base.loaded_modules, Targets.MAKIE_ID)
        @test_throws "Makie backend" tar_visnetwork(diamond())
    end
end

@testitem "tar_visnetwork plots through the Makie extension" setup = [GraphFixtures] begin
    using Makie
    fig = tar_visnetwork(diamond(); status = false)
    @test fig isa Makie.Figure
    ax = only(filter(c -> c isa Makie.Axis, fig.content))
    @test !isempty(ax.scene.plots)
    @test tar_visnetwork(diamond(); names = [:left], status = false) isa Makie.Figure
    @test tar_visnetwork(diamond(); names = [:left], descendants = true, status = false) isa
        Makie.Figure
end

@testitem "tar_visnetwork is interactive by default only with GLMakie or WGLMakie" setup = [
    GraphFixtures,
] begin
    using Makie
    using Targets: interactive_backend
    previous = Makie.CURRENT_BACKEND[]
    try
        # stand-ins named like backends: only the name decides
        for (name, expected) in ((:GLMakie, true), (:WGLMakie, true), (:CairoMakie, false))
            Makie.CURRENT_BACKEND[] = Module(name)
            @test interactive_backend() == expected
        end
        # WGLMakie fills the browser tab; GLMakie's window resizes the figure itself
        ext = Base.get_extension(Targets, :TargetsMakieExt)
        @test ext.screen_config(:WGLMakie) == (; resize_to = :body)
        @test ext.screen_config(:GLMakie) == (;)

        Makie.CURRENT_BACKEND[] = missing
        @test !interactive_backend()
        fig = tar_visnetwork(diamond(); status = false) # static by default
        ax = only(filter(c -> c isa Makie.Axis, fig.content))
        @test haskey(ax.interactions, :rectanglezoom)
        @test_throws "interactive Makie backend" tar_visnetwork(
            diamond();
            status = false,
            interactive = true,
        )
    finally
        Makie.CURRENT_BACKEND[] = previous
    end
end

@testmodule MouseFixtures begin
    using Makie
    using Targets
    using Targets: NetworkData, network_data, network_figure
    export interactive_diamond, figure_px, drag!, click!

    """
    An interactive figure of raw -> {left, right} -> both, plus `other`, as
    `(; data, fig, ax, state, at)`, where `at(name)` is a target's current position.
    `statuses` (in that node order) adds a status per target.
    """
    function interactive_diamond(; statuses = nothing)
        p = tar_pipeline(
            target(:raw, () -> 1),
            target(:left, raw -> raw + 1),
            target(:right, raw -> raw + 2),
            target(:both, (left, right) -> left + right),
            target(:other, () -> 5),
        )
        data = network_data(
            p;
            names = nothing,
            descendants = false,
            status = false,
            store = "",
            root = nothing,
        )
        fields = [getfield(data, f) for f in fieldnames(NetworkData)]
        data = NetworkData(fields[1:(end - 1)]..., statuses)
        fig, ax, state = network_figure(data; interactive = true)
        at(name) = state.positions[][findfirst(==(name), data.nodes)]
        return (; data, fig, ax, state, at)
    end

    "Figure pixels of `point` (data units) in `ax`."
    function figure_px(ax, point)
        lims, vp = ax.finallimits[], Makie.viewport(ax.scene)[]
        return Tuple(vp.origin .+ (point .- lims.origin) .* widths(vp) ./ widths(lims))
    end

    function with_shift(f, fig, shift::Bool)
        ev = events(fig)
        shift && (ev.keyboardbutton[] = Makie.KeyEvent(Keyboard.left_shift, Keyboard.press))
        f()
        shift &&
            (ev.keyboardbutton[] = Makie.KeyEvent(Keyboard.left_shift, Keyboard.release))
    end

    "A left-button drag between two figure pixel positions."
    drag!(fig, from, to; shift = false) = with_shift(fig, shift) do
        ev = events(fig)
        ev.mouseposition[] = from
        ev.mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
        for t in 0.25:0.25:1
            ev.mouseposition[] = from .+ t .* (to .- from)
        end
        ev.mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
    end

    "A left click at a figure pixel position."
    click!(fig, at; shift = false) = with_shift(fig, shift) do
        ev = events(fig)
        ev.mouseposition[] = at
        ev.mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.press)
        ev.mousebutton[] = Makie.MouseButtonEvent(Mouse.left, Mouse.release)
    end
end

@testitem "interactive network figures drag nodes and pan the background" setup = [
    MouseFixtures,
] begin
    using Makie
    using Targets: network_figure
    (; data, fig, ax, state, at) = interactive_diamond()
    @test !haskey(ax.interactions, :rectanglezoom) # left drags are ours
    labels = only(filter(p -> p isa Makie.Text, ax.scene.plots))
    arrows = only(filter(p -> p isa Makie.Arrows2D, ax.scene.plots))

    start = at(:both)
    arrows_before = copy(arrows[1][])
    target = start + Point2f(-0.5, 1)
    drag!(fig, figure_px(ax, start), figure_px(ax, target))
    @test at(:both) ≈ target atol = 0.01
    @test labels[1][][findfirst(==(:both), data.nodes)] ≈
        target atol = 0.01 # the label follows
    @test arrows[1][] != arrows_before # and so do the edges
    moved(i) = state.positions[][i] != Point2f(data.positions[i]...)
    @test count(moved, eachindex(data.nodes)) == 1

    # dragging empty space pans instead
    limits_before = ax.targetlimits[]
    empty_space = Point2f(ax.finallimits[].origin) + Point2f(0.05, 0.05)
    drag!(fig, figure_px(ax, empty_space), figure_px(ax, empty_space) .+ (100, 0))
    @test ax.targetlimits[].origin[1] < limits_before.origin[1]
    @test at(:both) ≈ target atol = 0.01

    # without interactive, the axis keeps its usual interactions and there is no panel
    plain_fig, plain = network_figure(data)
    @test haskey(plain.interactions, :rectanglezoom)
    @test !any(c -> c isa Makie.Button, plain_fig.content)
end

@testitem "interactive network figures select targets and move them together" setup = [
    MouseFixtures,
] begin
    using Makie
    (; data, fig, ax, state, at) = interactive_diamond()
    selected() = data.nodes[state.selected[]]
    px(name) = figure_px(ax, at(name))

    # shift-drag around left and right (one above the other, between raw and both)
    lo = min.(at(:left), at(:right)) .- 0.3
    hi = max.(at(:left), at(:right)) .+ 0.3
    drag!(fig, figure_px(ax, lo), figure_px(ax, hi); shift = true)
    @test selected() == [:left, :right]
    @test !state.boxing[] # the box is gone once the selection is made

    # dragging a selected target moves the whole selection, and nothing else
    before = Dict(n => at(n) for n in data.nodes)
    drag!(fig, px(:left), figure_px(ax, at(:left) + Point2f(0.5, 0)))
    moved = [n for n in data.nodes if !isapprox(at(n), before[n]; atol = 0.01)]
    @test moved == [:left, :right]
    @test at(:right) ≈ before[:right] + Point2f(0.5, 0) atol = 0.01

    # dragging a target outside the selection moves only it
    drag!(fig, px(:raw), figure_px(ax, at(:raw) + Point2f(0, 0.3)))
    @test at(:left) ≈ before[:left] + Point2f(0.5, 0) atol = 0.01
    @test selected() == [:left, :right]

    # shift-click adds a target, and removes it again
    click!(fig, px(:raw); shift = true)
    @test selected() == [:raw, :left, :right]
    click!(fig, px(:raw); shift = true)
    @test selected() == [:left, :right]

    # a plain click selects one target; on the background it clears the selection
    click!(fig, px(:both))
    @test selected() == [:both]
    click!(fig, figure_px(ax, Point2f(ax.finallimits[].origin) + Point2f(0.05, 0.05)))
    @test isempty(selected())
end

@testitem "interactive network figures hide targets by selection, kind and status" setup = [
    MouseFixtures,
] begin
    using Makie
    statuses = [:uptodate, :outdated, :outdated, :unbuilt, :uptodate]
    (; data, fig, ax, state, at) = interactive_diamond(; statuses)
    shown() = data.nodes[state.visible[]]
    # the panel, in order: kinds present (constants, computations), then statuses
    # present (up to date, outdated, not built); then Hide selected, Show only
    # selected and Show all
    constants, computations, uptodate, outdated, unbuilt = filter(
        c -> c isa Makie.Checkbox,
        fig.content,
    )
    hide, only_selected, show = filter(c -> c isa Makie.Button, fig.content)
    labels = only(filter(p -> p isa Makie.Text, ax.scene.plots))
    arrows = only(filter(p -> p isa Makie.Arrows2D, ax.scene.plots))
    left = findfirst(==(:left), data.nodes)

    # hide the selection: its label and edges go, and it can no longer be grabbed
    click!(fig, figure_px(ax, at(:left)))
    hide.clicks[] += 1
    @test shown() == [:raw, :right, :both, :other]
    @test labels.color[][left].alpha == 0
    touching = [k for (k, (i, j)) in enumerate(data.edges) if left in (i, j)]
    @test all(iszero, arrows[2][][touching])
    @test !any(iszero, arrows[2][][setdiff(eachindex(data.edges), touching)])
    @test !any(state.selected[]) # hidden targets leave the selection
    before = at(:left)
    drag!(fig, figure_px(ax, at(:left)), figure_px(ax, at(:left) + Point2f(0.4, 0)))
    @test at(:left) == before # the drag panned instead

    # by kind, on top of the hand-hidden target
    computations.checked[] = false
    @test shown() == [:raw, :other]
    computations.checked[] = true
    @test shown() == [:raw, :right, :both, :other]

    # by status; selected targets that get hidden leave the selection
    click!(fig, figure_px(ax, at(:right)))
    outdated.checked[] = false
    @test shown() == [:raw, :both, :other]
    @test !any(state.selected[])
    uptodate.checked[] = false
    @test shown() == [:both]

    # Show all undoes every kind of hiding
    show.clicks[] += 1
    @test shown() == data.nodes
    @test all(c -> c.checked[], (constants, computations, uptodate, outdated, unbuilt))

    # Show only selected hides everything else, keeping the selection and its edges
    click!(fig, figure_px(ax, at(:left)))
    click!(fig, figure_px(ax, at(:both)); shift = true)
    only_selected.clicks[] += 1
    @test shown() == [:left, :both]
    @test data.nodes[state.selected[]] == [:left, :both]
    between = findfirst(==((left, findfirst(==(:both), data.nodes))), data.edges)
    @test findall(!iszero, arrows[2][]) == [between]
    # with nothing selected it does nothing, rather than hiding everything
    click!(fig, figure_px(ax, Point2f(ax.finallimits[].origin) + Point2f(0.05, 0.05)))
    only_selected.clicks[] += 1
    @test shown() == [:left, :both]
    show.clicks[] += 1
    @test shown() == data.nodes

    # without statuses, only the kinds have checkboxes
    plain = interactive_diamond()
    @test count(c -> c isa Makie.Checkbox, plain.fig.content) == 2
end

@testitem "interactive network figures show the dependencies and descendants of shown targets" setup = [
    MouseFixtures,
] begin
    using Makie
    (; data, fig, ax, state, at) = interactive_diamond()
    shown() = data.nodes[state.visible[]]
    px(name) = figure_px(ax, at(name))
    background = Point2f(ax.finallimits[].origin) + Point2f(0.05, 0.05)
    constants, computations = filter(c -> c isa Makie.Checkbox, fig.content)
    hide, only_selected, show = filter(c -> c isa Makie.Button, fig.content)
    dependencies, descendants = filter(c -> c isa Makie.Toggle, fig.content)

    # dependencies and descendants are followed recursively
    reachable = Base.get_extension(Targets, :TargetsMakieExt).reachable
    marked(names...) = [n in names for n in data.nodes]
    @test data.nodes[reachable(data.edges, marked(:both), :upstream)] ==
        [:raw, :left, :right]
    @test data.nodes[reachable(data.edges, marked(:raw), :downstream)] ==
        [:left, :right, :both]
    @test !any(reachable(data.edges, marked(:other), :upstream))

    # hide some targets, then bring back those the rest depend on
    click!(fig, px(:raw))
    click!(fig, px(:left); shift = true)
    hide.clicks[] += 1
    @test shown() == [:right, :both, :other]
    dependencies.active[] = true
    @test shown() == data.nodes # right needs raw, and both needs left
    dependencies.active[] = false
    @test shown() == [:right, :both, :other]
    show.clicks[] += 1

    # the switches start from the shown targets, whatever is selected, and not
    # from what the other switch shows
    click!(fig, px(:left))
    only_selected.clicks[] += 1
    click!(fig, figure_px(ax, background))
    @test shown() == [:left] && !any(state.selected[])
    dependencies.active[] = true
    @test shown() == [:raw, :left]
    descendants.active[] = true
    @test shown() == [:raw, :left, :both] # not right, a descendant of raw

    # what is shown stays while other targets are selected, e.g. to move them
    click!(fig, px(:raw))
    @test data.nodes[state.selected[]] == [:raw]
    @test shown() == [:raw, :left, :both]

    # switching off hides them again (and they leave the selection)
    dependencies.active[] = false
    @test shown() == [:left, :both]
    @test !any(state.selected[])

    # shown targets stay shown when their kind is hidden
    computations.checked[] = false
    @test shown() == [:both]

    # Show all switches them off too
    show.clicks[] += 1
    @test shown() == data.nodes
    @test !dependencies.active[] && !descendants.active[]

    # with nothing shown, a switch shows nothing either
    constants.checked[] = false
    computations.checked[] = false
    dependencies.active[] = true
    @test isempty(shown())
end

@testitem "tar_dot returns a DotGraph that prints its DOT text" setup = [
    GraphFixtures,
] begin
    using Targets: DotGraph
    d = tar_dot(diamond(); status = false)
    @test d isa DotGraph
    @test sprint(show, MIME("text/plain"), d) == string(d)
    @test startswith(string(d), "digraph targets {")
    mktempdir() do dir
        path = joinpath(dir, "p.dot")
        write(path, d)
        @test read(path, String) == string(d)
    end
end

@testitem "network_data describes the nodes, edges and labels to draw" setup = [
    GraphFixtures,
] begin
    using Targets: network_data
    d = network_data(
        diamond();
        names = nothing,
        descendants = false,
        status = false,
        store = "",
        root = nothing,
    )
    @test d.nodes == [:raw, :left, :right, :both, :other]
    @test sort(d.edges) == [(1, 2), (1, 3), (2, 4), (3, 4)]
    @test d.labels == string.(d.nodes)
    @test length(d.positions) == 5 && !any(d.is_file)
    @test d.sections ==
        [:constants, :computations, :computations, :computations, :constants]
    @test d.statuses === nothing
    mktempdir() do dir
        # nothing built yet
        s = network_data(
            diamond();
            names = [:left],
            descendants = false,
            status = true,
            store = joinpath(dir, "_targets"),
            root = dir,
        )
        @test s.statuses == [:unbuilt, :outdated] # as in tar_dot's colours
    end
end

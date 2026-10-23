module TargetsGraphMakieExt

# Loaded automatically once both GraphMakie and Makie (through a backend such as
# CairoMakie or GLMakie) are loaded, so `using Targets` itself stays fast.

using GraphMakie: graphplot!
using Graphs: SimpleDiGraph, add_edge!
using Makie: Axis, Figure, Point2f, hidedecorations!, hidespines!
using Targets:
    Targets,
    Pipeline,
    STATUS_COLORS,
    get_target,
    graph_layout,
    graph_nodes,
    branch_counts,
    node_label,
    node_statuses

function Targets.tar_visnetwork(
    p::Pipeline;
    names = nothing,
    descendants::Bool = false,
    status::Bool = true,
    store = Targets.default_store_path(),
    root = nothing,
    figure_size = (900, 500),
)
    nodes = graph_nodes(p, names, descendants)
    layout = graph_layout(p, nodes)
    index = Dict(n => i for (i, n) in enumerate(nodes))
    g = SimpleDiGraph(length(nodes))
    for n in nodes, d in get_target(p, n).deps
        haskey(index, d) && add_edge!(g, index[d], index[n])
    end
    statuses = status ? node_statuses(p, nodes; store, root) : nothing
    colors = [statuses === nothing ? "#ffffff" : STATUS_COLORS[statuses[n]] for n in nodes]
    counts = status ? branch_counts(p, nodes, store) : Dict{Symbol, Int}()
    labels = [node_label(get_target(p, n), counts) for n in nodes]
    positions = [Point2f(layout.positions[n]...) for n in nodes]

    fig = Figure(; size = figure_size)
    ax = Axis(fig[1, 1])
    hidedecorations!(ax)
    hidespines!(ax)
    graphplot!(
        ax,
        g;
        layout = _ -> positions,
        node_color = colors,
        node_size = 30,
        nlabels = labels,
        nlabels_align = (:center, :bottom),
        nlabels_offset = Point2f(0, 0.12),
        arrow_size = 14,
    )
    return fig
end

end

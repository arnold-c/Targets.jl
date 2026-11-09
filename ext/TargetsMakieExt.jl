module TargetsMakieExt

# Loaded automatically once Makie is loaded (any backend: `using CairoMakie` or
# `using GLMakie` is enough), so `using Targets` itself stays fast. Draws the layout
# Targets computes with plain Makie primitives.

using Makie:
    Axis,
    Figure,
    Point2f,
    arrows2d!,
    hidedecorations!,
    hidespines!,
    scatter!,
    text!,
    xlims!,
    ylims!
using Targets: Targets, NetworkData

const MARKER_SIZE = 28                # px
const LABEL_OFFSET = 18               # px above the marker centre
const ARROW_GAP = MARKER_SIZE / 2 + 4 # px between an arrow's ends and the marker centres

function limits(data::NetworkData)
    xs = isempty(data.positions) ? [0.0] : first.(data.positions)
    ys = isempty(data.positions) ? [0.0] : last.(data.positions)
    return (minimum(xs) - 0.5, maximum(xs) + 0.5), (minimum(ys) - 0.6, maximum(ys) + 0.8)
end

# Edges are shortened by a fixed number of *pixels*, not data units: the axes are not
# square, so a data-space gap would leave arrow heads overlapping the markers.
function edge_segments(data::NetworkData, xlim, ylim, figure_size)
    sx = figure_size[1] / (xlim[2] - xlim[1]) # px per data unit
    sy = figure_size[2] / (ylim[2] - ylim[1])
    starts, dirs = Point2f[], Point2f[]
    for (i, j) in data.edges
        a, b = data.positions[i], data.positions[j]
        dx, dy = (b[1] - a[1]) * sx, (b[2] - a[2]) * sy # edge in pixels
        len = sqrt(dx^2 + dy^2)
        len > 2 * ARROW_GAP || continue
        k = ARROW_GAP / len
        push!(starts, Point2f(a[1] + k * (b[1] - a[1]), a[2] + k * (b[2] - a[2])))
        push!(dirs, Point2f((1 - 2k) * (b[1] - a[1]), (1 - 2k) * (b[2] - a[2])))
    end
    return starts, dirs
end

function Targets.network_figure(data::NetworkData; figure_size = (900, 500))
    fig = Figure(; size = figure_size)
    ax = Axis(fig[1, 1])
    hidedecorations!(ax)
    hidespines!(ax)
    xlim, ylim = limits(data)
    xlims!(ax, xlim...)
    ylims!(ax, ylim...)

    starts, dirs = edge_segments(data, xlim, ylim, figure_size)
    isempty(starts) ||
        arrows2d!(
            ax,
            starts,
            dirs;
            color = :gray40,
            shaftwidth = 1.5,
            tipwidth = 10,
            tiplength = 10,
        )
    points = [Point2f(p...) for p in data.positions]
    scatter!(
        ax,
        points;
        color = data.colors,
        marker = [f ? :rect : :circle for f in data.is_file],
        markersize = MARKER_SIZE,
        strokewidth = 1.5,
        strokecolor = :gray30,
    )
    text!(
        ax,
        points;
        text = data.labels,
        align = (:center, :bottom),
        offset = (0, LABEL_OFFSET),
        fontsize = 14,
    )
    return fig, ax
end

end

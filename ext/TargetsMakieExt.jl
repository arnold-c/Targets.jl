module TargetsMakieExt

# Loaded automatically once Makie is loaded (any backend: `using CairoMakie`,
# `using GLMakie` or `using WGLMakie` is enough), so `using Targets` itself stays
# fast. Draws the layout Targets computes with plain Makie primitives, from node
# positions held in an Observable so that the interactive view can move them.

using Makie:
    Axis,
    Consume,
    Figure,
    MouseEvent,
    MouseEventTypes,
    Observable,
    Point2f,
    Rect2d,
    arrows2d!,
    current_backend,
    deregister_interaction!,
    hidedecorations!,
    hidespines!,
    lift,
    register_interaction!,
    scatter!,
    text!,
    viewport,
    widths,
    xlims!,
    ylims!
using Targets: Targets, NetworkData

const MARKER_SIZE = 28                # px
const LABEL_OFFSET = 18               # px above the marker centre
const ARROW_GAP = MARKER_SIZE / 2 + 4 # px between an arrow's ends and the marker centres
const GRAB_RADIUS = MARKER_SIZE / 2 +
    4 # px from a marker centre within which a press grabs it
const INTERACTIVE_BACKENDS = (:GLMakie, :WGLMakie)

function limits(data::NetworkData)
    xs = isempty(data.positions) ? [0.0] : first.(data.positions)
    ys = isempty(data.positions) ? [0.0] : last.(data.positions)
    return (minimum(xs) - 0.5, maximum(xs) + 0.5), (minimum(ys) - 0.6, maximum(ys) + 0.8)
end

"Pixels per data unit along x and y, for an axis showing `lims` in `vp`."
pixels_per_unit(lims, vp) = widths(vp) ./ widths(lims)

# Edges are shortened by a fixed number of *pixels*, not data units: the axes are not
# square, so a data-space gap would leave arrow heads overlapping the markers. There
# is always one arrow per edge (an Observable's length must not change), so the edge
# between overlapping markers becomes a zero-length arrow, which draws nothing.
function edge_segments(positions, edges, lims, vp)
    scale = pixels_per_unit(lims, vp)
    starts = Vector{Point2f}(undef, length(edges))
    dirs = Vector{Point2f}(undef, length(edges))
    for (k, (i, j)) in enumerate(edges)
        a, b = positions[i], positions[j]
        len = sqrt(sum(abs2, (b - a) .* scale)) # edge length in pixels
        k_gap = len > 2 * ARROW_GAP ? ARROW_GAP / len : 0.5
        starts[k] = a + k_gap * (b - a)
        dirs[k] = (1 - 2k_gap) * (b - a)
    end
    return starts, dirs
end

function Targets.network_figure(
    data::NetworkData;
    figure_size = (900, 500),
    interactive::Bool = false,
)
    fig = Figure(; size = figure_size)
    ax = Axis(fig[1, 1])
    hidedecorations!(ax)
    hidespines!(ax)
    xlim, ylim = limits(data)
    xlims!(ax, xlim...)
    ylims!(ax, ylim...)

    positions = Observable([Point2f(p...) for p in data.positions])
    if !isempty(data.edges)
        # recomputed on zoom, pan and resize as well, so the pixel gaps stay right
        segments = lift(
            (ps, lims, vp) -> edge_segments(ps, data.edges, lims, vp),
            positions,
            ax.finallimits,
            viewport(ax.scene),
        )
        arrows2d!(
            ax,
            lift(first, segments),
            lift(last, segments);
            color = :gray40,
            shaftwidth = 1.5,
            tipwidth = 10,
            tiplength = 10,
        )
    end
    scatter!(
        ax,
        positions;
        color = data.colors,
        marker = [f ? :rect : :circle for f in data.is_file],
        markersize = MARKER_SIZE,
        strokewidth = 1.5,
        strokecolor = :gray30,
    )
    text!(
        ax,
        positions;
        text = data.labels,
        align = (:center, :bottom),
        offset = (0, LABEL_OFFSET),
        fontsize = 14,
    )
    interactive && add_dragging!(ax, positions)
    return fig, ax
end

"""
    add_dragging!(ax, positions)

Left-dragging a node moves it (its edges and label follow); left-dragging the
background pans, replacing the axis's rectangle zoom. Makie's own scroll zoom,
right-drag pan and ctrl-click reset stay.
"""
function add_dragging!(ax::Axis, positions::Observable{Vector{Point2f}})
    deregister_interaction!(ax, :rectanglezoom)
    grabbed = Ref(0) # index of the node being dragged, 0 for none
    register_interaction!(ax, :drag_targets) do event::MouseEvent, ax
        if event.type === MouseEventTypes.leftdown
            grabbed[] = node_at(ax, positions[], event.px)
        elseif event.type === MouseEventTypes.leftdrag
            grabbed[] == 0 ? pan!(ax, event) : move_node!(positions, grabbed[], event)
            return Consume(true)
        elseif event.type in (MouseEventTypes.leftdragstop, MouseEventTypes.leftup)
            grabbed[] = 0
        end
        return Consume(false)
    end
    return ax
end

"The index of the node under `px` (pixels within the axis), or 0 if there is none."
function node_at(ax::Axis, positions, px)
    isempty(positions) && return 0
    lims = ax.finallimits[]
    scale = pixels_per_unit(lims, viewport(ax.scene)[])
    distance(p) = sqrt(sum(abs2, (p .- lims.origin) .* scale .- px))
    d, i = findmin(distance, positions)
    return d <= GRAB_RADIUS ? i : 0
end

function move_node!(positions::Observable, i::Int, event::MouseEvent)
    positions[][i] += event.data - event.prev_data
    notify(positions)
    return nothing
end

function pan!(ax::Axis, event::MouseEvent)
    lims = ax.targetlimits[]
    shift = (event.px - event.prev_px) ./
        pixels_per_unit(ax.finallimits[], viewport(ax.scene)[])
    ax.targetlimits[] = Rect2d(lims.origin .- shift, widths(lims))
    return nothing
end

"The name of the active Makie backend, or `:none`."
function backend_name()
    backend = current_backend()
    return backend isa Module ? nameof(backend) : :none
end

Targets.interactive_backend() = backend_name() in INTERACTIVE_BACKENDS

# Screen options for showing an interactive figure with `backend`. WGLMakie otherwise
# draws the figure at its fixed size in a corner of the browser tab; `resize_to = :body`
# makes it follow the tab's size. GLMakie's window already resizes the figure with it.
screen_config(backend::Symbol) = backend === :WGLMakie ? (; resize_to = :body) : (;)

function Targets.open_interactive(fig::Figure)
    Targets.interactive_backend() ||
        error(
            "tar_visnetwork(; interactive = true) needs an interactive Makie backend, but the " *
                "active one is $(backend_name()): load `GLMakie` (opens a window) or `WGLMakie` " *
                "(opens a browser tab), or activate one that is loaded, e.g. `GLMakie.activate!()`",
        )
    display(fig; screen_config(backend_name())...)
    return fig
end

end

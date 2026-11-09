module TargetsMakieExt

# Loaded automatically once Makie is loaded (any backend: `using CairoMakie`,
# `using GLMakie` or `using WGLMakie` is enough), so `using Targets` itself stays
# fast. Draws the layout Targets computes with plain Makie primitives, from the
# Observables of a `NetworkState`, so that the interactive view can move, select
# and hide targets.

using Makie:
    Axis,
    Box,
    Button,
    Checkbox,
    Consume,
    Figure,
    GridLayout,
    Keyboard,
    Label,
    MouseEvent,
    MouseEventTypes,
    Observable,
    Point2d,
    Point2f,
    RGBAf,
    Rect2d,
    arrows2d!,
    current_backend,
    deregister_interaction!,
    hidedecorations!,
    hidespines!,
    ispressed,
    lift,
    notify,
    on,
    poly!,
    register_interaction!,
    scatter!,
    text!,
    to_color,
    viewport,
    widths,
    xlims!,
    ylims!
using Targets: Targets, NetworkData, LIST_SECTIONS, STATUS_COLORS, STATUS_LABELS

const MARKER_SIZE = 28                # px
const HALO_SIZE = MARKER_SIZE + 14    # px, the ring drawn around selected targets
const LABEL_OFFSET = 18               # px above the marker centre
const ARROW_GAP = MARKER_SIZE / 2 + 4 # px between an arrow's ends and the marker centres
const GRAB_RADIUS = MARKER_SIZE / 2 +
    4 # px from a marker centre within which a press grabs it
const INTERACTIVE_BACKENDS = (:GLMakie, :WGLMakie)

const CLEAR = RGBAf(0, 0, 0, 0)
const SELECTION_COLOR = RGBAf(0.12, 0.47, 0.71, 1) # blue
const STROKE_COLOR = to_color(:gray30)
const LABEL_COLOR = to_color(:black)

const HELP = """
    Drag a target to move it
    (moves all selected targets
    when it is selected)
    Drag the background to pan
    Click: select a target
    Shift-click: add or remove
    Shift-drag: select an area
    Scroll: zoom, ctrl-click: reset"""

"""
    NetworkState(data)

The Observables a network is drawn from. `positions` are the node positions;
`hidden` marks targets hidden by hand and `hidden_kinds` the sections and
statuses hidden as a whole, which together give `visible`. `selected` marks the
selected targets, and `box` is the area being selected while `boxing`.
"""
struct NetworkState
    data::NetworkData
    positions::Observable{Vector{Point2f}}
    hidden::Observable{Vector{Bool}}
    hidden_kinds::Observable{Set{Symbol}}
    visible::Observable{Vector{Bool}}
    selected::Observable{Vector{Bool}}
    box::Observable{Rect2d}
    boxing::Observable{Bool}
end

function NetworkState(data::NetworkData)
    n = length(data.nodes)
    hidden = Observable(fill(false, n))
    hidden_kinds = Observable(Set{Symbol}())
    visible = lift(hidden, hidden_kinds) do hidden, kinds
        Bool[!hidden[i] && !any(in(kinds), kinds_of(data, i)) for i in 1:n]
    end
    selected = Observable(fill(false, n))
    # hidden targets leave the selection, so they cannot be moved or hidden unseen
    on(visible) do v
        any(selected[] .& .!v) && (selected[] = selected[] .& v)
    end
    return NetworkState(
        data,
        Observable([Point2f(p...) for p in data.positions]),
        hidden,
        hidden_kinds,
        visible,
        selected,
        Observable(Rect2d(0, 0, 0, 0)),
        Observable(false),
    )
end

"The kinds of node `i` that can be hidden as a whole: its section and its status."
kinds_of(data::NetworkData, i) = data.statuses === nothing ?
    (data.sections[i],) :
    (data.sections[i], data.statuses[i])

"`colors`, with those of hidden nodes made transparent."
shown_colors(colors, visible) = [v ? c : CLEAR for (c, v) in zip(colors, visible)]

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
# between overlapping markers, or to a hidden node, becomes a zero-length arrow,
# which draws nothing.
function edge_segments(positions, edges, visible, lims, vp)
    scale = pixels_per_unit(lims, vp)
    starts = Vector{Point2f}(undef, length(edges))
    dirs = Vector{Point2f}(undef, length(edges))
    for (k, (i, j)) in enumerate(edges)
        a, b = positions[i], positions[j]
        len = sqrt(sum(abs2, (b - a) .* scale)) # edge length in pixels
        k_gap = (visible[i] && visible[j] && len > 2 * ARROW_GAP) ? ARROW_GAP / len : 0.5
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
    state = NetworkState(data)
    draw_network!(ax, state)
    if interactive
        add_interactions!(ax, state)
        add_panel!(fig[1, 2], state)
    end
    return fig, ax, state
end

function draw_network!(ax::Axis, state::NetworkState)
    data, n = state.data, length(state.data.nodes)
    if !isempty(data.edges)
        # recomputed on zoom, pan and resize as well, so the pixel gaps stay right
        segments = lift(
            (ps, v, lims, vp) -> edge_segments(ps, data.edges, v, lims, vp),
            state.positions,
            state.visible,
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
    markers = [f ? :rect : :circle for f in data.is_file]
    scatter!( # a ring around selected targets, under the markers
        ax,
        state.positions;
        color = lift(
            (s, v) -> shown_colors([x ? SELECTION_COLOR : CLEAR for x in s], v),
            state.selected,
            state.visible,
        ),
        marker = markers,
        markersize = HALO_SIZE,
    )
    fills = to_color.(data.colors)
    scatter!(
        ax,
        state.positions;
        color = lift(v -> shown_colors(fills, v), state.visible),
        marker = markers,
        markersize = MARKER_SIZE,
        strokewidth = 1.5,
        strokecolor = lift(v -> shown_colors(fill(STROKE_COLOR, n), v), state.visible),
    )
    text!(
        ax,
        state.positions;
        text = data.labels,
        color = lift(v -> shown_colors(fill(LABEL_COLOR, n), v), state.visible),
        align = (:center, :bottom),
        offset = (0, LABEL_OFFSET),
        fontsize = 14,
    )
    return ax
end

## Mouse interaction

"""
    add_interactions!(ax, state)

Dragging a target moves it, or every selected target when it is selected;
dragging the background pans, replacing the axis's rectangle zoom. A click
selects a target (or clears the selection, on the background), a shift-click adds
or removes one, and a shift-drag selects every target in the area. Makie's own
scroll zoom, right-drag pan and ctrl-click reset stay.
"""
function add_interactions!(ax::Axis, state::NetworkState)
    deregister_interaction!(ax, :rectanglezoom)
    poly!(
        ax,
        state.box;
        color = (SELECTION_COLOR, 0.15),
        strokecolor = SELECTION_COLOR,
        strokewidth = 1,
        visible = state.boxing,
    )
    grabbed = Ref(0)            # the target under the press, 0 for none
    origin = Ref(Point2d(0, 0)) # where the press was, in data units
    mode = Ref(:none)           # what the current drag does: :move, :select or :pan
    register_interaction!(ax, :targets_network) do event::MouseEvent, ax
        type = event.type
        if type === MouseEventTypes.leftdown
            grabbed[] = node_at(ax, state, event.px)
            origin[] = event.data
        elseif type === MouseEventTypes.leftdragstart
            mode[] = shift_pressed(ax) ? :select : grabbed[] == 0 ? :pan : :move
        elseif type === MouseEventTypes.leftdrag
            if mode[] === :move
                move_targets!(state, grabbed[], event.data - event.prev_data)
            elseif mode[] === :select
                draw_box!(state, origin[], event.data)
            else
                pan!(ax, event)
            end
            return Consume(true)
        elseif type === MouseEventTypes.leftdragstop
            mode[] === :select && select_box!(state)
            mode[] = :none
        elseif type in (MouseEventTypes.leftclick, MouseEventTypes.leftdoubleclick)
            click!(state, grabbed[], shift_pressed(ax))
        end
        return Consume(false)
    end
    return ax
end

shift_pressed(ax::Axis) = ispressed(ax.scene, Keyboard.left_shift | Keyboard.right_shift)

"The index of the visible target under `px` (pixels within the axis), or 0."
function node_at(ax::Axis, state::NetworkState, px)
    lims = ax.finallimits[]
    scale = pixels_per_unit(lims, viewport(ax.scene)[])
    distance(i) = state.visible[][i] ?
        sqrt(sum(abs2, (state.positions[][i] .- lims.origin) .* scale .- px)) :
        Inf
    isempty(state.positions[]) && return 0
    d, i = findmin(distance, eachindex(state.positions[]))
    return d <= GRAB_RADIUS ? i : 0
end

"Move target `i` by `delta`, together with the rest of the selection if it is selected."
function move_targets!(state::NetworkState, i::Int, delta)
    selected = state.selected[]
    moved = selected[i] ? findall(selected .& state.visible[]) : [i]
    positions = state.positions[]
    for k in moved
        positions[k] += delta
    end
    notify(state.positions)
    return nothing
end

function click!(state::NetworkState, i::Int, shift::Bool)
    selected = copy(state.selected[])
    if shift
        i == 0 && return nothing
        selected[i] = !selected[i]
    else
        fill!(selected, false)
        i == 0 || (selected[i] = true)
    end
    state.selected[] = selected
    return nothing
end

function draw_box!(state::NetworkState, from, to)
    state.box[] = Rect2d(min.(from, to), abs.(to - from))
    state.boxing[] = true
    return nothing
end

"Add the visible targets inside the selection box to the selection."
function select_box!(state::NetworkState)
    box = state.box[]
    inside(p) = all(box.origin .<= p .<= box.origin .+ box.widths)
    state.selected[] = state.selected[] .| (inside.(state.positions[]) .& state.visible[])
    state.boxing[] = false
    return nothing
end

function pan!(ax::Axis, event::MouseEvent)
    lims = ax.targetlimits[]
    shift = (event.px - event.prev_px) ./
        pixels_per_unit(ax.finallimits[], viewport(ax.scene)[])
    ax.targetlimits[] = Rect2d(lims.origin .- shift, widths(lims))
    return nothing
end

## The side panel: hiding targets

"""
    add_panel!(position, state)

A panel at `position` with a checkbox per section and per status present
(unchecking one hides those targets), a "Hide selected" button, a "Show all"
button that undoes all hiding, and a summary of the mouse controls.
"""
function add_panel!(position, state::NetworkState)
    data = state.data
    panel = GridLayout(
        position;
        tellheight = false,
        valign = :top,
        default_rowgap = 4,
        default_colgap = 6,
    )
    row = Ref(0)
    next_row!() = (row[] += 1)
    heading!(text) = Label(panel[next_row!(), 1:3], text; font = :bold, halign = :left)

    heading!("Show")
    checkboxes = [
        kind_checkbox!(panel, next_row!(), state, kind, label)
        for (kind, label) in pairs(LIST_SECTIONS)
        if kind in data.sections
    ]
    if data.statuses !== nothing
        heading!("Status")
        for (kind, label) in pairs(STATUS_LABELS)
            kind in data.statuses || continue
            r = next_row!()
            push!(checkboxes, kind_checkbox!(panel, r, state, kind, label))
            Box(panel[r, 2]; color = STATUS_COLORS[kind], width = 14, height = 14)
        end
    end

    hide = Button(panel[next_row!(), 1:3]; label = "Hide selected", halign = :left)
    on(_ -> hide_selected!(state), hide.clicks)
    show = Button(panel[next_row!(), 1:3]; label = "Show all", halign = :left)
    on(show.clicks) do _
        foreach(c -> c.checked[] = true, checkboxes)
        state.hidden[] = fill(false, length(data.nodes))
    end
    Label(
        panel[next_row!(), 1:3],
        HELP;
        fontsize = 11,
        color = :gray40,
        halign = :left,
        justification = :left,
    )
    return panel
end

"A checked checkbox that hides the targets of `kind` while unchecked."
function kind_checkbox!(panel, row, state::NetworkState, kind::Symbol, label)
    checkbox = Checkbox(panel[row, 1]; checked = true)
    Label(panel[row, 3], label; halign = :left)
    on(checkbox.checked) do checked
        kinds = copy(state.hidden_kinds[])
        checked ? delete!(kinds, kind) : push!(kinds, kind)
        state.hidden_kinds[] = kinds
    end
    return checkbox
end

function hide_selected!(state::NetworkState)
    state.hidden[] = state.hidden[] .| state.selected[]
    return nothing
end

## Displaying

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

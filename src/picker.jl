## Picking targets in the terminal and running an action on them

"The actions [`tar_picker`](@ref) offers, each called with the pipeline and the picked names."
const PICKER_ACTIONS = (
    tar_make = (p, names; store, root, io) -> tar_make(p; names, store, root, io),
    tar_invalidate = (p, names; store, root, io) -> tar_invalidate(; names, store),
    tar_status = (p, names; store, root, io) -> tar_status(p; names, store, root),
    tar_visnetwork = (p, names; store, root, io) -> tar_visnetwork(p; names, store, root),
)

"""
    tar_picker(p::Pipeline; store = default_store_path(), root = nothing,
               input = stdin, io = stdout)
    tar_picker(; script = default_script(), kwargs...)

Pick targets with a fuzzy finder in the terminal, then an action to run on them,
for exploring a pipeline at the REPL.

Type to narrow the list of targets (in [`tar_list`](@ref) order) to those whose
names contain the typed characters in order, best matches first: `fm` matches
`fit_model`, and space-separated terms must all match. Tab selects the target
under the cursor (shift-tab moving up instead), ctrl-a selects every match (or
unselects them all), and enter finishes; enter without a selection picks the
target under the cursor. Up and down move, ctrl-u clears the query, and Esc or
ctrl-c cancels.

Then choose the action the same way, by typing part of its name:

- `tar_make`: build the picked targets and what they need;
- `tar_invalidate`: forget their metadata, so they rebuild next time;
- `tar_status`: list them and their dependencies with their status;
- `tar_visnetwork`: plot them and their dependencies (needs a Makie backend).

The equivalent call is printed before it runs, and its result is returned
(`nothing` if cancelled). `tar_picker()` loads `_targets.jl`.
"""
function tar_picker(
    p::Pipeline;
    store::Union{Store, AbstractString} = default_store_path(),
    root::Union{Nothing, AbstractString} = nothing,
    input::IO = stdin,
    io::IO = stdout,
)
    names = listed_names(tar_list(p))
    picked = fuzzy_pick(string.(names); multiple = true, prompt = "Targets> ", input, io)
    picked === nothing && return nothing
    selected = names[picked]
    actions = collect(keys(PICKER_ACTIONS))
    prompt = "Action for $(plural(length(selected), "target"))> "
    chosen = fuzzy_pick(string.(actions); prompt, input, io)
    chosen === nothing && return nothing
    action = only(chosen)
    println(io, actions[action], "(names = ", repr(selected), ")")
    return PICKER_ACTIONS[action](p, selected; store, root, io)
end
tar_picker(; script::AbstractString = default_script(), kwargs...) = tar_picker(
    load_pipeline(script);
    kwargs...,
)

@testitem "tar_picker runs an action on the picked targets" begin
    p = tar_pipeline(
        target(:a, () -> 1),
        target(:fit_model, a -> a + 1),
        target(:fit_data, a -> a + 2),
        target(:summary, (fit_model, fit_data) -> fit_model + fit_data),
    )
    mktempdir() do dir
        store = joinpath(dir, "_targets")
        tar_make(p; store, root = dir, io = devnull)
        "Run tar_picker on `typed` keys, returning its result and output."
        function picker(typed)
            io = IOBuffer()
            result = tar_picker(p; store, root = dir, input = IOBuffer(typed), io)
            return result, String(take!(io))
        end

        status, out = picker("fm\rstat\r")
        @test status isa TargetStatus
        @test keys(status.status) == Set([:a, :fit_model])
        @test occursin("tar_status(names = [:fit_model])\n", out)

        # ctrl-a selects both fits; invalidating them rebuilds exactly those
        @test first(picker("fit\x01\rinval\r")) === nothing
        @test [o.name for o in tar_outdated(p; store, root = dir)] ==
            [:fit_model, :fit_data, :summary]
        summary, out = picker("fit\x01\rmake\r")
        @test summary.built == [:fit_model, :fit_data]
        @test summary.skipped == [:a]
        @test occursin("tar_make(names = [:fit_data, :fit_model])\n", out) # tar_list order

        @test first(picker("fit\x03")) === nothing # cancelled at the targets
        @test first(picker("fit\r\e")) === nothing # cancelled at the action
    end
end

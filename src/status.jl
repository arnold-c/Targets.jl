## Listing the targets of a pipeline with their status

"Status => terminal colour, as `tar_status` prints it."
const STATUS_TERMINAL_COLORS = (
    uptodate = :green,
    outdated = :yellow,
    errored = :red,
    unbuilt = :blue,
    running = :normal,
)

"""
    TargetStatus

The targets of a pipeline with their status, returned by [`tar_status`](@ref):
`list` is their [`TargetList`](@ref), `status` maps each name to `:uptodate`,
`:outdated`, `:errored`, `:unbuilt` or `:running`, and `reason` maps each
outdated name to its [`tar_outdated`](@ref) reason. Prints as a sectioned list,
coloured by status.
"""
struct TargetStatus
    list::TargetList
    status::Dict{Symbol, Symbol}
    reason::Dict{Symbol, Symbol}
end

"""
    tar_status(p::Pipeline; names = nothing, descendants = false,
               store = default_store_path(), root = nothing)

[`tar_list`](@ref) with the status of each target, as a [`TargetStatus`](@ref).
In a terminal, up-to-date targets are green, outdated ones yellow (with the
reason they would rebuild), errored ones red and targets not built yet blue;
targets that a build in progress is running are not coloured. Statuses are
those of [`tar_dot`](@ref), and as conservative as [`tar_outdated`](@ref):
everything downstream of an outdated target is outdated. `tar_status()` loads
`_targets.jl`.
"""
function tar_status(
    p::Pipeline;
    names = nothing,
    descendants::Bool = false,
    store::Union{Store, AbstractString} = default_store_path(),
    root::Union{Nothing, AbstractString} = nothing,
)
    list = tar_list(p; names, descendants)
    nodes = listed_names(list)
    reasons = outdated_reasons(p, nodes; store, root)
    running = running_targets(as_store(store))
    status = Dict(n => node_status(n, reasons, running) for n in nodes)
    reason = Dict(n => reasons[n] for n in nodes if status[n] === :outdated)
    return TargetStatus(list, status, reason)
end
tar_status(; script::AbstractString = default_script(), kwargs...) = tar_status(
    load_pipeline(script);
    kwargs...,
)

listed_names(l::TargetList) = Symbol[n for c in l.components for s in c for n in s]

status_label(status::Symbol) = lowercase(STATUS_LABELS[status])

function status_text(s::TargetStatus, n::Symbol)
    label = status_label(s.status[n])
    return haskey(s.reason, n) ? "$label ($(s.reason[n]))" : label
end

"Status => count, for the statuses present, in the order statuses are listed."
status_counts(s::TargetStatus) = [
    k => count(==(k), values(s.status))
    for k in keys(STATUS_LABELS)
    if k in values(s.status)
]

function Base.show(io::IO, s::TargetStatus)
    counts = join(("$n $(status_label(k))" for (k, n) in status_counts(s)), ", ")
    print(
        io,
        "TargetStatus(",
        plural(length(s.status), "target"),
        isempty(counts) ? "" : ": $counts",
        ")",
    )
end

function Base.show(io::IO, ::MIME"text/plain", s::TargetStatus)
    width = maximum(n -> textwidth(string(n)), keys(s.status); init = 0)
    print_list(io, s.list, (io, n) -> print_status(io, s, n, width))
    isempty(s.status) && return
    print(io, "\n\n")
    for (i, (k, n)) in enumerate(status_counts(s))
        i > 1 && print(io, ", ")
        printstyled(io, n, " ", status_label(k); color = STATUS_TERMINAL_COLORS[k])
    end
end

function print_status(io::IO, s::TargetStatus, n::Symbol, width::Int)
    printstyled(
        io,
        rpad(string(n), width),
        "  ",
        status_text(s, n);
        color = STATUS_TERMINAL_COLORS[s.status[n]],
    )
end

@testitem "tar_status lists targets coloured by status" setup = [SourceFixtures] begin
    code(b) = """
    p = tar_pipeline(
        target(:a, () -> 1),
        target(:b, a -> $b),
        target(:bad, () -> error("boom")),
        target(:after_bad, bad -> bad),
        target(:other, () -> 2),
    )
    """
    mktempdir() do dir
        build_source(code("a + 1"), dir; names = [:b, :bad], keep_going = true)
        m, _ = load_source(code("a + 2"); dir)
        p = Base.invokelatest(getproperty, m, :p)
        s = tar_status(p; store = joinpath(dir, "_targets"), root = dir)
        @test s.status ==
            Dict(
                :a => :uptodate,
                :b => :outdated,
                :bad => :errored,
                :after_bad => :outdated,
                :other => :unbuilt,
            )
        @test s.reason == Dict(:b => :command_changed, :after_bad => :upstream_outdated)
        @test sprint(show, s) ==
            "TargetStatus(5 targets: 1 up to date, 2 outdated, 1 errored, 1 not built)"
        text = sprint(show, MIME("text/plain"), s)
        @test occursin(
            "\n    a          up to date\n",
            text,
        ) # aligned after the longest name
        @test occursin("b          outdated (command_changed)", text)
        @test occursin("bad        errored", text)
        @test occursin("other      not built", text)
        @test endswith(text, "\n\n1 up to date, 2 outdated, 1 errored, 1 not built")
        coloured = sprint(show, MIME("text/plain"), s; context = :color => true)
        @test occursin("\e[32ma          up to date", coloured)
        @test occursin("\e[33mb          outdated (command_changed)", coloured)
        @test occursin("\e[31mbad        errored", coloured)
        @test occursin("\e[34mother      not built", coloured)
        # names selects like tar_list
        @test collect(keys(
            tar_status(
                p;
                names = [:a],
                store = joinpath(dir, "_targets"),
                root = dir,
            ).status,
        )) ==
            [:a]
    end
end

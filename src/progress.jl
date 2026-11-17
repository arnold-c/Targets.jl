## Progress events
##
## Each run appends machine-readable events to `_targets/log/events.tsv`: run id,
## time, key, status, seconds and worker. Only the process running `tar_make`
## writes them, so no locking is needed, and other sessions can follow a build
## by reading the file (`tar_progress`, `tar_poll`).

const EVENT_STATUSES = (
    :run_started,
    :queued,
    :started,
    :built,
    :skipped,
    :errored,
    :blocked,
    :run_finished,
)

events_path(s::Store) = joinpath(s.root, "log", "events.tsv")

new_run_id() = string(
    Dates.format(Dates.now(Dates.UTC), "yyyymmddTHHMMSS"),
    "-",
    string(rand(UInt32); base = 16),
)

"Append one event of the current run."
function event!(
    ctx,
    key,
    status::Symbol;
    seconds::Real = 0.0,
    worker::AbstractString = "local",
)
    status in EVENT_STATUSES || error("unknown event status $status")
    line = join(
        (
            ctx.run_id,
            string(Dates.now(Dates.UTC)),
            string(key),
            string(status),
            string(round(seconds; digits = 3)),
            worker,
        ),
        '\t',
    )
    path = events_path(ctx.store)
    mkpath(dirname(path))
    open(io -> println(io, line), path, "a")
    return nothing
end

const ProgressEvent = NamedTuple{
    (:run_id, :time, :key, :status, :seconds, :worker),
    Tuple{String, String, String, Symbol, Float64, String},
}

"All events in the store, oldest first."
function read_events(s::Store)
    path = events_path(s)
    isfile(path) || return ProgressEvent[]
    events = ProgressEvent[]
    for line in eachline(path)
        fields = split(line, '\t')
        length(fields) == 6 || continue # a line being written right now
        run_id, time, key, status, seconds, worker = fields
        push!(
            events,
            ProgressEvent((
                run_id,
                time,
                key,
                Symbol(status),
                parse(Float64, seconds),
                worker,
            )),
        )
    end
    return events
end

"""
    tar_progress(; store = default_store_path())

The latest run's progress: a vector of `(; key, status, seconds)` with the most
recent status of every target and branch it touched, in the order they first
appeared. Works while a build runs in another session.
"""
function tar_progress(; store::Union{Store, AbstractString} = default_store_path())
    events = read_events(as_store(store))
    isempty(events) &&
        return NamedTuple{(:key, :status, :seconds), Tuple{String, Symbol, Float64}}[]
    run = events[end].run_id
    latest = Dict{String, ProgressEvent}()
    order = String[]
    for e in events
        (e.run_id == run && !isempty(e.key)) || continue
        haskey(latest, e.key) || push!(order, e.key)
        latest[e.key] = e
    end
    return [
        (key = k, status = latest[k].status, seconds = latest[k].seconds)
        for k in order
    ]
end

"Whether the latest run in the store has finished (or there is none)."
function run_finished(s::Store)
    events = read_events(s)
    return isempty(events) || events[end].status === :run_finished
end

"""
    tar_poll(; interval = 2, store = default_store_path(), io = stdout, timeout = Inf)

Print a one-line summary of the latest run every `interval` seconds until it
finishes (or `timeout` seconds pass), for following a build from another Julia
session. The estimate of the time left adds up the last recorded build times of
the targets still queued or running.
"""
function tar_poll(;
    interval::Real = 2,
    store::Union{Store, AbstractString} = default_store_path(),
    io::IO = stdout,
    timeout::Real = Inf,
)
    s = as_store(store)
    started = time()
    while true
        println(io, progress_line(s))
        run_finished(s) && return nothing
        time() - started > timeout && return nothing
        sleep(interval)
    end
end

function progress_line(s::Store)
    rows = tar_progress(; store = s)
    count(status) = Base.count(r -> r.status === status, rows)
    pending = [r.key for r in rows if r.status in (:queued, :started)]
    eta = sum((something(read_meta(s, k), Record()).seconds for k in pending); init = 0.0)
    return "$(count(:built)) built, $(count(:skipped)) up to date, $(count(:errored)) errored, " *
        "$(count(:blocked)) blocked, $(count(:started)) running, $(count(:queued)) queued" *
        (isempty(pending) ? "" : ", about $(round(eta; digits = 1))s left")
end

"Targets running in the latest run, if it has not finished."
function running_targets(s::Store)
    run_finished(s) && return Set{Symbol}()
    return Set(
        Symbol(r.key)
        for r in tar_progress(; store = s)
        if r.status === :started && !occursin('/', r.key)
    )
end

@testitem "a run's events record what happened, and tar_progress reads them" setup = [
    SourceFixtures,
    JETChecks,
] begin
    using Targets: read_events
    code = """
    p = tar_pipeline(
        target(:bad, () -> error("boom")),
        target(:after, bad -> bad),
        target(:good, () -> 1),
        target(:grid, () -> [1, 2]),
        target(:fits, grid -> grid; pattern = :grid),
    )
    """
    mktempdir() do dir
        finished_during = Bool[]
        build_source(
            code,
            dir;
            keep_going = true,
            observe = ctx -> push!(finished_during, Targets.run_finished(ctx.store)),
        )
        @test !any(finished_during)
        rows = tar_progress(; store = joinpath(dir, "_targets"))
        status = Dict(r.key => r.status for r in rows)
        @test status["bad"] === :errored && status["after"] === :blocked
        @test status["good"] === :built && status["fits"] === :built
        @test count(k -> startswith(k, "fits/"), keys(status)) == 2
        events = read_events(Targets.open_store(joinpath(dir, "_targets")))
        @test first(events).status === :run_started && last(events).status === :run_finished
        @test any(e -> e.key == "good" && e.status === :queued, events)
        io = IOBuffer()
        tar_poll(; store = joinpath(dir, "_targets"), io)
        @test occursin("5 built", String(take!(io))) # good, grid, fits and its two branches
        @test_call tar_progress(; store = joinpath(dir, "_targets"))
        @test_call tar_poll(; store = joinpath(dir, "_targets"), io)
        build_source(code, dir; keep_going = true)
        @test length(unique(
            e.run_id
            for e in read_events(Targets.open_store(joinpath(dir, "_targets")))
        )) ==
            2
        @test Dict(
            r.key => r.status
            for r in tar_progress(; store = joinpath(dir, "_targets"))
        )["good"] ===
            :skipped
        # a run in progress elsewhere: its running targets are coloured in the graph
        s = Targets.open_store(joinpath(dir, "_targets"))
        fake = (run_id = "elsewhere", store = s)
        Targets.event!(fake, "", :run_started)
        Targets.event!(fake, "good", :started)
        @test Targets.running_targets(s) == Set([:good])
        m, _ = load_source(code; dir)
        p = Base.invokelatest(getproperty, m, :p)
        dot = string(tar_dot(p; store = s.root, root = dir))
        @test occursin("#80b1d3", dot)
    end
end

## Running jobs, one at a time or concurrently
##
## Only the scheduler task (the one that called `tar_make`) plans, commits and
## touches the `BuildContext`. Spawned jobs only `execute`, and hand their
## `JobResult` back through one `Channel`, the only object tasks share.

const CURRENT_SLOTS = ScopedValue{Int}(0)

"""
    tar_slots()

The number of job slots granted to the target that is currently running (see
the `slots` option of [`target`](@ref) and `jobs` of [`tar_make`](@ref)), for
sizing the target's own parallelism, e.g.
`OhMyThreads.tmap(f, xs; ntasks = tar_slots())`. Errors outside a target.
"""
function tar_slots()
    slots = CURRENT_SLOTS[]
    slots == 0 && error("tar_slots() is only available while a target is running")
    return slots
end

"How many of the `jobs` slots target `t` occupies while it runs."
job_slots(t::Target, jobs::Int) = t.slots === :all ? jobs : min(t.slots::Int, jobs)

"Resolve `tar_make`'s `jobs` option to a number of slots."
function resolve_jobs(jobs)
    jobs === :auto && return Threads.nthreads(:default)
    (jobs isa Integer && jobs >= 1) ||
        throw(ArgumentError("jobs must be a positive integer or `:auto`, got `$jobs`"))
    return Int(jobs)
end

"Run `job` with `slots` granted; never throws, so a spawned job always reports back."
function execute_granted(job::Job, slots::Int)
    try
        return with(() -> execute(job), CURRENT_SLOTS => slots)
    catch e
        return JobResult(job, nothing, "", (;), 0.0, e, catch_backtrace())
    end
end

"""
    run_jobs!(ctx, queue, executor; keep_going)

Plan, execute and commit every target in `queue`, running up to `jobs` slots'
worth of jobs at once (the executor's capacity). Ready targets that need no job
(up to date, or blocked by a failed upstream) are settled first, wherever they
are in the queue. Ready jobs start strictly in queue order: when the next
one does not fit, the scheduler waits rather than letting smaller jobs overtake
it. With `jobs = 1`, and for `deployment = :main` targets, jobs run in this
task. After a failure without `keep_going`, nothing new starts, running jobs
are committed, and the failure is rethrown.
"""
function run_jobs!(
    ctx::BuildContext,
    queue::ReadyQueue,
    executor::Executor;
    keep_going::Bool,
)
    jobs = capacity(executor)
    state = (pending = Job[], executor, running = Ref(0), used = Ref(0))
    failure = Ref{Any}(nothing)
    try
        while true
            # start as much as fits before waiting for a result
            while failure[] === nothing
                settle_ready!(ctx, queue)
                plan_ready!(ctx, queue, state.pending)
                dispatch!(ctx, queue, state, failure; jobs, keep_going) || break
            end
            if state.running[] == 0
                idle = isempty(state.pending) && !has_ready(queue)
                (failure[] !== nothing || idle) && break
                continue
            end
            r = take_result!(executor)
            state.running[] -= 1
            state.used[] -= job_slots(r.job.target, jobs)
            handle_result!(ctx, queue, r, failure; keep_going)
        end
    catch e
        e isa InterruptException || rethrow()
        abandon!(ctx, state)
        rethrow()
    end
    failure[] === nothing || throw(failure[])
    return nothing
end

"""
Settle the ready targets that need no job, and those that become ready as a
result: they never wait for a slot, so a build reports every up-to-date target
before its first job, and a target whose upstream was rebuilt to the same value
is settled as soon as that upstream finishes.
"""
function settle_ready!(ctx::BuildContext, queue::ReadyQueue)
    settled = true
    while settled
        settled = false
        for name in copy(queue.ready)
            t = get_target(ctx.pipeline, name)
            needs_job(ctx, t) && continue
            remove_ready!(queue, name)
            plan!(ctx, t) # records it as up to date or blocked
            finish_target!(ctx, queue, name)
            settled = true
        end
    end
    return nothing
end

# Branching targets are planned as usual: whether a branch needs a job is
# decided branch by branch.
function needs_job(ctx::BuildContext, t::Target)
    t.pattern === nothing || return true
    isempty(upstream_failures(ctx, t)) || return false
    return decision_for!(ctx, t).reason !== nothing
end

# Plan ready targets until some job is waiting to start (or nothing is ready).
function plan_ready!(ctx::BuildContext, queue::ReadyQueue, pending::Vector{Job})
    while isempty(pending) && has_ready(queue)
        name = pop_ready!(queue)
        jobs = plan!(ctx, get_target(ctx.pipeline, name))
        if isempty(jobs) && !haskey(ctx.branching, name)
            finish_target!(ctx, queue, name)
        else
            foreach(job -> event!(ctx, job.key, :queued), jobs)
            queued!(ctx.display, length(jobs))
            append!(pending, jobs)
        end
    end
end

# Start pending jobs in order while they fit; returns whether any job started.
function dispatch!(ctx::BuildContext, queue::ReadyQueue, state, failure; jobs, keep_going)
    started = false
    while !isempty(state.pending)
        job = first(state.pending)
        slots = job_slots(job.target, jobs)
        (state.used[] == 0 || state.used[] + slots <= jobs) || return started
        popfirst!(state.pending)
        log_start!(ctx, job)
        started = true
        if runs_inline(state.executor, job)
            handle_result!(ctx, queue, execute_granted(job, slots), failure; keep_going)
            return started # planning may have new work now
        end
        state.used[] += slots
        state.running[] += 1
        submit!(state.executor, job, slots)
    end
    return started
end

function handle_result!(
    ctx::BuildContext,
    queue::ReadyQueue,
    r::JobResult,
    failure;
    keep_going,
)
    finished!(ctx.display, r.job)
    done = try
        commit!(ctx, r; keep_going = keep_going || failure[] !== nothing)
    catch e
        e isa InterruptException && rethrow()
        failure[] === nothing && (failure[] = e)
        true
    end
    done && finish_target!(ctx, queue, r.job.target.name)
    return nothing
end

function finish_target!(ctx::BuildContext, queue::ReadyQueue, name::Symbol)
    release!(ctx, get_target(ctx.pipeline, name))
    target_done!(ctx.display)
    ctx.observe(ctx)
    finish!(queue, name)
    return nothing
end

# On interrupt: commit nothing more, but wait for running jobs (they cannot be
# killed) unless interrupted again.
function abandon!(ctx::BuildContext, state)
    state.running[] == 0 && return
    log!(
        ctx,
        "interrupted: waiting for $(state.running[]) running job(s); interrupt again to abandon them",
    )
    try
        foreach(_ -> take_result!(state.executor), 1:state.running[])
    catch
    end
end

"Sort the summary's lists into build order, whatever order jobs finished in."
function sort_summary!(s::BuildSummary, p::Pipeline)
    position = Dict(name => i for (i, name) in enumerate(p.order))
    for list in (s.built, s.skipped, s.errored, s.blocked)
        sort!(list; by = n -> position[n])
    end
    return s
end

@testmodule Concurrency begin
    using Targets
    export reset!, meet, enter_exit, LOG, build

    const EVENTS = Dict{Symbol, Base.Event}()
    const LOG = Tuple{Symbol, Symbol, UInt}[]
    const LOG_LOCK = ReentrantLock()

    reset!() = (empty!(EVENTS); empty!(LOG); nothing)

    "Signal `me`, then wait (up to `timeout` seconds) for `other`: only succeeds when both run concurrently."
    function meet(me::Symbol, other::Symbol; timeout = 10.0)
        lock(LOG_LOCK) do
            notify(get!(Base.Event, EVENTS, me))
            get!(Base.Event, EVENTS, other)
        end
        ev = lock(() -> EVENTS[other], LOG_LOCK)
        return timedwait(() -> ev.set, timeout; pollint = 0.01) === :ok
    end

    "Log entry and exit around a short pause; returns the slots granted."
    function enter_exit(name::Symbol; pause = 0.05)
        lock(() -> push!(LOG, (name, :enter, objectid(current_task()))), LOG_LOCK)
        sleep(pause)
        slots = tar_slots()
        lock(() -> push!(LOG, (name, :exit, objectid(current_task()))), LOG_LOCK)
        return slots
    end

    build(p, dir; kwargs...) = tar_make(
        p;
        store = joinpath(dir, "_targets"),
        root = dir,
        io = devnull,
        kwargs...,
    )

    "Names that ran at some point while `name` ran, and the most that ran alongside it at once."
    function overlapping(name)
        running = Set{Symbol}()
        seen = Set{Symbol}()
        most = 0
        for (n, event, _) in LOG
            event === :enter ? push!(running, n) : delete!(running, n)
            if name in running
                others = setdiff(running, [name])
                union!(seen, others)
                most = max(most, length(others))
            end
        end
        return (; seen, most)
    end
    export overlapping
end

@testitem "independent targets run concurrently with jobs > 1" setup = [Concurrency] begin
    reset!()
    p = tar_pipeline(
        target(:a, () -> Concurrency.meet(:a, :b)),
        target(:b, () -> Concurrency.meet(:b, :a)),
        target(:both, (a, b) -> a && b),
    )
    mktempdir() do dir
        s = build(p, dir; jobs = 2)
        @test s.built == [:a, :b, :both] # sorted into build order
        @test tar_read(:both; store = joinpath(dir, "_targets"))
    end
    reset!()
    q = tar_pipeline(
        target(:a, () -> Concurrency.meet(:a, :b; timeout = 0.2)),
        target(:b, () -> Concurrency.meet(:b, :a; timeout = 0.2)),
    )
    mktempdir() do dir
        build(q, dir; jobs = 1)
        @test !tar_read(:a; store = joinpath(dir, "_targets")) # one job at a time
    end
end

@testitem "deployment = :main runs in the calling task, one at a time" setup = [
    Concurrency,
] begin
    reset!()
    p = tar_pipeline(
        target(:m1, () -> Concurrency.enter_exit(:m1); deployment = :main),
        target(:m2, () -> Concurrency.enter_exit(:m2); deployment = :main),
        target(:s1, () -> Concurrency.enter_exit(:s1)),
        target(:s2, () -> Concurrency.enter_exit(:s2)),
    )
    mktempdir() do dir
        build(p, dir; jobs = 4)
    end
    tasks = Dict(n => t for (n, e, t) in LOG if e === :enter)
    me = objectid(current_task())
    @test tasks[:m1] == me && tasks[:m2] == me
    @test tasks[:s1] != me
    @test !(:m2 in overlapping(:m1).seen)
end

@testitem "slots = :all runs alone, is not overtaken, and sees all slots" setup = [
    Concurrency,
] begin
    reset!()
    p = tar_pipeline(
        target(:a, () -> Concurrency.enter_exit(:a)),
        target(:b, () -> Concurrency.enter_exit(:b)),
        target(:big, () -> Concurrency.enter_exit(:big); slots = :all),
        target(:c, () -> Concurrency.enter_exit(:c)),
        target(:pair, () -> Concurrency.enter_exit(:pair; pause = 0.3); slots = 2),
        target(:d, () -> Concurrency.enter_exit(:d)),
        target(:e, () -> Concurrency.enter_exit(:e)),
        target(:f, () -> Concurrency.enter_exit(:f)),
    )
    mktempdir() do dir
        build(p, dir; jobs = 4)
        store = joinpath(dir, "_targets")
        @test tar_read(:big; store) == 4
        @test tar_read(:a; store) == 1
        @test tar_read(:pair; store) == 2
    end
    @test isempty(overlapping(:big).seen)
    entered = [n for (n, e, _) in LOG if e === :enter]
    # a and b started first; c is declared after big, so it waits for big
    @test findfirst(==(:big), entered) < findfirst(==(:c), entered)
    @test 1 <= overlapping(:pair).most <= 2
end

@testitem "a failure lets running jobs commit, then stops the build" setup = [
    Concurrency,
] begin
    p = tar_pipeline(
        target(:bad, () -> error("boom")),
        target(:slow, () -> (sleep(0.3); 1)),
        target(:after, slow -> slow + 1),
    )
    mktempdir() do dir
        @test_throws "boom" build(p, dir; jobs = 2)
        store = joinpath(dir, "_targets")
        @test tar_read(:slow; store, on_outdated = :ignore) == 1
        @test !isfile(joinpath(store, "meta", "after.toml"))
        s = build(p, dir; jobs = 2, keep_going = true)
        @test s.errored == [:bad] && s.built == [:after] && s.skipped == [:slow]
    end
end

@testitem "branches run as concurrent jobs" setup = [Concurrency] begin
    reset!()
    p = tar_pipeline(
        target(:grid, () -> [:x, :y]),
        target(
            :met,
            grid -> Concurrency.meet(grid, grid === :x ? :y : :x);
            pattern = :grid,
        ),
    )
    mktempdir() do dir
        s = build(p, dir; jobs = 2)
        @test length(s.branches[:met]) == 2
        @test all(tar_read(:met; store = joinpath(dir, "_targets")))
    end
end

@testitem "up-to-date targets are reported before the first job starts" begin
    # `slow` is rebuilt; `b` and `c` are up to date but declared after it, so a
    # queue taken strictly in order would build `slow` first.
    pipeline(v) = tar_pipeline(
        target(:a, () -> 1),
        target(:slow, () -> v),
        target(:b, a -> a + 1),
        target(:c, b -> b + 1),
        target(:d, slow -> slow),
    )
    for jobs in (1, 2)
        mktempdir() do dir
            store = joinpath(dir, "_targets")
            tar_make(pipeline(1); store, root = dir, io = devnull, jobs)
            io = IOBuffer()
            s = tar_make(pipeline(2); store, root = dir, io, jobs, progress = :lines)
            lines = split(String(take!(io)), '\n')
            first_job = findfirst(l -> occursin(r"[▶✔] slow", l), lines)
            up_to_date(n) = findfirst(l -> occursin("· $n up to date", l), lines)
            @test all(n -> up_to_date(n) < first_job, (:a, :b, :c))
            @test s.built == [:slow, :d]
            @test s.skipped == [:a, :b, :c]
        end
    end
end

@testitem "the package never reasons about thread ids" begin
    banned = ["thread" * "id(", "@" * "threads"]
    dir = joinpath(pkgdir(Targets), "src")
    for file in readdir(dir; join = true)
        text = read(file, String)
        @test !any(b -> occursin(b, text), banned)
    end
end

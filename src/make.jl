"""
    BuildSummary

Names of targets that were `built`, found up to date (`skipped`), failed
(`errored`) or not attempted because an upstream target failed (`blocked`),
each in build order. `branches` maps each branching target to the ids of the
branches that were (re)built in this run, and `trimmed` each `error = :trim`
target to the ids of the failed branches left out of its value.
"""
struct BuildSummary
    built::Vector{Symbol}
    skipped::Vector{Symbol}
    errored::Vector{Symbol}
    blocked::Vector{Symbol}
    branches::Dict{Symbol, Vector{String}}
    trimmed::Dict{Symbol, Vector{String}}
end
BuildSummary() = BuildSummary(
    Symbol[],
    Symbol[],
    Symbol[],
    Symbol[],
    Dict{Symbol, Vector{String}}(),
    Dict{Symbol, Vector{String}}(),
)

function Base.show(io::IO, s::BuildSummary)
    print(
        io,
        "BuildSummary(built = ",
        s.built,
        ", skipped = ",
        s.skipped,
        ", errored = ",
        s.errored,
        ", blocked = ",
        s.blocked,
        isempty(s.branches) ? "" : ", branches = " * string(s.branches),
        isempty(s.trimmed) ? "" : ", trimmed = " * string(s.trimmed),
        ")",
    )
end

"State for one `tar_make` run."
struct BuildContext
    pipeline::Pipeline
    store::Store
    root::String
    forced::Set{Symbol}
    display::BuildDisplay
    discovery::Discovery
    commands::Dict{Symbol, CommandHash}
    codes::Dict{Symbol, String}
    values::Dict{Symbol, Any}
    value_hashes::Dict{Symbol, String}
    remaining::Dict{Symbol, Int}
    branching::Dict{Symbol, BranchProgress}
    nulled::Set{Symbol} # failed `error = :null` targets: consumers get `nothing`
    warned::Set{String} # keys of jobs that logged warnings
    run_id::String      # identifies this run's progress events
    summary::BuildSummary
    observe::Function
end

"""
    passes_values(f)

Whether target function `f` is called with the values of its dependencies (the
default). A function that reads them from the store itself, such as a report's
renderer, returns `false`: its dependencies then only count through their
value hashes, and their values are neither loaded nor kept in memory for it.
"""
passes_values(f) = true

"The dependencies whose values `t`'s function receives."
value_deps(t::Target) = passes_values(t.f) ? t.deps : Symbol[]

# How many selected targets still need each target's value in this run.
function consumer_counts(p::Pipeline, selected)
    counts = Dict{Symbol, Int}(name => 0 for name in selected)
    for name in selected, d in value_deps(get_target(p, name))
        counts[d] += 1
    end
    return counts
end

function BuildContext(
    p::Pipeline,
    store::Store,
    root::AbstractString,
    forced,
    display::BuildDisplay,
    discovery::Discovery,
    selected,
    observe::Function,
)
    return BuildContext(
        p,
        store,
        String(root),
        Set{Symbol}(forced),
        display,
        discovery,
        Dict{Symbol, CommandHash}(),
        Dict{Symbol, String}(),
        Dict{Symbol, Any}(),
        Dict{Symbol, String}(),
        consumer_counts(p, selected),
        Dict{Symbol, BranchProgress}(),
        Set{Symbol}(),
        Set{String}(),
        new_run_id(),
        BuildSummary(),
        observe,
    )
end

function log!(ctx::BuildContext, message::AbstractString)
    show_line(ctx.display, message)
    write_log(ctx.store, message)
    return nothing
end

write_log(s::Store, message::AbstractString) = open(
    io -> println(io, message),
    log_path(s),
    "a",
)

"""
    stored_value(store, name, kind)

The stored value of a finished target of `kind`: `:file` gives its path(s),
`:branches` the vector of its branch values, `:object` its object.
"""
function stored_value(s::Store, name::Symbol, kind::Symbol)
    kind === :file && return file_value(read_meta(s, name)::Record)
    kind === :branches && return load_branches(s, name)
    return read_object(s, name)
end

"The kind of value a target stores, from its definition (see [`stored_value`](@ref))."
value_kind(t::Target) = is_external(t) ? :file : t.pattern === nothing ? :object : :branches

"The stored value of a finished target during a build: its kind comes from the pipeline."
retrieve_value(ctx::BuildContext, name::Symbol) = stored_value(
    ctx.store,
    name,
    value_kind(get_target(ctx.pipeline, name)),
)

"Value of a finished target, loaded from the store on first use."
get_value!(ctx::BuildContext, name::Symbol) = get!(
    () -> retrieve_value(ctx, name),
    ctx.values,
    name,
)

command_for!(ctx::BuildContext, t::Target) = get!(
    () -> command_hash(t),
    ctx.commands,
    t.name,
)
code_for!(ctx::BuildContext, t::Target) = get!(
    () -> code_hash(ctx.discovery, t),
    ctx.codes,
    t.name,
)

function check_supported(p::Pipeline, names)
    for name in names
        t = get_target(p, name)
        (t.pattern !== nothing && is_external(t)) &&
            error(
                "target `$name`: a branching target cannot also be a file target; " *
                    "branch over a file target and write files from a plain target instead",
            )
    end
end

"Warn once about targets whose code could only be hashed in a Julia-version-dependent way."
function warn_weak_hashes(ctx::BuildContext, names)
    kinds = Dict(n => command_for!(ctx, get_target(ctx.pipeline, n)).kind for n in names)
    lowered = [n for n in names if kinds[n] == :lowered]
    unknown = [n for n in names if kinds[n] == :unknown]
    isempty(lowered) ||
        @warn "no source found for these targets; their lowered code is hashed instead, so a Julia upgrade will rebuild them" targets = lowered
    isempty(unknown) ||
        @warn "the code of these targets cannot be hashed, so they are always rebuilt" targets = unknown
end

# Hash all code up front, so that problems are reported before anything is built.
function prepare!(ctx::BuildContext, selected; check_stale::Bool)
    maybe_revise()
    for name in selected
        t = get_target(ctx.pipeline, name)
        command_for!(ctx, t)
        code_for!(ctx, t)
    end
    check_stale && check_stale_session(ctx.discovery.files)
    warn_weak_hashes(ctx, selected)
end

"The last recorded build time of each target, used to prioritise the critical path."
function last_seconds(s::Store, names)
    seconds = Dict{Symbol, Float64}()
    for name in names
        record = read_meta(s, name)
        record === nothing || (seconds[name] = record.seconds)
    end
    return seconds
end

# Returns the names to force: all of them if the Manifest changed and the user asked for that.
function manifest_forced(store::Store, root::AbstractString, selected, track_manifest::Bool)
    changes = manifest_changes(store, root)
    changes === nothing && return Symbol[]
    summary = isempty(changes) ? "no package versions changed" : join(changes, "; ")
    if track_manifest
        @info "the Manifest changed ($summary); rebuilding everything"
        return selected
    end
    @warn "the Manifest changed since the last build ($summary); results may be stale. " *
        "Rebuild with tar_make(force = true), tar_invalidate(), or set track_manifest = true."
    return Symbol[]
end

"""
    tar_make(p::Pipeline; names = nothing, force = false, store = default_store_path(),
             root = nothing, keep_going = false, track_manifest = false,
             check_stale = true, jobs = 1, executor = nothing, check_mutation = false,
             io = stdout, progress = :auto)

Build the targets of `p` that are outdated, in dependency order, and return a
[`BuildSummary`](@ref). With `names`, only those targets and everything they
depend on are considered. With `force = true`, all of those are rebuilt whatever
their status. An error stops the run and is rethrown, unless `keep_going` is
set, in which case independent targets are still built and the failure is
reported in the summary.

`root` is the project directory whose code counts as user code (default: the
active project); `p.track` adds more. When the Manifest changes, a warning
names the packages that moved, or with `track_manifest = true` everything is
rebuilt. With `check_stale`, the run errors if a tracked source file changed on
disk after this session loaded it (unless Revise is loaded), since the hashes
would then describe code the session is not running.

Values are kept in memory only while a target in this run still needs them, so
memory use follows the width of the pipeline, not its length.

With `jobs = n` (or `:auto`, one per default thread), up to `n` independent
targets and branches run at once, each as a Julia task; targets on the longest
remaining path (by their last build times) start first. A target occupies its
`slots` of the `n` while it runs, and `deployment = :main` targets run in the
calling task. Concurrent targets share the process: they must not `cd`, change
`ENV` or mutate their arguments (consumers of one upstream share its value),
and BLAS-heavy targets may want `BLAS.set_num_threads(1)`. After a failure,
running jobs are finished and committed before the error is rethrown; on
interrupt, running jobs are waited for (interrupt again to abandon them).

`check_mutation = true` hashes every argument before and after each call and
errors, naming the target and argument, if a target modified its input. It is
costly, so it is off by default; turn it on in tests and CI.

Progress is logged to `io` and to `_targets/log/progress.log`, one line per
finished target or branch: `✔ name 1.2s (reason)` in green, `✖ name: error`
in red. With `progress = :live` (the default `:auto` picks it when `io` is a
terminal), the jobs still running stay in a footer below the log, each with a
spinner and its time so far, above a count of the targets done, running and
queued; console log messages from targets are printed above the footer, but
what targets print straight to `stdout` can disturb it until the next redraw.
With `progress = :lines`, a `▶ name (reason)` line also marks each start.
"""
tar_make(p::Pipeline; kwargs...) = Base.invokelatest(build_pipeline, p; kwargs...)

# The build itself. `tar_make` enters it in the latest world: a pipeline script
# (or code it includes) is usually loaded after the caller was compiled, and the
# build touches user bindings and types outside the target calls too (printing
# stack frames and errors, saving values), which in an older world is a
# world-age violation from Julia 1.12 on.
function build_pipeline(
    p::Pipeline;
    names = nothing,
    force::Bool = false,
    store::Union{Store, AbstractString} = default_store_path(),
    root::Union{Nothing, AbstractString} = nothing,
    keep_going::Bool = false,
    track_manifest::Bool = false,
    check_stale::Bool = true,
    jobs::Union{Integer, Symbol} = 1,
    executor::Union{Nothing, Executor} = nothing,
    check_mutation::Bool = false,
    io::IO = stdout,
    progress::Symbol = :auto,
    observe::Function = ctx -> nothing,
)
    exec = something(executor, TaskExecutor(jobs))
    slots = capacity(exec)
    rootdir = something(root, project_root())
    s = store isa Store ? store : open_store(store)
    selected = selected_order(p, names)
    record_groups!(s, p.groups)
    check_supported(p, selected)
    ctx = BuildContext(
        p,
        s,
        rootdir,
        Symbol[],
        open_display(progress, io, length(selected)),
        Discovery(user_roots(rootdir, p.track)),
        selected,
        observe,
    )
    prepare!(ctx, selected; check_stale)
    union!(
        ctx.forced,
        force ? selected : manifest_forced(s, rootdir, selected, track_manifest),
    )
    # Relative paths in file targets are relative to the project root.
    priority = slots == 1 ?
        Dict{Symbol, Float64}() :
        critical_path(p, selected, last_seconds(s, selected))
    queue = ReadyQueue(p, selected; priority)
    event!(ctx, "", :run_started)
    try
        with(CHECK_MUTATION => check_mutation) do
            cd(rootdir) do
                start!(exec, ctx)
                try
                    showing(() -> run_jobs!(ctx, queue, exec; keep_going), ctx.display)
                finally
                    stop!(exec)
                end
            end
        end
    finally
        event!(ctx, "", :run_finished)
    end
    sm = sort_summary!(ctx.summary, p)
    isempty(sm.errored) && record_manifest!(s, rootdir)
    log!(
        ctx,
        "summary: $(length(sm.built)) built, $(length(sm.skipped)) up to date, " *
            "$(length(sm.errored)) errored, $(length(sm.blocked)) blocked" *
            (isempty(ctx.warned) ? "" : ", $(length(ctx.warned)) with warnings"),
    )
    return sm
end

default_script() = joinpath(project_root(), "_targets.jl")

"Load a pipeline script into a fresh module, so no state leaks from the REPL between runs."
function load_pipeline(script::AbstractString)
    isfile(script) || error("no pipeline script at $script")
    m = register_script!(script, Module(:TargetsScript))
    Core.eval(m, :(using Targets))
    # a plain Module has no `include`/`eval`, which scripts reasonably expect
    Core.eval(m, :(include(path::AbstractString) = Base.include($m, path)))
    Core.eval(m, :(eval(ex) = Core.eval($m, ex)))
    p = Base.include(m, script)
    p isa Pipeline ||
        error(
            "$script must end with a `tar_pipeline(...)` call, but returned `$(typeof(p))`",
        )
    return p
end

"""
    tar_make(; script = joinpath(project_root(), "_targets.jl"), kwargs...)

Load `script` into a fresh module and build the [`Pipeline`](@ref) its last
expression returns.
"""
function tar_make(;
    script::AbstractString = default_script(),
    fresh::Bool = false,
    kwargs...,
)
    fresh && return tar_make_fresh(script; kwargs...)
    return tar_make(load_pipeline(script); kwargs...)
end

# Drop a value from memory once its last consumer in this run has finished.
function release!(ctx::BuildContext, t::Target)
    for d in value_deps(t)
        ctx.remaining[d] -= 1
        ctx.remaining[d] <= 0 && delete!(ctx.values, d)
    end
    return nothing
end

const SUMMARY_LISTS = (:built, :skipped, :errored, :blocked)

function write_summary(path::AbstractString, s::BuildSummary)
    d = Dict{String, Any}(string(f) => string.(getfield(s, f)) for f in SUMMARY_LISTS)
    d["branches"] = Dict(string(k) => v for (k, v) in s.branches)
    d["trimmed"] = Dict(string(k) => v for (k, v) in s.trimmed)
    open(io -> TOML.print(io, d), path, "w")
end

function read_summary(path::AbstractString)
    d = TOML.parsefile(path)
    lists = [Symbol.(d[string(f)]) for f in SUMMARY_LISTS]
    ids(key) = Dict{Symbol, Vector{String}}(
        Symbol(k) => Vector{String}(v)
        for (k, v) in get(d, key, Dict())
    )
    return BuildSummary(lists..., ids("branches"), ids("trimmed"))
end

"""
Build in a new Julia process, like the R package's `callr` default: no state from
the current session (stale code, redefined functions) can leak in. Requires the
pipeline to come from a script, since a `Pipeline` cannot cross processes.
"""
function tar_make_fresh(
    script::AbstractString;
    names = nothing,
    force::Bool = false,
    store::Union{Store, AbstractString} = default_store_path(),
    root::Union{Nothing, AbstractString} = nothing,
    keep_going::Bool = false,
    track_manifest::Bool = false,
    check_stale::Bool = true,
    jobs::Union{Integer, Symbol} = 1,
    check_mutation::Bool = false,
    io::IO = stdout,
    progress::Symbol = :auto,
)
    check_progress(progress)
    summary_path = tempname()
    store_path = store isa Store ? store.root : String(store)
    program = """
    using Targets
    summary = tar_make(;
        script = $(repr(abspath(script))),
        names = $(repr(names)),
        force = $(repr(force)),
        store = $(repr(store_path)),
        root = $(repr(root === nothing ? nothing : String(root))),
        keep_going = $(repr(keep_going)),
        track_manifest = $(repr(track_manifest)),
        check_stale = $(repr(check_stale)),
        jobs = $(repr(jobs)),
        check_mutation = $(repr(check_mutation)),
    progress = $(repr(progress)),
    )
    Targets.write_summary($(repr(summary_path)), summary)
    """
    project = Base.active_project()
    threads = Threads.nthreads(:default)
    cmd = `$(Base.julia_cmd()) --startup-file=no --threads=$threads --project=$project -e $program`
    try
        # the child writes to `io` itself, so with `progress = :auto` it sees a terminal too
        run(pipeline(cmd; stdout = io, stderr = io))
    catch e
        e isa InterruptException && rethrow()
        error("the fresh build failed; see the output above for the cause")
    end
    try
        return read_summary(summary_path)
    finally
        rm(summary_path; force = true)
    end
end

"""
    plan!(ctx, t) -> Vector{Job}

Decide what target `t` needs: nothing if an upstream failed or it is up to date
(both recorded right away), else the jobs to execute. A branching target may
need several jobs, or none.
"""
function plan!(ctx::BuildContext, t::Target)
    sm = ctx.summary
    upstream_failed = filter(
        d -> (d in sm.errored && !(d in ctx.nulled)) || d in sm.blocked,
        t.deps,
    )
    if !isempty(upstream_failed)
        push!(sm.blocked, t.name)
        event!(ctx, t.name, :blocked)
        log!(ctx, "⊘ $(t.name) skipped: upstream $(join(upstream_failed, ", ")) failed")
        return Job[]
    end
    cmd = command_for!(ctx, t)
    code = code_for!(ctx, t)
    t.pattern === nothing || return plan_branching!(ctx, t, cmd, code)
    dep_hashes = Dict{Symbol, String}(d => ctx.value_hashes[d] for d in t.deps)
    seed = resolve_seed(ctx.pipeline, t)
    reason = outdated_reason(
        ctx.store,
        t,
        cmd,
        code,
        dep_hashes;
        seed = seed_string(seed),
        forced = t.name in ctx.forced,
        root = ctx.root,
    )
    if reason === nothing
        ctx.value_hashes[t.name] = stored_value_hash(ctx.store, t.name)
        push!(sm.skipped, t.name)
        event!(ctx, t.name, :skipped)
        log!(ctx, "· $(t.name) up to date")
        return Job[]
    end
    args, load_error = resolve_args(() -> Any[get_value!(ctx, d) for d in value_deps(t)])
    return [Job(
        t,
        string(t.name),
        0,
        args,
        load_error,
        seed,
        reason,
        cmd,
        code,
        dep_hashes,
        pattern_use_of(ctx.pipeline, t.name),
        ctx.store,
        ctx.root,
    )]
end

# Load a job's arguments; a failure becomes the job's error rather than ending the run.
function resolve_args(load)
    try
        return load(), nothing
    catch e
        e isa InterruptException && rethrow()
        return Any[], e
    end
end

"""
    commit!(ctx, result; keep_going) -> Bool

Record a job's outcome. Returns whether its target is now finished (a
branching target finishes with its last branch). Without `keep_going`, a
failure is rethrown after it is recorded.
"""
function commit!(ctx::BuildContext, r::JobResult; keep_going::Bool)
    job = r.job
    for (i, message) in enumerate(r.retried)
        log!(ctx, "↻ $(job.key) attempt $i failed, retrying: $message")
    end
    failed(r) ? keep_workspace!(ctx, r) : delete_workspace!(ctx.store, job.key)
    isempty(get(r.stored, :warnings, String[])) || push!(ctx.warned, job.key)
    job.branch > 0 && return commit_branch!(ctx, r; keep_going)
    t = job.target
    if failed(r)
        record_failure!(ctx, t, r.exception; backtrace = r.backtrace)
        push!(ctx.summary.errored, t.name)
        event!(ctx, t.name, :errored; r.seconds)
        log!(ctx, done_line(r))
        t.error === :null && null_value!(ctx, t)
        stops_build(t, keep_going) && throw(r.exception)
        return true
    end
    write_meta(ctx.store, t.name, job_record(r))
    # a value computed on another process is loaded from the store when needed
    ctx.remaining[t.name] > 0 && !(r.value isa Unloaded) && (ctx.values[t.name] = r.value)
    ctx.value_hashes[t.name] = r.value_hash
    push!(ctx.summary.built, t.name)
    event!(ctx, t.name, :built; r.seconds)
    log!(ctx, done_line(r))
    return true
end

"Whether a failure of `t` stops the build (see the `error` option of [`target`](@ref))."
stops_build(t::Target, keep_going::Bool) = !keep_going && t.error === :stop

const NULL_VALUE_HASH = canonical_hash((:null_value,))

"Give the consumers of failed target `t` `nothing` instead of blocking them."
function null_value!(ctx::BuildContext, t::Target)
    push!(ctx.nulled, t.name)
    get(ctx.remaining, t.name, 0) > 0 && (ctx.values[t.name] = nothing)
    ctx.value_hashes[t.name] = NULL_VALUE_HASH
    return nothing
end

function log_start!(ctx::BuildContext, job::Job)
    event!(ctx, job.key, :started)
    write_log(ctx.store, start_line(job))
    started!(ctx.display, job)
    return nothing
end

# Record the failure but leave the last good object in place.
function record_failure!(ctx::BuildContext, t::Target, e; key = t.name, backtrace = nothing)
    previous = something(read_meta(ctx.store, key), Record(; format = record_format(t)))
    message = first(sprint(showerror, e), 2000)
    write_meta(
        ctx.store,
        key,
        update(previous; error = message, traceback = user_frames(backtrace)),
    )
end

@testitem "a second run with no changes builds nothing" setup = [SourceFixtures] begin
    mktempdir() do dir
        code = """
        p = tar_pipeline(
            target(:raw, () -> 10),
            target(:clean, raw -> raw + 1),
            target(:model, clean -> clean * 2),
        )
        """
        first_run = build_source(code, dir)
        @test first_run.built == [:raw, :clean, :model]
        @test read_values(dir, :raw, :clean, :model) == (10, 11, 22)
        second = build_source(code, dir)
        @test isempty(second.built)
        @test second.skipped == [:raw, :clean, :model]
    end
end

@testitem "editing a function rebuilds it and affected descendants only" setup = [
    SourceFixtures,
] begin
    mktempdir() do dir
        code(clean; note = "") = """
        $note
        p = tar_pipeline(
            target(:raw, () -> 10),
            target(:clean, raw -> $clean),
            target(:model, clean -> clean * 2),
            target(:other, raw -> raw - 1),
        )
        """
        build_source(code("raw + 1"), dir)
        # reformatting and moving code changes nothing
        @test isempty(build_source(code("raw  +  1"; note = "# a comment\n\n"), dir).built)
        # a behavioral change rebuilds the target and what depends on its output
        s = build_source(code("raw + 2"), dir)
        @test s.built == [:clean, :model]
        @test s.skipped == [:raw, :other]
        @test read_values(dir, :model) == (24,)
    end
end

@testitem "an unchanged rebuilt output stops propagation (early cutoff)" setup = [
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
        build_source(code("raw + 1"), dir)
        s = build_source(code("1 + raw"), dir) # new code, same output
        @test s.built == [:clean]
        @test s.skipped == [:raw, :model]
    end
end

@testitem "a deleted object rebuilds only that target" setup = [SourceFixtures] begin
    using Targets: open_store, delete_object
    mktempdir() do dir
        code = """
        p = tar_pipeline(
            target(:raw, () -> 10),
            target(:clean, raw -> raw + 1),
            target(:model, clean -> clean * 2),
        )
        """
        build_source(code, dir)
        delete_object(open_store(joinpath(dir, "_targets")), :clean)
        s = build_source(code, dir)
        @test s.built == [:clean]
        @test s.skipped == [:raw, :model]
    end
end

@testitem "names selects ancestors and force rebuilds them" setup = [SourceFixtures] begin
    mktempdir() do dir
        code = """
        p = tar_pipeline(
            target(:raw, () -> 10),
            target(:clean, raw -> raw + 1),
            target(:model, clean -> clean * 2),
            target(:other, () -> 5),
        )
        """
        @test build_source(code, dir; names = [:clean]).built == [:raw, :clean]
        @test build_source(code, dir).built == [:model, :other]
        s = build_source(code, dir; names = [:model], force = true)
        @test s.built == [:raw, :clean, :model]
        @test s.skipped == Symbol[]
        @test build_source(code, dir; force = true).built == [:raw, :clean, :model, :other]
        @test_throws "did you mean `model`" build_source(code, dir; names = [:modle])
    end
end

@testitem "a failing target keeps its previous object and stops the run" setup = [
    SourceFixtures,
] begin
    using Targets: open_store, read_meta
    mktempdir() do dir
        code(body) = """
        p = tar_pipeline(
            target(:raw, () -> 10),
            target(:model, raw -> $body),
            target(:report, model -> model + 1),
        )
        """
        build_source(code("raw * 2"), dir)
        @test_throws ErrorException build_source(code("error(\"boom\")"), dir)
        @test read_values(dir, :model, :report) == (20, 21) # last good objects kept
        record = read_meta(open_store(joinpath(dir, "_targets")), :model)
        @test occursin("boom", record.error)
        # fixing the function rebuilds the errored target on the next run
        s = build_source(code("raw * 3"), dir)
        @test s.built == [:model, :report]
        @test read_values(dir, :report) == (31,)
    end
end

@testitem "keep_going builds independent targets and blocks descendants" setup = [
    SourceFixtures,
] begin
    mktempdir() do dir
        code = """
        p = tar_pipeline(
            target(:bad, () -> error("nope")),
            target(:after_bad, bad -> bad),
            target(:good, () -> 1),
            target(:after_good, good -> good + 1),
        )
        """
        s = build_source(code, dir; keep_going = true)
        @test s.errored == [:bad]
        @test s.blocked == [:after_bad]
        @test s.built == [:good, :after_good]
        @test read_values(dir, :after_good) == (2,)
    end
end

@testitem "tar_make() loads _targets.jl into a fresh module" begin
    mktempdir() do dir
        script = joinpath(dir, "_targets.jl")
        write(script, "tar_pipeline(target(:x, () -> 41), target(:y, x -> x + 1))\n")
        store = joinpath(dir, "_targets")
        s = tar_make(; script, store, io = devnull)
        @test s.built == [:x, :y]
        @test tar_read(:y; store) == 42
        @test isempty(tar_make(; script, store, io = devnull).built)
        write(script, "1 + 1\n")
        @test_throws "must end with" tar_make(; script, store, io = devnull)
    end
end

@testitem "a pipeline script can include helper files" begin
    mktempdir() do dir
        write(joinpath(dir, "helpers.jl"), "double(x) = 2x\n")
        script = joinpath(dir, "_targets.jl")
        write(
            script,
            "include(joinpath(@__DIR__, \"helpers.jl\"))\ntar_pipeline(target(:x, () -> double(21)))\n",
        )
        store = joinpath(dir, "_targets")
        @test tar_make(; script, store, root = dir, io = devnull).built == [:x]
        @test tar_read(:x; store) == 42
    end
end

@testitem "tar_make writes a progress log" setup = [SourceFixtures] begin
    mktempdir() do dir
        build_source("p = tar_pipeline(target(:a, () -> 1))", dir)
        log = read(joinpath(dir, "_targets", "log", "progress.log"), String)
        @test occursin("▶ a (missing)", log)
        @test occursin(r"✔ a [0-9.]+s \(missing\)", log)
        @test occursin("summary: 1 built", log)
    end
end

@testitem "editing code a target reaches rebuilds exactly its consumers" setup = [
    SourceFixtures,
] begin
    mktempdir() do dir
        code(; helper = "x + 1", extra = "") = """
        $extra
        helper(x) = $helper
        unused(x) = x
        mid(x) = helper(x) * 2
        p = tar_pipeline(
            target(:a, () -> mid(1)),
            target(:b, a -> a + 1),
            target(:c, () -> 5),
            target(:d, () -> mid(2)),
        )
        """
        @test build_source(code(), dir).built == [:a, :b, :c, :d]
        @test isempty(
            build_source(code(; helper = "x +  1", extra = "# moved\n"), dir).built,
        )
        @test isempty(build_source(code(; extra = "unused(x) = x + 100"), dir).built)
        s = build_source(code(; helper = "x + 2"), dir) # two calls deep
        @test s.built == [:a, :b, :d]
        @test s.skipped == [:c]
    end
end

@testitem "adding a method or changing a global rebuilds consumers, with early cutoff" setup = [
    SourceFixtures,
] begin
    mktempdir() do dir
        code(; methods = "", alpha = "2") = """
        const ALPHA = $alpha
        h(x::Int) = x + ALPHA
        $methods
        p = tar_pipeline(
            target(:a, () -> h(1)),
            target(:b, a -> a * 10),
        )
        """
        build_source(code(), dir)
        s = build_source(
            code(; methods = "h(x::String) = 0"),
            dir,
        ) # new method, same output
        @test s.built == [:a]
        @test s.skipped == [:b]
        s = build_source(code(; methods = "h(x::String) = 0", alpha = "3"), dir)
        @test s.built == [:a, :b]
        @test read_values(dir, :b) == (40,)
    end
end

@testitem "the stale-session guard stops a run on edited but unreloaded code" setup = [
    SourceFixtures,
] begin
    mktempdir() do dir
        m, path = load_source(
            "h(x) = x + 1\np = tar_pipeline(target(:a, () -> h(1)))\n";
            dir,
        )
        p = Base.invokelatest(getproperty, m, :p)
        run(; kwargs...) = tar_make(
            p;
            store = joinpath(dir, "_targets"),
            root = dir,
            io = devnull,
            kwargs...,
        )
        @test run().built == [:a]
        write(
            path,
            "h(x) = x + 2\np = tar_pipeline(target(:a, () -> h(1)))\n",
        ) # edited, not reloaded
        Targets.with_revise_assumed(false) do
            @test_throws "Revise" run()
        end
        Targets.with_revise_assumed(true) do
            # with Revise the check is off
            @test run() isa BuildSummary
        end
        @test run(; check_stale = false) isa
            BuildSummary # opting out hashes the new file anyway
    end
end

@testitem "a changed Manifest warns, or rebuilds everything when asked" setup = [
    SourceFixtures,
] begin
    mktempdir() do dir
        manifest(version) = write(
            joinpath(dir, "Manifest.toml"),
            "manifest_format = \"2.0\"\n[[deps.Foo]]\nuuid = \"x\"\nversion = \"$version\"\n",
        )
        code = "p = tar_pipeline(target(:a, () -> 1), target(:b, a -> a + 1))"
        manifest("1.0.0")
        @test build_source(code, dir).built == [:a, :b]
        @test isempty(build_source(code, dir).built)
        manifest("1.1.0")
        @test_logs (:warn, r"Foo 1\.0\.0 → 1\.1\.0") build_source(code, dir)
        @test isempty(build_source(code, dir).built) # warned once
        manifest("2.0.0")
        s = @test_logs (:info, r"rebuilding everything") build_source(
            code,
            dir;
            track_manifest = true,
        )
        @test s.built == [:a, :b]
    end
end

@testitem "tar_outdated explains what a build would do" setup = [SourceFixtures] begin
    mktempdir() do dir
        code(clean) = """
        p = tar_pipeline(
            target(:raw, () -> 10),
            target(:clean, raw -> $clean),
            target(:model, clean -> clean * 2),
        )
        """
        before = outdated_source(code("raw + 1"), dir)
        @test before ==
            [
                (name = :raw, reason = :missing),
                (name = :clean, reason = :upstream_outdated),
                (name = :model, reason = :upstream_outdated),
            ]
        build_source(code("raw + 1"), dir)
        @test isempty(outdated_source(code("raw + 1"), dir))
        @test outdated_source(code("raw + 2"), dir) ==
            [
                (name = :clean, reason = :command_changed),
                (name = :model, reason = :upstream_outdated),
            ]
        @test outdated_source(code("raw + 2"), dir; names = [:raw]) == []
    end
end

# A tiny deterministic generator, so that failures are reproducible.
@testmodule MiniRandom begin
    export Gen, draw!
    mutable struct Gen
        state::UInt64
    end
    "A uniform integer in 1:n."
    function draw!(g::Gen, n::Integer)
        g.state = g.state * 6364136223846793005 + 1442695040888963407
        return Int((g.state >> 33) % n) + 1
    end
end

@testitem "oracle: incremental builds always equal a clean build" setup = [
    SourceFixtures,
    MiniRandom,
] begin
    # A target is a small integer function of its dependencies. Random edits change
    # a coefficient, the shared modulus, or only the formatting or operand order,
    # so some edits change outputs, some change code only, and some change nothing.
    function render(spec)
        lines = [
            "const MODULUS = $(spec.modulus)",
            "wrap(x) = mod(x, MODULUS)",
            spec.noise,
            "p = tar_pipeline(",
        ]
        for (i, t) in enumerate(spec.targets)
            args = join(("t$d" for d in t.deps), ", ")
            terms = ["$(t.a)", ("$(t.b) * t$d" for d in t.deps)...]
            t.swap && (terms = reverse(terms))
            push!(lines, "    target(:t$i, ($args) -> wrap($(join(terms, " + ")))),")
        end
        push!(lines, ")")
        return join(lines, "\n") * "\n"
    end
    Target3 = NamedTuple{(:deps, :a, :b, :swap), Tuple{Vector{Int}, Int, Int, Bool}}
    function random_spec(g)
        n = 3 + draw!(g, 3)
        ts = [
            Target3((
                sort(unique([draw!(g, i - 1) for _ in 1:(i == 1 ? 0 : draw!(g, 2))])),
                draw!(g, 50),
                draw!(g, 9),
                false,
            ))
            for i in 1:n
        ]
        return (modulus = 1000 + draw!(g, 50), noise = "", targets = ts)
    end
    function edit(spec, g)
        i = draw!(g, length(spec.targets))
        t = spec.targets[i]
        kind = draw!(g, 5)
        targets = copy(spec.targets)
        if kind == 1
            targets[i] = merge(t, (a = draw!(g, 50),))
        elseif kind == 2
            targets[i] = merge(t, (b = draw!(g, 9),))
        elseif kind == 3
            targets[i] = merge(t, (swap = !t.swap,)) # same value, different code
        end
        modulus = kind == 4 ? 1000 + draw!(g, 50) : spec.modulus
        noise = kind == 5 ? "# edit $(draw!(g, 1000))" : spec.noise # comment only
        return (; modulus, noise, targets)
    end

    for seed in 1:4
        g = Gen(UInt64(seed))
        spec = random_spec(g)
        names = [Symbol("t$i") for i in eachindex(spec.targets)]
        incremental = mktempdir()
        for step in 1:12
            code = render(spec)
            build_source(code, incremental; jobs = isodd(step) ? 1 : 4)
            @test isempty(outdated_source(code, incremental))
            clean = mktempdir()
            build_source(code, clean)
            @test read_values(incremental, names...) == read_values(clean, names...)
            spec = edit(spec, g)
        end
    end
end

@testitem "values are dropped from memory once their last consumer has run" setup = [
    SourceFixtures,
] begin
    mktempdir() do dir
        chain = """
        p = tar_pipeline(
            target(:a, () -> collect(1:100)),
            target(:b, a -> sum(a)),
            target(:c, b -> b + 1),
            target(:d, c -> c + 1),
        )
        """
        sizes = Int[]
        build_source(chain, dir; observe = ctx -> push!(sizes, length(ctx.values)))
        @test sizes == [1, 1, 1, 0] # never more than one finished value held

        diamond = """
        p = tar_pipeline(
            target(:raw, () -> 1),
            target(:left, raw -> raw + 1),
            target(:right, raw -> raw + 2),
            target(:both, (left, right) -> left + right),
        )
        """
        sizes = Int[]
        build_source(diamond, dir; observe = ctx -> push!(sizes, length(ctx.values)))
        @test sizes == [1, 2, 2, 0] # raw is released after its last consumer

        sizes = Int[]
        @test isempty(
            build_source(
                diamond,
                dir;
                observe = ctx -> push!(sizes, length(ctx.values)),
            ).built,
        )
        @test all(==(0), sizes) # an up-to-date run loads no object at all
    end
end

@testitem "a target that reads the store itself gets no values and holds none" setup = [
    SourceFixtures,
] begin
    mktempdir() do dir
        code(n) = """
        struct Reader end
        (::Reader)(values...) = length(values)
        Targets.passes_values(::Reader) = false
        p = tar_pipeline(
            target(:a, () -> $n),
            target(:reader, Reader(); deps = [:a], source = :(read_store())),
        )
        """
        sizes = Int[]
        observe = ctx -> push!(sizes, length(ctx.values))
        @test build_source(code(1), dir; observe).built == [:a, :reader]
        @test read_values(dir, :reader) == (0,)
        @test sizes == [0, 0] # nothing kept for a consumer that does not take values
        @test isempty(build_source(code(1), dir).built)
        @test build_source(code(2), dir).built == [:a, :reader] # still a dependency
    end
end

@testitem "a fresh build runs in a new process and reports the same summary" begin
    mktempdir() do dir
        script = joinpath(dir, "_targets.jl")
        write(script, "tar_pipeline(target(:x, () -> 41), target(:y, x -> x + 1))\n")
        store = joinpath(dir, "_targets")
        s = tar_make(; script, store, root = dir, fresh = true, io = devnull)
        @test s.built == [:x, :y]
        @test tar_read(:y; store) == 42
        again = tar_make(;
            script,
            store,
            root = dir,
            fresh = true,
            io = devnull,
            names = [:y],
        )
        @test isempty(again.built) && again.skipped == [:x, :y]
        write(script, "tar_pipeline(target(:x, () -> error(\"boom\")))\n")
        @test_throws "fresh build failed" tar_make(;
            script,
            store,
            root = dir,
            fresh = true,
            force = true,
            io = devnull,
        )
    end
end

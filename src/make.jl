"""
    BuildSummary

Names of targets that were `built`, found up to date (`skipped`), failed
(`errored`) or not attempted because an upstream target failed (`blocked`),
each in build order.
"""
struct BuildSummary
    built::Vector{Symbol}
    skipped::Vector{Symbol}
    errored::Vector{Symbol}
    blocked::Vector{Symbol}
end
BuildSummary() = BuildSummary(Symbol[], Symbol[], Symbol[], Symbol[])

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
        ")",
    )
end

"State for one `tar_make` run."
struct BuildContext
    pipeline::Pipeline
    store::Store
    forced::Set{Symbol}
    io::IO
    commands::Dict{Symbol, CommandHash}
    values::Dict{Symbol, Any}
    value_hashes::Dict{Symbol, String}
    summary::BuildSummary
end

function BuildContext(p::Pipeline, store::Store, forced, io::IO)
    return BuildContext(
        p,
        store,
        Set{Symbol}(forced),
        io,
        Dict{Symbol, CommandHash}(),
        Dict{Symbol, Any}(),
        Dict{Symbol, String}(),
        BuildSummary(),
    )
end

function log!(ctx::BuildContext, message::AbstractString)
    println(ctx.io, message)
    open(io -> println(io, message), log_path(ctx.store), "a")
    return nothing
end

"Value of a finished target, loaded from the store on first use."
get_value!(ctx::BuildContext, name::Symbol) = get!(
    () -> read_object(ctx.store, name),
    ctx.values,
    name,
)

command_for!(ctx::BuildContext, t::Target) = get!(
    () -> command_hash(t),
    ctx.commands,
    t.name,
)

function check_supported(p::Pipeline, names)
    for name in names
        t = get_target(p, name)
        t.format == :file && error("target `$name`: file targets are not implemented yet")
        t.pattern === nothing ||
            error("target `$name`: dynamic branching is not implemented yet")
    end
end

"Warn once about targets whose code could only be hashed in a Julia-version-dependent way."
function warn_weak_hashes(ctx::BuildContext, names)
    lowered = [
        n
        for n in names
        if command_for!(ctx, get_target(ctx.pipeline, n)).kind == :lowered
    ]
    unknown = [
        n
        for n in names
        if command_for!(ctx, get_target(ctx.pipeline, n)).kind == :unknown
    ]
    isempty(lowered) ||
        @warn "no source found for these targets; their lowered code is hashed instead, so a Julia upgrade will rebuild them" targets = lowered
    isempty(unknown) ||
        @warn "the code of these targets cannot be hashed, so they are always rebuilt" targets = unknown
end

"""
    tar_make(p::Pipeline; names = nothing, force = false, store = default_store_path(),
             keep_going = false, io = stdout)

Build the targets of `p` that are outdated, in dependency order, and return a
[`BuildSummary`](@ref). With `names`, only those targets and everything they
depend on are considered. With `force = true`, all of those are rebuilt whatever
their status. An error stops the run and is rethrown, unless `keep_going` is
set, in which case independent targets are still built and the failure is
reported in the summary.
"""
function tar_make(
    p::Pipeline;
    names = nothing,
    force::Bool = false,
    store::Union{Store, AbstractString} = default_store_path(),
    keep_going::Bool = false,
    io::IO = stdout,
)
    s = store isa Store ? store : open_store(store)
    selected = selected_order(p, names)
    check_supported(p, selected)
    ctx = BuildContext(p, s, force ? selected : Symbol[], io)
    warn_weak_hashes(ctx, selected)
    for name in selected
        process!(ctx, get_target(p, name); keep_going)
    end
    sm = ctx.summary
    log!(
        ctx,
        "summary: $(length(sm.built)) built, $(length(sm.skipped)) up to date, " *
            "$(length(sm.errored)) errored, $(length(sm.blocked)) blocked",
    )
    return sm
end

"""
    tar_make(; script = joinpath(project_root(), "_targets.jl"), kwargs...)

Load `script` into a fresh module (so no state leaks from the REPL between
runs) and build the [`Pipeline`](@ref) its last expression returns.
"""
function tar_make(;
    script::AbstractString = joinpath(project_root(), "_targets.jl"),
    kwargs...,
)
    isfile(script) || error("no pipeline script at $script")
    m = Module(:TargetsScript)
    Core.eval(m, :(using Targets))
    p = Base.include(m, script)
    p isa Pipeline ||
        error(
            "$script must end with a `tar_pipeline(...)` call, but returned `$(typeof(p))`",
        )
    return tar_make(p; kwargs...)
end

function process!(ctx::BuildContext, t::Target; keep_going::Bool)
    sm = ctx.summary
    upstream_failed = filter(d -> d in sm.errored || d in sm.blocked, t.deps)
    if !isempty(upstream_failed)
        push!(sm.blocked, t.name)
        log!(ctx, "⊘ $(t.name) skipped: upstream $(join(upstream_failed, ", ")) failed")
        return nothing
    end
    cmd = command_for!(ctx, t)
    dep_hashes = Dict{Symbol, String}(d => ctx.value_hashes[d] for d in t.deps)
    reason = outdated_reason(ctx.store, t, cmd, dep_hashes; forced = t.name in ctx.forced)
    if reason === nothing
        ctx.value_hashes[t.name] = stored_value_hash(ctx.store, t.name)
        push!(sm.skipped, t.name)
        log!(ctx, "· $(t.name) up to date")
    else
        build!(ctx, t, cmd, dep_hashes, reason; keep_going)
    end
    return nothing
end

function build!(ctx::BuildContext, t::Target, cmd, dep_hashes, reason; keep_going::Bool)
    log!(ctx, "▶ $(t.name) ($reason)")
    started = time_ns()
    try
        args = Any[get_value!(ctx, d) for d in t.deps]
        value = Base.invokelatest(t.f, args...)
        seconds = (time_ns() - started) / 1.0e9
        path = write_object(ctx.store, t.name, value)
        vhash = object_hash(value, path)
        write_meta(
            ctx.store,
            t.name,
            Record(;
                command_hash = something(cmd.hash, ""),
                hash_source = string(cmd.kind),
                dep_hashes = Dict{String, String}(string(d) => h for (d, h) in dep_hashes),
                value_hash = vhash,
                format = string(t.format),
                built_at = string(Dates.now(Dates.UTC)),
                seconds,
            ),
        )
        ctx.values[t.name] = value
        ctx.value_hashes[t.name] = vhash
        push!(ctx.summary.built, t.name)
        log!(ctx, "✔ $(t.name) $(round(seconds; digits = 2))s")
    catch e
        e isa InterruptException && rethrow()
        record_failure!(ctx, t, cmd, e)
        push!(ctx.summary.errored, t.name)
        log!(ctx, "✖ $(t.name): $(first(sprint(showerror, e), 200))")
        keep_going || rethrow()
    end
    return nothing
end

# Record the failure but leave the last good object in place.
function record_failure!(ctx::BuildContext, t::Target, cmd, e)
    previous = something(read_meta(ctx.store, t.name), Record(; format = string(t.format)))
    message = first(sprint(showerror, e), 2000)
    write_meta(ctx.store, t.name, update(previous; error = message))
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

@testitem "tar_make writes a progress log" setup = [SourceFixtures] begin
    mktempdir() do dir
        build_source("p = tar_pipeline(target(:a, () -> 1))", dir)
        log = read(joinpath(dir, "_targets", "log", "progress.log"), String)
        @test occursin("▶ a (missing)", log)
        @test occursin("summary: 1 built", log)
    end
end

"""
    BuildSummary

Names of targets that were `built`, found up to date (`skipped`), failed
(`errored`) or not attempted because an upstream target failed (`blocked`),
each in build order. `branches` maps each branching target to the ids of the
branches that were (re)built in this run.
"""
struct BuildSummary
    built::Vector{Symbol}
    skipped::Vector{Symbol}
    errored::Vector{Symbol}
    blocked::Vector{Symbol}
    branches::Dict{Symbol, Vector{String}}
end
BuildSummary() = BuildSummary(
    Symbol[],
    Symbol[],
    Symbol[],
    Symbol[],
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
        ")",
    )
end

"State for one `tar_make` run."
struct BuildContext
    pipeline::Pipeline
    store::Store
    root::String
    forced::Set{Symbol}
    io::IO
    discovery::Discovery
    commands::Dict{Symbol, CommandHash}
    codes::Dict{Symbol, String}
    values::Dict{Symbol, Any}
    value_hashes::Dict{Symbol, String}
    remaining::Dict{Symbol, Int}
    summary::BuildSummary
    observe::Function
end

# How many selected targets still need each target's value in this run.
function consumer_counts(p::Pipeline, selected)
    counts = Dict{Symbol, Int}(name => 0 for name in selected)
    for name in selected, d in get_target(p, name).deps
        counts[d] += 1
    end
    return counts
end

function BuildContext(
    p::Pipeline,
    store::Store,
    root::AbstractString,
    forced,
    io::IO,
    discovery::Discovery,
    selected,
    observe::Function,
)
    return BuildContext(
        p,
        store,
        String(root),
        Set{Symbol}(forced),
        io,
        discovery,
        Dict{Symbol, CommandHash}(),
        Dict{Symbol, String}(),
        Dict{Symbol, Any}(),
        Dict{Symbol, String}(),
        consumer_counts(p, selected),
        BuildSummary(),
        observe,
    )
end

function log!(ctx::BuildContext, message::AbstractString)
    println(ctx.io, message)
    open(io -> println(io, message), log_path(ctx.store), "a")
    return nothing
end

"The stored value of a finished target: its object, or for a file target its path(s)."
function load_value(ctx::BuildContext, name::Symbol)
    t = get_target(ctx.pipeline, name)
    t.format == :file && return file_value(read_meta(ctx.store, name)::Record)
    t.pattern === nothing || return load_branches(ctx.store, name)
    return read_object(ctx.store, name)
end

"Value of a finished target, loaded from the store on first use."
get_value!(ctx::BuildContext, name::Symbol) = get!(
    () -> load_value(ctx, name),
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
        (t.pattern !== nothing && t.format == :file) &&
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
             check_stale = true, io = stdout)

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
"""
function tar_make(
    p::Pipeline;
    names = nothing,
    force::Bool = false,
    store::Union{Store, AbstractString} = default_store_path(),
    root::Union{Nothing, AbstractString} = nothing,
    keep_going::Bool = false,
    track_manifest::Bool = false,
    check_stale::Bool = true,
    io::IO = stdout,
    observe::Function = ctx -> nothing,
)
    rootdir = something(root, project_root())
    s = store isa Store ? store : open_store(store)
    selected = selected_order(p, names)
    check_supported(p, selected)
    ctx = BuildContext(
        p,
        s,
        rootdir,
        Symbol[],
        io,
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
    cd(rootdir) do
        for name in selected
            t = get_target(p, name)
            process!(ctx, t; keep_going)
            release!(ctx, t)
            ctx.observe(ctx)
        end
    end
    sm = ctx.summary
    isempty(sm.errored) && record_manifest!(s, rootdir)
    log!(
        ctx,
        "summary: $(length(sm.built)) built, $(length(sm.skipped)) up to date, " *
            "$(length(sm.errored)) errored, $(length(sm.blocked)) blocked",
    )
    return sm
end

default_script() = joinpath(project_root(), "_targets.jl")

"Load a pipeline script into a fresh module, so no state leaks from the REPL between runs."
function load_pipeline(script::AbstractString)
    isfile(script) || error("no pipeline script at $script")
    m = Module(:TargetsScript)
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
    for d in t.deps
        ctx.remaining[d] -= 1
        ctx.remaining[d] <= 0 && delete!(ctx.values, d)
    end
    return nothing
end

const SUMMARY_LISTS = (:built, :skipped, :errored, :blocked)

function write_summary(path::AbstractString, s::BuildSummary)
    d = Dict{String, Any}(string(f) => string.(getfield(s, f)) for f in SUMMARY_LISTS)
    d["branches"] = Dict(string(k) => v for (k, v) in s.branches)
    open(io -> TOML.print(io, d), path, "w")
end

function read_summary(path::AbstractString)
    d = TOML.parsefile(path)
    lists = [Symbol.(d[string(f)]) for f in SUMMARY_LISTS]
    branches = Dict{Symbol, Vector{String}}(
        Symbol(k) => Vector{String}(v)
        for (k, v) in d["branches"]
    )
    return BuildSummary(lists..., branches)
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
    io::IO = stdout,
)
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
    )
    Targets.write_summary($(repr(summary_path)), summary)
    """
    project = Base.active_project()
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$project -e $program`
    try
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

function process!(ctx::BuildContext, t::Target; keep_going::Bool)
    sm = ctx.summary
    upstream_failed = filter(d -> d in sm.errored || d in sm.blocked, t.deps)
    if !isempty(upstream_failed)
        push!(sm.blocked, t.name)
        log!(ctx, "⊘ $(t.name) skipped: upstream $(join(upstream_failed, ", ")) failed")
        return nothing
    end
    cmd = command_for!(ctx, t)
    code = code_for!(ctx, t)
    t.pattern === nothing || return process_branching!(ctx, t, cmd, code; keep_going)
    dep_hashes = Dict{Symbol, String}(d => ctx.value_hashes[d] for d in t.deps)
    reason = outdated_reason(
        ctx.store,
        t,
        cmd,
        code,
        dep_hashes;
        forced = t.name in ctx.forced,
        root = ctx.root,
    )
    if reason === nothing
        ctx.value_hashes[t.name] = stored_value_hash(ctx.store, t.name)
        push!(sm.skipped, t.name)
        log!(ctx, "· $(t.name) up to date")
    else
        build!(ctx, t, cmd, code, dep_hashes, reason; keep_going)
    end
    return nothing
end

# Persist what a target returned. Returns the value its consumers receive, its
# value hash, and any extra record fields (a file target keeps no object).
function commit_value!(ctx::BuildContext, t::Target, value)
    if t.format == :file
        paths, scalar = normalize_file_value(t, value, ctx.root)
        state = file_state(ctx.root, paths)
        stored = (;
            files = paths,
            file_scalar = scalar,
            file_signatures = state.signatures,
            file_hashes = state.hashes,
        )
        pattern_use = pattern_use_of(ctx.pipeline, t.name)
        (pattern_use === nothing || !scalar) ||
            error(
                "target `$(t.name)` is the pattern of `$pattern_use`, so it must return a vector of paths",
            )
        return (scalar ? first(paths) : paths), state.value_hash, stored
    end
    path = write_object(ctx.store, t.name, value)
    stored = (;)
    pattern_use = pattern_use_of(ctx.pipeline, t.name)
    if pattern_use !== nothing && t.pattern === nothing
        value isa AbstractVector ||
            error(
                "target `$(t.name)` is the pattern of `$pattern_use`, so it must return a vector, " *
                    "not a `$(typeof(value))`",
            )
        stored = (; element_hashes = element_hashes(value), elements_recorded = true)
    end
    return value, object_hash(value, path), stored
end

function build!(
    ctx::BuildContext,
    t::Target,
    cmd,
    code,
    dep_hashes,
    reason;
    keep_going::Bool,
)
    log!(ctx, "▶ $(t.name) ($reason)")
    started = time_ns()
    try
        args = Any[get_value!(ctx, d) for d in t.deps]
        value = Base.invokelatest(t.f, args...)
        seconds = (time_ns() - started) / 1.0e9
        consumer_value, vhash, stored = commit_value!(ctx, t, value)
        write_meta(
            ctx.store,
            t.name,
            Record(;
                command_hash = something(cmd.hash, ""),
                code_hash = code,
                hash_source = string(cmd.kind),
                dep_hashes = Dict{String, String}(string(d) => h for (d, h) in dep_hashes),
                value_hash = vhash,
                format = string(t.format),
                built_at = string(Dates.now(Dates.UTC)),
                seconds,
                stored...,
            ),
        )
        ctx.remaining[t.name] > 0 && (ctx.values[t.name] = consumer_value)
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
function record_failure!(ctx::BuildContext, t::Target, cmd, e; key = t.name)
    previous = something(read_meta(ctx.store, key), Record(; format = string(t.format)))
    message = first(sprint(showerror, e), 2000)
    write_meta(ctx.store, key, update(previous; error = message))
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
        @test_throws "Revise" run()
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
            build_source(code, incremental)
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

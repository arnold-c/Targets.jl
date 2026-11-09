# A small, self-contained project for trying Targets by hand.
#
# The demo is a real project with its own environment in `examples/.demo/` (git-ignored;
# delete it to start over). Create it once from the repository root:
#
#   julia --project=. -e 'include("examples/demo.jl"); demo_setup()'
#
# Then work in it like any project, in a fresh REPL:
#
#   cd examples/.demo
#   julia --project=.                 # or: pkg> activate .
#   julia> using Targets, CairoMakie  # or GLMakie (a window), or WGLMakie (a browser tab)
#   julia> tar_make()                 # builds; run it again to see "up to date"
#   julia> tar_outdated()
#   julia> tar_read(:report)
#   julia> print(tar_dot())
#   julia> tar_visnetwork()           # needs one of the Makie backends above; with
#                                     # GLMakie or WGLMakie: drag targets, pan, zoom
#
# To try an edit, regenerate the files with one change (from that same REPL):
#
#   julia> include("../demo.jl")
#   julia> write_demo(; scale = 4)    # a global that `score` reaches
#   julia> tar_outdated()             # what would rebuild, and why
#   julia> tar_make()
#
# Other knobs of `write_demo`: note (comment only), data (input file), grid (branching),
# discount (a helper two calls deep), shifts (static branching).
#
# The v0.2 features (seeds, concurrent jobs, formats, patterns, tar_rep, error modes,
# retries, workspaces, cues, progress, executors) have a second project in
# `examples/.demo-features/` (also git-ignored). Create it once:
#
#   julia --project=. -e 'include("examples/demo.jl"); features_setup()'
#
# Start Julia with threads, so concurrent targets really run in parallel (`jobs`
# also works on one thread, but then tasks only interleave):
#
#   cd examples/.demo-features
#   julia --project=. -t 4
#   julia> using Targets, GLMakie     # or CairoMakie, or WGLMakie
#   julia> tar_make(; jobs = 4)       # `maybe` fails (error = :null), one branch of
#                                     # `fragile_fits` is trimmed, `flaky` is retried
#   julia> tar_read(:uses_maybe), tar_read(:fragile_fits), tar_read(:exclusive)
#   julia> tar_errored()              # what failed, and why
#   julia> tar_traceback(:maybe)
#   julia> tar_workspace(:maybe)      # the arguments of the failed call
#   julia> tar_rerun(:maybe)          # rerun it here, with the same seed
#   julia> tar_meta()                 # look for `warnings` in the `noisy` row
#   julia> tar_progress()             # the last run's events, also during a build
#   julia> tar_visnetwork()
#
# Then fix the failures and edit things:
#
#   julia> rm("fail_10"); rm("fail_maybe")
#   julia> tar_make(; jobs = 4)       # only the failed parts rebuild
#   julia> include("../demo.jl")
#   julia> write_features(; seed = 1)                   # :seed_changed
#   julia> write_features(; seed = 1, total = "sum(xs) + 0")  # Cue(code = false): nothing
#   julia> write_features(; seed = 1, fast_format = :jld2)    # :format_changed
#   julia> tar_outdated(); tar_make(; jobs = 4, check_mutation = true)
#
# Or on worker processes, from the same REPL:
#
#   julia> using Distributed; addprocs(2; exeflags = "--project=$(Base.active_project())")
#   julia> tar_make(; executor = DistributedExecutor(workers()), force = true)
#
# `walkthrough()` and `features_walkthrough()` run fixed sequences of these edits in
# temporary directories and check that each step rebuilds exactly what it should:
#
#   julia --project=. -t 4 examples/demo.jl [--distributed]

# Use the repository's Targets when no environment provides one (e.g. a fresh `julia`).
using Pkg
if Base.identify_package("Targets") === nothing
    Pkg.activate(; temp = true, io = devnull)
    Pkg.develop(; path = dirname(@__DIR__), io = devnull)
end
using Targets
using Logging: Logging, ConsoleLogger, with_logger

demo_dir() = joinpath(@__DIR__, ".demo")
demo_store(dir = demo_dir()) = joinpath(dir, "_targets")

# Every demo environment has all three, so each way of plotting can be tried.
const MAKIE_BACKENDS = (:CairoMakie, :GLMakie, :WGLMakie)

# The Makie backend the demo script in `dir` loads, if any (so regenerating keeps it).
function makie_backend(dir)
    isfile(demo_script(dir)) || return nothing
    script = read(demo_script(dir), String)
    i = findfirst(b -> occursin("using $b\n", script), MAKIE_BACKENDS)
    return i === nothing ? nothing : MAKIE_BACKENDS[i]
end

# The line of a `_targets.jl` that loads the Makie backend `makie`, if any.
function makie_line(makie)
    makie === nothing && return ""
    makie in MAKIE_BACKENDS ||
        throw(ArgumentError(
            "makie must be `nothing` or one of $MAKIE_BACKENDS, got $(repr(makie))",
        ))
    return "using $makie\n"
end

function print_plotting_help()
    println("  Plot with any Makie backend (all three are installed):")
    println("  using CairoMakie; tar_visnetwork()   # a static figure")
    println("  using GLMakie; tar_visnetwork()      # an interactive window")
    println("  using WGLMakie; tar_visnetwork()     # an interactive browser tab")
    return nothing
end

"""
    write_demo(dir; scale = 3, note = "", data = "1.0 2.0 NaN 4.0", grid = "[0.1, 0.5, 1.0]",
               discount = "x", shifts = "(low = 1, high = 2)", makie = makie_backend(dir))

Write the demo project into `dir`. Each keyword changes one thing:

- `scale`: a `const` in `analysis.jl` that `score` reaches (code edit, changes outputs)
- `note`: a comment line (formatting-only edit: must rebuild nothing)
- `data`: contents of the input file `data/raw.csv`
- `grid`: the pattern target's elements (branching)
- `discount`: an expression inside a helper two calls deep from the `scores` target
- `shifts`: a named tuple of shifts; each name gets a `shifted_<name>` and a
  `shift_summary_<name>` target (static branching with `tar_map`), combined by
  `shifted_total` (`tar_combine`)
- `makie`: a Makie backend for `_targets.jl` to load (`:CairoMakie`, `:GLMakie` or
  `:WGLMakie`), or `nothing`; kept on regeneration. Loading a backend activates it,
  so leave this `nothing` to choose the backend in the REPL instead
"""
function write_demo(
    dir::AbstractString = demo_dir();
    scale = 3,
    note = "",
    data = "1.0 2.0 NaN 4.0",
    grid = "[0.1, 0.5, 1.0]",
    discount = "x",
    shifts = "(low = 1, high = 2)",
    makie = makie_backend(dir),
)
    mkpath(joinpath(dir, "data"))
    write(joinpath(dir, "data", "raw.csv"), data)
    write(
        joinpath(dir, "analysis.jl"),
        """
        $note
        const SCALE = $scale

        struct Params
            alpha::Float64
        end

        clean(xs) = filter(!isnan, xs)

        adjust(x) = $discount
        weight(p::Params, x) = p.alpha * adjust(x) * SCALE
        score(p::Params, xs) = sum(weight(p, x) for x in xs)

        summarize(scores) = (n = length(scores), total = round(sum(scores); digits = 3))
        """,
    )
    write(
        joinpath(dir, "_targets.jl"),
        """
        using Targets
        $(makie_line(makie))Base.include(@__MODULE__, joinpath(@__DIR__, "analysis.jl"))

        base = @pipeline begin
            @target raw_file = "data/raw.csv"  format = :file
            @target raw      = parse.(Float64, split(read(raw_file, String)))
            @target cleaned  = clean(raw)
            @target grid     = $grid
            @target scores   = score(Params(grid), cleaned)  pattern = grid
            @target report   = summarize(scores)
        end

        # Static branching: two targets per named shift (`shifted_low`, `shift_summary_low`, ...).
        # `shift_summary` depends on `shifted` from its own branch; one target combines them.
        static = tar_map($shifts) do k
            (
                target(:shifted, cleaned -> cleaned .+ k),
                target(:shift_summary, shifted -> summarize(shifted)),
            )
        end

        combined = tar_combine(
        	:shifted_total,
        	(xs...) -> sum(x.total for x in xs),
        	static.shift_summary
        )

        tar_pipeline(base.targets, static, combined)
        """,
    )
    return dir
end

"""
    demo_setup(dir = demo_dir(); makie = nothing)

Write the demo project and give it its own environment with this repository's
Targets developed into it, plus CairoMakie, GLMakie and WGLMakie, ready to
`activate` and `tar_make()`. `makie` is passed to [`write_demo`](@ref).
"""
function demo_setup(dir::AbstractString = demo_dir(); makie = nothing)
    write_demo(dir; makie)
    setup_environment(dir, [string.(MAKIE_BACKENDS)...])
    println("Demo project ready in ", dir)
    println("  cd(\"", relpath(dir), "\"); then start julia with --project=. and run:")
    println("  using Targets")
    println("  tar_make()")
    print_plotting_help()
    return dir
end

"""
    setup_environment(dir, packages)

Give `dir` its own environment with this repository's Targets developed into it,
plus `packages`.
"""
function setup_environment(dir::AbstractString, packages)
    previous = Base.active_project()
    try
        Pkg.activate(dir; io = devnull)
        # Always (re)resolve: the Manifest records Targets' dependencies and
        # extensions, which go stale whenever the package's Project.toml changes.
        isfile(joinpath(dir, "Manifest.toml")) ?
            Pkg.resolve() :
            Pkg.develop(; path = dirname(@__DIR__))
        Pkg.add(packages)
    finally
        previous === nothing ?
            Pkg.activate(; io = devnull) :
            Pkg.activate(previous; io = devnull)
    end
    return dir
end

demo_script(dir = demo_dir()) = joinpath(dir, "_targets.jl")

"Run `tar_make` on the demo project in `dir`, with the store inside it."
demo_make(dir = demo_dir(); io = stdout, kwargs...) = tar_make(;
    script = demo_script(dir),
    store = demo_store(dir),
    root = dir,
    io,
    kwargs...,
)

"What a build would do, without building."
demo_outdated(dir = demo_dir(); kwargs...) = tar_outdated(;
    script = demo_script(dir),
    store = demo_store(dir),
    root = dir,
    kwargs...,
)

"The demo's `Pipeline`, e.g. for `tar_dot`."
demo_pipeline(dir = demo_dir()) = Targets.load_pipeline(demo_script(dir))

"Remove the demo project and its store."
reset_demo(dir = demo_dir()) = rm(dir; recursive = true, force = true)

## Scripted walkthrough

function check(label, summary, expected_built)
    ok = sort(summary.built) == sort(expected_built)
    println(ok ? "  ✓ " : "  ✗ ", label, ": built ", summary.built)
    ok || println("      expected ", expected_built)
    return ok
end

"""
    walkthrough(dir = mktempdir())

Build, edit and rebuild the demo project, checking after each step that exactly the
expected targets were rebuilt. Returns `true` if every step matched.
"""
function walkthrough(dir = mktempdir())
    everything = [:raw_file, :raw, :cleaned, :grid, :scores, :report]
    shifted(names...) = [Symbol(p, n) for n in names for p in (:shifted_, :shift_summary_)]
    append!(everything, shifted(:low, :high), [:shifted_total])
    results = Bool[]
    run(label, expected; kw...) = push!(
        results,
        check(label, demo_make(dir; io = devnull), expected),
    )

    println("Walkthrough in ", dir)
    write_demo(dir)
    run("first build", everything)
    run("second build (nothing changed)", Symbol[])

    write_demo(dir; note = "# only a comment, and everything below it moves down a line")
    run("comment added", Symbol[])

    write_demo(dir; discount = "x + 0") # helper edited, same outputs
    run("helper edited, outputs unchanged (early cutoff)", [:scores])

    write_demo(dir; discount = "x + 0", scale = 4) # global edited, outputs change
    run("global edited", [:scores, :report])

    write_demo(dir; discount = "x + 0", scale = 4, grid = "[0.1, 0.5, 1.0, 2.0]")
    run("one element added to the pattern", [:grid, :scores, :report])

    write_demo(
        dir;
        discount = "x + 0",
        scale = 4,
        grid = "[0.1, 0.5, 1.0, 2.0]",
        shifts = "(low = 1, high = 3)",
    )
    run("static branch value changed", [shifted(:high)..., :shifted_total])

    write_demo(
        dir;
        discount = "x + 0",
        scale = 4,
        grid = "[0.1, 0.5, 1.0, 2.0]",
        shifts = "(low = 1, mid = 2, high = 3)",
    )
    run("static branch added", [shifted(:mid)..., :shifted_total])

    write_demo(
        dir;
        discount = "x + 0",
        scale = 4,
        grid = "[0.1, 0.5, 1.0, 2.0]",
        shifts = "(low = 1, mid = 2, high = 3)",
        data = "1.0 2.0 NaN 4.0 8.0",
    )
    run(
        "input file edited",
        [
            :raw_file,
            :raw,
            :cleaned,
            :scores,
            :report,
            shifted(:low, :mid, :high)...,
            :shifted_total,
        ],
    )

    touch(joinpath(dir, "data", "raw.csv"))
    run("input file touched, same bytes", Symbol[])

    println("Pending: ", demo_outdated(dir))
    println("Report: ", tar_read(:report; store = demo_store(dir)))
    ok = all(results)
    println(ok ? "All steps behaved." : "Some steps did not.")
    return ok
end

## A second project exercising what v0.2 added: seeds, concurrent jobs and slots,
## storage formats, pattern combinators, `tar_rep`, error modes, retries,
## workspaces, tracebacks and warnings, cues, progress events and executors.
## `features_walkthrough()` builds and edits it, checking each step:
##
##   julia --project=. -t 4 examples/demo.jl
##
## (URL targets need a server, so they are not part of it; see `format = :url`.)

features_dir() = joinpath(@__DIR__, ".demo-features")

"""
    write_features(dir = features_dir(); seed = 0, noise = 1.0, total = "sum(xs)",
                   fast_format = :jls, makie = makie_backend(dir))

Write the v0.2 feature project into `dir`. Each keyword changes one thing:

- `seed`: the pipeline seed (every `seed = :auto` target rebuilds, `:seed_changed`)
- `noise`: a `const` reached by the seeded `draws` target
- `total`: the body of a helper used by `cached_total`, whose cue ignores code edits
- `fast_format`: the storage format of `fast` (`:format_changed` when it changes)
- `makie`: a Makie backend for `_targets.jl` to load, or `nothing` (as in [`write_demo`](@ref));
  a backend loaded there is also loaded on `Distributed` workers

Targets fail while marker files exist: `fail_10` fails one branch of
`fragile_fits` (`error = :trim`), `fail_maybe` fails `maybe` (`error = :null`).
`flaky` fails on its first attempt in each fresh project and succeeds on retry.
"""
function write_features(
    dir::AbstractString = features_dir();
    seed = 0,
    noise = 1.0,
    total = "sum(xs)",
    fast_format = :jls,
    makie = makie_backend(dir),
)
    mkpath(dir)
    write(
        joinpath(dir, "features.jl"),
        """
        const NOISE = $noise

        simulate(mu) = mu + NOISE * randn()
        fragile(x) = isfile("fail_\$(round(Int, x))") ? error("element \$x failed") : 10x
        maybe_value() = isfile("fail_maybe") ? error("no value today") : 42
        total(xs) = $total

        # fails on the first attempt only (the attempt count lives in a file, not in code)
        function flaky()
            n = isfile("attempts") ? parse(Int, read("attempts", String)) : 0
            write("attempts", string(n + 1))
            n == 0 && error("flaky connection")
            return n + 1
        end

        function noisy_sum(xs)
            length(xs) < 5 && @warn "only \$(length(xs)) values"
            return sum(xs)
        end
        """,
    )
    write(
        joinpath(dir, "_targets.jl"),
        """
        using Targets
        $(makie_line(makie))Base.include(@__MODULE__, joinpath(@__DIR__, "features.jl"))

        tar_pipeline(
            target(:mus, () -> [0.0, 10.0, 20.0]),
            target(:sizes, () -> [1, 2]),
            # seeded branches: the same draws however and wherever they are built
            target(:draws, mus -> simulate(mus); pattern = :mus),
            # pattern combinators
            target(:combos, (mus, sizes) -> mus * sizes; pattern = Cross(:mus, :sizes)),
            target(:paired, (mus, sizes) -> (mus, sizes); pattern = Map(Head(:mus, 2), :sizes)),
            target(:sampled, mus -> mus; pattern = Sample(:mus, 2)),
            # batched replication: 2 branches of 5 reps
            tar_rep(:reps, () -> randn(); batches = 2, reps = 5),
            # error modes and retries
            target(:fragile_fits, mus -> fragile(mus); pattern = :mus, error = :trim),
            target(:maybe, () -> maybe_value(); error = :null),
            target(:uses_maybe, maybe -> maybe === nothing ? "no value" : "value \$maybe"),
            target(:flaky, () -> flaky(); retries = 2),
            # warnings are recorded
            target(:noisy, draws -> noisy_sum(draws)),
            # concurrency options
            target(:exclusive, () -> tar_slots(); slots = :all),
            target(:on_main, () -> "ran in the calling task"; deployment = :main),
            # cues and formats
            target(:cached_total, mus -> total(mus); cue = Cue(code = false)),
            target(:fast, () -> Dict(:a => [1, 2, 3]); format = :$fast_format);
            seed = $seed,
        )
        """,
    )
    return dir
end

"""
    features_setup(dir = features_dir(); makie = nothing)

Write the v0.2 feature project, with the marker files that make two targets
fail, and give it its own environment (Targets, CairoMakie, GLMakie, WGLMakie
and Distributed), ready to `activate` and `tar_make(; jobs = 4)`. `makie` is
passed to [`write_features`](@ref).
"""
function features_setup(dir::AbstractString = features_dir(); makie = nothing)
    write_features(dir; makie)
    touch(joinpath(dir, "fail_10"))
    touch(joinpath(dir, "fail_maybe"))
    setup_environment(dir, [string.(MAKIE_BACKENDS)..., "Distributed"])
    println("Feature project ready in ", dir)
    println("  cd(\"", relpath(dir), "\"); then start julia with --project=. -t 4 and run:")
    println("  using Targets")
    println("  tar_make(; jobs = 4)")
    print_plotting_help()
    return dir
end

# `noisy` warns on purpose; the warning is still recorded in its metadata (checked
# below), so keep it off the console.
features_make(dir; kwargs...) = with_logger(ConsoleLogger(stderr, Logging.Error)) do
    tar_make(;
        script = demo_script(dir),
        store = demo_store(dir),
        root = dir,
        io = devnull,
        kwargs...,
    )
end

features_outdated(dir) = tar_outdated(;
    script = demo_script(dir),
    store = demo_store(dir),
    root = dir,
)

"""
    features_walkthrough(dir = mktempdir(); distributed = false)

Build and edit the v0.2 feature project, checking each step. With
`distributed = true`, also build it on two `Distributed` workers. Returns `true`
if every check passed.
"""
function features_walkthrough(dir = mktempdir(); distributed = false)
    results = Bool[]
    function ok(label, cond, detail = "")
        println(
            cond ? "  \u2713 " : "  \u2717 ",
            label,
            (cond || isempty(detail)) ? "" : ": " * detail, # details only on failure
        )
        push!(results, cond)
        return cond
    end
    store = demo_store(dir)
    read_target(name) = tar_read(name; store, on_outdated = :ignore)

    println("Feature walkthrough in ", dir, " (", Threads.nthreads(), " threads)")
    write_features(dir)
    touch(joinpath(dir, "fail_10"))
    touch(joinpath(dir, "fail_maybe"))

    # 1. a concurrent first build, with failures handled by error modes and retries
    s = features_make(dir; jobs = 4)
    ok(
        "concurrent build finished despite failures",
        s.errored == [:maybe],
        "errored $(s.errored)",
    )
    ok(":null gives consumers nothing", read_target(:uses_maybe) == "no value")
    ok(
        ":trim drops the failed branch",
        read_target(:fragile_fits) == [0.0, 200.0],
        "got $(read_target(:fragile_fits))",
    )
    ok("retries recovered the flaky target", read_target(:flaky) == 2)
    ok("slots = :all got every slot", read_target(:exclusive) == 4)
    ok(
        "Cross builds every combination",
        read_target(:combos) == [0.0, 0.0, 10.0, 20.0, 20.0, 40.0],
    )
    ok("Map(Head(...), ...) pairs elements", read_target(:paired) == [(0.0, 1), (10.0, 2)])
    ok("Sample picks two", length(read_target(:sampled)) == 2)
    ok("tar_rep gathers batches x reps", length(read_target(:reps)) == 10)
    ok(":jls objects are stored", isfile(joinpath(store, "objects", "fast.jls")))

    # 2. debugging the failure
    ok("tar_errored lists the failures", "maybe" in [r.name for r in tar_errored(; store)])
    ok("a workspace was saved", tar_workspace(:maybe; store) == NamedTuple())
    rerun = try
        tar_rerun(Targets.load_pipeline(demo_script(dir)), :maybe; store, root = dir)
    catch e
        sprint(showerror, e)
    end
    ok("tar_rerun reproduces the error", rerun == "no value today", "got $(repr(rerun))")
    ok(
        "the traceback starts in user code",
        any(f -> occursin("maybe_value", f), tar_traceback(:maybe; store)),
    )
    noisy = Targets.read_meta(Targets.open_store(store), :noisy)
    ok("warnings are recorded", noisy.warnings == ["only 3 values"])

    # 3. fixing the inputs rebuilds the failed parts only
    rm(joinpath(dir, "fail_10"))
    rm(joinpath(dir, "fail_maybe"))
    s = features_make(dir; jobs = 2)
    ok(
        "fixed targets rebuilt",
        sort(s.built) == sort([:fragile_fits, :maybe, :uses_maybe]),
        "built $(s.built)",
    )
    ok("the trimmed branch is back", read_target(:fragile_fits) == [0.0, 100.0, 200.0])
    ok("nothing left to do", isempty(features_outdated(dir)))

    # 4. seeds: a one-job build elsewhere gives the same random values
    other = mktempdir()
    write_features(other)
    features_make(other; jobs = 1)
    same(name) = tar_read(name; store = demo_store(other), on_outdated = :ignore) ==
        read_target(name)
    ok("seeded draws match across builds", same(:draws) && same(:reps))
    write_features(dir; seed = 1)
    reasons = Dict(r.name => r.reason for r in features_outdated(dir))
    ok(
        "a new pipeline seed is :seed_changed",
        get(reasons, :mus, nothing) == :seed_changed,
        "got $reasons",
    )
    s = features_make(dir; jobs = 4)
    ok("seeded targets rebuilt", :draws in s.built && :reps in s.built, "built $(s.built)")

    # 5. cues and formats
    write_features(dir; seed = 1, total = "sum(xs) + 0")
    ok("Cue(code = false) ignores a helper edit", isempty(features_make(dir).built))
    write_features(dir; seed = 1, total = "sum(xs) + 0", fast_format = :jld2)
    reasons = Dict(r.name => r.reason for r in features_outdated(dir))
    ok(
        "changing a format is :format_changed",
        get(reasons, :fast, nothing) == :format_changed,
    )
    ok("only that target rebuilds", features_make(dir).built == [:fast])

    # 6. progress events of the last run
    progress = tar_progress(; store)
    ok(
        "tar_progress reports the last run",
        any(r -> r.key == "fast" && r.status == :built, progress),
    )

    # 7. check_mutation catches a target that modifies its input
    p = tar_pipeline(target(:xs, () -> [1, 2]), target(:bad, xs -> push!(xs, 3)))
    caught = try
        tar_make(
            p;
            store = joinpath(dir, "mutation"),
            root = dir,
            io = devnull,
            check_mutation = true,
        )
        false
    catch e
        occursin("mutated its argument", sprint(showerror, e))
    end
    ok("check_mutation caught the mutation", caught)

    # 8. optionally, the same project on worker processes
    if distributed
        Dist = Base.require(Base.PkgId(
            Base.UUID("8ba89e20-285c-5b6f-9357-94700520ee1b"),
            "Distributed",
        ))
        pids = Base.invokelatest(
            Dist.addprocs,
            2;
            exeflags = "--project=$(Base.active_project())",
        )
        try
            remote = mktempdir()
            write_features(remote)
            exec = Base.invokelatest(
                DistributedExecutor,
                pids;
                script = demo_script(remote),
            )
            features_make(remote; executor = exec)
            r(name) = tar_read(name; store = demo_store(remote), on_outdated = :ignore)
            ok(
                "workers give the same seeded draws",
                r(:draws) ==
                    tar_read(:draws; store = demo_store(other), on_outdated = :ignore),
            )
        finally
            Base.invokelatest(Dist.rmprocs, pids)
        end
    end

    all_ok = all(results)
    println(all_ok ? "All feature checks passed." : "Some feature checks failed.")
    return all_ok
end

if abspath(PROGRAM_FILE) == @__FILE__
    walkthrough() || exit(1)
    features_walkthrough(; distributed = "--distributed" in ARGS) || exit(1)
end

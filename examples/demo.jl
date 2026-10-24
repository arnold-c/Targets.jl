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
#   julia> using Targets
#   julia> tar_make()                 # builds; run it again to see "up to date"
#   julia> tar_outdated()
#   julia> tar_read(:report)
#   julia> print(tar_dot())
#
# To try an edit, regenerate the files with one change (from that same REPL):
#
#   julia> include("../demo.jl")
#   julia> write_demo(; scale = 4)    # a global that `score` reaches
#   julia> tar_outdated()             # what would rebuild, and why
#   julia> tar_make()
#
# Other knobs of `write_demo`: note (comment only), data (input file), grid (branching),
# discount (a helper two calls deep), shifts (static branching). `walkthrough()` runs a fixed sequence of edits in a
# temporary directory and checks each step rebuilds exactly what it should:
#
#   julia --project=. examples/demo.jl

# Use the repository's Targets when no environment provides one (e.g. a fresh `julia`).
using Pkg
if Base.identify_package("Targets") === nothing
    Pkg.activate(; temp = true, io = devnull)
    Pkg.develop(; path = dirname(@__DIR__), io = devnull)
end
using Targets

demo_dir() = joinpath(@__DIR__, ".demo")
demo_store(dir = demo_dir()) = joinpath(dir, "_targets")

"""
    write_demo(dir; scale = 3, note = "", data = "1.0 2.0 NaN 4.0", grid = "[0.1, 0.5, 1.0]",
               discount = "x", shifts = "(1, 2)")

Write the demo project into `dir`. Each keyword changes one thing:

- `scale`: a `const` in `analysis.jl` that `score` reaches (code edit, changes outputs)
- `note`: a comment line (formatting-only edit: must rebuild nothing)
- `data`: contents of the input file `data/raw.csv`
- `grid`: the pattern target's elements (branching)
- `discount`: an expression inside a helper two calls deep from the `scores` target
- `shifts`: the values that generate one `shifted_<k>` target each (static branching),
  combined by `shifted_total`
"""
function write_demo(
    dir::AbstractString = demo_dir();
    scale = 3,
    note = "",
    data = "1.0 2.0 NaN 4.0",
    grid = "[0.1, 0.5, 1.0]",
    discount = "x",
    shifts = "(1, 2)",
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
        Base.include(@__MODULE__, joinpath(@__DIR__, "analysis.jl"))

        base = @pipeline begin
            @target raw_file = "data/raw.csv"  format = :file
            @target raw      = parse.(Float64, split(read(raw_file, String)))
            @target cleaned  = clean(raw)
            @target grid     = $grid
            @target scores   = score(Params(grid), cleaned)  pattern = grid
            @target report   = summarize(scores)
        end

        # Static branching: plain Julia generates one target per value; one target combines them.
        static = [target(Symbol(:shifted_, k), cleaned -> sum(cleaned) + k) for k in $shifts]
        combined = target(:shifted_total, (xs...) -> sum(xs); deps = [t.name for t in static])

        tar_pipeline(base.targets, static, combined)
        """,
    )
    return dir
end

"""
    demo_setup(dir = demo_dir())

Write the demo project and give it its own environment with this repository's
Targets developed into it, ready to `activate` and `tar_make()`.
"""
function demo_setup(dir::AbstractString = demo_dir())
    write_demo(dir)
    # Always (re)resolve: the Manifest records Targets' dependencies and extensions,
    # which go stale whenever the package's Project.toml changes.
    let
        previous = Base.active_project()
        try
            Pkg.activate(dir; io = devnull)
            isfile(joinpath(dir, "Manifest.toml")) ?
                Pkg.resolve() :
                Pkg.develop(; path = dirname(@__DIR__))
            Pkg.add("CairoMakie")
        finally
            previous === nothing ?
                Pkg.activate(; io = devnull) :
                Pkg.activate(previous; io = devnull)
        end
    end
    println("Demo project ready in ", dir)
    println(
        "  cd(\"",
        relpath(dir),
        "\"); then start julia with --project=. and run tar_make()",
    )
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
    append!(everything, [:shifted_1, :shifted_2, :shifted_total])
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
        shifts = "(1, 3)",
    )
    run("static branch value changed", [:shifted_3, :shifted_total])

    write_demo(
        dir;
        discount = "x + 0",
        scale = 4,
        grid = "[0.1, 0.5, 1.0, 2.0]",
        shifts = "(1, 3)",
        data = "1.0 2.0 NaN 4.0 8.0",
    )
    run(
        "input file edited",
        [:raw_file, :raw, :cleaned, :scores, :report, :shifted_1, :shifted_3, :shifted_total],
    )

    touch(joinpath(dir, "data", "raw.csv"))
    run("input file touched, same bytes", Symbol[])

    println("Pending: ", demo_outdated(dir))
    println("Report: ", tar_read(:report; store = demo_store(dir)))
    ok = all(results)
    println(ok ? "All steps behaved." : "Some steps did not.")
    return ok
end

if abspath(PROGRAM_FILE) == @__FILE__
    walkthrough() || exit(1)
end

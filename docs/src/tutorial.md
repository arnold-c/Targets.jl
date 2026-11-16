# Tutorial: an example workflow

This page walks through a small analysis from start to finish: a project with its own
functions, a pipeline, a first build, a look at the graph, a code change, new data that
breaks the build, and the tools for finding out why. Every output on this page was
produced by running the code shown, in order, when the documentation was built.

```@setup tutorial
using Markdown

# The documentation's environment; the tutorial's project uses the same packages.
const DOCS_PROJECT = Base.active_project()
const PROJECT = joinpath(tempdir(), "MyAnalysis")

rm(PROJECT; force = true, recursive = true)
mkpath(joinpath(PROJECT, "src"))
mkpath(joinpath(PROJECT, "data"))
let docs = dirname(DOCS_PROJECT), uuids = Base.parsed_toml(DOCS_PROJECT)["deps"]
    uuids["Statistics"] = "10745b16-79ce-11e8-11f9-7d13ad32a3b2"
    deps = ["CSV", "CairoMakie", "DataFrames", "Revise", "Statistics", "Targets"]
    write(
        joinpath(PROJECT, "Project.toml"),
        """
        name = "MyAnalysis"
        uuid = "4b6e2c1e-8f0a-4c56-9a3e-1d2b3c4d5e6f"

        [deps]
        """ * join(("$d = \"$(uuids[d])\"\n" for d in deps)),
    )
    # the same package versions as the documentation, with Targets from this repository
    manifest = read(joinpath(docs, "Manifest.toml"), String)
    write(
        joinpath(PROJECT, "Manifest.toml"),
        replace(manifest, "path = \"..\"" => "path = $(repr(dirname(docs)))"),
    )
end
Base.set_active_project(joinpath(PROJECT, "Project.toml"))

language(path) = Dict(".jl" => "julia", ".csv" => "csv")[last(splitext(path))]

"Write a file of the project and show it."
function show_file(path, content)
    write(joinpath(PROJECT, path), content)
    return Markdown.MD([Markdown.Code(language(path), rstrip(content))])
end

"""
Edit a file of the project and show the change as a diff. Revise picks up edits
to code before the next command, as it does at the REPL.
"""
function change_file(path, edits::Pair...)
    file = joinpath(PROJECT, path)
    old = read(file, String)
    new = foldl(edits; init = old) do text, (from, to)
        occursin(from, text) || error("`$from` is not in $path")
        replace(text, from => to)
    end
    write(file, new)
    if endswith(path, ".jl")
        sleep(1) # let Revise's file watcher see the edit
        Revise.revise()
    end
    return Markdown.MD([Markdown.Code("diff", diff_lines(old, new))])
end

"The lines that differ, with a line of context on each side."
function diff_lines(old, new)
    a, b = split(rstrip(old), '\n'), split(rstrip(new), '\n')
    n = min(length(a), length(b))
    head = 0 # lines the same at the start
    while head < n && a[head + 1] == b[head + 1]
        head += 1
    end
    tail = 0 # lines the same at the end, after those
    while tail < n - head && a[end - tail] == b[end - tail]
        tail += 1
    end
    lines = vcat(
        " " .* a[max(1, head):head],
        "-" .* a[(head + 1):(end - tail)],
        "+" .* b[(head + 1):(end - tail)],
        " " .* a[(end - tail + 1):min(end, end - tail + 1)],
    )
    return join(lines, '\n')
end
```

## 1. Create a project

A Targets project is an ordinary Julia project: its functions live in a package, and
`_targets.jl` at its root says which targets to build from them. Create one with Pkg (press
`]` at the REPL), and add the packages the analysis uses, Targets, a Makie backend for
plotting the pipeline and [Revise](https://timholy.github.io/Revise.jl/stable/) for editing
code without restarting Julia:

```julia-repl
pkg> generate MyAnalysis
pkg> activate MyAnalysis
pkg> add CSV DataFrames Statistics
pkg> add https://github.com/arnold-c/Targets.jl
pkg> add CairoMakie Revise
```

By the end of this section the project looks like this:

```
MyAnalysis/
├── Project.toml          # created by `generate`, lists the packages
├── src/MyAnalysis.jl     # the analysis code, a module
├── data/readings.csv     # the input data
└── _targets.jl           # the pipeline
```

### The code

The analysis code is a module in `src/MyAnalysis.jl`. Keeping functions in a package,
rather than in `_targets.jl`, means they are compiled once, can be tested and reused, and
can define types whose values Targets can store and load again. Replace the file that
`generate` created with:

```@eval tutorial
show_file("src/MyAnalysis.jl", raw"""
module MyAnalysis

using CSV, DataFrames, Statistics

export load_readings, clean_readings, station_summary, warming_trend

"Read the raw temperature readings."
load_readings(path) = CSV.read(path, DataFrame)

"Drop readings outside a plausible range: sensor errors."
clean_readings(readings) = filter(:temperature => t -> -50 <= t <= 60, readings)

"Mean, minimum and maximum temperature of each station."
station_summary(readings) = combine(
    groupby(readings, :station),
    :temperature => mean => :mean,
    :temperature => minimum => :min,
    :temperature => maximum => :max,
)

"How fast each station warms, in degrees per day."
warming_trend(readings) = combine(groupby(readings, :station)) do g
    (; per_day = slope(g.day, g.temperature))
end

slope(x, y) = sum((x .- mean(x)) .* (y .- mean(y))) / sum((x .- mean(x)) .^ 2)

end
""")
```

### The data

Daily temperatures from three weather stations, in `data/readings.csv`. One reading is a
sensor error:

```@eval tutorial
show_file("data/readings.csv", """
station,day,temperature
A,1,12.1
A,2,12.8
A,3,13.0
A,4,13.6
B,1,8.4
B,2,999.0
B,3,9.1
B,4,9.0
C,1,15.2
C,2,15.0
C,3,15.9
C,4,16.3
""")
```

### The pipeline

`_targets.jl` loads the code and declares the targets. Each `@target` names a result and
the expression that computes it; the targets an expression mentions are its dependencies.
`raw_file` is a *file target*: its value is the path, and Targets watches the file's
contents, so editing the data rebuilds everything that reads it.

```@eval tutorial
show_file("_targets.jl", raw"""
using Targets
using MyAnalysis

@pipeline begin
    @target raw_file  = "data/readings.csv"  format = :file
    @target readings  = load_readings(raw_file)
    @target cleaned   = clean_readings(readings)
    @target summaries = station_summary(cleaned)
    @target trends    = warming_trend(cleaned)
end
""")
```

## 2. Build the pipeline

```@setup tutorial
# load the project's code once, quietly, so that its precompilation does not show below
using Revise
using MyAnalysis
```

Start Julia in the project (`julia --project=MyAnalysis`, or `activate MyAnalysis` as
above). Load Revise first, so that it tracks the edits you make to `MyAnalysis` later, then
build:

```@repl tutorial
using Revise
using Targets, CairoMakie, DataFrames
using MyAnalysis
tar_make()
```

`tar_make` loads `_targets.jl`, works out which targets are outdated, and builds them in
dependency order. Each target's line says why it was built: `missing`, because nothing has
been stored yet. The results go to the store, `_targets/` in the project. (In a terminal,
the targets still running are shown in a live footer instead of the `▶` lines.)

Nothing has changed, so a second build does nothing:

```@repl tutorial
tar_make()
```

Read a stored value with [`tar_read`](@ref):

```@example tutorial
tar_read(:summaries)
```

[`@tar_load`](@ref) does the same, and assigns it to a variable of the same name:

```@example tutorial
@tar_load trends
trends
```

[`tar_meta`](@ref) shows what the store recorded about each target, such as when it was
built and how long it took:

```@example tutorial
select(DataFrame(tar_meta()), :name, :format, :seconds, :built_at)
```

## 3. Look at the pipeline

[`tar_visnetwork`](@ref) draws the pipeline, coloured by status. With CairoMakie it is a
static figure; with GLMakie or WGLMakie you can drag targets around, zoom, and hide parts of
the graph.

```@example tutorial
tar_visnetwork()
```

The square is the file target, and green means up to date. [`tar_status`](@ref) gives the
same information as text, grouped by kind of target:

```@repl tutorial
tar_status()
```

## 4. Change the code

Report each station's standard deviation too. Edit `station_summary` in
`src/MyAnalysis.jl`:

```@eval tutorial
change_file(
    "src/MyAnalysis.jl",
    "    :temperature => maximum => :max,\n" =>
        "    :temperature => maximum => :max,\n    :temperature => std => :sd,\n",
)
```

Revise loads the new definition when you press enter at the REPL. Before building, check
what the change affects. [`tar_outdated`](@ref) lists the targets a build would run, with
the reason for each:

```@repl tutorial
tar_outdated()
```

Only `summaries` calls `station_summary`, so it is the only target whose code changed.
`trends` does not use it, so it stays up to date. `tar_status` shows the same, alongside
the targets that are up to date:

```@repl tutorial
tar_status()
```

and in the graph, `summaries` is now light orange, for outdated:

```@example tutorial
tar_visnetwork()
```

Build, and only `summaries` runs:

```@repl tutorial
tar_make()
```

```@example tutorial
tar_read(:summaries)
```

## 5. New data breaks the build

The next day, new readings arrive. Station C's sensor sent nothing, so its temperature is
empty:

```@eval tutorial
change_file("data/readings.csv", "C,4,16.3\n" => "C,4,16.3\nA,5,14.1\nB,5,9.6\nC,5,\n")
```

The data file changed, so every target that depends on it is outdated:

```@repl tutorial
tar_outdated()
```

Build again:

```@repl tutorial
tar_make()
```

`cleaned` failed, so the build stopped and rethrew its error. `summaries` and `trends`
were not run: they keep their previous values, and are rebuilt once `cleaned` succeeds.

## 6. Find out what went wrong

The status shows the failed target, and that everything downstream of it is outdated. In
the graph, the failed target is dark orange:

```@repl tutorial
tar_status()
```

```@example tutorial
tar_visnetwork()
```

[`tar_errored`](@ref) lists every target whose last build failed, with its error:

```@example tutorial
DataFrame(tar_errored())
```

[`tar_traceback`](@ref) gives the stack frames of the failure, innermost first, without
Targets' own frames. The first frame is the anonymous function in `clean_readings`, which
was called with `missing`; the frames in between are DataFrames' `filter`; and the last
frame is the `@target` line in `_targets.jl` that called `clean_readings`:

```@repl tutorial
foreach(println, tar_traceback(:cleaned))
```

When a target fails, Targets saves the arguments it was called with. [`tar_workspace`](@ref)
returns them as a `NamedTuple`, so you can look at exactly what the target received:

```@example tutorial
ws = tar_workspace(:cleaned)
ws.readings
```

[`@tar_workspace`](@ref) assigns each argument to a variable of the same name instead,
ready for experimenting at the REPL (here, `readings`):

```@repl tutorial
@tar_workspace cleaned;
```

```@example tutorial
filter(:temperature => ismissing, readings)
```

So the new row for station C has a `missing` temperature, and the comparison
`-50 <= t <= 60` cannot decide whether `missing` is in range. [`tar_rerun`](@ref) calls the
target's current function on the saved arguments, with the same seed, in your session, to
reproduce the error; wrap it in Infiltrator.jl's `@exfiltrate` or Debugger.jl's `@enter` to
step through it:

```@repl tutorial
tar_rerun(:cleaned)
```

## 7. Fix it and rebuild

Missing readings are not plausible readings either, so `clean_readings` should drop them:

```@eval tutorial
change_file(
    "src/MyAnalysis.jl",
    "t -> -50 <= t <= 60" => "t -> !ismissing(t) && -50 <= t <= 60",
)
```

Check the fix on the saved arguments before building:

```@example tutorial
clean_readings(readings)
```

Then build. Only what failed, and what depends on it, runs: `readings` was already rebuilt
from the new data before `cleaned` failed.

```@repl tutorial
tar_make()
```

Everything is up to date again:

```@example tutorial
tar_visnetwork()
```

```@example tutorial
tar_read(:summaries)
```

```@setup tutorial
Base.set_active_project(DOCS_PROJECT)
```

## Where next

- [Declaring pipelines](guide/pipelines.md): more ways to declare targets, fragments and
  static branching.
- [Branching](guide/branching.md): one target per element of a collection, such as one fit
  per station.
- [Running builds](guide/builds.md): building some targets, error modes, retries and seeds.
- [What triggers a rebuild](guide/rebuilds.md): exactly what counts as a change.
- [Inspecting a pipeline](guide/inspecting.md): the rest of the helpers.

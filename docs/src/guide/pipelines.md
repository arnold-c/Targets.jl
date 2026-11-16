# Declaring pipelines

A pipeline is a set of targets and the dependencies between them. It lives in
`_targets.jl` at the project root, whose last expression returns it. `tar_make()`,
`tar_read` and the other functions load that file into a fresh module each time, so nothing
leaks in from your session.

Each target name can be declared only once in a pipeline. Declaring a name twice, in the
same block, in two fragments, or through names that `@map`, `tar_map` or `@rep` generate,
is an error that gives the line of each declaration.

!!! tip "Where to keep code"
    Put functions and types in a **named module or package** (for example
    `src/MyAnalysis.jl`, loaded with `using MyAnalysis`), and keep `_targets.jl` to
    target declarations. Values are stored with JLD2, which records types by module path,
    so types defined inside `_targets.jl` cannot be loaded later.

## The macro form

`@pipeline` takes a block of `@target name = expression` lines:

```julia
@pipeline begin
    @target raw     = load_raw("data.csv")
    @target cleaned = clean(raw)
    @target model   = fit_model(cleaned)
    @target summary = summarize(model)
end
```

A target's dependencies are the targets its expression refers to:

- Names the expression binds itself (comprehension variables, lambda arguments, `let` and
  `do` bindings) are not dependencies.
- A name that is neither a target nor defined where the pipeline is written is an error
  that names its line.
- A target's own name means what it means outside the pipeline, so
  `@target summary = summary(fits)` calls the function `summary`. Calling a function that
  has the same name as *another* target is an error, since that name means the target.

Options follow the expression: `@target model = fit_model(cleaned)  cue = :always`. They are
the keyword arguments of [`target`](@ref): `format`, `pattern`, `cue`, `seed`, `slots`,
`deployment`, `error`, `retries` and `retry_delay`. `@pipeline` itself takes `seed` and `track` before its
block: `@pipeline seed = 2026 begin ... end`.

A block may also assign variables that its targets share, and splice in fragments or
`target()`s:

```julia
@pipeline begin
    directory = "output"
    @target figure = save_figure(model, joinpath(directory, "fit.png"))  format = :file
    extra_targets()                       # a function returning a fragment
end
```

## The function form

[`target`](@ref) declares one target and [`tar_pipeline`](@ref) collects them:

```julia
tar_pipeline(
    target(:raw, () -> load_raw("data.csv")),
    target(:cleaned, raw -> clean(raw)),
    target(:model, cleaned -> fit_model(cleaned)),
    target(:summary, model -> summarize(model)),
)
```

A target's dependencies are the argument names of its function, which must therefore have
exactly one method, with positional arguments. Otherwise pass them explicitly with
`deps = [...]`; the values are then passed positionally in that order. Argument names
starting with `_` are reserved. `tar_pipeline` accepts targets and (nested) collections of
them, so the targets can be built in separate statements or vectors:

```julia
loading = [
    target(:raw, () -> load_raw("data.csv")),
    target(:cleaned, raw -> clean(raw)),
]
modelling = [
    target(:model, cleaned -> fit_model(cleaned)),
    target(:summary, model -> summarize(model)),
]
tar_pipeline(loading, modelling; seed = 2026)
```

## Fragments

[`@targets`](@ref) declares part of a pipeline as a [`Fragment`](@ref), so each analysis
can live in its own file or be returned by a function. Names are resolved when
`tar_pipeline` (or `@pipeline`) puts the fragments together, so fragments can refer to each
other's targets:

```julia
# loading.jl
loading = @targets begin
    @target raw     = load_raw("data.csv")
    @target cleaned = clean(raw)
end

# _targets.jl
include("loading.jl")
modelling = @targets begin
    @target model = fit_model(cleaned)      # `cleaned` comes from the other fragment
end
tar_pipeline(loading, modelling)
```

Variables assigned in a block (`directory = "output"`) are visible only in that block.

## Static branching

Static branching declares the same targets once per value of a list written in the script.
Inside a block, [`@map`](@ref) does this:

```julia
@pipeline begin
    @target data = load_data()
    @map((ols = OLS(), lasso = Lasso(0.1))) do model
        @target fit     = fit_model(model, data)   # fit_ols, fit_lasso
        @target summary = summarize(fit)           # summary_ols uses fit_ols, ...
    end
    @target all_summaries = collect(summary)       # summary is (ols = ..., lasso = ...)
end
```

Within a branch, a name means that branch's target. Outside the `@map`, a template's name
means all of its targets, as a `NamedTuple` keyed by suffix. `@map`s nest, and with
`prefix = true` the suffix goes first (`real_fit` rather than `fit_real`).

In the function form, [`tar_map`](@ref) calls a template once per value and suffixes the
names of the targets it returns. Dependencies between targets of the same template get the
same suffix, so they can still be written as argument names. [`tar_combine`](@ref) collects
a group:

```julia
m = tar_map((ols = OLS(), lasso = Lasso(0.1))) do model
    (
        target(:fit, data -> fit_model(model, data)),    # fit_ols, fit_lasso
        target(:summary, fit -> summarize(fit)),         # summary_ols, summary_lasso
    )
end
tar_pipeline(
    target(:data, () -> load_data()),
    m,
    tar_combine(:all_summaries, (xs...) -> collect(xs), m.summary),
)
```

Suffixes are the keys of a `NamedTuple` or `Dict`; otherwise the values themselves when
they are symbols, strings, integers or tuples of those (`Iterators.product` crossings give
`fit_ols_1`); otherwise positions. Override them with `names = [...]` or
`names = v -> ...`.

A template name also works in every `names` keyword: `tar_make(names = [:fit])`,
`tar_invalidate(names = :fit)` and `tar_delete(names = :fit)` act on all of its targets,
while a generated name such as `:fit_ols` acts on that one alone.

## Replication

[`@rep`](@ref) (or [`tar_rep`](@ref)) evaluates an expression many times, in batches, each
replication with its own seed:

```julia
@pipeline begin
    @target priors = default_priors()
    @rep null = simulate_null(priors)  batches = 10  reps = 100
end
```

This declares `null_batch` (the batch numbers), `null_batches` (one branch per batch) and
`null`, the vector of all 1,000 replications in order, which is what consumers should use.
Results do not depend on how the work is batched. Inside a `@map`, `@rep` replicates per
value, as [`tar_map_rep`](@ref) does.

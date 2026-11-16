# Branching

Branching runs the same code once per element of a list. Targets.jl has two kinds, which
differ in when the list is known and in what the branches become.

- **Static branching** ([`@map`](@ref), [`tar_map`](@ref)): the list is written in the
  script, and each element becomes a normal, named target. See
  [Declaring pipelines](pipelines.md#Static-branching).
- **Dynamic branching** (`pattern = ...`): one target whose branches are created when the
  build runs, from the value of another target. That value can come from data, such as the
  files in a folder or the groups in a dataset.

The same three values, both ways:

```julia
score(data, alpha) = sum(data) * alpha

@pipeline begin
    @target data = [1, 2, 3]

    # static: three targets written into the pipeline
    @map((low = 0.1, mid = 0.5, high = 1.0)) do alpha
        @target fit = score(data, alpha)
    end
    @target best_static = maximum(fit)

    # dynamic: one target, one branch per element of `alphas`, decided when built
    @target alphas = [0.1, 0.5, 1.0]
    @target fits = score(data, alphas)  pattern = alphas
    @target best_dynamic = maximum(fits)
end
```

| | Static | Dynamic |
| --- | --- | --- |
| Targets in the pipeline | `fit_low`, `fit_mid`, `fit_high` | `fits` |
| What is stored | one record per target | `fits` and its branches `fits/3931e98c`, `fits/4ba9361b`, `fits/935915f8` |
| When the list is known | when the script is loaded | when the build runs |
| Reading | `tar_read(:fit_mid)` is `3.0` | `tar_read(:fits)` is `[0.6, 3.0, 6.0]` |
| Downstream code receives | a `NamedTuple` (macro form), or arguments through [`tar_combine`](@ref) | a `Vector` |
| Adding `2.0` to the list rebuilds | `fit_max` and `best_static` | `alphas`, one new branch of `fits`, and `best_dynamic` |
| Per-element flexibility | each element can declare several targets, with their own options | every branch runs the same code |
| Graph views | one node per element | one node |

Use static branching when the list is a fixed setting of your analysis and you want each
result as a named target. Use dynamic branching when the list is itself a result, or is
long.

## Dynamic branching

`pattern = name` runs the target once per element of the target `name`'s vector. Inside the
expression (or as the function's argument), the pattern's name means *one* element; every
other dependency is passed whole to each branch:

```julia
@target fits = fit_model(clean_data, grid)  pattern = grid        # macro form
target(:fits, (clean_data, grid) -> fit_model(clean_data, grid); pattern = :grid)
```

A target that is not itself branching receives the vector of branch values, in pattern
order. Branching over a branching target, `pattern = fits`, gives one branch per upstream
branch, so a change to one element rebuilds exactly one chain of branches.

### Branch names

Branches have no readable names: each is stored under its target with the first 8
hexadecimal characters of a hash of its element, such as `fits/3931e98c`. Because the name
comes from the value rather than the position, inserting, removing or reordering elements
leaves the other branches alone. Only branches for new or changed elements run, and the
records of branches that are no longer in the pattern are deleted. Names are extended to
16 characters when two collide, and repeated elements are told apart automatically.

`tar_read(:fits)` returns a plain vector in pattern order, with no labels, so return the
inputs alongside the result when you need to know which entry is which.

## Several parameters

Patterns combine several targets:

| Macro form | Function form | Branches |
| --- | --- | --- |
| `pattern = cross(a, b)` | `pattern = Cross(:a, :b)` | every combination, the last part varying fastest |
| `pattern = map(a, b)` | `pattern = Map(:a, :b)` | element `i` of each, in step (equal lengths) |
| `pattern = head(a, n)` | `pattern = Head(:a, n)` | the first `n` |
| `pattern = slice(a, [1, 3])` | `pattern = Slice(:a, [1, 3])` | those positions |
| `pattern = sample(a, n)` | `pattern = Sample(:a, n)` | `n` drawn at random, with the target's seed |

They nest, as in `cross(alphas, map(betas, gammas))`. Inside a branch, each pattern
target's name means one element:

```julia
@pipeline begin
    @target alphas = [0.1, 0.5]
    @target betas  = [1, 2]

    # (0.1, 1), (0.1, 2), (0.5, 1), (0.5, 2)
    @target every_pair = (alpha = alphas, beta = betas, value = score(alphas, betas))  pattern = cross(alphas, betas)

    # (0.1, 1), (0.5, 2)
    @target in_step = (alpha = alphas, beta = betas, value = score(alphas, betas))  pattern = map(alphas, betas)

    # or build the combinations yourself and branch over one target
    @target grid = [(alpha = a, beta = b) for a in alphas for b in betas]
    @target over_grid = (grid..., value = score(grid.alpha, grid.beta))  pattern = grid
end
```

A branch that combines several elements is named by a hash of their hashes, in pattern
order, so the same combination has the same name in every target that uses it: above,
`every_pair` and `in_step` both store `(0.1, 1)` as `f73276cf`. Adding `3` to `betas`
runs two new branches of `every_pair`, for `(0.1, 3)` and `(0.5, 3)`, and reuses the other
four.

!!! warning
    The parts of a `map` pattern must have equal lengths. When they do not, the build stops
    while it is being planned, even with `keep_going = true`.

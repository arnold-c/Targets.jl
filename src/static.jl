"""
    tar_map(template, values; names = nothing)

Static branching: call `template(value)` for each element of `values` and give
every target it returns a suffix, so `:fit` becomes `:fit_ols`. A dependency (or
`pattern`) naming another target from the same template call is renamed with
the same suffix; any other dependency is left alone. `template` returns a
target or a collection of targets.

Returns a `NamedTuple` mapping each template name to its generated targets
(`m.fit == [fit_ols, fit_lasso]`); pass it to [`tar_pipeline`](@ref) and
combine a group with [`tar_combine`](@ref).

Suffixes come from `names` when given: a collection with one suffix per
element, or a function of the element. Otherwise, for each element:

- the key, when `values` is a `NamedTuple` or `AbstractDict`;
- the element itself, when it is a `Symbol`, string or integer, or a tuple of
  those (joined with `_`, for crossings from `Iterators.product`);
- its position (1, 2, ...) otherwise.

```julia
m = tar_map((ols = OLS(), lasso = Lasso(0.1))) do model
    (
        target(:fit, raw -> fit(model, raw)),          # fit_ols, fit_lasso
        target(:summary, fit -> summarize(fit)),       # depends on fit_ols / fit_lasso
    )
end
tar_pipeline(target(:raw, load), m, tar_combine(:all, (xs...) -> reduce(vcat, xs), m.summary))
```
"""
function tar_map(template, values; names = nothing)
    elements = map_elements(values)
    suffixes = map_suffixes(values, elements, names)
    branches = map(
        (v, s) -> suffix_branch(flatten_targets(template(v)), s),
        elements,
        suffixes,
    )
    return group_by_template(branches)
end

"""
    tar_combine(name, f, targets...; kwargs...)

A target that depends on every target in `targets` (which may be nested
collections, such as a group from [`tar_map`](@ref)) and passes their values to
`f` positionally, in order. Keyword arguments go to [`target`](@ref).
"""
tar_combine(name::Symbol, f, ts...; kwargs...) = target(
    name,
    f;
    deps = [t.name for t in flatten_targets(ts)],
    kwargs...,
)

map_elements(xs::Union{NamedTuple, AbstractDict}) = collect(Base.values(xs))
map_elements(xs) = vec(collect(xs))

function map_suffixes(values, elements, names)
    suffixes = string.(given_suffixes(values, elements, names))
    length(suffixes) == length(elements) ||
        throw(ArgumentError(
            "tar_map: `names` has $(length(suffixes)) suffixes for $(length(elements)) values",
        ))
    dup = findfirst(s -> count(==(s), suffixes) > 1, suffixes)
    dup === nothing ||
        throw(ArgumentError(
            "tar_map: suffix `$(suffixes[dup])` is used more than once; pass `names = ...`",
        ))
    return suffixes
end

given_suffixes(values, elements, names::Function) = map(names, elements)
given_suffixes(values, elements, names) = vec(collect(names))
given_suffixes(values::Union{NamedTuple, AbstractDict}, elements, ::Nothing) = collect(keys(
    values,
))
given_suffixes(values, elements, ::Nothing) = [
    default_suffix(v, i)
    for (i, v) in enumerate(elements)
]

const SimpleValue = Union{Symbol, AbstractString, Integer}
default_suffix(v::SimpleValue, i) = v
default_suffix(v::Tuple{Vararg{SimpleValue}}, i) = join(v, "_")
default_suffix(v, i) = i

function suffix_branch(ts::Vector{Target}, suffix::AbstractString)
    local_names = Set(t.name for t in ts)
    rename(n) = n in local_names ? branch_name(n, suffix) : n
    rename(::Nothing) = nothing
    return [
        t.name => Target(
            rename(t.name),
            t.f,
            rename.(t.deps),
            t.format,
            rename(t.pattern),
            t.cue,
            t.source,
        )
        for t in ts
    ]
end

function branch_name(name::Symbol, suffix::AbstractString)
    new = Symbol(name, :_, suffix)
    Base.isidentifier(new) ||
        throw(ArgumentError(
            "tar_map: suffix `$suffix` gives `$new`, which is not a valid target name; pass `names = ...`",
        ))
    return new
end

@testitem "tar_map suffixes: keys, simple values, positions or given names" begin
    using Targets
    names_for(values; kw...) = [
        t.name
        for t in tar_map(v -> target(:x, () -> v), values; kw...).x
    ]
    struct Spec
        alpha::Float64
    end
    @test names_for((:ols, :lasso)) == [:x_ols, :x_lasso]
    @test names_for([1, 3]) == [:x_1, :x_3]
    @test names_for((ols = Spec(1), lasso = Spec(2))) == [:x_ols, :x_lasso]
    @test names_for(Dict(:a => Spec(1))) == [:x_a]
    @test names_for(Iterators.product((:a, :b), (1, 2))) == [:x_a_1, :x_b_1, :x_a_2, :x_b_2]
    @test names_for([Spec(1), Spec(2)]) == [:x_1, :x_2]
    @test names_for([Spec(1), Spec(2)]; names = s -> Int(s.alpha * 10)) == [:x_10, :x_20]
    @test names_for([Spec(1), Spec(2)]; names = (:lo, :hi)) == [:x_lo, :x_hi]
end

@testitem "tar_map renames dependencies within a branch only" begin
    using Targets
    m = tar_map((:a, :b)) do k
        (
            target(:grid, () -> [1, 2]),
            target(:fit, (raw, grid) -> (k, raw, grid); pattern = :grid),
            target(:summary, fit -> fit),
        )
    end
    @test keys(m) == (:grid, :fit, :summary)
    @test [t.name for t in m.fit] == [:fit_a, :fit_b]
    @test m.fit[2].deps == [:raw, :grid_b]
    @test m.fit[2].pattern == :grid_b
    @test m.summary[1].deps == [:fit_a]
    all = tar_combine(:all, (xs...) -> xs, m.summary)
    @test all.deps == [:summary_a, :summary_b]
    p = tar_pipeline(target(:raw, () -> 1), m, all)
    @test p.order == [:raw, :grid_a, :grid_b, :fit_a, :fit_b, :summary_a, :summary_b, :all]
end

@testitem "tar_map errors name the problem and suggest `names`" begin
    using Targets
    make(values; kw...) = tar_map(v -> target(:x, () -> v), values; kw...)
    @test_throws "used more than once" make([1, 1])
    @test_throws "not a valid target name" make(["a b"])
    @test_throws "not a valid target name" make([-1])
    @test_throws "2 suffixes for 3 values" make(1:3; names = (:a, :b))
end

@testitem "tar_map: changing one value rebuilds only its branch" setup = [
    SourceFixtures,
] begin
    mktempdir() do dir
        code(lasso) = """
        m = tar_map((ols = 1, lasso = $lasso)) do w
            (target(:fit, raw -> raw * w), target(:summary, fit -> fit + 1))
        end
        p = tar_pipeline(target(:raw, () -> 10), m, tar_combine(:all, (xs...) -> sum(xs), m.summary))
        """
        @test build_source(code(2), dir).built ==
            [:raw, :fit_ols, :fit_lasso, :summary_ols, :summary_lasso, :all]
        @test read_values(dir, :all) == (32,)
        s = build_source(code(3), dir)
        @test s.built == [:fit_lasso, :summary_lasso, :all]
        @test read_values(dir, :all) == (42,)
    end
end

# `branches` holds `template name => generated target` pairs, one vector per value.
function group_by_template(branches)
    pairs = reduce(vcat, branches; init = Pair{Symbol, Target}[])
    bases = unique(first.(pairs))
    groups = map(b -> Target[last(p) for p in pairs if first(p) == b], bases)
    return NamedTuple{Tuple(bases)}(Tuple(groups))
end

## Branching patterns
##
## `pattern = :grid` maps over one target. Combinators build richer patterns:
## `Map(:a, :b)` pairs elements, `Cross(:a, :b)` takes all combinations, and
## `Head`, `Slice` and `Sample` select elements. They nest, as in
## `Cross(:a, Map(:b, :c))`.

"""
    Pattern

Supertype of branching pattern combinators: [`Map`](@ref), [`Cross`](@ref),
[`Head`](@ref), [`Slice`](@ref) and [`Sample`](@ref).
"""
abstract type Pattern end

const PatternPart = Union{Symbol, Pattern}

"One element of a pattern target: its branch id and identity hash."
struct PatternElement
    id::String
    hash::String
end

"""
    Map(a, b, ...)

Branch over the elements of `a`, `b`, ... in step: the `i`th branch receives the
`i`th element of each. All parts must have the same length.
"""
struct Map <: Pattern
    parts::Vector{PatternPart}
    Map(parts::PatternPart...) = new(PatternPart[parts...])
end

"""
    Cross(a, b, ...)

Branch over every combination of the elements of `a`, `b`, ... (the last part
varies fastest).
"""
struct Cross <: Pattern
    parts::Vector{PatternPart}
    Cross(parts::PatternPart...) = new(PatternPart[parts...])
end

"""
    Head(part, n)

Branch over the first `n` elements of `part`.
"""
struct Head <: Pattern
    part::PatternPart
    n::Int
end

"""
    Slice(part, indices)

Branch over the elements of `part` at `indices`.
"""
struct Slice <: Pattern
    part::PatternPart
    indices::Vector{Int}
    Slice(part::PatternPart, indices) = new(part, collect(Int, indices))
end

"""
    Sample(part, n)

Branch over `n` elements of `part` drawn at random (without replacement) using
the target's seed, so the same elements are drawn on every run.
"""
struct Sample <: Pattern
    part::PatternPart
    n::Int
end

Base.:(==)(a::T, b::T) where {T <: Pattern} = all(
    getfield(a, f) == getfield(b, f)
    for f in fieldnames(T)
)
Base.hash(p::Pattern, h::UInt) = hash(
    (typeof(p), (getfield(p, f) for f in fieldnames(typeof(p)))...),
    h,
)

"Target names a pattern branches over, in order of first appearance."
pattern_names(p::Symbol) = [p]
pattern_names(::Nothing) = Symbol[]
pattern_names(p::Union{Map, Cross}) = unique(reduce(
    vcat,
    map(pattern_names, p.parts);
    init = Symbol[],
))
pattern_names(p::Union{Head, Slice, Sample}) = pattern_names(p.part)

"The pattern with every target name replaced by `f(name)`."
map_names(f, p::Symbol) = f(p)
map_names(f, ::Nothing) = nothing
map_names(f, p::Map) = Map((map_names(f, x) for x in p.parts)...)
map_names(f, p::Cross) = Cross((map_names(f, x) for x in p.parts)...)
map_names(f, p::Head) = Head(map_names(f, p.part), p.n)
map_names(f, p::Slice) = Slice(map_names(f, p.part), p.indices)
map_names(f, p::Sample) = Sample(map_names(f, p.part), p.n)

"""
    Pick

One component of a branch: element `index` of the pattern target `name`, with
its branch id and identity hash.
"""
struct Pick
    name::Symbol
    index::Int
    element::PatternElement
end

"""
    Branch

One branch of a branching target: its id, identity hash, and the pattern
elements it combines.
"""
struct Branch
    id::String
    hash::String
    picks::Vector{Pick}
end

"""
    select_combinations(pattern, elements_of, seed)

The branches of `pattern` as vectors of [`Pick`](@ref)s, in pattern order.
`elements_of(name)` gives the elements of a pattern target, and `seed` drives
[`Sample`](@ref).
"""
select_combinations(p::Symbol, elements_of, seed) = [
    [Pick(p, i, el)]
    for (i, el) in enumerate(elements_of(p))
]
function select_combinations(p::Map, elements_of, seed)
    parts = [select_combinations(x, elements_of, seed) for x in p.parts]
    lengths = length.(parts)
    allequal(lengths) ||
        error(
            "the parts of a Map pattern must have equal lengths, got $(join(lengths, ", "))",
        )
    return [reduce(vcat, (part[i] for part in parts)) for i in 1:first(lengths)]
end
function select_combinations(p::Cross, elements_of, seed)
    combos = [Pick[]]
    for part in (select_combinations(x, elements_of, seed) for x in p.parts)
        combos = [vcat(c, x) for c in combos for x in part]
    end
    return combos
end
function select_combinations(p::Head, elements_of, seed)
    combos = select_combinations(p.part, elements_of, seed)
    return combos[1:min(p.n, length(combos))]
end
function select_combinations(p::Slice, elements_of, seed)
    combos = select_combinations(p.part, elements_of, seed)
    bad = filter(i -> !(1 <= i <= length(combos)), p.indices)
    isempty(bad) || error("Slice indices $(bad) are out of range 1:$(length(combos))")
    return combos[p.indices]
end
function select_combinations(p::Sample, elements_of, seed)
    combos = select_combinations(p.part, elements_of, seed)
    n = min(p.n, length(combos))
    rng = Random.Xoshiro(something(seed, UInt64(0)))
    return combos[sort!(Random.randperm(rng, length(combos))[1:n])]
end

@testitem "Cross builds exactly the new combinations when one side grows" setup = [
    SourceFixtures,
] begin
    code(bs) = """
    p = tar_pipeline(
        target(:a, () -> [1, 2]),
        target(:b, () -> $bs),
        target(:prod, (a, b) -> a * b; pattern = Cross(:a, :b)),
        target(:pairs, (a, b) -> a + b; pattern = Map(:a, :b)),
        target(:first2, b -> b; pattern = Head(:b, 2)),
        target(:some, b -> b; pattern = Sample(:b, 2)),
    )
    """
    mktempdir() do dir
        s = build_source(code("[10, 20]"), dir)
        @test length(s.branches[:prod]) == 4
        @test read_values(dir, :prod, :pairs, :first2) ==
            ([10, 20, 20, 40], [11, 22], [10, 20])
        picked = only(read_values(dir, :some))
        @test_throws "equal lengths" build_source(
            code("[10, 20, 30]"),
            dir;
            names = [:pairs],
        )
        s = build_source(code("[10, 20, 30]"), dir; names = [:prod, :first2])
        @test length(s.branches[:prod]) == 2 # (1, 30) and (2, 30) only
        @test only(read_values(dir, :prod)) == [10, 20, 30, 20, 40, 60]
        @test !haskey(s.branches, :first2) # still the first two
        again = mktempdir()
        build_source(code("[10, 20]"), again)
        @test only(read_values(again, :some)) == picked # Sample is seeded
    end
end

@testitem "macro patterns use R-style calls" begin
    p = @pipeline begin
        @target a = [1, 2]
        @target b = [3, 4]
        @target c = a * b pattern = cross(a, head(b, 1))
        @target d = a + b pattern = map(a, b)
    end
    @test p.targets[3].pattern == Cross(:a, Head(:b, 1))
    @test p.targets[4].pattern == Map(:a, :b)
    q = tar_pipeline(
        target(:a, () -> [1, 2]),
        target(:b, () -> [3, 4]),
        target(:c, (a, b) -> a * b; pattern = Cross(:a, Head(:b, 1))),
        target(:d, (a, b) -> a + b; pattern = Map(:a, :b)),
    )
    @test tar_manifest(p) == tar_manifest(q)
end

@testitem "pattern combinators select and combine elements" begin
    using Targets: select_combinations, PatternElement, pattern_names, map_names
    els = Dict(
        :a => [PatternElement("a$i", "ha$i") for i in 1:3],
        :b => [PatternElement("b$i", "hb$i") for i in 1:3],
        :c => [PatternElement("c$i", "hc$i") for i in 1:2],
    )
    ids(p) = [
        [x.element.id for x in combo]
        for combo in select_combinations(p, n -> els[n], UInt64(1))
    ]
    @test ids(:a) == [["a1"], ["a2"], ["a3"]]
    @test ids(Map(:a, :b)) == [["a1", "b1"], ["a2", "b2"], ["a3", "b3"]]
    @test ids(Cross(:a, :c)) ==
        [["a1", "c1"], ["a1", "c2"], ["a2", "c1"], ["a2", "c2"], ["a3", "c1"], ["a3", "c2"]]
    @test ids(Head(:a, 2)) == [["a1"], ["a2"]]
    @test ids(Slice(:a, [3, 1])) == [["a3"], ["a1"]]
    @test length(ids(Sample(Cross(:a, :b), 4))) == 4
    @test ids(Sample(:a, 2)) == ids(Sample(:a, 2))
    @test ids(Cross(:c, Map(:a, :b)))[1] == ["c1", "a1", "b1"]
    @test_throws "equal lengths" ids(Map(:a, :c))
    @test_throws "out of range" ids(Slice(:a, [4]))
    @test pattern_names(Cross(:c, Map(:a, :b), Head(:c, 1))) == [:c, :a, :b]
    @test map_names(n -> Symbol(n, :_x), Cross(:a, Head(:b, 1))) ==
        Cross(:a_x, Head(:b_x, 1))
end

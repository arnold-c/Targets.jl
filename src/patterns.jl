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

@testitem "property: pattern combinators follow their laws" setup = [Properties] begin
    using Targets: select_combinations, PatternElement, Pick, pattern_names, map_names

    # Nested patterns over the targets :a, :b and :c (Cross takes two parts at
    # most, so trees stay small).
    small = Data.Integers(0, 4)
    extend(p) = Data.OneOf(
        map(ps -> Map(ps...), Data.Vectors(p; min_size = 1, max_size = 3)),
        map(ps -> Cross(ps...), Data.Vectors(p; min_size = 1, max_size = 2)),
        map(Head, p, small),
        map(Slice, p, Data.Vectors(Data.Integers(1, 6); max_size = 4)),
        map(Sample, p, small),
    )
    patterns = Data.recursive(extend, Data.SampledFrom([:a, :b, :c]); max_layers = 3)

    leaves(p::Symbol) = [p]
    leaves(p::Union{Map, Cross}) = reduce(vcat, leaves.(p.parts))
    leaves(p::Union{Head, Slice, Sample}) = leaves(p.part)
    parts(::Symbol) = []
    parts(p::Union{Map, Cross}) = p.parts
    parts(p::Union{Head, Slice, Sample}) = [p.part]
    subpatterns(p) = [p; reduce(vcat, subpatterns.(parts(p)); init = [])]

    "How many branches `p` has given each target's length, or `nothing` if it is invalid."
    size_of(p::Symbol, n) = n[p]
    function size_of(p::Pattern, n)
        s = [size_of(x, n) for x in parts(p)]
        any(isnothing, s) && return nothing
        p isa Map && return allequal(s) ? first(s) : nothing
        p isa Cross && return prod(s)
        p isa Slice &&
            return all(i -> 1 <= i <= only(s), p.indices) ? length(p.indices) : nothing
        return min(only(s), p.n) # Head, Sample
    end

    "Whether `xs` is `ys` with some elements left out (in order)."
    function subsequence(xs, ys)
        j = 0
        for x in xs
            j = something(findnext(==(x), ys, j + 1), 0)
            j == 0 && return false
        end
        return true
    end

    throws(f) = try
        f()
        false
    catch e
        e isa ErrorException
    end

    "The laws of `p`'s own combinator, given how its parts select (`select`)."
    function node_lawful(p, select)
        combos = select(p)
        p isa Head && return combos == select(p.part)[1:min(p.n, end)]
        p isa Slice && return combos == select(p.part)[p.indices]
        # distinct elements of the part, in its order, the same each time
        p isa Sample && return subsequence(combos, select(p.part)) && combos == select(p)
        return true
    end

    report = @check config = check_config(;
        max_examples = 300,
    ) rng = property_rng() function patterns_follow_their_laws(
        p = patterns,
        q = patterns,
        r = patterns,
        sizes = Data.Vectors(Data.Integers(0, 3); min_size = 3, max_size = 3),
        seed = Data.Integers{UInt64}(),
    )
        n = Dict(zip((:a, :b, :c), sizes))
        elements(name) = [PatternElement("$name$i", "h$name$i") for i in 1:n[name]]
        select(x) = select_combinations(x, elements, seed)
        for x in subpatterns(p)
            expected = size_of(x, n)
            expected === nothing && (throws(() -> select(x)) ? continue : return false)
            combos = select(x)
            length(combos) == expected || return false
            for c in combos
                # one pick per leaf, each the element at its index
                [pick.name for pick in c] == leaves(x) || return false
                all(pick -> pick.element == elements(pick.name)[pick.index], c) ||
                    return false
            end
            node_lawful(x, select) || return false
        end
        # one part is the part itself, and nesting does not matter
        same(a, b) = (size_of(a, n) === nothing) ?
            throws(() -> select(b)) :
            select(a) == select(b)
        all((
            same(p, Map(p)),
            same(p, Cross(p)),
            same(Map(p, q, r), Map(Map(p, q), r)),
            same(Map(p, q, r), Map(p, Map(q, r))),
        )) ||
            return false
        if something(size_of(Cross(p, q, r), n), 0) <= 1000
            # products grow fast
            same(Cross(p, q, r), Cross(Cross(p, q), r)) || return false
            same(Cross(p, q, r), Cross(p, Cross(q, r))) || return false
        end
        # names are the leaves' in order, and renaming commutes with selecting
        pattern_names(p) == unique(leaves(p)) || return false
        renamed = map_names(x -> Symbol(x, :_x), p)
        map_names(x -> Symbol(chop(String(x); tail = 2)), renamed) == p || return false
        size_of(p, n) === nothing && return true
        unrenamed(name) = elements(Symbol(chop(String(name); tail = 2)))
        rename(x) = Pick(Symbol(x.name, :_x), x.index, x.element)
        return map(c -> map(rename, c), select(p)) ==
            select_combinations(renamed, unrenamed, seed)
    end
    @test check_result(report).holds
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

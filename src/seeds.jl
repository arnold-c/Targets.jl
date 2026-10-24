## Reproducible per-target random number seeds
##
## Every target (and every branch) runs with the default RNG seeded from the
## pipeline seed and the target's key, so its result does not depend on build
## order, subset builds or scheduling. The default RNG is task-local: the calling
## task's state is saved before seeding and restored afterwards, so the session's
## random stream is untouched and concurrent jobs (each in its own task) do not
## interfere.

const CURRENT_SEED = ScopedValue{Union{Nothing, UInt64}}(nothing)

"""
    target_seed(pipeline_seed, key)

The seed of the target or branch stored under `key` (`name` or `"name/id"`).
Branch ids come from element hashes, so a branch keeps its seed when the
pattern is reordered or extended.
"""
target_seed(pipeline_seed::Integer, key) = parse(
    UInt64,
    canonical_hash((:seed, Int(pipeline_seed), string(key)))[1:16];
    base = 16,
)

"The seed target `t` runs with under `key`, or `nothing` if it is not seeded."
function resolve_seed(p::Pipeline, t::Target, key = t.name)
    seed = t.seed
    seed === nothing && return nothing
    seed isa Int && return seed % UInt64
    return target_seed(p.seed, key) # :auto
end

"How a seed is recorded in metadata."
seed_string(seed::Union{Nothing, UInt64}) = seed === nothing ? "" : string(seed)

"""
    tar_seed()

The seed of the target that is currently running, as a `UInt64`, for creating
your own random stream, e.g. `StableRNG(tar_seed())` when results must be
identical across Julia versions (the default RNG stream may change between
releases). Tasks the target spawns see the same value. Errors outside a seeded
target.
"""
function tar_seed()
    seed = CURRENT_SEED[]
    seed === nothing &&
        error("tar_seed() is only available while a target with a seed is running")
    return seed
end

"""
    call_target(f, args, seed)

Call `f(args...)` in the latest world, in the current task. With a seed, the
task's default RNG is seeded first and restored afterwards.
"""
function call_target(f, args, seed::Union{Nothing, UInt64})
    seed === nothing && return Base.invokelatest(f, args...)
    rng = Random.default_rng()
    saved = copy(rng)
    Random.seed!(seed)
    try
        return with(() -> Base.invokelatest(f, args...), CURRENT_SEED => seed)
    finally
        copy!(rng, saved)
    end
end

@testitem "target seeds are stable, distinct and pinnable" begin
    using Targets: target_seed, resolve_seed, call_target
    @test target_seed(0, :a) == target_seed(0, :a)
    @test target_seed(0, :a) != target_seed(0, :b)
    @test target_seed(0, :a) != target_seed(1, :a)
    p = tar_pipeline(
        target(:a, () -> 1),
        target(:b, () -> 1; seed = 7),
        target(:c, () -> 1; seed = nothing),
    )
    @test resolve_seed(p, p.targets[1]) == target_seed(0, :a)
    @test resolve_seed(p, p.targets[1], "a/1234") == target_seed(0, "a/1234")
    @test resolve_seed(p, p.targets[2]) == UInt64(7)
    @test resolve_seed(p, p.targets[3]) === nothing
    @test call_target(rand, (), UInt64(1)) == call_target(rand, (), UInt64(1))
    @test call_target(tar_seed, (), UInt64(5)) == 5
    @test_throws "only available" tar_seed()
    @test_throws DomainError call_target(sqrt, (-1.0,), UInt64(1))
end

@testitem "seeding a target leaves the session RNG alone" begin
    using Targets: call_target
    using Random
    Random.seed!(42)
    expected = rand()
    Random.seed!(42)
    call_target(rand, (), UInt64(1))
    @test rand() == expected
end

@testitem "tasks spawned by a seeded target are reproducible" begin
    using Targets: call_target
    f() = fetch.([Threads.@spawn(rand()) for _ in 1:4])
    @test call_target(f, (), UInt64(3)) == call_target(f, (), UInt64(3))
    @test call_target(() -> fetch(Threads.@spawn tar_seed()), (), UInt64(9)) == 9
end

@testitem "random targets give the same values however they are built" setup = [
    SourceFixtures,
] begin
    code(order; seed = 0) = """
    ts = Dict(
        :a => target(:a, () -> rand()),
        :b => target(:b, () -> rand(3)),
        :c => target(:c, (a, b) -> a + sum(b) + rand()),
    )
    p = tar_pipeline([ts[n] for n in $order]...; seed = $seed)
    """
    full = mktempdir()
    build_source(code("[:a, :b, :c]"), full)
    values = read_values(full, :a, :b, :c)
    reordered = mktempdir()
    build_source(code("[:b, :a, :c]"), reordered)
    @test read_values(reordered, :a, :b, :c) == values
    subset = mktempdir()
    build_source(code("[:a, :b, :c]"), subset; names = [:b])
    @test read_values(subset, :b) == (values[2],)

    s = build_source(code("[:a, :b, :c]"; seed = 1), full)
    @test s.built == [:a, :b, :c]
    @test read_values(full, :a) != (values[1],)
    @test outdated_source(code("[:a, :b, :c]"; seed = 2), full)[1] ==
        (name = :a, reason = :seed_changed)
end

@testitem "branches keep their random values when the pattern is reordered" setup = [
    SourceFixtures,
] begin
    code(elements) = """
    p = tar_pipeline(
        target(:grid, () -> $elements),
        target(:draws, grid -> grid + rand(); pattern = :grid),
    )
    """
    mktempdir() do dir
        build_source(code("[1, 2, 3]"), dir)
        before = only(read_values(dir, :draws))
        s = build_source(code("[3, 1, 2]"), dir)
        @test isempty(s.branches)
        @test only(read_values(dir, :draws)) == before[[3, 1, 2]]
    end
end

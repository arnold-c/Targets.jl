## Batched replication
##
## Thousands of one-rep branches each cost a record, an object file and hashing.
## `tar_rep` instead runs `reps` replications per branch over `batches` branches.
## Measured on a 2000-branch target: about 2.5 ms per built branch (object
## writes ~0.5 ms, records ~0.15 ms, the rest scheduling, logging and hashing)
## and 0.5 ms per up-to-date branch, so batching, not a cheaper record format,
## is what pays off.

"The seed of replication `rep` within the running batch (see [`tar_rep`](@ref))."
rep_seed(rep::Integer) = parse(
    UInt64,
    canonical_hash((:rep, tar_seed(), Int(rep)))[1:16];
    base = 16,
)

"""
    tar_rep(name, f; batches, reps, deps = nothing, kwargs...)

Run `f` `batches * reps` times, as `batches` branches of `reps` replications
each, for simulations with many cheap repetitions. `f` takes the values of its
dependencies (by argument name, or `deps`) and each replication runs with its
own seed, derived from the branch seed and its index, so results do not depend
on how the work is batched across runs. Returns three targets: `name_batch`
(the batch numbers), `name_batches` (one branch per batch) and `name`, the
vector of all replications in order, which is what consumers should use.
Other keyword arguments go to the batch target (see [`target`](@ref)).
"""
function tar_rep(
    name::Symbol,
    f;
    batches::Integer,
    reps::Integer,
    deps::Union{Nothing, AbstractVector{Symbol}} = nothing,
    kwargs...,
)
    dependencies = deps === nothing ? arg_names(f, name) : collect(Symbol, deps)
    return rep_targets(name, f, (), dependencies; batches, reps, kwargs...)
end

# `leading` arguments are passed to `f` before its dependencies. They are captured
# by the batch target's closure, so they are part of its command hash.
function rep_targets(
    name::Symbol,
    f,
    leading::Tuple,
    dependencies;
    batches,
    reps,
    kwargs...,
)
    (batches >= 1 && reps >= 1) ||
        throw(ArgumentError("tar_rep: batches and reps must be positive"))
    batch = Symbol(name, :_batch)
    runs = Symbol(name, :_batches)
    n = Int(reps)
    return [
        target(batch, () -> collect(1:Int(batches))),
        target(
            runs,
            (b, args...) -> run_reps(f, n, (leading..., args...));
            deps = [batch; dependencies],
            pattern = batch,
            kwargs...,
        ),
        target(name, xs -> reduce(vcat, xs; init = Any[]); deps = [runs]),
    ]
end

"Run `f(args...)` `reps` times, each replication with its own seed."
function run_reps(f, reps::Int, args)
    return map(1:reps) do r
        Random.seed!(rep_seed(r))
        Base.invokelatest(f, args...)
    end
end

"""
    tar_map_rep(name, f, values; batches, reps, names = nothing, kwargs...)

[`tar_rep`](@ref) for each element of `values`, as with [`tar_map`](@ref): `f`
receives the element first, then its dependencies. Returns the `tar_map` groups,
so `m.name` lists each element's vector of replications.
"""
function tar_map_rep(name::Symbol, f, values; batches, reps, names = nothing, kwargs...)
    deps = arg_names(f, name)[2:end]
    return tar_map(values; names) do v
        rep_targets(name, f, (v,), deps; batches, reps, kwargs...)
    end
end

@testitem "tar_rep batches replications reproducibly" setup = [SourceFixtures] begin
    code(batches, reps) = """
    p = tar_pipeline(
        target(:scale, () -> 10),
        tar_rep(:draws, scale -> scale * rand(); batches = $batches, reps = $reps),
        target(:n, draws -> length(draws)),
    )
    """
    mktempdir() do dir
        s = build_source(code(2, 3), dir)
        @test length(s.branches[:draws_batches]) == 2
        @test read_values(dir, :n) == (6,)
        draws = only(read_values(dir, :draws))
        @test allunique(draws) && all(d -> 0 <= d <= 10, draws)
        @test isempty(build_source(code(2, 3), dir).built)
        s = build_source(code(3, 3), dir) # one more batch: one new branch
        @test length(s.branches[:draws_batches]) == 1
        @test only(read_values(dir, :draws))[1:6] == draws
    end
end

@testitem "tar_map_rep replicates per value" begin
    m = tar_map_rep(:sim, (mu, n) -> mu + n, (a = 1, b = 100); batches = 2, reps = 2)
    p = tar_pipeline(target(:n, () -> 0.5), m)
    mktempdir() do dir
        store = joinpath(dir, "_targets")
        tar_make(p; store, root = dir, io = devnull)
        @test tar_read(:sim_a; store) == fill(1.5, 4)
        @test tar_read(:sim_b; store) == fill(100.5, 4)
    end
end

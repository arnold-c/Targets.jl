# Fixtures shared by test items. These only run under the test runner.

@testmodule SourceFixtures begin
    using Targets
    export load_source, build_source, outdated_source, read_values

    "Write `code` to a temp file and include it into a fresh module."
    function load_source(code::AbstractString; dir = mktempdir(), name = "src.jl")
        path = joinpath(dir, name)
        write(path, code)
        m = Module(:Fixture)
        Core.eval(m, :(using Targets))
        Base.include(m, path)
        return m, path
    end

    "Load `code` (which must define `p`) from `dir` and run `tar_make` on it with the store in `dir`."
    function build_source(code::AbstractString, dir::AbstractString; kwargs...)
        m, _ = load_source(code; dir)
        p = Base.invokelatest(
            getproperty,
            m,
            :p,
        ) # `m.p` was defined after this method was compiled
        return tar_make(
            p;
            store = joinpath(dir, "_targets"),
            root = dir,
            io = devnull,
            kwargs...,
        )
    end

    "Like `build_source`, but report what `tar_outdated` says about the store in `dir`."
    function outdated_source(code::AbstractString, dir::AbstractString; kwargs...)
        m, _ = load_source(code; dir)
        p = Base.invokelatest(getproperty, m, :p)
        return tar_outdated(p; store = joinpath(dir, "_targets"), root = dir, kwargs...)
    end

    read_values(dir, names...) = map(
        n -> tar_read(n; store = joinpath(dir, "_targets")),
        names,
    )
end

@testmodule ObjectFixtures begin
    using Targets: Record, format_fields, write_meta, write_object
    export store_object

    """
        store_object(s, key, value, format)

    Write `value` as the object of `key` in `format`, with the metadata a build
    records for it, so that it reads back in that format with its options. Returns
    the object's path.
    """
    function store_object(s, key, value, format)
        path = write_object(s, key, value; format)
        write_meta(s, key, Record(; format_fields(format)...))
        return path
    end
end

@testmodule Properties begin
    using Supposition: Supposition, Data, @check, @composed
    using Random: Xoshiro
    export Data,
        @check,
        @composed,
        check_config,
        property_rng,
        check_result,
        sized,
        plain_values

    """
        check_config(; max_examples)

    Options for `@check config = ...`: no example database in the repo, and the
    report is not recorded in the test set (check it with [`check_result`](@ref)).
    Pass the seed separately, as `rng = property_rng()`.
    """
    check_config(; max_examples::Int) = Supposition.CheckConfig(;
        rng = property_rng(),
        max_examples,
        record = false,
        db = false,
    )

    """
        property_rng(seed = 1)

    The generator for `@check rng = ...`: a fixed seed, so every run tries the same
    examples (change it to explore others). It must be passed to `@check` itself:
    Supposition 0.3 replaces the `rng` of a `config` with a randomly seeded one.
    """
    property_rng(seed = 1) = Xoshiro(seed)

    """
        check_result(report)

    `holds`: whether the property `@check` returned `report` for held. Assert it
    with `@test check_result(report).holds`: the test item runner finishes its test
    set in a world that predates `using Supposition`, so a recorded report would
    count as no tests, and its failures would pass silently. (A field, rather than
    a call, keeps `@test` from printing the whole report; `@check` has already
    printed the counterexample.)
    """
    check_result(report) = (; holds = Supposition.results(report).ispass)

    """
        sized(gen, most)

    Vectors of `n` values of `gen`, with `n` uniform in `1:most` (`Data.Vectors`
    favours short ones). `n` is drawn after the values, so it shrinks on its own.
    """
    sized(gen, most) = map(
        (xs, n) -> xs[1:n],
        Data.Vectors(gen; min_size = most, max_size = most),
        Data.Integers(1, most),
    )

    """
        plain_values()

    Nested plain data: integers of two widths, floats (with `-0.0` and `Inf`),
    booleans, strings, symbols, characters, `nothing` and `missing`, in vectors,
    matrices, tuples, named tuples, pairs, dicts, sets and expressions. Scalars come
    from small domains, so that equal values are drawn often; containers hold
    `Any`, so their types depend only on their kind and shape.
    """
    function plain_values()
        scalars = Data.OneOf(
            Data.Integers(-2, 2),
            map(Int32, Data.Integers(-2, 2)),
            Data.SampledFrom([0.0, -0.0, 0.5, 1.0, Inf]),
            Data.Booleans(),
            Data.SampledFrom(["", "a", "ab", "b"]),
            Data.SampledFrom([:a, :ab, :b]),
            Data.SampledFrom(['a', 'b']),
            Data.Just(nothing),
            Data.Just(missing),
        )
        few(v) = Data.Vectors(v; max_size = 3)
        extend(v) = Data.OneOf(
            map(xs -> Any[xs...], few(v)),
            map(
                xs -> reshape(Any[xs; xs], 2, :),
                Data.Vectors(v; min_size = 1, max_size = 2),
            ),
            map(xs -> (xs...,), few(v)),
            map(xs -> NamedTuple{Tuple(Symbol.(:k, eachindex(xs)))}(Tuple(xs)), few(v)),
            map(Pair, v, v),
            map(xs -> Dict{Any, Any}(xs), Data.Vectors(Data.Pairs(v, v); max_size = 3)),
            map(xs -> Set{Any}(xs), few(v)),
            map((h, xs) -> Expr(h, xs...), Data.SampledFrom([:call, :tuple]), few(v)),
        )
        return Data.recursive(extend, scalars; max_layers = 3)
    end
end

@testmodule JETChecks begin
    using Targets: Targets
    using TOML: TOML
    export JET_ENABLED, @test_call

    # JET is tied to specific Julia versions, so it only runs on stable releases
    # recent enough for the JET versions allowed in test/Project.toml. CI removes
    # JET from the test environment on older Julia versions (see CI.yml).
    const JET_ENABLED = VERSION >= v"1.12" && isempty(VERSION.prerelease)
    if JET_ENABLED
        using JET: JET
    end

    # Targets and its extensions (by name: they need not be loaded).
    const TARGET_MODULES = (
        Targets,
        Symbol.(keys(TOML.parsefile(pkgdir(Targets, "Project.toml"))["extensions"]))...,
    )

    """
        @test_call [broken = false] [skip = false] f(args...; kwargs...)

    `JET.@test_call`, reporting only problems in the code of Targets and its
    extensions; does nothing where JET does not run. `JET.test_package` analyses
    each method once, for its declared argument types, so it misses what only
    happens with the concrete types a real call passes; this analyses that call.
    """
    macro test_call(args...)
        JET_ENABLED || return nothing
        return esc(Expr(
            :macrocall,
            GlobalRef(JET, Symbol("@test_call")),
            __source__,
            :(target_modules = $TARGET_MODULES),
            args...,
        ))
    end
end

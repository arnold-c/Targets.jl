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

@testmodule Properties begin
    using Supposition: Supposition, Data, @check, @composed
    using Random: Xoshiro
    export Data, @check, @composed, check_config, passed, sized

    """
        check_config(; max_examples, seed = 1)

    Options for `@check config = ...`: a fixed seed, so every run tries the same
    examples (change it to explore others), and no example database in the repo.
    The report is not recorded in the test set: check it with [`passed`](@ref).
    """
    check_config(; max_examples::Int, seed = 1) = Supposition.CheckConfig(;
        rng = Xoshiro(seed),
        max_examples,
        record = false,
        db = false,
    )

    """
        passed(report)

    Whether the property `@check` returned `report` for held. Assert it with
    `@test`: the test item runner finishes its test set in a world that predates
    `using Supposition`, so a recorded report would count as no tests, and its
    failures would pass silently.
    """
    passed(report) = Supposition.results(report).ispass

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

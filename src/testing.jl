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

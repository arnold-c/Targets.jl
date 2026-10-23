# Fixtures shared by test items. These only run under the test runner.

@testmodule SourceFixtures begin
    using Targets
    export load_source, build_source, read_values

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
        return tar_make(m.p; store = joinpath(dir, "_targets"), io = devnull, kwargs...)
    end

    read_values(dir, names...) = map(n -> tar_read(n; store = joinpath(dir, "_targets")), names)
end

## Error handling: error modes (see the `error` option of `target`)

@testitem "error modes: stop, continue and null on a chain" setup = [SourceFixtures] begin
    code(mode) = """
    p = tar_pipeline(
        target(:bad, () -> error("boom"); error = :$mode),
        target(:after, bad -> something(bad, 0) + 1),
        target(:other, () -> 7),
    )
    """
    mktempdir() do dir
        @test_throws "boom" build_source(code("stop"), dir)
    end
    mktempdir() do dir
        s = build_source(code("continue"), dir)
        @test s.errored == [:bad] && s.blocked == [:after] && s.built == [:other]
    end
    mktempdir() do dir
        s = build_source(code("null"), dir)
        @test s.errored == [:bad] && s.built == [:after, :other]
        @test read_values(dir, :after) == (1,)
        # the failed target is retried, and its consumers rebuilt once it succeeds
        s = build_source(replace(code("null"), "error(\"boom\")" => "41"), dir)
        @test s.built == [:bad, :after]
        @test read_values(dir, :after) == (42,)
    end
end

@testitem "error = :trim drops failed branches and retries them" setup = [
    SourceFixtures,
] begin
    # a branch fails while its marker file exists, so fixing it changes no code
    code = """
    p = tar_pipeline(
        target(:grid, () -> [1, 2, 3]),
        target(:fits, grid -> isfile("fail_\$grid") ? error("bad element") : grid * 10;
            pattern = :grid, error = :trim),
        target(:total, fits -> sum(fits)),
    )
    """
    mktempdir() do dir
        touch(joinpath(dir, "fail_2"))
        s = build_source(code, dir)
        @test s.built == [:grid, :fits, :total]
        @test length(s.trimmed[:fits]) == 1
        @test read_values(dir, :fits, :total) == ([10, 30], 40)
        @test outdated_source(code, dir)[1] == (name = :fits, reason = :errored)
        rm(joinpath(dir, "fail_2"))
        s = build_source(code, dir)
        @test isempty(s.trimmed) && length(s.branches[:fits]) == 1 # only the retried one
        @test read_values(dir, :total) == (60,)
    end
    @test_throws "needs a branching target" target(:x, () -> 1; error = :trim)
    @test_throws "error must be" target(:x, () -> 1; error = :ignore)
end

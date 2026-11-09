# Check that hashes survive a change of Julia version, so that upgrading Julia does
# not mark anything stale.
#
# Run it once per Julia version, against the same persistent store, e.g. with juliaup:
#
#   julia +1.10 examples/version_check.jl --reset     # build with the oldest version
#   julia +1.11 examples/version_check.jl             # must build nothing
#   julia +release examples/version_check.jl          # must build nothing
#
# Each later run exits with status 1 if any target was rebuilt. It also prints, per
# target, how its code was hashed: `source` hashes are stable across Julia versions,
# while `lowered` ones are not (those targets are *expected* to rebuild once, and the
# run says so instead of failing).
#
# The store lives in `examples/.version_check/` (override with TARGETS_EXAMPLE_DIR).

include(joinpath(@__DIR__, "demo.jl"))

function main(args)
    dir = get(ENV, "TARGETS_EXAMPLE_DIR", joinpath(@__DIR__, ".version_check"))
    "--reset" in args && reset_demo(dir)
    first_run = !isdir(demo_store(dir))
    write_demo(dir) # same content every time: any rebuild comes from Julia, not edits

    println(
        "Julia ",
        VERSION,
        first_run ? "  (first run: building the reference store)" : "",
    )
    summary = demo_make(dir; io = devnull)
    println("  built:   ", summary.built)
    println("  skipped: ", summary.skipped)

    meta = tar_meta(; store = demo_store(dir))
    println("  hash source per target:")
    for row in meta
        println(
            "    ",
            rpad(row.name, 20),
            row.hash_source,
            "   command ",
            first(row.command_hash, 8),
            "  code ",
            first(row.code_hash, 8),
            "  (built with Julia ",
            row.julia_version,
            ")",
        )
    end
    open(joinpath(dir, "versions.log"), "a") do io
        println(io, "Julia ", VERSION, ": built=", summary.built)
    end

    first_run && return 0
    isempty(summary.built) &&
        (println("OK: nothing rebuilt under Julia ", VERSION); return 0)
    lowered = [Symbol(r.name) for r in meta if r.hash_source == "lowered"]
    if all(in(lowered), summary.built)
        println("Rebuilt only targets hashed from lowered code (expected): ", summary.built)
        return 0
    end
    println("FAIL: targets with source-based hashes were rebuilt under Julia ", VERSION)
    return 1
end

exit(main(ARGS))

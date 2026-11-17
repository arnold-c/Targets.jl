using TestItemRunner

@testitem "Code quality (Aqua.jl)" tags = [:quality] begin
    using Aqua
    Aqua.test_all(Targets)
end

# Analyses every method for its declared argument types. Unit tests check the
# calls they make with JETChecks' `@test_call`, which this misses.
@testitem "Code linting (JET.jl)" tags = [:quality] setup = [JETChecks] begin
    if JET_ENABLED
        using JET
        JET.test_package(Targets; target_modules = (Targets,))
    end
end

@run_package_tests

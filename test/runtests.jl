using TestItemRunner

@testitem "Code quality (Aqua.jl)" tags = [:quality] begin
    using Aqua
    Aqua.test_all(Targets)
end

# JET is tied to specific Julia versions, so only run it on stable releases
# recent enough for the JET versions allowed in test/Project.toml.
@testitem "Code linting (JET.jl)" tags = [:quality] begin
    if VERSION >= v"1.12" && isempty(VERSION.prerelease)
        using JET
        JET.test_package(Targets; target_modules = (Targets,))
    end
end

@run_package_tests

using Targets
using Test
using Aqua
using JET

@testset "Targets.jl" begin
    @testset "Code quality (Aqua.jl)" begin
        Aqua.test_all(Targets)
    end
    @testset "Code linting (JET.jl)" begin
        JET.test_package(Targets; target_defined_modules = true)
    end
    # Write your tests here.
end

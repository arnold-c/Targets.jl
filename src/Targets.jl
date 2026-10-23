module Targets

using CodeTracking: CodeTracking
using Dates: Dates
using Graphs: SimpleDiGraph, add_edge!, inneighbors, nv, outneighbors
using JLD2: JLD2
using JuliaSyntax:
    JuliaSyntax,
    SyntaxNode,
    @K_str,
    children,
    kind,
    last_byte,
    source_location
using SHA: SHA
using Serialization: Serialization
using TOML: TOML
using TestItems: @testitem, @testmodule

include("testing.jl")

include("target.jl")
export Target, target

include("pipeline.jl")
export Pipeline, tar_pipeline

include("canonical.jl")

include("source.jl")

include("hashing.jl")

include("store.jl")
export tar_meta

include("outdated.jl")

include("make.jl")
export tar_make, BuildSummary

include("api.jl")
export tar_read

end

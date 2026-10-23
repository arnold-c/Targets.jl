module Targets

using Graphs: SimpleDiGraph, add_edge!, inneighbors, nv, outneighbors
using JLD2: JLD2
using SHA: SHA
using Serialization: Serialization
using TOML: TOML
using TestItems: @testitem

include("target.jl")
export Target, target

include("pipeline.jl")
export Pipeline, tar_pipeline

include("canonical.jl")

include("store.jl")
export tar_meta

end

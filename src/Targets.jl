module Targets

using Graphs: SimpleDiGraph, add_edge!, inneighbors, nv, outneighbors
using TestItems: @testitem

include("target.jl")
export Target, target

include("pipeline.jl")
export Pipeline, tar_pipeline

end

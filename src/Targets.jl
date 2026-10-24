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
using Preferences: Preferences
using Random: Random
using ScopedValues: ScopedValue, with
using SHA: SHA
using Serialization: Serialization
using TOML: TOML
using TestItems: @testitem, @testmodule

include("testing.jl")

include("formats.jl")
export StorageFormat, ArrowFormat, ParquetFormat, CSVFormat

include("target.jl")
export Target, target

include("pipeline.jl")
export Pipeline, tar_pipeline

include("static.jl")
export tar_map, tar_combine

include("canonical.jl")

include("source.jl")

include("hashing.jl")

include("seeds.jl")
export tar_seed

include("store.jl")
export tar_meta

include("codedeps.jl")

include("manifest.jl")

include("files.jl")

include("outdated.jl")

include("scheduler.jl")

include("jobs.jl")

include("make.jl")
export tar_make, tar_outdated, BuildSummary

include("branching.jl")

include("dispatch.jl")
export tar_slots

include("graph.jl")
export tar_dot, tar_visnetwork

include("api.jl")

include("macros.jl")
export @pipeline, @target
export tar_read, @tar_load, tar_manifest, tar_invalidate, tar_delete, tar_prune, tar_destroy

end

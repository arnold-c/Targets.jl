module Targets

using CodeTracking: CodeTracking
using Dates: Dates
using Downloads: Downloads
using ExpressionExplorer: ExpressionExplorer
using Graphs:
    SimpleDiGraph,
    add_edge!,
    induced_subgraph,
    inneighbors,
    nv,
    outneighbors,
    weakly_connected_components
using JLD2: JLD2
using Logging: Logging
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

include("cues.jl")
export CueRule, Cue, cue_age, cue_force

include("patterns.jl")
export Pattern, Map, Cross, Head, Slice, Sample

include("target.jl")
export Target, target

include("pipeline.jl")
export Pipeline, tar_pipeline

include("declarations.jl")

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

include("urls.jl")

include("outdated.jl")

include("scheduler.jl")

include("jobs.jl")

include("executors.jl")
export Executor, TaskExecutor, DistributedExecutor

include("make.jl")
export tar_make, tar_outdated, BuildSummary

include("branching.jl")

include("errors.jl")
export tar_workspace, @tar_workspace, tar_rerun, tar_errored, tar_traceback

include("replicate.jl")
export tar_rep, tar_map_rep

include("quarto.jl")
export tar_quarto

include("dispatch.jl")
export tar_slots

include("progress.jl")
export tar_progress, tar_poll

include("graph.jl")
export tar_dot, tar_visnetwork

include("list.jl")
export tar_list, TargetList

include("api.jl")

include("macros.jl")
export @pipeline, @targets, @target, @quarto, @map, Fragment
export tar_read, @tar_load, tar_manifest, tar_invalidate, tar_delete, tar_prune, tar_destroy

end

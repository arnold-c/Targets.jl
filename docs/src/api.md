# API reference

```@meta
CurrentModule = Targets
```

## Declaring targets

```@docs
target
Target
tar_pipeline
Pipeline
@pipeline
@targets
@target
Fragment
tar_quarto
@quarto
```

## Static branching and replication

```@docs
tar_map
@map
tar_combine
tar_rep
tar_map_rep
@rep
```

## Dynamic branching patterns

```@docs
Pattern
Map
Cross
Head
Slice
Sample
```

## Cues

```@docs
CueRule
Cue
cue_age
cue_force
```

## Storage formats

```@docs
StorageFormat
ArrowFormat
ParquetFormat
CSVFormat
```

## Building

```@docs
tar_make
BuildSummary
tar_outdated
Executor
TaskExecutor
DistributedExecutor
JobResult
tar_slots
tar_seed
```

## Reading and managing the store

```@docs
tar_read
@tar_load
tar_meta
tar_manifest
tar_invalidate
tar_delete
tar_prune
tar_destroy
```

## Failures

```@docs
tar_errored
tar_traceback
tar_workspace
@tar_workspace
tar_rerun
```

## Progress

```@docs
tar_progress
tar_poll
```

## Viewing the pipeline

```@docs
tar_list
TargetList
tar_status
TargetStatus
tar_dot
DotGraph
tar_visnetwork
tar_picker
```

"""
    tar_read(name; store = default_store_path(), script = nothing,
             on_outdated = outdated_preference())

The stored value of target `name`. For a file target this is its path (or vector
of paths), relative to the project root; for a branching target it is the vector
of its branch values in pattern order.

The value is the last one stored, even if the target is no longer up to date.
`on_outdated` says what happens then: `:warn` (the default), `:error`, or
`:ignore` (which also skips the check). Set the default for a project with the
`on_outdated` preference, e.g. in `LocalPreferences.toml`:

```toml
[Targets]
on_outdated = "error"
```

When reading the project's own store, the check is [`tar_outdated`](@ref) on the
project's `_targets.jl` (or on `script`), so code edits count. Otherwise, and for
targets no longer in the pipeline, only an invalidated target (one with no
build record) counts as outdated.
"""
tar_read(name::Symbol; kwargs...) = only(read_targets([name]; kwargs...))

"""
    @tar_load names...
    @tar_load store = path script = path on_outdated = :error names...

Assign the stored value of each target to a variable of the same name in the
caller's scope, so it works at the REPL, inside functions and inside modules.
Options go before the names and work as in [`tar_read`](@ref); the targets are
checked together, so at most one warning is given.
"""
macro tar_load(args...)
    names = collect(Any, args)
    options = Expr[]
    while !isempty(names) &&
            Meta.isexpr(names[1], :(=)) &&
            names[1].args[1] in (:store, :script, :on_outdated)
        opt = popfirst!(names)
        push!(options, Expr(:kw, opt.args[1], esc(opt.args[2])))
    end
    (!isempty(names) && all(n -> n isa Symbol, names)) ||
        error("@tar_load expects one or more target names, e.g. @tar_load model clean_data")
    values = gensym(:values)
    read = Expr(
        :call,
        GlobalRef(@__MODULE__, :read_targets),
        Expr(:parameters, options...),
        QuoteNode(Symbol[names...]),
    )
    loads = [:($(esc(n)) = $values[$i]) for (i, n) in enumerate(names)]
    return Expr(:block, :($values = $read), loads..., nothing)
end

"The stored values of `names`, after checking them together (see [`tar_read`](@ref))."
function read_targets(
    names::Vector{Symbol};
    store::Union{Store, AbstractString} = default_store_path(),
    script::Union{Nothing, AbstractString} = nothing,
    on_outdated::Symbol = outdated_preference(),
)
    s = as_store(store)
    values = [retrieve_value(s, n) for n in names]
    check_reads(s, names, script, check_on_outdated(on_outdated))
    return values
end

"The stored value of `name`, outside a build: its kind comes from the store alone."
retrieve_value(s::Store, name::Symbol) = stored_value(s, name, stored_kind(s, name))

# The kind of value stored under `name`, from the store alone (see `stored_value`).
function stored_kind(s::Store, name::Symbol)
    record = read_meta(s, name)
    record === nothing && return :object
    record.format == "file" && return :file
    # a branching target has a record but no object of its own: its value is its branches
    return has_object(s, name) ? :object : :branches
end

const ON_OUTDATED = (:warn, :error, :ignore)

"""
    outdated_preference()

The default `on_outdated` of [`tar_read`](@ref) and [`@tar_load`](@ref): the
`on_outdated` preference of Targets (e.g. in `LocalPreferences.toml`), or `:warn`.
"""
outdated_preference() = check_on_outdated(Symbol(Preferences.load_preference(
    @__MODULE__,
    "on_outdated",
    "warn",
)))

check_on_outdated(mode::Symbol) = mode in ON_OUTDATED ?
    mode :
    throw(ArgumentError("on_outdated must be one of $ON_OUTDATED, got `$mode`"))

# The pipeline to check reads against: `script`, or the project's `_targets.jl`
# when reading the project's own store.
function read_script(s::Store, script)
    script === nothing || return script
    Base.active_project() === nothing && return nothing
    s.root == abspath(default_store_path()) || return nothing
    path = default_script()
    return isfile(path) ? path : nothing
end

"`(name, reason)` for each of `names` whose stored value is not up to date."
function outdated_reads(s::Store, names::Vector{Symbol}, script)
    path = read_script(s, script)
    path === nothing && return store_outdated(s, names)
    p = load_pipeline(path)
    checked = filter(n -> haskey(p.index, n), names)
    return vcat(
        pipeline_outdated(p, s, checked, dirname(path)),
        store_outdated(s, setdiff(names, checked)),
    )
end

function pipeline_outdated(
    p::Pipeline,
    s::Store,
    names::Vector{Symbol},
    root::AbstractString,
)
    isempty(names) && return Tuple{Symbol, Symbol}[]
    return Tuple{Symbol, Symbol}[
        (r.name, r.reason)
        for r in tar_outdated(p; names, store = s, root)
        if r.name in names
    ]
end

# Without the pipeline, only a missing build record (an invalidated target) shows.
store_outdated(s::Store, names) = Tuple{Symbol, Symbol}[
    (n, :missing)
    for n in names
    if read_meta(s, n) === nothing
]

function check_reads(s::Store, names::Vector{Symbol}, script, on_outdated::Symbol)
    on_outdated === :ignore && return nothing
    outdated = outdated_reads(s, names, script)
    isempty(outdated) && return nothing
    message = "read stored values that are not up to date: " *
        join(("`$n` ($reason)" for (n, reason) in outdated), ", ") *
        "; run tar_make() to update them (reasons as in tar_outdated())"
    on_outdated === :error && error(message)
    @warn message
    return nothing
end

"""
    tar_manifest(p::Pipeline)

One row per target (`name`, `deps`, `format`, `pattern`, `cue`, `slots`,
`deployment`), without touching the store. `tar_manifest()` loads `_targets.jl`.
"""
tar_manifest(p::Pipeline) = [
    (
        name = t.name,
        deps = t.deps,
        format = t.format,
        pattern = t.pattern,
        cue = t.cue,
        slots = t.slots,
        deployment = t.deployment,
    )
    for t in p.targets
]
tar_manifest(; script::AbstractString = default_script()) = tar_manifest(load_pipeline(
    script,
))

# Everything stored under a target's name: its object, its record, and any branches.
function remove_target_files!(s::Store, name)
    rm(object_path(s, name); force = true)
    rm(joinpath(s.root, "objects", string(name)); recursive = true, force = true)
    delete_meta(s, name)
    rm(joinpath(s.root, "meta", string(name)); recursive = true, force = true)
    return nothing
end

"""
    stored_target_names(s, names)

`names` with each [`tar_map`](@ref) group name replaced by its targets, using the
groups recorded by the last `tar_make`; `nothing` means every stored target.
"""
stored_target_names(s::Store, ::Nothing) = stored_names(s)
function stored_target_names(s::Store, names)
    groups = stored_groups(s)
    return unique(reduce(
        vcat,
        (get(groups, n, [n]) for n in as_names(names));
        init = Symbol[],
    ))
end

"""
    tar_invalidate(; names = nothing, store = default_store_path(), ask = true,
                   input = stdin, io = stdout)

Delete the metadata of the targets in `names` (a vector of symbols, or one symbol)
so that they rebuild on the next run. Their stored objects stay, so `tar_read`
keeps working in the meantime. A [`tar_map`](@ref) group name (as of the last
`tar_make`) stands for all of its targets; a single generated name affects only
that one, and the next `tar_make` rebuilds only it and what depends on it.

Without `names`, every stored target is invalidated, so the whole pipeline
rebuilds; this asks for confirmation first unless `ask = false`.
"""
function tar_invalidate(;
    names::Union{Nothing, Symbol, AbstractVector{Symbol}} = nothing,
    store::Union{Store, AbstractString} = default_store_path(),
    ask::Bool = true,
    input::IO = stdin,
    io::IO = stdout,
)
    s = as_store(store)
    (names === nothing && ask) &&
        !confirm(
            "Invalidate every target in $(s.root), so the whole pipeline rebuilds?";
            input,
            io,
        ) &&
        return nothing
    for name in stored_target_names(s, names)
        delete_meta(s, name)
        rm(joinpath(s.root, "meta", string(name)); recursive = true, force = true)
    end
    return nothing
end

"""
    tar_delete(; names, store = default_store_path())

Delete the stored object and metadata of the targets in `names`. As with
[`tar_invalidate`](@ref), a [`tar_map`](@ref) group name stands for all of its targets.
"""
function tar_delete(;
    names::Union{Symbol, AbstractVector{Symbol}},
    store::Union{Store, AbstractString} = default_store_path(),
)
    s = as_store(store)
    foreach(name -> remove_target_files!(s, name), stored_target_names(s, names))
    return nothing
end

"Names of every target that has something in the store (an object or a record)."
function stored_names(s::Store)
    names = Set{String}(first(split(k, '/')) for k in meta_keys(s))
    objects = joinpath(s.root, "objects")
    if isdir(objects)
        for entry in readdir(objects)
            occursin(".tmp-", entry) && continue
            push!(names, endswith(entry, ".jld2") ? chopsuffix(entry, ".jld2") : entry)
        end
    end
    return Symbol[Symbol(n) for n in sort!(collect(names))]
end

"""
    tar_prune(p::Pipeline; store = default_store_path())

Delete the objects and records of targets that are no longer in the pipeline
(including targets that were renamed). Returns the names removed.
"""
function tar_prune(p::Pipeline; store::Union{Store, AbstractString} = default_store_path())
    s = as_store(store)
    stale = filter(name -> !haskey(p.index, name), stored_names(s))
    foreach(name -> remove_target_files!(s, name), stale)
    return stale
end
tar_prune(; script::AbstractString = default_script(), kwargs...) = tar_prune(
    load_pipeline(script);
    kwargs...,
)

"""
    tar_destroy(; store = default_store_path(), ask = true, input = stdin, io = stdout)

Delete the whole store, after asking for confirmation unless `ask = false`.
Returns whether it was deleted. Refuses to delete a directory that is not a store.
"""
function tar_destroy(;
    store::Union{Store, AbstractString} = default_store_path(),
    ask::Bool = true,
    input::IO = stdin,
    io::IO = stdout,
)
    s = as_store(store)
    isdir(s.root) || return false
    isfile(joinpath(s.root, "store.toml")) ||
        error(
            "$(s.root) does not look like a Targets store (no store.toml); not deleting it",
        )
    (!ask || confirm("Delete the store at $(s.root)?"; input, io)) || return false
    rm(s.root; recursive = true)
    return true
end

"Ask a yes/no `question` on `io`; true only for an answer of y or yes on `input`."
function confirm(question::AbstractString; input::IO, io::IO)
    print(io, question, " [y/N] ")
    flush(io)
    return lowercase(strip(readline(input))) in ("y", "yes")
end

@testmodule StoreFixtures begin
    using Targets
    export built_store

    "A store in a temp dir holding targets x, y and z (each built from the previous one)."
    function built_store(dir)
        p = tar_pipeline(
            target(:x, () -> 1),
            target(:y, x -> x + 1),
            target(:z, y -> y + 1),
        )
        store = joinpath(dir, "_targets")
        tar_make(p; store, root = dir, io = devnull)
        return p, store
    end
end

@testitem "@tar_load assigns in the caller's scope, including inside functions and modules" setup = [
    StoreFixtures,
] begin
    mktempdir() do dir
        p, store = built_store(dir)
        @tar_load store = store x y
        @test (x, y) == (1, 2)
        function in_function(store)
            @tar_load store = store z
            return z
        end
        @test in_function(store) == 3
        m = Module(:Loader)
        Core.eval(m, :(using Targets))
        Core.eval(m, :(@tar_load store = $store x))
        @test Core.eval(m, :x) == 1
        @test_throws LoadError Core.eval(m, :(@tar_load))
    end
end

@testitem "reading an outdated target warns, errors or is ignored" setup = [
    StoreFixtures,
] begin
    mktempdir() do dir
        p, store = built_store(dir)
        @test (@test_logs tar_read(:y; store)) == 2 # up to date: silent
        tar_invalidate(; names = :y, store)
        @test (@test_logs (:warn, r"`y` \(missing\)") tar_read(:y; store)) == 2
        @test_throws "`y` (missing)" tar_read(:y; store, on_outdated = :error)
        @test (@test_logs tar_read(:y; store, on_outdated = :ignore)) == 2
        @test_throws "on_outdated must be one of" tar_read(:y; store, on_outdated = :loud)

        # one check, one warning, for all the names
        local x, y, z
        @test_logs (:warn, r"`y` \(missing\)") @tar_load store = store x y z
        @test (x, y, z) == (1, 2, 3)
        @test_throws "not up to date" @tar_load store = store on_outdated = :error y
    end
end

@testitem "reads are checked against the pipeline script, so code edits count" setup = [
    SourceFixtures,
] begin
    mktempdir() do dir
        code(k) = """
        p = tar_pipeline(target(:x, () -> $k), target(:y, x -> x + 1))
        """
        build_source(code(1), dir)
        store = joinpath(dir, "_targets")
        script = joinpath(dir, "src.jl")
        @test (@test_logs tar_read(:y; store, script)) == 2
        write(script, code(5))
        @test (
            @test_logs (:warn, r"`y` \(upstream_outdated\)") tar_read(:y; store, script)
        ) ==
            2
        @test (@test_logs tar_read(:y; store)) == 2 # no script: store-only check
    end
end

@testitem "the on_outdated default comes from the Targets preference" begin
    using Targets: outdated_preference
    @test outdated_preference() == :warn
    mktempdir() do dir
        write(
            joinpath(dir, "Project.toml"),
            "[deps]\nTargets = \"ccd79084-dcf1-4aa0-8fea-6744ff5e7af6\"\n",
        )
        write(
            joinpath(dir, "LocalPreferences.toml"),
            "[Targets]\non_outdated = \"error\"\n",
        )
        pushfirst!(LOAD_PATH, dir)
        try
            @test outdated_preference() == :error
            write(
                joinpath(dir, "LocalPreferences.toml"),
                "[Targets]\non_outdated = \"loud\"\n",
            )
            @test_throws "on_outdated must be one of" outdated_preference()
        finally
            popfirst!(LOAD_PATH)
        end
    end
end

@testitem "tar_manifest lists targets without touching the store" begin
    p = tar_pipeline(
        target(:a, () -> 1),
        target(:b, a -> a; cue = :always, slots = :all, deployment = :main),
    )
    @test tar_manifest(p) ==
        [
            (
                name = :a,
                deps = Symbol[],
                format = :jld2,
                pattern = nothing,
                cue = :thorough,
                slots = 1,
                deployment = :spawn,
            ),
            (
                name = :b,
                deps = [:a],
                format = :jld2,
                pattern = nothing,
                cue = :always,
                slots = :all,
                deployment = :main,
            ),
        ]
end

@testitem "tar_invalidate keeps the object but forces a rebuild; tar_delete removes both" setup = [
    StoreFixtures,
] begin
    using Targets: open_store, has_object, read_meta
    mktempdir() do dir
        p, store = built_store(dir)
        s = open_store(store)
        tar_invalidate(; names = [:y], store)
        @test (@test_logs (:warn, r"`y` \(missing\)") tar_read(:y; store)) == 2
        @test read_meta(s, :y) === nothing
        built = tar_make(p; store, root = dir, io = devnull).built
        @test built == [:y] # z is unchanged by early cutoff
        tar_delete(; names = [:y, :z], store)
        @test !has_object(s, :y) && !has_object(s, :z)
        @test read_meta(s, :z) === nothing
        @test tar_make(p; store, root = dir, io = devnull).built == [:y, :z]
    end
end

@testitem "make, invalidate and delete accept tar_map groups; single arms stay single" setup = [
    SourceFixtures,
] begin
    using Targets: open_store, has_object, read_meta
    mktempdir() do dir
        code = """
        m = tar_map((low = 1, high = 2)) do k
            (target(:shifted, raw -> raw + k), target(:summary, shifted -> 2shifted))
        end
        p = tar_pipeline(target(:raw, () -> 10), m, tar_combine(:total, (xs...) -> sum(xs), m.summary))
        """
        store = joinpath(dir, "_targets")
        s = open_store(store)
        @test build_source(code, dir; names = [:shifted]).built ==
            [:raw, :shifted_low, :shifted_high]

        @test build_source(code, dir).built == [:summary_low, :summary_high, :total]

        # one arm: only it reruns; early cutoff stops at its unchanged value
        tar_invalidate(; names = :shifted_low, store)
        @test read_meta(s, :shifted_high) !== nothing
        r = build_source(code, dir)
        @test r.built == [:shifted_low]
        @test :shifted_high in r.skipped

        tar_invalidate(; names = [:shifted], store)
        @test read_meta(s, :shifted_low) === nothing &&
            read_meta(s, :shifted_high) === nothing
        @test build_source(code, dir).built == [:shifted_low, :shifted_high]

        tar_delete(; names = :summary, store)
        @test !has_object(s, :summary_low) && !has_object(s, :summary_high)
        @test has_object(s, :shifted_low)
        @test build_source(code, dir).built == [:summary_low, :summary_high]
    end
end

@testitem "tar_invalidate without names invalidates the whole pipeline" setup = [
    StoreFixtures,
] begin
    using Targets: open_store, meta_keys
    mktempdir() do dir
        p, store = built_store(dir)
        tar_invalidate(; store, input = IOBuffer("n\n"), io = devnull)
        @test !isempty(meta_keys(open_store(store)))
        tar_invalidate(; names = :x, store, input = IOBuffer(), io = devnull) # never asks
        tar_invalidate(; store, input = IOBuffer("y\n"), io = devnull)
        @test isempty(meta_keys(open_store(store)))
        @test tar_read(:z; store, on_outdated = :ignore) == 3
        @test tar_make(p; store, root = dir, io = devnull).built == [:x, :y, :z]
        tar_invalidate(; store, ask = false)
        @test isempty(meta_keys(open_store(store)))
    end
end

@testitem "tar_prune removes targets that left the pipeline" setup = [StoreFixtures] begin
    using Targets: open_store, has_object, stored_names
    mktempdir() do dir
        p, store = built_store(dir)
        smaller = tar_pipeline(target(:x, () -> 1), target(:renamed, x -> x + 1))
        @test tar_prune(smaller; store) == [:y, :z]
        @test stored_names(open_store(store)) == [:x]
        @test tar_read(:x; store) == 1
        @test isempty(tar_prune(smaller; store))
    end
end

@testitem "tar_destroy asks before deleting a store, and only deletes stores" setup = [
    StoreFixtures,
] begin
    mktempdir() do dir
        p, store = built_store(dir)
        @test !tar_destroy(; store, input = IOBuffer("n\n"), io = devnull)
        @test isdir(store)
        @test tar_destroy(; store, input = IOBuffer("y\n"), io = devnull)
        @test !isdir(store)
        @test !tar_destroy(; store, ask = false) # nothing left to delete
        plain = mkpath(joinpath(dir, "not_a_store"))
        @test_throws "does not look like" tar_destroy(; store = plain, ask = false)
    end
end

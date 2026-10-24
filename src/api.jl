"""
    tar_read(name; store = default_store_path())

The stored value of target `name`. For a file target this is its path (or vector
of paths), relative to the project root; for a branching target it is the vector
of its branch values in pattern order.
"""
function tar_read(name::Symbol; store::Union{Store, AbstractString} = default_store_path())
    s = as_store(store)
    record = read_meta(s, name)
    (record !== nothing && record.format == "file") && return file_value(record)
    # a branching target has records but no object of its own: its value is its branches
    (record !== nothing && !has_object(s, name)) && return load_branches(s, name)
    return read_object(s, name)
end

"""
    @tar_load names...
    @tar_load store = path names...

Assign the stored value of each target to a variable of the same name in the
caller's scope, so it works at the REPL, inside functions and inside modules.
"""
macro tar_load(args...)
    store = :(default_store_path())
    names = collect(Any, args)
    if !isempty(names) && Meta.isexpr(names[1], :(=)) && names[1].args[1] === :store
        store = names[1].args[2]
        popfirst!(names)
    end
    (!isempty(names) && all(n -> n isa Symbol, names)) ||
        error("@tar_load expects one or more target names, e.g. @tar_load model clean_data")
    reader = GlobalRef(@__MODULE__, :tar_read)
    path = gensym(:store)
    loads = [:($(esc(n)) = $reader($(QuoteNode(n)); store = $path)) for n in names]
    return Expr(:block, :($path = $(esc(store))), loads..., nothing)
end

"""
    tar_manifest(p::Pipeline)

One row per target (`name`, `deps`, `format`, `pattern`, `cue`), without touching
the store. `tar_manifest()` loads `_targets.jl`.
"""
tar_manifest(p::Pipeline) = [
    (name = t.name, deps = t.deps, format = t.format, pattern = t.pattern, cue = t.cue)
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
groups recorded by the last `tar_make`.
"""
function stored_target_names(s::Store, names)
    groups = stored_groups(s)
    return unique(reduce(
        vcat,
        (get(groups, n, [n]) for n in as_names(names));
        init = Symbol[],
    ))
end

"""
    tar_invalidate(; names, store = default_store_path())

Delete the metadata of the targets in `names` (a vector of symbols, or one symbol)
so that they rebuild on the next run. Their stored objects stay, so `tar_read`
keeps working in the meantime. A [`tar_map`](@ref) group name (as of the last
`tar_make`) stands for all of its targets; a single generated name affects only
that one, and the next `tar_make` rebuilds only it and what depends on it.
"""
function tar_invalidate(;
    names::Union{Symbol, AbstractVector{Symbol}},
    store::Union{Store, AbstractString} = default_store_path(),
)
    s = as_store(store)
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
    if ask
        print(io, "Delete the store at $(s.root)? [y/N] ")
        flush(io)
        answer = lowercase(strip(readline(input)))
        answer in ("y", "yes") || return false
    end
    rm(s.root; recursive = true)
    return true
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

@testitem "tar_manifest lists targets without touching the store" begin
    p = tar_pipeline(target(:a, () -> 1), target(:b, a -> a; cue = :always))
    @test tar_manifest(p) ==
        [
            (
                name = :a,
                deps = Symbol[],
                format = :jld2,
                pattern = nothing,
                cue = :thorough,
            ),
            (name = :b, deps = [:a], format = :jld2, pattern = nothing, cue = :always),
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
        @test tar_read(:y; store) == 2
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

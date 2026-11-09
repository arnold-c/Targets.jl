## Package versions
##
## Changes to installed packages are not tracked per function. Instead the
## Manifest is fingerprinted in the store: when it changes the user is told which
## packages moved, and can opt in to rebuilding everything.

"The project's Manifest, if there is one (a versioned manifest wins)."
function manifest_file(root::AbstractString)
    versioned = joinpath(root, "Manifest-v$(VERSION.major).$(VERSION.minor).toml")
    isfile(versioned) && return versioned
    plain = joinpath(root, "Manifest.toml")
    return isfile(plain) ? plain : nothing
end

"`name => version` for every package in a Manifest (either file format)."
function manifest_packages(path::AbstractString)
    parsed = TOML.parsefile(path)
    entries = get(parsed, "deps", parsed)
    packages = Dict{String, String}()
    for (name, specs) in entries
        specs isa AbstractVector || continue
        spec = isempty(specs) ? Dict{String, Any}() : first(specs)
        packages[name] = string(get(spec, "version", ""))
    end
    return packages
end

function describe_changes(old::AbstractDict, new::AbstractDict)
    changes = String[]
    for name in sort!(collect(union(keys(old), keys(new))))
        before, after = get(old, name, nothing), get(new, name, nothing)
        before == after && continue
        push!(
            changes,
            before === nothing ?
                "$name added ($after)" :
                after === nothing ? "$name removed ($before)" : "$name $before → $after",
        )
    end
    return changes
end

"""
    manifest_changes(store, root)

`nothing` if the Manifest is unchanged since the last successful build (or there
is none), otherwise a description of what changed. The first build only records it.
"""
function manifest_changes(store::Store, root::AbstractString)
    path = manifest_file(root)
    path === nothing && return nothing
    info = read_store_info(store)
    haskey(info, "manifest_hash") || return nothing
    hash_file(path) == info["manifest_hash"] && return nothing
    return describe_changes(
        get(info, "manifest_packages", Dict{String, Any}()),
        manifest_packages(path),
    )
end

"Record the current Manifest in the store."
function record_manifest!(store::Store, root::AbstractString)
    path = manifest_file(root)
    path === nothing && return nothing
    info = read_store_info(store)
    info["manifest_hash"] = hash_file(path)
    info["manifest_packages"] = manifest_packages(path)
    write_store_info(store, info)
    return nothing
end

@testitem "manifest changes are described package by package" begin
    using Targets: describe_changes
    old = Dict("A" => "1.0.0", "B" => "2.0.0", "C" => "3.0.0")
    new = Dict("A" => "1.1.0", "B" => "2.0.0", "D" => "0.1.0")
    @test describe_changes(old, new) ==
        ["A 1.0.0 → 1.1.0", "C removed (3.0.0)", "D added (0.1.0)"]
    @test isempty(describe_changes(old, old))
end

@testitem "manifest_packages reads both manifest formats" begin
    using Targets: manifest_packages
    mktempdir() do dir
        v2 = joinpath(dir, "v2.toml")
        write(
            v2,
            "manifest_format = \"2.0\"\n[[deps.Foo]]\nuuid = \"x\"\nversion = \"1.2.3\"\n[[deps.Bar]]\nuuid = \"y\"\n",
        )
        @test manifest_packages(v2) == Dict("Foo" => "1.2.3", "Bar" => "")
        v1 = joinpath(dir, "v1.toml")
        write(v1, "[[Foo]]\nuuid = \"x\"\nversion = \"0.5.0\"\n")
        @test manifest_packages(v1) == Dict("Foo" => "0.5.0")
    end
end

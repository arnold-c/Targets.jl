## File targets
##
## A file target returns the path (or paths) of files it owns; its value is their
## contents. Nothing is stored as an object: the record keeps the paths, and per
## path a cheap stat signature (to skip re-reading unchanged files) and a content
## hash (which alone decides whether anything changed).

file_root(root::AbstractString) = String(root)
file_root(::Nothing) = error("file targets need the project root; pass `root`")

resolve_path(root::AbstractString, path::AbstractString) = isabspath(path) ?
    String(path) :
    joinpath(root, path)

"A path relative to the project root with `/` separators, or absolute (with a warning) if outside it."
function relative_to_root(root::AbstractString, path::AbstractString)
    absolute = normpath(abspath(resolve_path(root, path)))
    base = normpath(abspath(root))
    prefix = rstrip(base, ['/', '\\']) * Base.Filesystem.path_separator
    if startswith(absolute, prefix)
        return replace(relpath(absolute, base), '\\' => '/')
    end
    @warn "file target path is outside the project, so it is stored as an absolute path and the project cannot be moved" path = absolute maxlog = 1 _id = Symbol(
        absolute,
    )
    return absolute
end

"""
    normalize_file_value(t, value, root)

The `(paths, scalar)` a file target returned: a string or a collection of strings,
all of which must exist. `scalar` records whether a single path was returned, so
consumers receive the same shape.
"""
function normalize_file_value(t::Target, value, root::AbstractString)
    scalar = value isa AbstractString
    items = scalar ? [value] : value
    (items isa AbstractVector && all(x -> x isa AbstractString, items)) ||
        error(
            "target `$(t.name)` is a file target, so its function must return a path or a " *
                "vector of paths, not a `$(typeof(value))`",
        )
    paths = String[relative_to_root(root, p) for p in items]
    missing_paths = filter(p -> !ispath(resolve_path(root, p)), paths)
    isempty(missing_paths) ||
        error(
            "target `$(t.name)` returned paths that do not exist: $(join(missing_paths, ", "))",
        )
    return paths, scalar
end

function walk_files(dir::AbstractString)
    return sort!(
        String[relpath(joinpath(r, f), dir) for (r, _, fs) in walkdir(dir) for f in fs]
    )
end

"Cheap fingerprint of a file's (or directory's files') size and modification time."
function file_signature(path::AbstractString)
    isdir(path) || return string(filesize(path), ":", mtime(path))
    entries = (
        string(rel, "=", filesize(joinpath(path, rel)), ":", mtime(joinpath(path, rel)))
        for rel in walk_files(path)
    )
    return bytes2hex(SHA.sha256(join(entries, ";")::String))
end

"Content hash of a file, or of a directory: every file under it, by sorted relative path."
function path_hash(path::AbstractString)
    isdir(path) || return hash_file(path)
    entries = (
        string(replace(rel, '\\' => '/'), '\0', hash_file(joinpath(path, rel)))
        for rel in walk_files(path)
    )
    return bytes2hex(SHA.sha256(join(entries, "\n")::String))
end

struct FileState
    signatures::Vector{String}
    hashes::Vector{String}
    value_hash::String
end

"Value hash of a file target's files; includes the paths, so renaming counts as a change."
function files_value_hash(files::Vector{String}, hashes::Vector{String})
    return bytes2hex(SHA.sha256(
        join((string(f, '\0', h) for (f, h) in zip(files, hashes)), "\n")::String,
    ))
end

files_exist(root::AbstractString, record::Record) = all(
    f -> ispath(resolve_path(root, f)),
    record.files,
)

"""
    file_state(root, files, previous = nothing)

Current signatures and hashes of `files`. A file whose signature matches the one
in `previous` (a [`Record`](@ref) of the same files) reuses its stored hash instead of
being read again.
"""
function file_state(root::AbstractString, files::Vector{String}, previous = nothing)
    signatures = String[]
    hashes = String[]
    reusable = previous !== nothing && previous.files == files
    for (i, f) in enumerate(files)
        path = resolve_path(root, f)
        signature = file_signature(path)
        push!(signatures, signature)
        unchanged = reusable &&
            get(previous.file_signatures, i, nothing) == signature &&
            i <= length(previous.file_hashes)
        push!(hashes, unchanged ? previous.file_hashes[i] : path_hash(path))
    end
    return FileState(signatures, hashes, files_value_hash(files, hashes))
end
file_state(root::AbstractString, record::Record) = file_state(root, record.files, record)

"The value consumers of a file target receive: its path, or its paths if it returned several."
file_value(record::Record) = record.file_scalar ? first(record.files) : copy(record.files)

@testmodule FileFixtures begin
    using Targets
    export write_files

    "Create files under `dir` from a `relative path => contents` list."
    function write_files(dir, pairs...)
        for (rel, contents) in pairs
            path = joinpath(dir, rel)
            mkpath(dirname(path))
            write(path, contents)
        end
    end
end

@testitem "file hashing: content decides, paths and directory contents count" setup = [
    FileFixtures,
] begin
    using Targets: path_hash, file_state, file_signature, files_value_hash
    mktempdir() do dir
        write_files(
            dir,
            "a.txt" => "one",
            "b.txt" => "one",
            "d/x.txt" => "x",
            "d/y.txt" => "y",
        )
        a, b = joinpath(dir, "a.txt"), joinpath(dir, "b.txt")
        @test path_hash(a) == path_hash(b) # same bytes, same hash
        write(a, "two")
        @test path_hash(a) != path_hash(b)
        d = joinpath(dir, "d")
        before = path_hash(d)
        write(joinpath(d, "y.txt"), "changed")
        @test path_hash(d) != before
        write(joinpath(d, "y.txt"), "y")
        @test path_hash(d) == before
        mv(joinpath(d, "y.txt"), joinpath(d, "z.txt")) # a rename inside the directory
        @test path_hash(d) != before
        # the stat signature lets an unchanged file reuse its hash
        s1 = file_state(dir, ["b.txt"])
        record = Targets.Record(;
            files = ["b.txt"],
            file_signatures = s1.signatures,
            file_hashes = ["not read"],
        )
        @test file_state(dir, ["b.txt"], record).hashes == ["not read"]
        write(b, "different")
        @test file_state(dir, ["b.txt"], record).hashes != ["not read"]
        @test files_value_hash(["x"], ["h"]) !=
            files_value_hash(["y"], ["h"]) # renaming counts
    end
end

@testitem "normalize_file_value validates and relativizes paths" setup = [
    FileFixtures,
] begin
    using Targets: normalize_file_value
    mktempdir() do dir
        write_files(dir, "data/raw.csv" => "1,2")
        t = target(:f, () -> 1; format = :file)
        @test normalize_file_value(t, "data/raw.csv", dir) == (["data/raw.csv"], true)
        @test normalize_file_value(t, joinpath(dir, "data", "raw.csv"), dir) ==
            (["data/raw.csv"], true)
        @test normalize_file_value(t, ["data/raw.csv", "data"], dir) ==
            (["data/raw.csv", "data"], false)
        @test_throws "do not exist" normalize_file_value(t, "nope.csv", dir)
        @test_throws "must return a path" normalize_file_value(t, 42, dir)
        mktempdir() do elsewhere
            write_files(elsewhere, "x.txt" => "x")
            outside = joinpath(elsewhere, "x.txt")
            result = @test_logs (:warn, r"outside the project") normalize_file_value(
                t,
                outside,
                dir,
            )
            @test result == ([outside], true)
        end
    end
end

@testitem "editing an input file rebuilds its consumers; touching it does not" setup = [
    SourceFixtures,
    FileFixtures,
] begin
    mktempdir() do dir
        code = """
        p = tar_pipeline(
            target(:raw_file, () -> "data/raw.csv"; format = :file),
            target(:raw_data, raw_file -> read(raw_file, String)),
            target(:rows, raw_data -> length(split(raw_data, "\\n"; keepempty = false))),
            target(:other, () -> 1),
        )
        """
        write_files(dir, "data/raw.csv" => "a\nb\n")
        @test build_source(code, dir).built == [:raw_file, :raw_data, :rows, :other]
        @test read_values(dir, :raw_file, :rows) == ("data/raw.csv", 2)
        @test isempty(build_source(code, dir).built)
        touch(joinpath(dir, "data", "raw.csv")) # new mtime, same bytes
        @test isempty(build_source(code, dir).built)
        write_files(dir, "data/raw.csv" => "a\nb\nc\n")
        s = build_source(code, dir)
        @test s.built == [:raw_file, :raw_data, :rows]
        @test s.skipped == [:other]
        @test read_values(dir, :rows) == (3,)
        @test isempty(outdated_source(code, dir))
        write_files(dir, "data/raw.csv" => "a\nb\nc\n") # bytes identical again
        @test isempty(build_source(code, dir).built)
    end
end

@testitem "a deleted or edited output file rebuilds the target that wrote it" setup = [
    SourceFixtures,
    FileFixtures,
] begin
    mktempdir() do dir
        code = """
        p = tar_pipeline(
            target(:numbers, () -> [1, 2, 3]),
            target(:report, numbers -> (mkpath("output"); write("output/sum.txt", string(sum(numbers))); "output/sum.txt"); format = :file),
            target(:summary, report -> parse(Int, read(report, String)) + 1),
        )
        """
        @test build_source(code, dir).built == [:numbers, :report, :summary]
        out = joinpath(dir, "output", "sum.txt")
        @test read(out, String) == "6"
        rm(out)
        s = build_source(code, dir)
        @test s.built == [:report] # same contents again: summary is cut off
        @test s.skipped == [:numbers, :summary]
        @test read(out, String) == "6"
        write(out, "999") # edited by hand
        s = build_source(code, dir)
        @test s.built == [:report]
        @test read(out, String) == "6"
    end
end

@testitem "file targets accept several paths and directories" setup = [
    SourceFixtures,
    FileFixtures,
] begin
    mktempdir() do dir
        code = """
        p = tar_pipeline(
            target(:inputs, () -> ["a.txt", "tables"]; format = :file),
            target(:count, inputs -> (length(inputs), sum(length(read(f, String)) for f in inputs if isfile(f)))),
        )
        """
        write_files(dir, "a.txt" => "abc", "tables/t1.txt" => "1", "tables/t2.txt" => "2")
        build_source(code, dir)
        @test read_values(dir, :inputs, :count) == (["a.txt", "tables"], (2, 3))
        write_files(dir, "tables/t3.txt" => "3") # a new file in the directory changes the hash
        @test build_source(code, dir).built == [:inputs, :count]
        @test isempty(build_source(code, dir).built)
        write_files(dir, "a.txt" => "abcd")
        @test build_source(code, dir).built == [:inputs, :count]
        @test read_values(dir, :count) == ((2, 4),)
    end
end

@testitem "a file target that forgets to write its file is an error" setup = [
    SourceFixtures,
    FileFixtures,
] begin
    mktempdir() do dir
        code = "p = tar_pipeline(target(:f, () -> \"missing.txt\"; format = :file))"
        @test_throws "do not exist" build_source(code, dir)
    end
end

## URL targets
##
## A URL target returns one or more URLs. Nothing is downloaded: like a file
## target, its record keeps the URLs and a hash per URL, here taken from an HTTP
## `HEAD` request (the ETag, else Last-Modified plus Content-Length). URLs are
## re-checked on every run; consumers receive the URL(s). When a URL cannot be
## reached, the recorded hash is kept with a warning, so working offline does not
## fail or rebuild anything.

"Whether `t` stores references to external data (files or URLs) instead of an object."
is_external(t) = t.format === :file || t.format === :url

"""
    normalize_url_value(t, value)

The `(urls, scalar)` a URL target returned: a string or a vector of strings,
each an `http(s)` URL.
"""
function normalize_url_value(t::Target, value)
    scalar = value isa AbstractString
    items = scalar ? [value] : value
    (
        items isa AbstractVector &&
            all(x -> x isa AbstractString && occursin(r"^https?://"i, x), items)
    ) ||
        error(
            "target `$(t.name)` is a URL target, so its function must return an http(s) URL " *
                "or a vector of them, got `$(repr(value))`",
        )
    return String[u for u in items], scalar
end

"""
    url_hash(url)

A hash of what a `HEAD` request says about `url`: its ETag, or else its
Last-Modified and Content-Length headers. Errors if the URL cannot be reached,
answers with an error status, or sends none of these headers.
"""
function url_hash(url::AbstractString)
    response = Downloads.request(url; method = "HEAD")
    response.status < 400 || error("HEAD $url answered with status $(response.status)")
    headers = Dict(lowercase(k) => v for (k, v) in response.headers)
    fields = haskey(headers, "etag") ? ("etag",) : ("last-modified", "content-length")
    any(f -> haskey(headers, f), fields) ||
        error(
            "HEAD $url sent no ETag or Last-Modified header, so changes cannot be detected",
        )
    return canonical_hash(Tuple(f => get(headers, f, "") for f in fields))
end

"""
    url_state(urls, previous = nothing)

Current hashes of `urls`. With a `previous` record of the same URLs, a URL that
cannot be reached keeps its recorded hash (with a warning) instead of failing.
"""
function url_state(urls::Vector{String}, previous = nothing)
    hashes = map(enumerate(urls)) do (i, url)
        try
            return url_hash(url)
        catch e
            e isa InterruptException && rethrow()
            (previous === nothing || previous.files != urls) && rethrow()
            @warn "could not check $url, so its recorded state is kept" exception = e maxlog = 1 _id = Symbol(
                url,
            )
            return previous.file_hashes[i]
        end
    end
    return FileState(String[], hashes, files_value_hash(urls, hashes))
end
url_state(record::Record) = url_state(record.files, record)

@testmodule UrlFixtures begin
    using HTTP, Sockets
    export serve

    "Serve `pages[]` (path => (etag, body)) on a free local port while `f(base_url)` runs."
    function serve(f, pages::Ref)
        port, probe = Sockets.listenany(ip"127.0.0.1", 18000)
        close(probe) # only used to find a free port
        server = HTTP.serve!("127.0.0.1", Int(port)) do request
            page = get(pages[], request.target, nothing)
            page === nothing && return HTTP.Response(404)
            return HTTP.Response(
                200,
                ["ETag" => page[1]],
                request.method == "HEAD" ? "" : page[2],
            )
        end
        try
            return f("http://127.0.0.1:$port")
        finally
            close(server)
        end
    end
end

@testitem "URL targets rebuild consumers when the resource changes" setup = [
    UrlFixtures,
] begin
    pages = Ref(Dict("/data" => ("\"v1\"", "one")))
    serve(pages) do base
        p = tar_pipeline(
            target(:source, () -> "$base/data"; format = :url),
            target(:size, source -> length(source)),
        )
        mktempdir() do dir
            store = joinpath(dir, "_targets")
            build() = tar_make(p; store, root = dir, io = devnull)
            @test build().built == [:source, :size]
            @test tar_read(:source; store) == "$base/data"
            @test isempty(build().built)
            pages[] = Dict("/data" => ("\"v2\"", "two"))
            @test tar_outdated(p; store, root = dir) ==
                [
                    (name = :source, reason = :url_changed),
                    (name = :size, reason = :upstream_outdated),
                ]
            @test build().built == [:source, :size]
            pages[] = Dict{String, Tuple{String, String}}()
            @test_logs (:warn, r"could not check") match_mode = :any @test isempty(
                build().built,
            )
        end
    end
end

@testitem "URL targets validate what they return" begin
    p = tar_pipeline(target(:u, () -> "not a url"; format = :url))
    mktempdir() do dir
        @test_throws "http(s) URL" tar_make(
            p;
            store = joinpath(dir, "_targets"),
            root = dir,
            io = devnull,
        )
    end
end

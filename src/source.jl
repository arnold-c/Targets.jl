## Locating the source of a method
##
## Methods are hashed by their *definition*, not by lowered code, so that hashes
## survive Julia upgrades. The definition is found by parsing the file the method
## came from and collecting the definition nodes that start on the method's line.
## CodeTracking supplies the current location, which stays correct under Revise
## even when edits above a method have shifted its line.

const PARSE_CACHE = Dict{String, Tuple{UInt, SyntaxNode}}()

"""
Parse `path`, reusing the last parse while the file's contents are unchanged.
Keyed by a content hash rather than the modification time, which can be too
coarse to notice two quick edits.
"""
function parsed_file(path::AbstractString)
    text = read(path, String)
    key = hash(text)
    cached = get(PARSE_CACHE, String(path), nothing)
    (cached !== nothing && cached[1] == key) && return cached[2]
    node = JuliaSyntax.parseall(SyntaxNode, text; filename = String(path))
    PARSE_CACHE[String(path)] = (key, node)
    return node
end

# `#f#12` is the body method of `f` that takes keyword arguments; `#12` and
# `#f##12` are anonymous functions.
const KWBODY_NAME = r"^#([A-Za-z_][A-Za-z_0-9!]*)#\d+$"

function definition_name(m::Method)
    s = string(m.name)
    km = match(KWBODY_NAME, s)
    km !== nothing && return Symbol(km.captures[1])
    return startswith(s, "#") ? nothing : m.name
end

"Name of the function defined by call signature `sig`, or `nothing`."
function signature_name(sig)
    sig isa Expr || return nothing
    if sig.head in (:where, :(::))
        return signature_name(sig.args[1])
    elseif sig.head == :call
        f = sig.args[1]
        f isa Symbol && return f
        # `Base.show` or `Foo.Bar.baz`
        if f isa Expr && f.head == :.
            last = f.args[end]
            last isa QuoteNode && return last.value
        end
        # `(::T)(x)` callable definitions and `Foo{T}(x)` constructors
        f isa Expr && f.head == :curly && f.args[1] isa Symbol && return f.args[1]
    end
    return nothing
end

lambda_arg(a::Symbol) = a
function lambda_arg(a::Expr)
    a.head in (:(::), :..., :kw) || return nothing
    return a.head == :(::) && length(a.args) == 1 ? nothing : lambda_arg(a.args[1])
end
lambda_arg(_) = nothing

"Argument names of an anonymous function expression; `nothing` entries are unnamed or destructured."
function lambda_argnames(lhs)
    lhs isa Symbol && return Union{Symbol, Nothing}[lhs]
    # `(xs...) -> ...` and `(x::T) -> ...` may parse without a surrounding tuple
    (lhs isa Expr && lhs.head in (:..., :(::))) &&
        return Union{Symbol, Nothing}[lambda_arg(lhs)]
    (lhs isa Expr && lhs.head == :tuple) || return nothing
    return Union{Symbol, Nothing}[
        lambda_arg(a)
        for a in lhs.args
        if !(a isa Expr && a.head == :parameters)
    ]
end

function names_match(candidate, actual::Vector{Symbol})
    candidate === nothing && return true # argument names not recoverable: do not exclude it
    length(candidate) == length(actual) || return false
    return all(
        i -> candidate[i] === nothing || candidate[i] === actual[i],
        eachindex(actual),
    )
end

# Line of the first statement in a lambda's body. Julia records this, not the
# line of the arrow, as the method's line for multi-line lambdas and `do` blocks.
function body_line(lambda::Expr)
    body = lambda.args[end]
    body isa Expr && body.head == :block || return nothing
    i = findfirst(a -> a isa LineNumberNode, body.args)
    return i === nothing ? nothing : body.args[i].line
end

# Each candidate is (kind, expression, detail) where expression is what gets hashed.
function classify(e::Expr, start::Integer, line::Integer)
    at_line(lambda) = start == line || body_line(lambda) == line
    if e.head in (:function, :(=)) && length(e.args) >= 1
        sig = e.args[1]
        if e.head == :function && sig isa Expr && sig.head == :tuple
            return at_line(e) ? (:anonymous, e, lambda_argnames(sig)) : nothing
        end
        name = signature_name(sig)
        (name === nothing || start != line) || return (:named, e, name)
    elseif e.head == :->
        return at_line(e) ? (:anonymous, e, lambda_argnames(e.args[1])) : nothing
    end
    return nothing
end

# A `do` node covers only `do args ... end` (the call is its parent), so rebuild
# the equivalent anonymous function from its argument tuple and body.
function classify_do(node::SyntaxNode, start::Integer, line::Integer)
    kids = children(node)
    kids === nothing && return nothing
    length(kids) >= 2 || return nothing
    lambda = Expr(:->, Expr(kids[1]), Expr(kids[2]))
    (start == line || body_line(lambda) == line) || return nothing
    return (:anonymous, lambda, lambda_argnames(lambda.args[1]))
end

const CANDIDATE_KINDS = (K"function", K"=", K"->", K"do")

function collect_candidates!(out, node::SyntaxNode, line::Integer)
    k = kind(node)
    if k in CANDIDATE_KINDS
        start = source_location(node)[1]
        # lambdas and `do` blocks may be identified by a line inside their span
        stop = k in (K"->", K"do") ?
            source_location(node.source, last_byte(node))[1] :
            start
        if start <= line <= stop
            c = k == K"do" ?
                classify_do(node, start, line) :
                classify(Expr(node), start, line)
            c === nothing || push!(out, c)
        end
    end
    kids = children(node)
    kids === nothing && return out
    for kid in kids
        collect_candidates!(out, kid, line)
    end
    return out
end

"""
    method_source(m::Method)

Definition expressions of `m` found by parsing its file, in source order, or
`nothing` if the file cannot be read or no definition is found on the method's
line. Several expressions are returned when definitions are ambiguous (for
example two lambdas with the same arguments on one line): hashing all of them is
conservative, so editing any of them rebuilds, but nothing stale is kept.
"""
function method_source(m::Method)
    loc = try
        CodeTracking.whereis(m)
    catch
        nothing
    end
    loc === nothing && return nothing
    file, line = loc
    isfile(file) || return nothing
    candidates = try
        collect_candidates!(Any[], parsed_file(file), line)
    catch e
        e isa InterruptException && rethrow()
        return nothing
    end
    name = definition_name(m)
    actual = _argnames(m)
    matching = filter(candidates) do (kind, _, detail)
        name === nothing ?
            (kind == :anonymous && names_match(detail, actual)) :
            (kind == :named && detail === name)
    end
    isempty(matching) && return nothing
    return Expr[e for (_, e, _) in matching]
end

"""
    lowered_source(m::Method)

Lowered code of `m` as plain data, for methods whose source cannot be found.
This depends on the Julia version, so callers must record that it was used.
"""
function lowered_source(m::Method)
    try
        ci = Base.uncompressed_ast(m)
        return (ci.code, ci.slotnames)
    catch e
        e isa InterruptException && rethrow()
        return nothing
    end
end

@testitem "method_source finds named functions and ignores formatting" setup = [
    SourceFixtures,
] begin
    using Targets: method_source, canonical_hash
    m, path = load_source(
        """
    f(x) = x + 1
    function g(x)
        # a comment
        x * 2
    end
    """,
    )
    f = only(method_source(only(methods(m.f))))
    @test f.head == :(=)
    @test canonical_hash(f) == canonical_hash(:(f(x) = x + 1))
    g = only(method_source(only(methods(m.g))))
    @test g.head == :function
    m2, _ = load_source(
        """
    f(x) = x +   1


    function g(x)
        x * 2   # moved and re-commented
    end
    """,
    )
    @test canonical_hash(method_source(only(methods(m2.g)))) == canonical_hash([g])
    @test canonical_hash(method_source(only(methods(m2.f)))) == canonical_hash([f])
end

@testitem "method_source distinguishes methods of one function by line" setup = [
    SourceFixtures,
] begin
    using Targets: method_source
    m, _ = load_source(
        """
    h(x::Int) = 1
    h(x::String) = 2
    struct P
        a::Int
        P(a, b) = new(a + b)
    end
    k(x; scale = 2) = x * scale
    """,
    )
    ms = sort(collect(methods(m.h)); by = x -> x.line)
    @test string.(method_source(ms[1])) != string.(method_source(ms[2]))
    @test only(method_source(only(methods(m.P)))).args[1].args[1] == :P
    # the keyword-argument body method maps back to its definition
    @test all(!isnothing, method_source.(collect(methods(m.k))))
end

@testitem "method_source separates lambdas by line and by arguments" setup = [
    SourceFixtures,
] begin
    using Targets: method_source
    m, _ = load_source(
        """
    fs = [x -> x + 1,
          y -> y + 2,
    ]
    both = (a -> a, b -> b)
    capture(f) = f
    lam = capture() do z
        z + 3
    end
    """,
    )
    src(f) = method_source(only(methods(f)))
    @test only(src(m.fs[1])).args[1] == :x
    @test only(src(m.fs[2])).args[1] == :y
    # two lambdas on one line with different argument names are told apart
    @test only(src(m.both[1])).args[1] == :a
    @test only(src(m.both[2])).args[1] == :b
    # a `do` block yields its lambda, not the surrounding call
    lam = only(src(m.lam))
    @test lam.head == :->
    @test lam.args[1] == Expr(:tuple, :z)
end

@testitem "method_source is nothing without a readable file" begin
    using Targets: method_source, lowered_source
    f = eval(Meta.parse("x -> x + 1")) # its file is `none`
    @test method_source(only(methods(f))) === nothing
    @test lowered_source(only(methods(f))) !== nothing
end

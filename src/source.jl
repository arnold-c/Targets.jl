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

# `#f#12` is the body method of `f` that takes keyword arguments (`f#12` for a
# closure before Julia 1.11); `#12` and `#f##12` are anonymous functions.
const KWBODY_NAME = r"^#?([A-Za-z_][A-Za-z_0-9!]*)#\d+$"

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
    elseif e.head == :macro && length(e.args) >= 1
        # `macro m(ex) ... end` defines the method `@m`
        name = signature_name(e.args[1])
        (name === nothing || start != line) || return (:named, e, Symbol('@', name))
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

const CANDIDATE_KINDS = (K"function", K"=", K"->", K"do", K"macro")

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

# Forms that define methods without writing them out: macro calls (`@kwdef`
# constructors and their keyword bodies, `@eval`, ...) and `struct` (default
# constructors).
const GENERATING_KINDS = (K"macrocall", K"struct")

"""
    generating_form(node, line)

The innermost macro call or `struct` in `node` spanning `line`, for methods
with no definition of their own; a `struct` that is an argument of a macro call
(`@kwdef struct ... end`) is reported as the call, since the macro decides
what the definitions are. `nothing` if there is none.
"""
function generating_form(node::SyntaxNode, line::Integer, parent = nothing)
    k = kind(node)
    found = nothing
    if k in GENERATING_KINDS
        start = source_location(node)[1]
        stop = source_location(node.source, last_byte(node))[1]
        start <= line <= stop || return nothing
        wrapped = k == K"struct" && parent !== nothing && kind(parent) == K"macrocall"
        found = wrapped ? parent : node
    end
    kids = children(node)
    kids === nothing && return found
    for kid in kids
        inner = generating_form(kid, line, node)
        inner === nothing || return inner
    end
    return found
end

"""
    method_source(m::Method)

Definition expressions of `m` found by parsing its file, in source order, or
`nothing` if the file cannot be read or no definition is found on the method's
line. Several expressions are returned when definitions are ambiguous (for
example two lambdas with the same arguments on one line): hashing all of them is
conservative, so editing any of them rebuilds, but nothing stale is kept.
Methods that a macro or `struct` generates (`@kwdef` constructors and their
keyword bodies, default constructors) have no definition of their own; their
source is the macro call or `struct` that generates them (`generating_form`),
provided it names them (`generates`).
"""
# Where a method is defined. Revise (through CodeTracking) keeps named methods'
# lines current after edits, but it cannot map anonymous functions and closures
# (gensym'd names starting with `#`) and warns about each one, so those use the
# location Julia recorded. A named function defined inside a `let` block or a
# function is a closure with a plain method name: Revise may know its current
# location, so it is asked, but quietly, falling back to the recorded location.
function method_location(m::Method)
    startswith(string(m.name), '#') && return recorded_location(m)
    is_generated_function_type(method_function_type(m)) || return CodeTracking.whereis(m)
    found = ScopedValues.with_logger(() -> CodeTracking.whereis(m), Logging.NullLogger())
    return something(found, recorded_location(m))
end

"The file and line Julia recorded for `m`, or `nothing` without a file."
function recorded_location(m::Method)
    file = Base.fixup_stdlib_path(string(m.file))
    return isabspath(file) ? (file, Int(m.line)) : nothing
end

"The type of the function `m` is a method of, from its signature, or `nothing`."
function method_function_type(m::Method)
    sig = Base.unwrap_unionall(m.sig)
    sig isa DataType && !isempty(sig.parameters) || return nothing
    return Base.unwrap_unionall(sig.parameters[1])
end

function method_source(m::Method)
    loc = try
        method_location(m)
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
    isempty(matching) || return Expr[e for (_, e, _) in matching]
    # Anonymous methods have no name to check the form against: lowered code.
    name === nothing && return nothing
    moved = moved_closure_source(m, file, name, actual)
    moved === nothing || return moved
    generated = generating_form(parsed_file(file), line)
    generated === nothing && return nothing
    expr = Expr(generated)
    return generates(expr, name) ? Expr[expr] : nothing
end

"""
    moved_closure_source(m, file, name, argnames)

The definition of the closure method `m` (a function named `name` inside a
function or `let` block) when the line Julia recorded for it no longer holds
it, found by name and argument names anywhere in `file`. Revise moves named
methods' lines with their file but cannot map closures, so after an edit above
the code that creates a closure, the closure keeps its old line, while a fresh
session finds its definition there; without this, the two sessions would hash
the closure differently. `nothing` unless exactly one definition matches and
`m` still runs what the code creating it now makes (`stale_closure`).
"""
function moved_closure_source(m::Method, file, name::Symbol, argnames)
    is_generated_function_type(method_function_type(m)) || return nothing
    matching = filter(
        e -> positional_match(definition_argnames(e), argnames),
        collect_named!(Expr[], parsed_file(file), name),
    )
    length(matching) == 1 || return nothing
    return stale_closure(m) ? nothing : matching
end

"""
Whether a definition with positional argument names `candidate` can define a
method with argument names `actual`: the same names, or for a keyword body,
whose arguments are the keywords, an unnamed separator, then the positional
ones, the same names at the end.
"""
function positional_match(candidate, actual::Vector{Symbol})
    candidate === nothing && return true
    p, n = length(candidate), length(actual)
    n == p && return names_match(candidate, actual)
    return n > p &&
        actual[n - p] === Symbol("") &&
        names_match(candidate, actual[(n - p + 1):n])
end

"""
Whether the closure method `m` runs other code than the newest closure of its
kind: the code creating it has been evaluated again since `m` was made, and now
makes a closure that does something else. Revise evaluates a function again when
it is edited, but not a `const` holding a closure the function made, which then
runs the old code, so the current definition does not describe it. (Revise also
evaluates unchanged closure definitions to find their signatures; those make
closures that do the same thing, and `m` is not stale.)
"""
stale_closure(m::Method) = (newest = newest_closure_method(m)) !== m &&
    lowered_fingerprint(newest) != lowered_fingerprint(m)

"""
The newest method with `m`'s name and argument names among the closure types
named like `m`'s up to Julia's counters: each evaluation of the code that
creates a closure makes such a type.
"""
function newest_closure_method(m::Method)
    T = method_function_type(m)
    mod = parentmodule(T)
    own = stable_name(nameof(T))
    argnames = _argnames(m)
    newest = m
    for n in names(mod; all = true)
        stable_name(n) === own || continue
        for g in closure_methods(GlobalRef(mod, n))
            (same_method_name(g, m) && _argnames(g) == argnames) || continue
            g.primary_world > newest.primary_world && (newest = g)
        end
    end
    return newest
end

# Method names up to Julia's counters: before Julia 1.11 a closure's keyword body
# is named like `f#12`, with a counter that changes each time it is made.
same_method_name(a::Method, b::Method) = strip_counters(String(a.name)) ==
    strip_counters(String(b.name))

"Definitions of functions named `name` anywhere in `node`, in source order."
function collect_named!(out::Vector{Expr}, node::SyntaxNode, name::Symbol)
    k = kind(node)
    kids = children(node)
    # Short-form definitions are `=` nodes whose left-hand side is a signature.
    defines = k == K"function" ||
        (k == K"=" && kids !== nothing && kind(first(kids)) in SIGNATURE_KINDS)
    if defines
        start = source_location(node)[1]
        c = classify(Expr(node), start, start)
        (c !== nothing && c[1] == :named && c[3] === name) && push!(out, c[2])
    end
    kids === nothing && return out
    for kid in kids
        collect_named!(out, kid, name)
    end
    return out
end

const SIGNATURE_KINDS = (K"call", K"where", K"::")

"Positional argument names of a named definition; `nothing` entries are unnamed or destructured."
function definition_argnames(e::Expr)
    sig = e.args[1]
    while sig isa Expr && sig.head in (:where, :(::))
        sig = sig.args[1]
    end
    (sig isa Expr && sig.head == :call) || return nothing
    return Union{Symbol, Nothing}[
        lambda_arg(a)
        for a in sig.args[2:end]
        if !(a isa Expr && a.head == :parameters)
    ]
end

"""
    generates(form::Expr, name::Symbol)

Whether a `generating_form` can generate the methods of `name`: a `struct`
called `name` (its constructors), a macro call wrapping one (`@kwdef`), or any
other macro call that mentions `name` (`@eval`). This keeps a stale line from
hashing an unrelated form that now occupies it; the method then falls back to
lowered code.
"""
function generates(form::Expr, name::Symbol)
    form.head == :struct && return struct_name(form) === name
    form.head == :macrocall || return false
    i = findfirst(a -> a isa Expr && a.head == :struct, form.args)
    return i === nothing ? mentions(form, name) : struct_name(form.args[i]) === name
end

"The name of the type a `struct` expression defines."
function struct_name(form::Expr)
    sig = form.args[2]
    while sig isa Expr && sig.head in (:<:, :curly)
        sig = sig.args[1]
    end
    return sig
end

mentions(x::Symbol, name::Symbol) = x === name
mentions(x::QuoteNode, name::Symbol) = mentions(x.value, name)
# `::Bool`: inference gives up on the recursion, and `any` of a non-Bool may be `missing`
mentions(x::Expr, name::Symbol) = any(a -> mentions(a, name)::Bool, x.args)
mentions(_, ::Symbol) = false

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
    JETChecks,
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
    @test_call method_source(only(methods(m.f)))
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

@testitem "method_source gives generated methods the macro call or struct that generates them" setup = [
    SourceFixtures,
] begin
    using Targets: method_source
    m, _ = load_source(
        """
    \"\"\"A documented struct.\"\"\"
    Base.@kwdef struct K
        a::Int = 1
        b::Float64 = 2.0
    end
    struct P
        x::Int
    end
    macro twice(ex)
        :(2 * \$(esc(ex)))
    end
    """,
    )
    body = only(n for n in names(m; all = true) if occursin(r"^#K#\d+$", string(n)))
    kwdef = [
        method_source.(methods(m.K))
        [method_source(only(methods(getfield(m, body))))]
    ]
    # constructors and keyword body: the macro call, which wraps the struct but
    # not its docstring
    @test all(src -> only(src).head == :macrocall, kwdef)
    @test all(src -> only(src).args[end].head == :struct, kwdef)
    @test all(meth -> only(method_source(meth)).head == :struct, methods(m.P))
    @test only(method_source(only(methods(getfield(m, Symbol("@twice")))))).head == :macro
end

@testitem "the generated-method fallback only accepts forms that generate the method" begin
    using Targets: generates
    @test generates(
        :(
            struct P{T} <: Number
                x::T
            end
        ),
        :P,
    )
    @test !generates(
        :(
            struct P
                x
            end
        ),
        :Q,
    )
    kwdef = :(
        Base.@kwdef struct K
            a::Int = 1
        end
    )
    @test generates(kwdef, :K)
    @test !generates(kwdef, :a) # a field of the struct, not the type
    @test generates(:(@eval f(x) = 1), :f)
    @test !generates(:(@eval g(x) = 1), :f)
end

@testitem "closures with plain names ask CodeTracking quietly" setup = [
    SourceFixtures,
] begin
    using Targets: method_location, method_source
    CodeTracking = Targets.CodeTracking
    m, path = load_source(
        """
    const cached = let store = Dict{Int, Int}()
        function lookup(x)
            get!(store, x, 2x)
        end
    end
    """,
    )
    meth = only(methods(m.cached))
    @test meth.name == :lookup # a closure whose method has a plain name
    # Revise warns when it cannot map a closure; simulate it.
    previous = CodeTracking.method_lookup_callback[]
    CodeTracking.method_lookup_callback[] = _ -> @warn "signature was not found"
    try
        @test_logs method_location(meth)
        file, line = method_location(meth)
        @test basename(file) == basename(path) && line == 2
    finally
        CodeTracking.method_lookup_callback[] = previous
    end
    @test only(method_source(meth)).head == :function
end

@testitem "a moved closure is found by name until the code creating it runs again" setup = [
    SourceFixtures,
] begin
    using Targets: method_source, canonical_hash
    factory(; name = "cache") = """
    function system_cache(build)
        $name = Dict{Any, Any}()
        return function cached(args...; series)
            get!(() -> build(args..., series), $name, args)
        end
    end
    """
    code(header = "") = header * factory() * "const CACHED = system_cache(+)\n"
    # the closure's methods and those of what it captured (its keyword body)
    closure_methods(c) = [
        collect(methods(c))
        [
            x
            for i in 1:nfields(c)
            for f in (getfield(c, i),)
            if f isa Function
            for x in methods(f)
        ]
    ]
    hashes(c) = [canonical_hash(method_source(x)) for x in closure_methods(c)]
    m, path = load_source(code())
    @test all(x -> only(method_source(x)).head == :function, closure_methods(m.CACHED))
    loaded = hashes(m.CACHED)
    # What Revise leaves after an edit above the factory: the file has moved on,
    # and the closure keeps the lines recorded when it was made.
    moved = code("# a\n# b\nhelper() = 1\n")
    write(path, moved)
    @test hashes(m.CACHED) == loaded
    # a fresh session, finding the definitions at their lines, agrees
    fresh, _ = load_source(moved)
    @test hashes(fresh.CACHED) == loaded
    # Once the factory is evaluated again (Revise does so when it is edited),
    # the closure kept in the `const` runs the old code: no source for what
    # changed.
    Core.eval(m, Meta.parse(factory(; name = "store")))
    @test any(x -> method_source(x) === nothing, closure_methods(m.CACHED))
    # evaluating it again unchanged (as Revise does to find signatures) does not
    m2, path2 = load_source(code())
    write(path2, moved)
    Core.eval(m2, Meta.parse(factory()))
    @test hashes(m2.CACHED) == loaded
end

@testitem "method_source is nothing without a readable file" begin
    using Targets: method_source, lowered_source
    f = eval(Meta.parse("x -> x + 1")) # its file is `none`
    @test method_source(only(methods(f))) === nothing
    @test lowered_source(only(methods(f))) !== nothing
end

## Recursive discovery of the user code a target can reach
##
## A target's `code_hash` covers every function, type and global defined in user
## code that its function can reach. "User code" means a source file under the
## project root or under one of the pipeline's `track` locations; Base, stdlibs and
## installed packages are covered by the Manifest check instead.

"Normalized directory prefixes that count as user code."
function user_roots(root::AbstractString, track)
    dirs = String[abspath(root)]
    for entry in track
        if entry isa Module
            dir = pkgdir(entry)
            dir === nothing &&
                error("cannot find the package directory of tracked module `$entry`")
            push!(dirs, dir)
        else
            push!(dirs, abspath(String(entry)))
        end
    end
    return [rstrip(normpath(d), ['/', '\\']) * Base.Filesystem.path_separator for d in dirs]
end

function is_user_file(file, roots::Vector{String})
    f = String(file)
    isabspath(f) || return false
    path = normpath(f) # a new name: reassigning `f` would box it in the closure
    return any(r -> startswith(path, r), roots)
end

function is_user_module(mod::Module, roots::Vector{String})
    root = Base.moduleroot(mod)
    root === Main && return true
    (root === Base || root === Core) && return false
    path = pathof(root)
    return path !== nothing && is_user_file(path, roots)
end

## Earlier loads of a pipeline script
##
## Each load of a script goes into a fresh module, and the methods it defined
## stay in the method tables of the functions it extended (every keyword
## function adds one to `Core.kwcall`). Once a script is loaded again, the
## earlier module's methods describe old code: they are not user code any more.

const LATEST_SCRIPTS = Dict{String, Module}()
const SUPERSEDED_SCRIPTS = Base.IdSet{Module}()
const SCRIPTS_LOCK = ReentrantLock()

"Record that `m` holds the latest load of the pipeline script at `path`."
function register_script!(path::AbstractString, m::Module)
    lock(SCRIPTS_LOCK) do
        old = get(LATEST_SCRIPTS, abspath(path), nothing)
        old === nothing || push!(SUPERSEDED_SCRIPTS, old)
        LATEST_SCRIPTS[abspath(path)] = m
    end
    return m
end

"Whether `mod` is (inside) a script module that a later load replaced."
function superseded(mod::Module)
    lock(SCRIPTS_LOCK) do
        while true
            mod in SUPERSEDED_SCRIPTS && return true
            parent = parentmodule(mod)
            parent === mod && return false
            mod = parent
        end
    end
end

is_user_method(m::Method, roots::Vector{String}) = is_user_file(m.file, roots) &&
    !superseded(m.module)

struct MethodInfo
    hash::CommandHash
    refs::Vector{Tuple{Module, Symbol}}
end

"""
    Discovery(roots)

Per-run memo for code discovery: parsed methods are shared by all targets, and
`files` collects every user source file reached (for the stale-session check).
"""
struct Discovery
    roots::Vector{String}
    infos::Dict{Method, MethodInfo}
    files::Set{String}
end
Discovery(roots::Vector{String}) = Discovery(
    roots,
    Dict{Method, MethodInfo}(),
    Set{String}(),
)

## Collecting the names an expression refers to

# The module may have been defined after the running code was compiled (for
# example a script included by `tar_make`), so read bindings in the latest world.
latest_isdefined(mod::Module, name::Symbol) = Base.invokelatest(isdefined, mod, name)
latest_getglobal(mod::Module, name::Symbol) = Base.invokelatest(getglobal, mod, name)

function resolve_module(mod::Module, ex)
    ex isa Module && return ex
    ex isa GlobalRef && return resolve_module(ex.mod, ex.name)
    if ex isa Symbol
        latest_isdefined(mod, ex) || return nothing
        v = latest_getglobal(mod, ex)
        return v isa Module ? v : nothing
    end
    if ex isa Expr && ex.head == :. && length(ex.args) == 2 && ex.args[2] isa QuoteNode
        parent = resolve_module(mod, ex.args[1])
        return parent === nothing ? nothing : resolve_module(parent, ex.args[2].value)
    end
    return nothing
end

collect_refs!(refs, mod::Module, x::Symbol) = push!(refs, (mod, x))
collect_refs!(refs, ::Module, x::GlobalRef) = push!(refs, (x.mod, x.name))
collect_refs!(refs, ::Module, ::QuoteNode) = refs
collect_refs!(refs, ::Module, _) = refs
function collect_refs!(refs, mod::Module, x::Expr)
    x.head == :quote && return refs
    if x.head == :. && length(x.args) == 2
        lhs, rhs = x.args
        owner = resolve_module(mod, lhs)
        if owner !== nothing && rhs isa QuoteNode
            push!(refs, (owner, rhs.value)) # `Mod.name`
        elseif rhs isa QuoteNode
            collect_refs!(refs, mod, lhs) # field access: `name` is not a binding
        else
            collect_refs!(refs, mod, lhs) # broadcast call `f.(args)`
            collect_refs!(refs, mod, rhs)
        end
        return refs
    end
    start = x.head == :macrocall ? 2 : 1 # an unexpanded macro's name is not a reference
    for a in x.args[start:end]
        collect_refs!(refs, mod, a)
    end
    return refs
end

# Lowered code refers to globals through `GlobalRef`s, so no resolution by name is needed.
# A keyword call lowers to `Core.kwcall(kwargs, f, args...)`, which names `f` too;
# following `Core.kwcall` itself would reach every keyword method there is.
collect_lowered_refs!(refs, x::GlobalRef) = x == GlobalRef(Core, :kwcall) ?
    refs :
    push!(refs, (x.mod, x.name))
collect_lowered_refs!(refs, x::Expr) = foreach(a -> collect_lowered_refs!(refs, a), x.args)
collect_lowered_refs!(refs, x::AbstractVector) = foreach(
    a -> collect_lowered_refs!(refs, a),
    x,
)
collect_lowered_refs!(refs, x::Core.ReturnNode) = isdefined(x, :val) ?
    collect_lowered_refs!(refs, x.val) :
    refs
collect_lowered_refs!(refs, x::Core.GotoIfNot) = collect_lowered_refs!(refs, x.cond)
collect_lowered_refs!(refs, _) = refs

"""
Macros an unexpanded expression calls, so that user-defined macros are followed
like functions: what they generate depends on their definitions, which the
expanded code no longer names.
"""
collect_macro_refs!(refs, ::Module, _) = refs
function collect_macro_refs!(refs, mod::Module, x::Expr)
    x.head == :quote && return refs
    x.head == :macrocall && collect_refs!(refs, mod, x.args[1]) # `@m` or `A.@m`
    foreach(a -> collect_macro_refs!(refs, mod, a), x.args)
    return refs
end

# Macros are expanded only to *find* callees: the hash itself is of the
# unexpanded source, because Base macros may expand differently across versions.
function expand_for_refs(mod::Module, expr)
    try
        return macroexpand(mod, expr)
    catch e
        e isa InterruptException && rethrow()
        return expr
    end
end

"""
    source_refs(mod, exprs)

The globals source `exprs` written in `mod` may refer to, as `(module, name)`:
the macros it calls and the names in its expanded code, without the names it
only ever binds itself (see [`global_names`](@ref)).
"""
function source_refs(mod::Module, exprs)
    refs = Tuple{Module, Symbol}[]
    expanded = [expand_for_refs(mod, e) for e in exprs]
    foreach(e -> collect_macro_refs!(refs, mod, e), exprs)
    foreach(e -> collect_refs!(refs, mod, e), expanded)
    globals = global_names(mod, vcat(exprs, expanded))
    globals === nothing && return refs
    return filter!(((owner, name),) -> owner !== mod || name in globals, refs)
end

"""
    global_names(mod, exprs)

The names `exprs` may use as globals of `mod`: those ExpressionExplorer finds
free in any of them (so not arguments, locals, or comprehension and `do`
variables), the functions they define, the macros they call, and every name
they write after a dot or as a `GlobalRef` into `mod`. A name a function binds
itself, such as an argument named like a global, is then not mistaken for that
global. `nothing` if the analysis fails, which keeps every name.
"""
function global_names(mod::Module, exprs)
    names = Set{Symbol}()
    try
        for e in exprs
            explicit_names!(names, mod, e)
            node = ExpressionExplorer.compute_reactive_node(without_globalrefs(e))
            for s in Iterators.flatten((node.references, node.definitions, node.macrocalls))
                union!(
                    names,
                    Symbol.(split(string(s), '.')),
                ) # `Mod.f` also names `Mod` and `f`
            end
            for f in node.funcdefs_without_signatures
                f isa Symbol ? push!(names, f) : union!(names, f)
            end
        end
    catch e
        e isa InterruptException && rethrow()
        return nothing
    end
    return names
end

# Names written as `GlobalRef`s into `mod`, or after a dot (`Mod.name`, `x.field`).
explicit_names!(names, mod::Module, x::GlobalRef) = x.mod === mod ?
    push!(names, x.name) :
    names
function explicit_names!(names, mod::Module, x::Expr)
    x.head == :. &&
        length(x.args) == 2 &&
        x.args[2] isa QuoteNode &&
        x.args[2].value isa Symbol &&
        push!(names, x.args[2].value)
    foreach(a -> explicit_names!(names, mod, a), x.args)
    return names
end
explicit_names!(names, ::Module, _) = names

without_globalrefs(::GlobalRef) = nothing
without_globalrefs(x::Expr) = Expr(x.head, map(without_globalrefs, x.args)...)
without_globalrefs(x) = x

function method_info(d::Discovery, m::Method)
    get!(d.infos, m) do
        exprs = method_source(m)
        exprs === nothing || return MethodInfo(method_hash(m), source_refs(m.module, exprs))
        refs = Tuple{Module, Symbol}[]
        lowered = lowered_source(m)
        lowered === nothing || collect_lowered_refs!(refs, lowered[1])
        return MethodInfo(method_hash(m), refs)
    end
end

## Walking the reachable code

mutable struct Walk
    d::Discovery
    own::Set{Method}
    queue::Vector{Method}
    seen_methods::Set{Method}
    seen_bindings::Set{Tuple{Module, Symbol}}
    seen_values::Base.IdSet{Any}
    entries::Vector{String}
end

function enqueue!(w::Walk, m::Method)
    m in w.seen_methods && return nothing
    is_user_method(m, w.d.roots) || return nothing
    push!(w.seen_methods, m)
    push!(w.queue, m)
    return nothing
end

function enqueue_user_methods!(w::Walk, v)
    ms = try
        collect(methods(v))
    catch e
        e isa InterruptException && rethrow()
        Method[]
    end
    foreach(m -> enqueue!(w, m), ms)
end

function type_hash(T::DataType)
    # Abstract types (and e.g. varargs tuples) have no definite fields.
    names = Base.datatype_fieldcount(T) === nothing ? Symbol[] : collect(fieldnames(T))
    return canonical_hash((
        stable_name(nameof(T)),
        nameof(supertype(T)),
        names,
        [type_string(ft) for ft in T.types],
        [p isa Type ? type_string(p) : string(p) for p in T.parameters],
        ismutabletype(T),
        isabstracttype(T),
    ))
end

function consider_type!(w::Walk, T)
    T0 = Base.unwrap_unionall(T)
    if T0 isa Union
        foreach(U -> consider_type!(w, U), Base.uniontypes(T0))
        return nothing
    end
    T0 isa DataType || return nothing
    T0 === Any && return nothing
    T0 in w.seen_values && return nothing
    push!(w.seen_values, T0)
    constructors = filter(m -> is_user_method(m, w.d.roots), collect(methods(T0)))
    (!isempty(constructors) || is_user_module(T0.name.module, w.d.roots)) || return nothing
    push!(w.entries, "type:$(T0.name.module).$(stable_name(T0.name.name))=$(type_hash(T0))")
    foreach(m -> enqueue!(w, m), constructors)
    consider_type!(w, supertype(T0))
    foreach(ft -> consider_type!(w, ft), T0.types)
    foreach(p -> p isa Type && consider_type!(w, p), T0.parameters)
    return nothing
end

function consider_binding!(w::Walk, mod::Module, name::Symbol)
    (mod, name) in w.seen_bindings && return nothing
    push!(w.seen_bindings, (mod, name))
    latest_isdefined(mod, name) || return nothing
    v = latest_getglobal(mod, name)
    v isa Module && return nothing
    if v isa Type
        consider_type!(w, v)
        return nothing
    end
    enqueue_user_methods!(w, v)
    v isa Function && consider_captures!(w, v)
    owner = Base.invokelatest(Base.binding_module, mod, name)
    if !(v isa Function) && is_user_module(owner, w.d.roots) && !(v in w.seen_values)
        push!(w.seen_values, v)
        push!(w.entries, "value:$owner.$name=$(canonical_hash(v))")
        consider_type!(w, typeof(v))
    end
    return nothing
end

"""
Follow the code a function value runs without naming it: what a closure (or a
callable struct such as `Base.Fix1`) captured. A closure made by a factory, as in
`const cached = make_cache(build)`, calls `build` through a captured variable, so
no source refers to it by name. Captured functions are followed like any other,
and captured types are considered; other captured values, such as a cache the
closure fills, are state rather than code and are not hashed.
"""
function consider_captures!(w::Walk, f)
    f in w.seen_values && return nothing
    push!(w.seen_values, f)
    for i in 1:nfields(f)
        isdefined(f, i) || continue
        v = getfield(f, i)
        if v isa Core.Box
            isdefined(v, :contents) || continue
            v = v.contents
        end
        if v isa Type
            consider_type!(w, v)
        elseif v isa Function
            enqueue_user_methods!(w, v)
            consider_captures!(w, v)
        end
    end
    return nothing
end

"""
Start walking from a target's own code. A function's methods are walked
(their hash is the command hash, so they add no entries). A `@target` is
followed from its expression, as for any method with source: its body's
lowered code would add what lowering introduces, such as `Core.kwcall`.
"""
function start_walk!(w::Walk, f, source)
    own = collect(methods(f))
    union!(w.own, own)
    union!(w.seen_methods, own)
    append!(w.queue, own)
    return nothing
end
start_walk!(w::Walk, r::RepCommand, source) = start_walk!(w, r.command, source)
function start_walk!(w::Walk, c::MacroCommand, source)
    foreach(m -> push!(w.d.files, String(m.file)), methods(c.body))
    for (mod, name) in source_refs(c.mod, [source])
        # names the target takes as dependencies or from its scope: see below
        (mod === c.mod && name in c.refs) || consider_binding!(w, mod, name)
    end
    consider_scope!(w, c)
    return nothing
end

"""
Follow the values a `@target` takes from where it was declared (not those of
its dependencies, which have the same names).
"""
function consider_scope!(w::Walk, c::MacroCommand)
    scope = scope_values(c)
    for (name, input) in zip(c.refs, c.inputs)
        input === nothing || continue
        v = getfield(scope, name)
        if latest_isdefined(c.mod, name) && latest_getglobal(c.mod, name) === v
            consider_binding!(w, c.mod, name)
        elseif v isa Type
            consider_type!(w, v) # a local; its value is part of the command hash
        elseif !(v isa Module)
            enqueue_user_methods!(w, v)
            v isa Function && consider_captures!(w, v)
        end
    end
    return nothing
end

"""
    code_hash(d::Discovery, t::Target)

Combined hash of every user function, type and global reachable from `t`'s
function, excluding that function itself (covered by its command hash).
"""
function code_hash(d::Discovery, t::Target)
    w = Walk(
        d,
        Set{Method}(),
        Method[],
        Set{Method}(),
        Set{Tuple{Module, Symbol}}(),
        Base.IdSet{Any}(),
        String[],
    )
    start_walk!(w, t.f, t.source)
    while !isempty(w.queue)
        m = pop!(w.queue)
        is_own = m in w.own
        info = method_info(d, m)
        push!(d.files, String(m.file))
        if !is_own
            info.hash.hash === nothing ||
                push!(
                    w.entries,
                    "method:$(m.module).$(stable_name(m.name))=$(info.hash.hash)",
                )
        end
        for (mod, name) in info.refs
            consider_binding!(w, mod, name)
        end
    end
    return combine_hashes(w.entries)
end

## Sessions that run old code

const LOADED_FILES = Dict{String, UInt}()

# Remember what each included file looked like when it was loaded.
function record_include(::Module, path::String)
    try
        LOADED_FILES[abspath(path)] = hash(read(path))
    catch e
        e isa InterruptException && rethrow()
    end
    return nothing
end

function __init__()
    filter!(!=(record_include), Base.include_callbacks)
    push!(Base.include_callbacks, record_include)
end

# Lets tests pretend Revise is (not) loaded: JET, used in the same test processes,
# loads Revise, which would otherwise switch the stale-session check off.
const REVISE_OVERRIDE = Ref{Union{Nothing, Bool}}(nothing)

function revise_loaded()
    override = REVISE_OVERRIDE[]
    override === nothing || return override
    return any(k -> k.name == "Revise", keys(Base.loaded_modules))
end

"Run `f()` as if Revise were (`assumed = true`) or were not loaded. For tests."
function with_revise_assumed(f, assumed::Bool)
    previous = REVISE_OVERRIDE[]
    REVISE_OVERRIDE[] = assumed
    try
        return f()
    finally
        REVISE_OVERRIDE[] = previous
    end
end

"Bring a loaded Revise up to date so that loaded code matches the files on disk."
function maybe_revise()
    revise_loaded() || return nothing
    for (id, mod) in Base.loaded_modules
        id.name == "Revise" && return Base.invokelatest(getproperty(mod, :revise))
    end
    return nothing
end

"""
    stale_files(files)

User source files that have changed on disk since this session loaded them. The
hashes would describe the new file while the session still runs the old code.
Files whose load this session did not observe are not reported.
"""
function stale_files(files)
    revise_loaded() && return String[]
    stale = String[]
    for f in sort!(collect(files))
        loaded = get(LOADED_FILES, abspath(f), nothing)
        loaded === nothing && continue
        (isfile(f) && hash(read(f)) != loaded) && push!(stale, f)
    end
    return stale
end

function check_stale_session(files)
    stale = stale_files(files)
    isempty(stale) && return nothing
    error(
        "these source files changed after they were loaded into this session:\n  " *
            join(stale, "\n  ") *
            "\nThe hashes would describe the new code while the session still runs the old code. " *
            "Load Revise, restart Julia, or build with `fresh = true`.",
    )
end

@testmodule CodeFixtures begin
    using Targets
    export reach, project_files

    "`code_hash` of target `:t` defined by `code`, treating `dir` as the project."
    function reach(code; dir = mktempdir(), track = [], target = :t)
        path = joinpath(dir, "src.jl")
        write(path, code)
        m = Module(:Fixture)
        Core.eval(m, :(using Targets))
        Base.include(m, path)
        t = Base.invokelatest(getproperty, m, target)
        d = Targets.Discovery(Targets.user_roots(dir, track))
        return Targets.code_hash(d, t), d
    end

    project_files(d) = d.files
end

@testitem "code_hash follows helpers however deeply they are called" setup = [
    CodeFixtures,
    JETChecks,
] begin
    code(; h2 = "x + 1", extra = "") = """
    $extra
    h2(x) = $h2
    h1(x) = h2(x) * 2
    unused(x) = x
    t = target(:a, () -> h1(1))
    """
    base, _ = reach(code())
    @test reach(code())[1] == base
    @test reach(code(; h2 = "x +   1", extra = "# comment\n\n"))[1] ==
        base # formatting and moving
    @test reach(code(; h2 = "x + 2"))[1] != base                  # two calls deep
    @test reach(code(; extra = "unused(x) = x + 100"))[1] == base # unreachable function
    _, d = reach(code())
    @test_call Targets.code_hash(d, target(:a, () -> 1))
end

@testitem "code_hash includes every method of a used function" setup = [CodeFixtures] begin
    one, _ = reach("h(x::Int) = 1\nt = target(:a, () -> h(1))")
    two, _ = reach("h(x::Int) = 1\nh(x::String) = 2\nt = target(:a, () -> h(1))")
    @test one != two
    swapped, _ = reach("h(x::String) = 2\nh(x::Int) = 1\nt = target(:a, () -> h(1))")
    @test swapped == two # independent of definition order
end

@testitem "code_hash follows functions passed as arguments, broadcasts and macros" setup = [
    CodeFixtures,
] begin
    pass(body) = reach(
        """
    clean_row(x) = $body
    t = target(:a, () -> map(clean_row, [1, 2]))
    """,
    )[1]
    @test pass("x + 1") != pass("x + 2")
    broadcast(body) = reach(
        """
    scale(x) = $body
    t = target(:a, () -> scale.([1, 2]))
    """,
    )[1]
    @test broadcast("x * 2") != broadcast("x * 3")
    macro_call(body) = reach(
        """
    scale(x) = $body
    t = target(:a, x -> @. scale(x))
    """,
    )[1]
    @test macro_call("x * 2") != macro_call("x * 3")
    qualified(body) = reach(
        """
    module Helpers
    scale(x) = $body
    end
    t = target(:a, () -> Helpers.scale(2))
    """,
    )[1]
    @test qualified("x * 2") != qualified("x * 3")
end

@testitem "code_hash ignores names a function binds itself, even if a global shares them" setup = [
    CodeFixtures,
] begin
    code(global_x, helpers) = reach(
        "x = $global_x\n$helpers\nt = target(:a, () -> g(2))",
    )[1]
    # arguments, locals, comprehension and `do` variables named like the global `x`
    shadowing = """
    inner(v) = map([1, 2]) do x
        x + v
    end
    g(x) = (y = [x for x in 1:x]; x + sum(y) + sum(inner(x)))
    """
    @test code(1, shadowing) == code(2, shadowing)
    # a function that does read the global is still tracked
    reading = "g(y) = y + x"
    @test code(1, reading) != code(2, reading)
    # so are names a macro hides from the unexpanded source
    macro_reading = "g(y) = @show(y + x)"
    @test code(1, macro_reading) != code(2, macro_reading)
end

@testitem "a target named like its upstream's variable keeps early cutoff" setup = [
    SourceFixtures,
] begin
    code(body) = """
    step(x, i) = x + i
    a = target(:a, () -> $body)
    b = target(:b, a -> step(a, 0))
    p = tar_pipeline([a, b])
    """
    mktempdir() do dir
        build_source(code("1"), dir)
        # new code for `a`, same value: `b` must not rebuild because the global `a` changed
        @test build_source(code("0 + 1"), dir).built == [:a]
    end
end

@testitem "code_hash tracks user globals and types but not Base" setup = [
    CodeFixtures,
] begin
    const_code(v) = reach("const ALPHA = $v\nt = target(:a, () -> ALPHA * 2)")[1]
    @test const_code("0.05") != const_code("0.10")
    @test const_code("0.05") == const_code("0.05")
    type_code(fields) = reach(
        """
    struct Params
        $fields
    end
    t = target(:a, () -> Params(1))
    """,
    )[1]
    @test type_code("a::Int") != type_code("a::Int\n b::Int")
    ctor(body) = reach(
        """
    struct P
        a::Int
        P(a) = new($body)
    end
    t = target(:a, () -> P(1))
    """,
    )[1]
    @test ctor("a") != ctor("a + 1")
    abstract_code(super) = reach(
        """
    abstract type Shape end
    abstract type Round <: $super end
    struct Circle <: Round
        r::Float64
    end
    t = target(:a, () -> Circle(1.0))
    """,
    )[1]
    @test abstract_code("Shape") != abstract_code("Any")
    h, d = reach("t = target(:a, () -> sum(map(abs, [1, -2])))")
    @test h == reach("t = target(:a, () -> sum(map(abs, [1, -2])) + 0)")[1]
    @test length(project_files(d)) == 1 # only the file defining the target itself
end

@testitem "code_hash ignores the counters Julia numbers generated functions with" setup = [
    CodeFixtures,
] begin
    code(; before = "", default = "1", step = "x + 1") = """
    $before
    Base.@kwdef struct Settings
        a::Int = $default
    end
    const STEPS = (double = x -> 2x, inc = x -> $step)
    run(x) = STEPS.inc(STEPS.double(x)) + Settings().a
    t = target(:a, () -> run(1))
    """
    base, _ = reach(code())
    # keyword and anonymous functions defined earlier renumber the generated ones
    renumbered = "g(; k = 1) = k\nh = [x -> x for _ in 1:2]\nw(f) = f(1)\nw() do y\n    y\nend"
    @test reach(code(; before = renumbered))[1] == base
    @test reach(code(; default = "2"))[1] != base  # a `@kwdef` default
    @test reach(code(; step = "x + 2"))[1] != base # a lambda stored in a global
end

@testitem "code_hash follows user-defined macros" setup = [CodeFixtures] begin
    with_macro(factor) = reach(
        """
    macro scaled(ex)
        :($factor * \$(esc(ex)))
    end
    f(x) = @scaled x
    t = target(:a, () -> f(1))
    """,
    )[1]
    @test with_macro("2") == with_macro("2")
    @test with_macro("2") != with_macro("3")
end

@testitem "code_hash follows functions captured by a closure stored in a global" setup = [
    CodeFixtures,
] begin
    # A cache of compiled models: the builder is only passed to the factory, and
    # the closure calls it through a captured variable.
    code(; build = "n * sum(s)") = """
    build_system(n, s) = $build
    function system_cache(build)
        cache = Dict{Any, Any}()
        return function cached(args...; series)
            get!(() -> build(args..., series), cache, (args..., series))
        end
    end
    const CACHED = system_cache(build_system)
    model(; series) = CACHED(2; series)
    t = target(:a, () -> model(; series = [1.0]))
    """
    base, _ = reach(code())
    @test reach(code())[1] == base
    @test reach(code(; build = "n + sum(s)"))[1] != base
    # what the closure's cache holds is state, not code
    dir = mktempdir()
    write(joinpath(dir, "src.jl"), code())
    m = Module(:Fixture)
    Core.eval(m, :(using Targets))
    Base.include(m, joinpath(dir, "src.jl"))
    t = Base.invokelatest(getproperty, m, :t)
    hash_now() = Targets.code_hash(Targets.Discovery(Targets.user_roots(dir, [])), t)
    empty = hash_now()
    Base.invokelatest(t.f)
    @test hash_now() == empty == base
end

@testitem "code_hash terminates on recursion" setup = [CodeFixtures] begin
    h, _ = reach(
        """
    even(n) = n == 0 ? true : odd(n - 1)
    odd(n) = n == 0 ? false : even(n - 1)
    fact(n) = n <= 1 ? 1 : n * fact(n - 1)
    t = target(:a, () -> (even(4), fact(3)))
    """,
    )
    @test length(h) == 64
end

@testitem "code_hash tracks code outside the project only when asked" setup = [
    CodeFixtures,
] begin
    mktempdir() do project
        mktempdir() do shared
            function build(body; track)
                lib = joinpath(shared, "lib.jl")
                write(lib, "libfn(x) = $body\n")
                code = "Base.include(@__MODULE__, $(repr(lib)))\nt = target(:a, () -> libfn(1))"
                return reach(code; dir = project, track)[1]
            end
            @test build("x + 1"; track = []) == build("x + 2"; track = [])
            @test build("x + 1"; track = [shared]) != build("x + 2"; track = [shared])
        end
    end
end

@testitem "the stale-session check notices files edited after they were loaded" setup = [
    CodeFixtures,
] begin
    using Targets: stale_files, check_stale_session
    mktempdir() do dir
        path = joinpath(dir, "src.jl")
        write(path, "h(x) = 1\n")
        Base.include(Module(:Fixture), path)
        @test isempty(stale_files([path]))
        write(path, "h(x) = 2\n")
        Targets.with_revise_assumed(false) do
            @test stale_files([path]) == [path]
            @test_throws "Revise" check_stale_session([path])
        end
        Targets.with_revise_assumed(true) do
            @test isempty(stale_files([path])) # Revise keeps loaded code current
        end
        Base.include(Module(:Again), path) # reloading clears it
        @test isempty(stale_files([path]))
        @test isempty(stale_files([joinpath(dir, "never_loaded.jl")]))
    end
end

@testitem "source and code hashes are identical across processes" begin
    using Targets: Discovery, user_roots, code_hash, command_hash
    mktempdir() do dir
        path = joinpath(dir, "src.jl")
        write(
            path,
            """
        const K = 3
        struct P
            a::Int
        end
        helper(x) = P(x * K)
        t = target(:a, () -> map(helper, [1, 2]))
        """,
        )
        probe = """
        using Targets
        m = Module(:Fixture)
        Core.eval(m, :(using Targets))
        Base.include(m, $(repr(path)))
        t = Base.invokelatest(getproperty, m, :t)
        d = Targets.Discovery(Targets.user_roots($(repr(dir)), []))
        print(Targets.command_hash(t).hash, " ", Targets.code_hash(d, t))
        """
        project = dirname(Base.active_project())
        there = read(
            `$(Base.julia_cmd()) --startup-file=no --project=$project -e $probe`,
            String,
        )
        m = Module(:Fixture)
        Core.eval(m, :(using Targets))
        Base.include(m, path)
        t = Base.invokelatest(getproperty, m, :t)
        d = Discovery(user_roots(dir, []))
        @test there == string(command_hash(t).hash, " ", code_hash(d, t))
    end
end

@testitem "a macro target's code hash follows what it calls, not every keyword function" setup = [
    CodeFixtures,
] begin
    # A keyword call lowers to `Core.kwcall`, whose methods are every keyword
    # function's: the target's code is followed from its expression instead.
    code(; helper = "x + k", unrelated = "x - k") = """
    helper(x; k = 1) = $helper
    unrelated(x; k = 1) = $unrelated
    p = @pipeline begin
        @target a = helper(1; k = 2)
    end
    t = only(p.targets)
    """
    base, _ = reach(code())
    @test reach(code(; unrelated = "x * k"))[1] == base
    @test reach(code(; helper = "x * k"))[1] != base
end

@testitem "methods from an earlier load of a pipeline script are not user code" begin
    using Targets: Discovery, user_roots, code_hash, load_pipeline
    mktempdir() do dir
        script = joinpath(dir, "_targets.jl")
        # Each load defines a new `Box`, so `length` gains a method per load.
        write(
            script,
            """
            struct Box end
            Base.length(::Box) = 2
            tar_pipeline(target(:a, () -> length([1])))
            """,
        )
        hash_of(p) = code_hash(Discovery(user_roots(dir, [])), only(p.targets))
        first_load = hash_of(load_pipeline(script))
        @test hash_of(load_pipeline(script)) == first_load
        @test hash_of(load_pipeline(script)) == first_load
    end
end

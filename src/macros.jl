## Macro sugar
##
## `@pipeline` rewrites a block of `@target name = expression options...` lines
## into `tar_pipeline(target(...), ...)`. It adds no behaviour of its own.

"""
    @target name = expression [format = ...] [pattern = ...] [cue = ...] [seed = ...]

Declare a target inside [`@pipeline`](@ref). Dependencies are the other targets
named in `expression`. Outside `@pipeline` it is an error, because dependency
detection needs to know every target name in the pipeline.
"""
macro target(args...)
    error(
        "@target can only be used inside @pipeline; use `target(:name, f)` to declare a " *
            "target on its own",
    )
end

struct TargetDecl
    name::Symbol
    body::Any
    options::Vector{Pair{Symbol, Any}}
    line::LineNumberNode
end

const TARGET_OPTIONS = (
    :format,
    :pattern,
    :cue,
    :seed,
    :slots,
    :deployment,
    :error,
    :retries,
    :retry_delay,
)
const PIPELINE_OPTIONS = (:track, :seed)

function parse_target_decl(ex, line::LineNumberNode)
    args = Any[a for a in ex.args[3:end] if !(a isa LineNumberNode)]
    (!isempty(args) && Meta.isexpr(args[1], :(=)) && args[1].args[1] isa Symbol) ||
        error(
            "$(line.file):$(line.line): expected `@target name = expression`, got `$(ex)`",
        )
    name, body = args[1].args
    options = Pair{Symbol, Any}[]
    for opt in args[2:end]
        (Meta.isexpr(opt, :(=)) && opt.args[1] in TARGET_OPTIONS) ||
            error(
                "$(line.file):$(line.line): in `@target $name`, expected an option like " *
                    "`format = :file`, `pattern = other` or `cue = :always`, got `$opt`",
            )
        push!(options, opt.args[1] => opt.args[2])
    end
    return TargetDecl(name, body, options, line)
end

function parse_pipeline_block(block)
    decls = TargetDecl[]
    line = LineNumberNode(0, :none)
    for ex in block.args
        if ex isa LineNumberNode
            line = ex
        elseif Meta.isexpr(ex, :macrocall) && ex.args[1] === Symbol("@target")
            push!(decls, parse_target_decl(ex, line))
        else
            error(
                "$(line.file):$(line.line): @pipeline expects `@target` lines, got `$ex`; " *
                    "use `tar_pipeline(...)` to mix in other targets",
            )
        end
    end
    return decls
end

"Names from `names` that occur in `ex` (once each, in order of first appearance)."
function referenced_targets(ex, names, found = Symbol[])
    if ex isa Symbol
        ex in names && !(ex in found) && push!(found, ex)
    elseif ex isa Expr
        ex.head == :quote && return found
        # `name = value` assigns a local (or names a NamedTuple field): only the value is read
        if ex.head == :(=) && ex.args[1] isa Symbol
            return referenced_targets(ex.args[2], names, found)
        end
        if ex.head == :. && length(ex.args) == 2 && ex.args[2] isa QuoteNode
            referenced_targets(ex.args[1], names, found) # `x.field`: field is not a target
        elseif ex.head == :kw
            referenced_targets(
                ex.args[2],
                names,
                found,
            ) # `f(key = value)`: key is not a target
        else
            foreach(a -> referenced_targets(a, names, found), ex.args)
        end
    end
    return found
end

# A bare symbol names a target (`pattern = grid`); a quoted one already is a Symbol.
option_value(::Val{:pattern}, v) = pattern_expr(v)

# R-style pattern calls, `map(a, b)`, `cross(a, head(b, 2))`, ..., become combinators.
const PATTERN_CALLS = Dict(
    :map => :Map,
    :cross => :Cross,
    :head => :Head,
    :slice => :Slice,
    :sample => :Sample,
)
pattern_expr(v::Symbol) = QuoteNode(v)
pattern_expr(v) = v
function pattern_expr(v::Expr)
    (Meta.isexpr(v, :call) && haskey(PATTERN_CALLS, v.args[1])) || return v
    f = v.args[1]
    args = v.args[2:end]
    # map and cross combine patterns; the others take one pattern and plain arguments
    parts = f in (:map, :cross) ?
        map(pattern_expr, args) :
        [pattern_expr(args[1]); args[2:end]]
    return Expr(:call, GlobalRef(@__MODULE__, PATTERN_CALLS[f]), parts...)
end
option_value(_, v) = v

function expand_target(d::TargetDecl, names)
    deps = referenced_targets(d.body, setdiff(names, [d.name]))
    lambda = Expr(:->, Expr(:tuple, deps...), Expr(:block, d.line, d.body))
    source = Base.remove_linenums!(deepcopy(
        d.body isa Expr ? d.body : Expr(:block, d.body),
    ))
    kws = Any[Expr(:kw, k, option_value(Val(k), v)) for (k, v) in d.options]
    push!(kws, Expr(:kw, :source, QuoteNode(source)))
    return Expr(
        :call,
        GlobalRef(@__MODULE__, :target),
        Expr(:parameters, kws...),
        QuoteNode(d.name),
        lambda,
    )
end

"""
    @pipeline [track = [...]] [seed = ...] begin
        @target name = expression [format = ...] [pattern = ...] [cue = ...] [seed = ...]
        ...
    end

Build a [`Pipeline`](@ref) from `@target` lines, equivalent to the
[`tar_pipeline`](@ref) of the corresponding [`target`](@ref)s. Each target's
dependencies are the other targets its expression mentions, and the expression
itself is what gets hashed, so reformatting never rebuilds. A local variable
that shadows a target name counts as a dependency (harmless: one extra edge).
"""
macro pipeline(args...)
    isempty(args) && error("@pipeline expects a `begin ... end` block of @target lines")
    block = args[end]
    Meta.isexpr(block, :block) ||
        error("@pipeline expects a `begin ... end` block of @target lines, got `$block`")
    decls = parse_pipeline_block(block)
    names = [d.name for d in decls]
    targets = Any[expand_target(d, names) for d in decls]
    options = Any[]
    for opt in args[1:(end - 1)]
        (Meta.isexpr(opt, :(=)) && opt.args[1] in PIPELINE_OPTIONS) ||
            error(
                "@pipeline accepts only `track = [...]` and `seed = ...` options before its block, got `$opt`",
            )
        push!(options, Expr(:kw, opt.args[1], opt.args[2]))
    end
    call = Expr(
        :call,
        GlobalRef(@__MODULE__, :tar_pipeline),
        Expr(:parameters, options...),
        targets...,
    )
    return esc(call)
end

@testmodule MacroFixtures begin
    using Targets
    export same_graph

    same_graph(p, q) = p.order == q.order &&
        [t.deps for t in p.targets] == [t.deps for t in q.targets] &&
        [t.name for t in p.targets] == [t.name for t in q.targets] &&
        p.graph.fadjlist == q.graph.fadjlist
end

@testitem "a macro pipeline matches the equivalent target() pipeline" setup = [
    MacroFixtures,
] begin
    p = @pipeline begin
        @target raw = 10
        @target clean = raw + 1
        @target other = 5
        @target model = fit(clean, other) cue = :always
    end
    fit(a, b) = a * b
    q = tar_pipeline(
        target(:raw, () -> 10),
        target(:clean, raw -> raw + 1),
        target(:other, () -> 5),
        target(:model, (clean, other) -> 1; cue = :always),
    )
    @test same_graph(p, q)
    @test p.order == [:raw, :clean, :other, :model]
    @test Targets.get_target(p, :model).cue == :always
    @test Targets.get_target(p, :model).deps == [:clean, :other]
    @test Targets.get_target(p, :clean).deps == [:raw]
end

@testitem "dependencies ignore field names, keywords and quoted code" setup = [
    MacroFixtures,
] begin
    p = @pipeline begin
        @target settings = (alpha = 1, depth = 2)
        @target alpha = 3
        @target model = settings.alpha + f(1; alpha = 2) + g(:alpha)
    end
    @test Targets.get_target(p, :model).deps == [:settings]
    @test Targets.get_target(p, :settings).deps == Symbol[]
end

@testitem "@target is only valid inside @pipeline, and @pipeline reports bad lines" begin
    m = Module(:MacroErrors)
    Core.eval(m, :(using Targets))
    @test_throws "inside @pipeline" Core.eval(m, :(@target a = 1))
    @test_throws "expected `@target name = expression`" Core.eval(
        m,
        :(
            @pipeline begin
                @target 1 + 2
            end
        ),
    )
    @test_throws "expects `@target` lines" Core.eval(
        m,
        :(
            @pipeline begin
                x = 5
            end
        ),
    )
    @test_throws "expected an option" Core.eval(
        m,
        :(
            @pipeline begin
                @target a = 1 colour = :red
            end
        ),
    )
    @test_throws "begin ... end" Core.eval(m, :(@pipeline 5))
end

@testitem "macro pipelines build, and editing one line rebuilds only its descendants" setup = [
    SourceFixtures,
] begin
    mktempdir() do dir
        code(clean; note = "") = """
        helper(x) = x * 2
        $note
        p = @pipeline begin
            @target raw = 10
            @target clean = $clean
            @target model = helper(clean)
            @target other = raw - 1
        end
        """
        @test build_source(code("raw + 1"), dir).built == [:raw, :clean, :model, :other]
        @test read_values(dir, :model) == (22,)
        @test isempty(
            build_source(code("raw  +  1"; note = "# moved down a line\n"), dir).built,
        )
        s = build_source(code("raw + 2"), dir)
        @test s.built == [:clean, :model]
        @test s.skipped == [:raw, :other]
    end
end

@testitem "macro pipelines support options and track" setup = [
    SourceFixtures,
    FileFixtures,
] begin
    mktempdir() do dir
        write_files(dir, "a.txt" => "123", "b.txt" => "45")
        code = """
        p = @pipeline track = [] begin
            @target inputs = ["a.txt", "b.txt"]  format = :file
            @target sizes = filesize(inputs)  pattern = inputs
            @target total = sum(sizes)
        end
        """
        s = build_source(code, dir)
        @test length(s.branches[:sizes]) == 2
        @test read_values(dir, :total) == (5,)
    end
    p = @pipeline seed = 3 begin
        @target a = 1 seed = 7
    end
    @test p.seed == 3 && p.targets[1].seed == 7
end

@testitem "errors in a macro target point at its line" setup = [SourceFixtures] begin
    mktempdir() do dir
        m, path = load_source(
            """
        p = @pipeline begin
            @target fine = 1
            @target bad = error("boom")
        end
        """;
            dir,
        )
        p = Base.invokelatest(getproperty, m, :p)
        f = Targets.get_target(p, :bad).f
        frames = try
            Base.invokelatest(f)
            Any[]
        catch
            stacktrace(catch_backtrace())
        end
        @test any(fr -> endswith(String(fr.file), "src.jl") && fr.line == 3, frames)
    end
end

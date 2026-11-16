using Targets
using Documenter
using DocumenterVitepress

makedocs(;
    modules = [Targets],
    authors = "Callum Arnold",
    sitename = "Targets.jl",
    format = DocumenterVitepress.MarkdownVitepress(
        repo = "github.com/arnold-c/Targets.jl",
        devbranch = "main",
        devurl = "dev",
        # the site is served from the root of its own domain, not under /Targets.jl/
        deploy_url = "https://targets.callumarnold.com",
    ),
    # internal docstrings (most of the package) are for developers, not the site
    checkdocs = :exports,
    pages = [
        "Home" => "index.md",
        "Example Workflow" => "tutorial.md",
        "Guide" => [
            "Declaring pipelines" => "guide/pipelines.md",
            "Branching" => "guide/branching.md",
            "Kinds of targets" => "guide/target_kinds.md",
            "Running builds" => "guide/builds.md",
            "Parallel and distributed builds" => "guide/parallel.md",
            "Running on a Slurm cluster" => "guide/slurm.md",
            "What triggers a rebuild" => "guide/rebuilds.md",
            "Inspecting a pipeline" => "guide/inspecting.md",
            "Large pipelines" => "guide/large_pipelines.md",
        ],
        "API reference" => "api.md",
    ],
)

DocumenterVitepress.deploydocs(;
    repo = "github.com/arnold-c/Targets.jl",
    target = joinpath(@__DIR__, "build"),
    branch = "docs-page",
    devbranch = "main",
    push_preview = true,
)

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
        # deploy_url = "https://targets.callumarnold.com", # with a custom domain (see config.mts)
    ),
    # internal docstrings (most of the package) are for developers, not the site
    checkdocs = :exports,
    pages = [
        "Home" => "index.md",
        "Guide" => [
            "Declaring pipelines" => "guide/pipelines.md",
            "Branching" => "guide/branching.md",
            "Kinds of targets" => "guide/target_kinds.md",
            "Running builds" => "guide/builds.md",
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

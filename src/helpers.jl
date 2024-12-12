function project_base()
    replace(
        Base.active_project(),
        r"/Project.toml$" => "",
        r"\\ Project.toml$" => ""
    )
end

function tar_read(
    output_name,
    output_format=jld2,
    hex_output=true,
    sha=SHA.sha256,
    store="",
    meta_path=joinpath(project_base(), "_meta", store),
    obj_path=joinpath(meta_path, "objects"),
)
    output_hash = generic_hash(output_name, hex_output, sha)
    output_path = joinpath(obj_path, output_hash)
    # TODO: Update dict key
    output = JLD2.load(output_path, "output")
    println(output)
    return nothing
end

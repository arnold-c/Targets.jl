function tar_target(
    output_name,
    fn,
    vargs...;
    output_format=jld2,
    hex_output=true,
    sha=SHA.sha256,
    store="",
    meta_path=joinpath(project_base(), "_meta", store),
    meta_df_name="hash_df",
    obj_path=joinpath(meta_path, "objects"),
)
    # Hash function lowered code
    fn_hash = hash_fn_method(fn, vargs...; hex_output=hex_output, sha=sha)
    # Hash arguments
    args_hash = generic_hash(vargs, hex_output, sha)
    # Hash output object name
    output_hash = generic_hash(output_name, hex_output, sha)

    # Load DF of previously computed values
    hash_df = load_hash_df(meta_df_name, store, meta_path)

    # Check if output exists in DF
    if in(output_hash, hash_df.output_hashes)
        # If true check if function hash same as previous version
        prev_output_hash, rownum = filter_hash_df_get_rownum(
            hash_df,
            output_hash
        )
        @assert DataFrames.nrow(prev_output_hash) == 1
        if prev_output_hash.fn_hashes == fn_hash && prev_output_hash.args_hashes == args_hash
            println("$output_name already up to date. Skipping")
            return nothing
        end
        # Remove old hashes
        delete_outdated_hashes!(hash_df, rownum)
    end

    # Run target
    output = fn(vargs...)

    if !ispath(obj_path)
        mkdir(obj_path)
    end
    # TODO: Update to use object name in dictionary - currently requiring appending file name with extension, but only want to be able to produce a single output file per method implementation
    # filepath = joinpath(obj_path, output_hash) * ".jld2"
    # output_dict = Dict(output_name => output)
    # JLD2.save(filepath, output_dict)
    filepath = joinpath(obj_path, output_hash)
    JLD2.jldsave(filepath; output)

    # Update DF with hashes
    update_hash_DF!(hash_df, output_hash, fn_hash, args_hash)

    return nothing
end

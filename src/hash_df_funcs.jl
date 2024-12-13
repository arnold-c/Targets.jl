function load_hash_df(
    hash_df_name="hash_df",
    store="",
    meta_path=joinpath(project_base(), "_meta", store),
)
    if !ispath(meta_path)
        error("_meta directory not found at $meta_path, therefore can't find the DF of hashes")
    end
    filepath = joinpath(meta_path, hash_df_name)
    if !isfile(filepath)
        error("DF of hashes not found at $filepath. Either create it first, or check correct path being searched")
    end
    return JLD2.load(filepath)["hash_df"]
end

function filter_hash_df_get_rownum(
    hash_df,
    output_hash
)
    rownum = findall(==(output_hash), hash_df.output_hashes)
    @assert length(rownum) == 1
    fdf = hash_df[rownum, :]
    return fdf, rownum
end

function delete_outdated_hashes!(
    hash_df,
    rownum
)
    DataFrames.deleteat!(hash_df, rownum)
    return nothing
end

function update_hash_DF!(
    hash_df,
    output_hash,
    fn_hash,
    args_hash,
)
    DataFrames.push!(
        hash_df,
        (
            ;
            output_hashes=output_hash,
            fn_hashes=fn_hash,
            args_hashes=args_hash
        )
    )
    return nothing
end

function save_hash_DF!(
    hash_df,
    hash_df_name="hash_df",
    store="",
    meta_path=joinpath(project_base(), "_meta", store),
)
    filepath = joinpath(meta_path, hash_df_name)
    if !isfile(filepath)
        error("DF of hashes not found at $filepath. Confirm the output path is the same as the load path")
    end
    return JLD2.jldsave(filepath; hash_df)
end

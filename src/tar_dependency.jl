function hash_dependencies(
    vargs...;
    hex_output=true,
    sha=SHA.sha256
)
    return generic_hash(vargs, hex_output, sha)
end

# TODO: Fix to remove eval() call as doesn't work in a module
macro hash_fn_method(expression::Expr, hex_output=true, sha=SHA.sha256)
    if Meta.isexpr(expression, :call)
        esc(:(hash_fn_method(
            $(expression.args...);
            hex_output=$(hex_output),
            sha=$(sha)
        )))
    end
end

function hash_fn_method(fn, vargs...; hex_output=true, sha=SHA.sha256)
    generic_hash(code_typed(fn, (typeof.(vargs)...,)), hex_output, sha)
end

function generic_hash(x, hex_output=true, sha=SHA.sha256)
    buf = IOBuffer()
    Serialization.serialize(buf, x)
    gen_hash = sha(take!(buf))
    if hex_output
        return SHA.bytes2hex(gen_hash)
    end
    return gen_hash
end


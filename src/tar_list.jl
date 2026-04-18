macro tar_list(targets...)
    esc(:(
        map(t -> t.args[2], $(targets))
    ))
end

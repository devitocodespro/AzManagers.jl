function shell_quote(value)
    "'" * replace(string(value), "'" => "'\"'\"'") * "'"
end

function valid_environment_name(name)
    occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", string(name))
end

function build_envstring(env::Dict)
    envstring = ""
    for (key,value) in env
        valid_environment_name(key) ||
            throw(ArgumentError("invalid environment variable name: $key"))
        envstring *= "export $key=$(shell_quote(value))\n"
    end
    envstring
end


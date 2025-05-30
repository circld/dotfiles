function then
    # allow chaining of `then` commands by only updating $__last_cmd_args
    # when empty or not a then invocation
    if test \( -z "$__last_cmd_args" \) -o \( $argv[1] = "then" \)
        set -g __last_cmd_args (string split " " $history[1])
    end
    set new_cmd (string join -- " " $argv[1] $__last_cmd_args[2..])
    eval $new_cmd
end

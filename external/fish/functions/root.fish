function root
    set project_root (git rev-parse --show-toplevel)
    if test $status -eq 0
        cd $project_root
    end
end

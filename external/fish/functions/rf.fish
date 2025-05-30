# inspired by:
# https://github.com/srid/neuron/blob/master/neuron/src-bash/neuron-search
function rf --description 'interactive file contents `rg` searching via `fzf`'
  if not argparse --name=rf "o/=+" -- $argv
    return 1
  end

  # pass optional flags to `rg` (e.g., --no-ignore)
  set rg_options (string join -- " " $_flag_o)

  # if no pattern provided, match all
  set query (string join " " $argv)
  if test -z $query
      set query "."
  end

  set match (
    eval "rg -i --color=never --no-heading --with-filename --line-number --sort path $rg_options '$query'" \
    | preview -l
  )
  # open nvim on line of match
  if test $status -eq 0
    set args (string split ":" $match)[1..2]
    echo nvim +$args[2] $args[1]
    nvim +$args[2] $args[1]
  end
end

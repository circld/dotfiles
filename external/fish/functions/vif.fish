function vif --description 'fuzzy find a file in directory or subdirectories and open in neovim'
  set found (fd $argv[1..-1] --type=f --full-path --color=never | preview)
  if test $status -eq 0
    nvim $found
  end
end

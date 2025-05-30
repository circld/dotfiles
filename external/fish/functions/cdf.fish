function cdf --description 'fuzzy find a directory or subdirectory and move there'
  # sort matching directories from least to most nested
  set found (fd $argv[1..-1] --full-path --type=d --color=never |
    awk '{ split($0, parts, "/"); print length(parts), $0 }' |
    sort -n |
    awk '{ print $2 }' |
    fzf --layout reverse \
       --preview "fd --color=always --base-directory {1} ." \
       --bind=shift-down:preview-half-page-down,shift-up:preview-half-page-up
  )
  if test $status -eq 0
    cd $found
  end
end

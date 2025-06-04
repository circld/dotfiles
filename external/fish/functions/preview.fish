function preview --description 'preview files using fzf'
  argparse 'l/line' -- $argv

  if test -n "$_flag_l"
    fzf -i -d ':' --with-nth=1,3 \
      --bind=down:preview-half-page-down,up:preview-half-page-up \
      --layout=reverse \
      --preview 'bat --force-colorization --terminal-width=$FZF_PREVIEW_COLUMNS --style=changes,header,numbers --highlight-line {2} {1}' \
      --preview-window +{2}-/2:right:70%:wrap
  else
    fzf -i \
      --bind=down:preview-half-page-down,up:preview-half-page-up \
      --layout=reverse \
      --preview 'bat --force-colorization --terminal-width=$FZF_PREVIEW_COLUMNS --style=changes,header,numbers {1}' \
      --preview-window=right:70%:wrap
  end
end

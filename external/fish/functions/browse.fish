function browse --description 'file browser'
  fd --full-path --type=file . | fzf \
    --layout=reverse \
    --bind shift-down:preview-half-page-down,shift-up:preview-half-page-up,"space:execute(bat --paging=always {})","enter:execute(nvim {})","tab:accept" \
    --preview 'bat --force-colorization --theme "base16" --terminal-width=$FZF_PREVIEW_COLUMNS --style=changes,header,numbers {1}' \
    --preview-window=right:70%:wrap \
    || true
end

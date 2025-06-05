function browse --description 'file browser'
  fd --full-path --type=file "$argv[1]" . | fzf \
    --layout=reverse \
    --bind down:preview-half-page-down,up:preview-half-page-up,"space:execute(bat --paging=always {})","enter:execute(nvim {})","tab:accept" \
    --preview 'bat --force-colorization --theme "base16" --terminal-width=$FZF_PREVIEW_COLUMNS --style=changes,header,numbers {1}' \
    --preview-window=right:70%:wrap \
    || true
end

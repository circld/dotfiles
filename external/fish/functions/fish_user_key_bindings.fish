function fish_user_key_bindings
  fzf_key_bindings

  # ghostty on mac workaround until 4.0.3
  bind --preset -M insert alt-f nextd-or-forward-word
  bind --preset alt-f nextd-or-forward-word
  bind --preset -M visual alt-f nextd-or-forward-word
  bind --preset -M insert alt-b prevd-or-backward-word
  bind --preset alt-b prevd-or-backward-word
  bind --preset -M visual alt-b prevd-or-backward-word
end

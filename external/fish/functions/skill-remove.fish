function skill-remove --description 'remove skills from dotfiles'
  if test (count $argv) -eq 0
    echo "usage: skill-remove <skill-name> [skill-name...]"
    return 1
  end

  set -l target_root "$HOME/dotfiles/external/opencode/skills"
  if not test -d "$target_root"
    echo "missing $target_root"
    return 1
  end

  for name in $argv
    set -l target_dir "$target_root/$name"
    if not test -d "$target_dir"
      echo "$name: not found"
      continue
    end

    command rm -rf -- "$target_dir"
    echo "$name: removed"
  end
end

function skill-list --description 'list installed skills'
  if not type -q fd
    echo "fd is required"
    return 1
  end

  set -l target_root "$HOME/dotfiles/external/opencode/skills"
  if not test -d "$target_root"
    echo "missing $target_root"
    return 1
  end

  set -l skill_mds (command fd --type f --max-depth 2 'SKILL.md' "$target_root")
  if test (count $skill_mds) -eq 0
    echo "no skills installed"
    return 0
  end

  for skill_md in $skill_mds
    set -l name (command awk 'BEGIN{fm=0} /^---/{if(fm==0){fm=1;next}else{exit}} fm && $1=="name:"{sub(/^name:[[:space:]]*/,""); print; exit}' "$skill_md")
    if test -z "$name"
      set name (path basename (path dirname "$skill_md"))
    end
    set -l rel_path (string replace "$HOME/dotfiles/" "" "$skill_md")
    printf "%s\t%s\n" "$name" "$rel_path"
  end
end

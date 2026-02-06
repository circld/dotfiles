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

  set -l skill_mds (command fd --type f --name SKILL.md --max-depth 2 "$target_root")
  if test (count $skill_mds) -eq 0
    echo "no skills installed"
    return 0
  end

  for skill_md in $skill_mds
    set -l name (command awk 'BEGIN{fm=0} /^---/{if(fm==0){fm=1;next}else{exit}} fm && $1=="name:"{sub(/^name:[[:space:]]*/,""); print; exit}' "$skill_md")
    set -l description (command awk 'BEGIN{fm=0} /^---/{if(fm==0){fm=1;next}else{exit}} fm && $1=="description:"{sub(/^description:[[:space:]]*/,""); print; exit}' "$skill_md")
    if test -z "$name"
      set name (path basename (path dirname "$skill_md"))
    end
    printf "%s\t%s\n" "$name" "$description"
  end
end

function skill-install --description 'install skills from skills.sh repos into dotfiles'
  set -l source "$argv[1]"
  if test -z "$source"
    echo "usage: skill-install owner/repo[@skill-name]"
    return 1
  end

  if not type -q git
    echo "git is required"
    return 1
  end

  if not type -q fd
    echo "fd is required"
    return 1
  end

  set -l parts (string split -m1 "@" -- $source)
  set -l repo $parts[1]
  set -l skill_filter ""
  if test (count $parts) -gt 1
    set skill_filter $parts[2]
  end

  if not string match -rq '^[^/]+/[^/]+$' -- $repo
    echo "expected owner/repo"
    return 1
  end

  set -l dotfiles "$HOME/dotfiles"
  set -l target_root "$dotfiles/external/opencode/skills"
  if not test -d "$target_root"
    echo "missing $target_root"
    return 1
  end

  set -l tmp ""
  function __skill_install_cleanup --argument-names tmp_path
    if test -n "$tmp_path"
      command rm -rf -- "$tmp_path"
    end
  end

  set tmp (mktemp -d 2>/dev/null)
  if test -z "$tmp"
    set tmp (mktemp -d -t skill-install)
  end
  if test -z "$tmp"
    echo "failed to create temp dir"
    return 1
  end

  set -l repo_url "https://github.com/$repo.git"
  command git clone --depth 1 "$repo_url" "$tmp" >/dev/null 2>&1
  if test $status -ne 0
    __skill_install_cleanup "$tmp"
    echo "failed to clone $repo_url"
    return 1
  end

  set -l search_dirs \
    $tmp \
    $tmp/skills \
    $tmp/skills/.curated \
    $tmp/skills/.experimental \
    $tmp/skills/.system \
    $tmp/.agent/skills \
    $tmp/.agents/skills \
    $tmp/.claude/skills \
    $tmp/.cline/skills \
    $tmp/.codebuddy/skills \
    $tmp/.codex/skills \
    $tmp/.commandcode/skills \
    $tmp/.continue/skills \
    $tmp/.cursor/skills \
    $tmp/.github/skills \
    $tmp/.goose/skills \
    $tmp/.iflow/skills \
    $tmp/.junie/skills \
    $tmp/.kilocode/skills \
    $tmp/.kiro/skills \
    $tmp/.mux/skills \
    $tmp/.neovate/skills \
    $tmp/.opencode/skills \
    $tmp/.openhands/skills \
    $tmp/.pi/skills \
    $tmp/.qoder/skills \
    $tmp/.roo/skills \
    $tmp/.trae/skills \
    $tmp/.windsurf/skills \
    $tmp/.zencoder/skills

  set -l skill_dirs
  for dir in $search_dirs
    if test -d "$dir"
      for skill_md in (command fd --type f -g "SKILL.md" --max-depth 2 "$dir")
        set -l skill_dir (path dirname "$skill_md")
        if not contains -- $skill_dir $skill_dirs
          set skill_dirs $skill_dirs $skill_dir
        end
      end
    end
  end

  if test (count $skill_dirs) -eq 0
    for skill_md in (command fd --type f -g "SKILL.md" --max-depth 5 "$tmp")
      set -l skill_dir (path dirname "$skill_md")
      if not contains -- $skill_dir $skill_dirs
        set skill_dirs $skill_dirs $skill_dir
      end
    end
  end

  if test (count $skill_dirs) -eq 0
    __skill_install_cleanup "$tmp"
    echo "no skills found in $repo"
    return 1
  end

  set -l installed 0
  set -l updated 0
  set -l skipped 0
  set -l matched 0

  for skill_dir in $skill_dirs
    set -l skill_md "$skill_dir/SKILL.md"
    if not test -f "$skill_md"
      continue
    end

    set -l frontmatter_name (command awk 'BEGIN{fm=0} /^---/{if(fm==0){fm=1;next}else{exit}} fm && $1=="name:"{sub(/^name:[[:space:]]*/,""); print; exit}' "$skill_md")
    set -l skill_name_raw $frontmatter_name
    if test -z "$skill_name_raw"
      set skill_name_raw (path basename $skill_dir)
    end
    set -l skill_name_raw_lower (string lower -- $skill_name_raw)

    set -l skill_name (string lower -- $skill_name_raw)
    set skill_name (string replace -ar '[^a-z0-9._]+' '-' -- $skill_name)
    set skill_name (string replace -ar '^[.-]+' '' -- $skill_name)
    set skill_name (string replace -ar '[.-]+$' '' -- $skill_name)
    if test -z "$skill_name"
      set skill_name "unnamed-skill"
    end

    if test -n "$skill_filter"
      set -l filter (string lower -- $skill_filter)
      set -l filter_sanitized (string replace -ar '[^a-z0-9._]+' '-' -- $filter)
      set filter_sanitized (string replace -ar '^[.-]+' '' -- $filter_sanitized)
      set filter_sanitized (string replace -ar '[.-]+$' '' -- $filter_sanitized)
      set -l dir_name (string lower -- (path basename $skill_dir))

      if test "$filter" != "$skill_name_raw_lower"; and test "$filter" != "$dir_name"; and test "$filter_sanitized" != "$skill_name"
        continue
      end
    end

    set matched (math $matched + 1)

    set -l target_dir "$target_root/$skill_name"
    set -l target_md "$target_dir/SKILL.md"

    set -l had_existing 0
    if test -f "$target_md"
      set had_existing 1
      if command git diff --no-index --quiet -- "$target_md" "$skill_md"
        echo "$skill_name: unchanged"
        set skipped (math $skipped + 1)
        continue
      end

      echo "$skill_name: update available"
      command git diff --no-index -- "$target_md" "$skill_md"
      read -l -P "apply update? [y/N] " confirm
      if not string match -iq "y" -- $confirm
        echo "$skill_name: skipped"
        set skipped (math $skipped + 1)
        continue
      end
    end

    command rm -rf -- "$target_dir"
    command mkdir -p -- "$target_dir"
    command cp -R -- "$skill_dir/." "$target_dir"

    if test $had_existing -eq 1
      echo "$skill_name: updated"
      set updated (math $updated + 1)
    else
      echo "$skill_name: installed"
      set installed (math $installed + 1)
    end
  end

  __skill_install_cleanup "$tmp"

  if test $matched -eq 0
    echo "no matching skill found"
    return 1
  end

  echo "installed: $installed, updated: $updated, skipped: $skipped"
end

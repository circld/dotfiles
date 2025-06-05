-- [[ Utility functions ]]

function FollowRoutePath()
  local target_path = vim.fn.expand("<cfile>")
  local ext = vim.fn.expand("<cfile>:e")

  -- check if in a project-local context
  local is_project_file = vim.startswith(target_path, "/") and vim.fn.empty(vim.fn.glob(target_path)) == 1
  local is_image = vim.tbl_contains({ "jpeg", "jpg", "png" }, ext)

  if is_project_file then
    -- remove leading /
    target_path = string.sub(target_path, 2)
  end

  if is_image then
    -- Use netrw to browse images
    vim.fn["netrw#BrowseX"](target_path, 0)
  else
    vim.cmd("edit " .. target_path)
  end
end

-- TODO replace w/https://github.com/folke/snacks.nvim/blob/main/docs/gitbrowse.md?
function OpenGithub()
  local file = vim.fn.expand("%:p")
  local line = vim.fn.getcurpos()[2]

  local function last_line_of_cmd(cmd)
    local output = vim.fn.systemlist(cmd)
    return output[#output] or ""
  end

  local repo_full_path = last_line_of_cmd("git rev-parse --show-toplevel")
  local branch = last_line_of_cmd("git rev-parse --abbrev-ref HEAD")

  -- Extract remote URL and parse it
  local remotes = vim.fn.systemlist("git remote -v")
  local remote_line = remotes[2] or remotes[1] or ""
  local remote = string.gsub(remote_line, "%.git", "")
  local remote = string.match(remote_line, "github.com[:/](.-)%s")

  if not remote then
    vim.notify("Could not find a valid GitHub remote", vim.log.levels.ERROR)
    return
  end

  -- Get file path relative to repo root
  local file_repo_path = file:gsub(repo_full_path, "")
  local github_url = string.format(
    "https://github.com/%s/tree/%s%s#L%d",
    remote,
    branch,
    file_repo_path,
    line
  )

  -- Open in default browser (macOS)
  vim.fn.system({ "open", github_url })
end

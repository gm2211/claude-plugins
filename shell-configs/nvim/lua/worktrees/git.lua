-- Git and GitHub CLI wrappers for worktree dashboard
-- All shell operations go through this module

local M = {}

local uv = vim.uv or vim.loop

--- Find the git project root from a given path (or cwd)
---@param path? string
---@return string|nil
function M.find_project_root(path)
    path = path or vim.fn.getcwd()
    local current = path
    while current ~= "/" do
        local stat = uv.fs_stat(current .. "/.git")
        if stat then
            return current
        end
        current = vim.fn.fnamemodify(current, ":h")
    end
    return nil
end

--- Find the main worktree root (the repo that owns the .worktrees/ dir)
---@return string|nil
function M.find_main_root()
    local cwd = vim.fn.getcwd()
    local main_root = cwd:match("^(.+)/.worktrees/[^/]+")
    if main_root then
        return main_root
    end
    local root = M.find_project_root(cwd)
    if root then
        local wt_dir = root .. "/.worktrees"
        local stat = uv.fs_stat(wt_dir)
        if stat and stat.type == "directory" then
            return root
        end
        return root
    end
    return nil
end

--- List all worktrees (synchronous). Returns {path, branch, is_current}[]
---@param root? string Main root override
---@return table[]
function M.list_worktrees_raw(root)
    root = root or M.find_main_root()
    if not root then
        return {}
    end

    local worktrees = {}
    local cwd = vim.fn.getcwd()
    local seen = {}

    -- Method 1: Scan .worktrees/ directory
    local wt_dir = root .. "/.worktrees"
    local stat = uv.fs_stat(wt_dir)
    if stat and stat.type == "directory" then
        local handle = uv.fs_scandir(wt_dir)
        if handle then
            while true do
                local name, ftype = uv.fs_scandir_next(handle)
                if not name then break end
                if ftype == "directory" then
                    local wt_path = wt_dir .. "/" .. name
                    if uv.fs_stat(wt_path .. "/.git") then
                        local resolved = vim.fn.resolve(wt_path)
                        local is_current = vim.fn.resolve(cwd) == resolved
                        table.insert(worktrees, {
                            path = wt_path,
                            branch = name,
                            is_current = is_current,
                        })
                        seen[resolved] = true
                    end
                end
            end
        end
    end

    -- Method 2: Parse `git worktree list --porcelain`
    local git_wt = vim.fn.system("git -C " .. vim.fn.shellescape(root) .. " worktree list --porcelain 2>/dev/null")
    if vim.v.shell_error == 0 and git_wt ~= "" then
        local current_path, current_branch = nil, nil
        for line in git_wt:gmatch("[^\n]+") do
            if line:match("^worktree ") then
                current_path = line:match("^worktree (.+)")
            elseif line:match("^branch ") then
                current_branch = line:match("^branch refs/heads/(.+)")
            elseif line == "" and current_path then
                local resolved = vim.fn.resolve(current_path)
                if not seen[resolved] then
                    table.insert(worktrees, {
                        path = current_path,
                        branch = current_branch or vim.fn.fnamemodify(current_path, ":t"),
                        is_current = vim.fn.resolve(cwd) == resolved,
                    })
                    seen[resolved] = true
                end
                current_path, current_branch = nil, nil
            end
        end
        if current_path then
            local resolved = vim.fn.resolve(current_path)
            if not seen[resolved] then
                table.insert(worktrees, {
                    path = current_path,
                    branch = current_branch or vim.fn.fnamemodify(current_path, ":t"),
                    is_current = vim.fn.resolve(cwd) == resolved,
                })
            end
        end
    end

    return worktrees
end

--- Async helper: run a command and call cb(stdout) on vim.schedule
---@param cmd string[]
---@param cwd string
---@param cb fun(stdout: string, ok: boolean)
local function async_cmd(cmd, cwd, cb)
    vim.system(cmd, { text = true, cwd = cwd }, function(obj)
        vim.schedule(function()
            cb(obj.stdout or "", obj.code == 0)
        end)
    end)
end

--- Get changed files for a worktree (async)
--- Returns via callback: {path, status, staged}[]
---@param path string Worktree path
---@param cb fun(files: table[])
function M.changed_files(path, cb)
    async_cmd({ "git", "status", "--porcelain=v1" }, path, function(stdout)
        local files = {}
        for line in stdout:gmatch("[^\n]+") do
            if #line >= 4 then
                local x = line:sub(1, 1) -- index status
                local y = line:sub(2, 2) -- working tree status
                local filepath = line:sub(4)
                -- Handle renames: "R  old -> new"
                local renamed = filepath:match("^.+ -> (.+)$")
                if renamed then filepath = renamed end
                local staged = x ~= " " and x ~= "?"
                local display_status
                if x == "?" then
                    display_status = "?"
                elseif staged and y ~= " " then
                    display_status = x -- show index status, mark as partially staged
                elseif staged then
                    display_status = x
                else
                    display_status = y
                end
                table.insert(files, {
                    path = filepath,
                    status = display_status,
                    staged = staged,
                    x = x,
                    y = y,
                })
            end
        end
        cb(files)
    end)
end

--- Get git log for a worktree (async)
---@param path string Worktree path
---@param limit number Max commits
---@param cb fun(entries: table[])
function M.log(path, limit, cb)
    async_cmd({
        "git", "log", "--format=%h|%s|%an|%cr|%D",
        "-n", tostring(limit),
    }, path, function(stdout)
        local entries = {}
        for line in stdout:gmatch("[^\n]+") do
            local hash, subject, author, date, refs = line:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
            if hash then
                table.insert(entries, {
                    hash = hash,
                    subject = subject,
                    author = author,
                    date = date,
                    refs = refs,
                })
            end
        end
        cb(entries)
    end)
end

--- Get ahead/behind count (async)
---@param path string
---@param cb fun(ahead: number, behind: number)
function M.ahead_behind(path, cb)
    async_cmd({ "git", "rev-list", "--left-right", "--count", "HEAD...@{upstream}" }, path, function(stdout, ok)
        if not ok then
            cb(0, 0)
            return
        end
        local ahead, behind = stdout:match("(%d+)%s+(%d+)")
        cb(tonumber(ahead) or 0, tonumber(behind) or 0)
    end)
end

--- Check if worktree has dirty state (async)
---@param path string
---@param cb fun(dirty: boolean)
function M.is_dirty(path, cb)
    async_cmd({ "git", "status", "--porcelain" }, path, function(stdout)
        cb(stdout ~= "")
    end)
end

--- Stage a single file
---@param wt_path string
---@param filepath string
---@param cb fun(ok: boolean)
function M.stage_file(wt_path, filepath, cb)
    async_cmd({ "git", "add", "--", filepath }, wt_path, function(_, ok)
        cb(ok)
    end)
end

--- Unstage a single file
---@param wt_path string
---@param filepath string
---@param cb fun(ok: boolean)
function M.unstage_file(wt_path, filepath, cb)
    async_cmd({ "git", "reset", "HEAD", "--", filepath }, wt_path, function(_, ok)
        cb(ok)
    end)
end

--- Stage all files
---@param wt_path string
---@param cb fun(ok: boolean)
function M.stage_all(wt_path, cb)
    async_cmd({ "git", "add", "-A" }, wt_path, function(_, ok)
        cb(ok)
    end)
end

--- Unstage all files
---@param wt_path string
---@param cb fun(ok: boolean)
function M.unstage_all(wt_path, cb)
    async_cmd({ "git", "reset", "HEAD" }, wt_path, function(_, ok)
        cb(ok)
    end)
end

--- Discard changes to a file
---@param wt_path string
---@param filepath string
---@param is_untracked boolean
---@param cb fun(ok: boolean)
function M.discard_file(wt_path, filepath, is_untracked, cb)
    if is_untracked then
        async_cmd({ "git", "clean", "-fd", "--", filepath }, wt_path, function(_, ok)
            cb(ok)
        end)
    else
        async_cmd({ "git", "checkout", "--", filepath }, wt_path, function(_, ok)
            cb(ok)
        end)
    end
end

--- Commit staged changes
---@param wt_path string
---@param message string
---@param cb fun(ok: boolean, output: string)
function M.commit(wt_path, message, cb)
    async_cmd({ "git", "commit", "-m", message }, wt_path, function(stdout, ok)
        cb(ok, stdout)
    end)
end

--- Create a new worktree
---@param root string Main repo root
---@param branch string Branch name
---@param cb fun(ok: boolean, output: string)
function M.create_worktree(root, branch, cb)
    local wt_path = root .. "/.worktrees/" .. branch
    async_cmd({ "git", "worktree", "add", "-b", branch, wt_path }, root, function(stdout, ok)
        cb(ok, ok and wt_path or stdout)
    end)
end

--- Delete a worktree
---@param root string Main repo root
---@param wt_path string Worktree path
---@param cb fun(ok: boolean, output: string)
function M.delete_worktree(root, wt_path, cb)
    async_cmd({ "git", "worktree", "remove", wt_path, "--force" }, root, function(stdout, ok)
        cb(ok, stdout)
    end)
end

--- Fetch remote for a worktree
---@param path string
---@param cb fun(ok: boolean)
function M.fetch(path, cb)
    async_cmd({ "git", "fetch" }, path, function(_, ok)
        cb(ok)
    end)
end

--- Fetch all remotes
---@param path string
---@param cb fun(ok: boolean)
function M.fetch_all(path, cb)
    async_cmd({ "git", "fetch", "--all" }, path, function(_, ok)
        cb(ok)
    end)
end

--- Get CI status for a branch via gh (async)
---@param branch string
---@param cb fun(status: string)
function M.ci_status(branch, cb)
    vim.system(
        { "gh", "run", "list", "--branch", branch, "--limit", "1", "--json", "status,conclusion", "-q", ".[0]" },
        { text = true },
        function(obj)
            vim.schedule(function()
                if obj.code ~= 0 or not obj.stdout or obj.stdout == "" then
                    cb("unknown")
                    return
                end
                local ok_json, data = pcall(vim.json.decode, obj.stdout)
                if not ok_json or not data then
                    cb("unknown")
                    return
                end
                if data.status == "completed" then
                    cb(data.conclusion or "unknown")
                else
                    cb(data.status or "in_progress")
                end
            end)
        end
    )
end

--- Open PR in browser for a branch
---@param branch string
function M.open_pr_url(branch)
    vim.system({ "gh", "pr", "view", branch, "--web" }, { text = true })
end

--- Create worktree from a PR number
---@param root string
---@param pr_num string
---@param cb fun(ok: boolean, output: string)
function M.create_from_pr(root, pr_num, cb)
    -- First get PR branch name
    vim.system(
        { "gh", "pr", "view", pr_num, "--json", "headRefName", "-q", ".headRefName" },
        { text = true },
        function(obj)
            vim.schedule(function()
                if obj.code ~= 0 or not obj.stdout or obj.stdout:match("^%s*$") then
                    cb(false, "Failed to get PR branch: " .. (obj.stderr or ""))
                    return
                end
                local branch = vim.trim(obj.stdout)
                local wt_path = root .. "/.worktrees/" .. branch
                -- Fetch the PR branch, then create worktree
                vim.system({ "git", "-C", root, "fetch", "origin", branch }, { text = true }, function(fetch_obj)
                    vim.schedule(function()
                        if fetch_obj.code ~= 0 then
                            cb(false, "Failed to fetch branch: " .. (fetch_obj.stderr or ""))
                            return
                        end
                        vim.system(
                            { "git", "-C", root, "worktree", "add", wt_path, branch },
                            { text = true },
                            function(wt_obj)
                                vim.schedule(function()
                                    cb(wt_obj.code == 0, wt_obj.code == 0 and wt_path or (wt_obj.stderr or ""))
                                end)
                            end
                        )
                    end)
                end)
            end)
        end
    )
end

--- Create worktree from an issue number (creates a branch named issue-<num>)
---@param root string
---@param issue_num string
---@param cb fun(ok: boolean, output: string)
function M.create_from_issue(root, issue_num, cb)
    local branch = "issue-" .. issue_num
    M.create_worktree(root, branch, cb)
end

--- Find default branch name (main or master)
---@param path string
---@return string
function M.default_branch(path)
    local out = vim.fn.system("git -C " .. vim.fn.shellescape(path) .. " rev-parse --verify main 2>/dev/null")
    if vim.v.shell_error == 0 and out ~= "" then
        return "main"
    end
    return "master"
end

--- Get merge-base between HEAD and default branch
---@param path string
---@return string|nil
function M.merge_base(path)
    local base = M.default_branch(path)
    local out = vim.fn.system(
        "git -C " .. vim.fn.shellescape(path) .. " merge-base " .. base .. " HEAD 2>/dev/null"
    )
    local hash = vim.trim(out)
    if vim.v.shell_error == 0 and hash ~= "" then
        return hash
    end
    return nil
end

return M

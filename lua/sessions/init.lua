local util = require("sessions.util")
local lfs = require "lfs"

local levels = vim.log.levels

-- TODO: add session delete

-- default configuration
local config = {
    -- events which trigger a session save
    events = { "VimLeavePre" },

    -- default session filepath
    session_filepath = "",

    -- treat the default session filepath as an absolute path
    -- if true, all session files will be stored in a single directory
    absolute = false,
}

local M = {}

-- ensure full path to session file exists, and attempt to create intermediate
-- directories if needed
local ensure_path = function(path)
    local dir, name = util.path.split(path)
    if dir and vim.fn.isdirectory(dir) == 0 then
        if vim.fn.mkdir(dir, "p") == 0 then
            return false
        end
    end
    return name ~= ""
end

-- converts a given filepath to a string safe to be used as a session filename
local safe_path = function(path)
    if util.windows then
        return path:gsub(util.path.sep, "."):sub(4)
    else
        return path:gsub(util.path.sep, "."):sub(2)
    end
end

-- check if a directory exists
local function directoryExists(path)
    local baseDir = path:match("^(.+[/\\])")
    if not baseDir then
        return false
    end

    local attrs = lfs.attributes(baseDir)
    return attrs and attrs.mode == "directory"
end

-- given a path (possibly empty or nil) returns the absolute session path or
-- the default session path if it exists. Will create intermediate directories
-- as needed. Returns nil otherwise.
local get_session_path = function(path, ensure)
    ensure = ensure or true

    -- if config.absolute and not config.session_filepath then
    --     vim.notify("sessions.nvim: config.session_filepath must be set when config.absolute=true", levels.ERROR)
    --     return nil
    -- end

    -- deault path if abs=true, else curr dir
    local defaultBasePath = config.absolute
        and vim.fn.expand(config.session_filepath, ":p")
        or vim.fn.fnamemodify(vim.fn.getcwd(), ":p") .. util.path.sep .. config.session_filepath

    if path and path ~= "" then
        local inputPath = vim.fn.expand(path, ":p")
        local inputPathBaseDirExists = directoryExists(inputPath)

        --   if path is full path (i.e., path starts with /), use as is
        if string.sub(inputPath, 1, 1) == "/" and inputPathBaseDirExists then
            return inputPath
        end

        --   if path is relative (may or may not contain slashes), append to basepath
        if defaultBasePath then
            return defaultBasePath .. util.path.sep .. inputPath
        end
    else
        --   if path is not provided:
        --     if absolute=true, save in curr_dir-session.vim in base_path
        --     if absolute=false, save in session.vim in cwd
        --   TODO: prompt for session name or to select an existing session
        vim.notify("sessions.nvim: session name is currently required", levels.ERROR)
        return nil
    end

    --[=====[
    -- old logic:
    if path and path ~= "" then
        path = vim.fn.expand(path, ":p")
    elseif config.session_filepath ~= "" then
        if config.absolute then
            local cwd = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
            path = vim.fn.expand(config.session_filepath, ":p") .. util.path.sep .. safe_path(cwd) .. "session"
        else
            path = vim.fn.expand(config.session_filepath, ":p")
        end
    end

    if path and path ~= "" then
        if ensure and not ensure_path(path) then
            return nil
        end
        return path
    end
    --]=====]

    return nil
end

-- set to nil when no session recording is active
local session_file_path = nil

local write_session_file = function()
    vim.cmd(string.format("mksession! %s", session_file_path))
end

-- start autosaving changes to the session file
local start_autosave = function()
    -- save future changes
    local augroup = vim.api.nvim_create_augroup("sessions.nvim", {})
    vim.api.nvim_create_autocmd(
        config.events,
        {
            group = augroup,
            pattern = "*",
            callback = write_session_file,
        }
    )

    -- save now
    write_session_file()
end

---stop autosaving changes to the session file
---@param opts table
M.stop_autosave = function(opts)
    if not session_file_path then return end

    opts = util.merge({
        save = true,
    }, opts)

    vim.api.nvim_clear_autocmds({ group = "sessions.nvim" })
    vim.api.nvim_del_augroup_by_name("sessions.nvim")

    -- save before stopping
    if opts.save then
        write_session_file()
    end

    session_file_path = nil
end

---save or overwrite a session file to the given path
---@param path string|nil
---@param opts table
M.save = function(path, opts)
    -- TODO: prompt overwrite if file exists
    opts = util.merge({
        autosave = true,
    }, opts)

    path = get_session_path(path)
    if not path then
        vim.notify("sessions.nvim: failed to save session file", levels.ERROR)
        return
    end

    session_file_path = path
    write_session_file()

    if not opts.autosave then return end
    start_autosave()
end

---load a session file from the given path
---@param path string|nil
---@param opts table
---@return boolean
M.load = function(path, opts)
    opts = util.merge({
        autosave = true,
        silent = false,
    }, opts)

    path = get_session_path(path, false)
    if not path or vim.fn.filereadable(path) == 0 then
        if not opts.silent then
            vim.notify(string.format("sessions.nvim: file '%s' does not exist", path))
        end
        return false
    end

    session_file_path = path
    vim.cmd(string.format("silent! source %s", path))

    if opts.autosave then
        start_autosave()
    end

    return true
end

---return true if currently recording a session
---@returns bool
M.recording = function()
    return session_file_path ~= nil
end

local subcommands = { "save", "load", "start", "stop" }

local subcommand_complete = function(lead)
    return vim.tbl_filter(function(item)
        return vim.startswith(item, lead)
    end, subcommands)
end

M.complete = function(lead, line, pos)
    -- remove the command name from the front
    line = string.sub(line, #"Sessions " + 1)
    pos = pos - #"Sessions "

    -- completion for subcommand names
    if #line == 0 then return subcommands end
    local index = string.find(line, " ")
    if not index or pos < index then
        return subcommand_complete(lead)
    end

    return {}
end

M.parse_args = function(subcommand, bang, path)
    if bang ~= "" then
        bang = true
    else
        bang = false
    end

    if path and #path ~= 0 then
        path = path[1]
    else
        path = nil
    end

    if subcommand == "save" then
        if bang then
            M.save(path, { autosave = false })
        else
            M.save(path)
        end
    elseif subcommand == "load" then
        if bang then
            M.load(path, { autosave = false })
        else
            M.load(path)
        end
    elseif subcommand == "stop" then
        if bang then
            M.stop_autosave({ save = false })
        else
            M.stop_autosave()
        end
    end
end

M.setup = function(opts)
    config = util.merge(config, opts)

    -- register commands
    vim.cmd [[
    command! -bang -nargs=* -complete=file SessionsSave lua require("sessions").parse_args("save", "<bang>", { <f-args> })
    command! -bang -nargs=* -complete=file SessionsLoad lua require("sessions").parse_args("load", "<bang>", { <f-args> })
    command! -bang SessionsStop lua require("sessions").parse_args("stop", "<bang>")
    ]]
end

return M

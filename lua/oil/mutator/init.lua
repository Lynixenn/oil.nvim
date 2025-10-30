local Progress = require("oil.mutator.progress")
local Trie = require("oil.mutator.trie")
local cache = require("oil.cache")
local columns = require("oil.columns")
local config = require("oil.config")
local confirmation = require("oil.mutator.confirmation")
local constants = require("oil.constants")
local fs = require("oil.fs")
local lsp_helpers = require("oil.lsp.helpers")
local oil = require("oil")
local parser = require("oil.mutator.parser")
local util = require("oil.util")
local view = require("oil.view")
local M = {}

local FIELD_NAME = constants.FIELD_NAME
local FIELD_TYPE = constants.FIELD_TYPE

---@alias oil.Action oil.CreateAction|oil.DeleteAction|oil.MoveAction|oil.CopyAction|oil.ChangeAction

---@class (exact) oil.CreateAction
---@field type "create"
---@field url string
---@field entry_type oil.EntryType
---@field link nil|string

---@class (exact) oil.DeleteAction
---@field type "delete"
---@field url string
---@field entry_type oil.EntryType

---@class (exact) oil.MoveAction
---@field type "move"
---@field entry_type oil.EntryType
---@field src_url string
---@field dest_url string

---@class (exact) oil.CopyAction
---@field type "copy"
---@field entry_type oil.EntryType
---@field src_url string
---@field dest_url string

---@class (exact) oil.ChangeAction
---@field type "change"
---@field entry_type oil.EntryType
---@field url string
---@field column string
---@field value any

---@param all_diffs table<integer, oil.Diff[]>
---@return oil.Action[]
M.create_actions_from_diffs = function(all_diffs)
    ---@type oil.Action[]
    local actions = {}

    ---@type table<integer, oil.Diff[]>
    local diff_by_id = setmetatable({}, {
        __index = function(t, key)
            local list = {}
            rawset(t, key, list)
            return list
        end,
    })

    -- To deduplicate create actions
    -- This can happen when creating deep nested files e.g.
    -- > foo/bar/a.txt
    -- > foo/bar/b.txt
    local seen_creates = {}

    ---@param action oil.Action
    local function add_action(action)
        local adapter = assert(config.get_adapter_by_scheme(action.dest_url or action.url))
        if not adapter.filter_action or adapter.filter_action(action) then
            if action.type == "create" then
                if seen_creates[action.url] then
                    return
                else
                    seen_creates[action.url] = true
                end
            end

            table.insert(actions, action)
        end
    end
    for bufnr, diffs in pairs(all_diffs) do
        local adapter = util.get_adapter(bufnr, true)
        if not adapter then
            error("Missing adapter")
        end
        local parent_url = vim.api.nvim_buf_get_name(bufnr)
        for _, diff in ipairs(diffs) do
            if diff.type == "new" then
                if diff.id then
                    local by_id = diff_by_id[diff.id]
                    -- Store destination URL on diff for move/copy action construction
                    -- This allows us to track where an existing entry is being moved/copied to
                    -- Normalize to resolve relative path components like '..'
                    local dest_path = parent_url .. diff.name
                    local scheme, path = util.parse_url(dest_path)
                    if path then
                        path = vim.fs.normalize(path)
                        dest_path = scheme .. path
                    end
                    ---@diagnostic disable-next-line: inject-field
                    diff.dest = dest_path
                    table.insert(by_id, diff)
                else
                    -- Parse nested files like foo/bar/baz using optimized path utilities
                    local pieces = fs.split_path(diff.name)
                    local url = parent_url:gsub("/$", "")
                    for i, v in ipairs(pieces) do
                        local is_last = i == #pieces
                        local entry_type = is_last and diff.entry_type or "directory"
                        local alternation = v:match("{([^}]+)}")
                        if is_last and alternation then
                            -- Parse alternations like foo.{js,test.js}
                            for _, alt in ipairs(vim.split(alternation, ",")) do
                                local alt_url = url .. "/" .. v:gsub("{[^}]+}", alt)
                                add_action({
                                    type = "create",
                                    url = alt_url,
                                    entry_type = entry_type,
                                    link = diff.link,
                                })
                            end
                        else
                            url = url .. "/" .. v

                            -- Skip creating action if this is an intermediate directory that already exists
                            local should_create = true
                            if not is_last and entry_type == "directory" then
                                -- Check if this directory URL is in seen_creates (being created this pass)
                                if seen_creates[url] then
                                    should_create = false
                                else
                                    -- Check the filesystem to see if directory already exists
                                    local adapter = assert(config.get_adapter_by_scheme(url))
                                    if adapter.name == "files" then
                                        local fs_path = vim.fn.fnamemodify(url:gsub("^oil://", ""), ":p")
                                        if vim.fn.isdirectory(fs_path) == 1 then
                                            should_create = false
                                        end
                                    end
                                end
                            end

                            if should_create then
                                add_action({
                                    type = "create",
                                    url = url,
                                    entry_type = entry_type,
                                    link = diff.link,
                                })
                            end
                        end
                    end
                end
            elseif diff.type == "change" then
                add_action({
                    type = "change",
                    url = parent_url .. diff.name,
                    entry_type = diff.entry_type,
                    column = diff.column,
                    value = diff.value,
                })
            else
                local by_id = diff_by_id[diff.id]
                -- Mark that this entry has a delete operation pending
                -- We use this to differentiate MOVE (delete + new) from COPY (just new)
                ---@diagnostic disable-next-line: inject-field
                by_id.has_delete = true
                -- Don't insert the delete diff - we only track new destinations for this entry
                -- The presence in diff_by_id already indicates a delete is occurring
            end
        end
    end

    for id, diffs in pairs(diff_by_id) do
        local entry = cache.get_entry_by_id(id)
        if not entry then
            error(string.format("Could not find entry with ID %d in cache", id))
        end
        -- Check if this entry has both delete and create operations (indicating a move/copy)
        ---@diagnostic disable-next-line: undefined-field
        if diffs.has_delete then
            local has_create = #diffs > 0
            if has_create then
                -- MOVE (+ optional copies) when has both creates and delete
                for i, diff in ipairs(diffs) do
                    add_action({
                        type = i == #diffs and "move" or "copy",
                        entry_type = entry[FIELD_TYPE],
                        -- Use the destination URL we stored earlier on the diff
                        ---@diagnostic disable-next-line: undefined-field
                        dest_url = diff.dest,
                        src_url = cache.get_parent_url(id) .. entry[FIELD_NAME],
                    })
                end
            else
                -- DELETE when no create
                add_action({
                    type = "delete",
                    entry_type = entry[FIELD_TYPE],
                    url = cache.get_parent_url(id) .. entry[FIELD_NAME],
                })
            end
        else
            -- COPY when create but no delete
            for _, diff in ipairs(diffs) do
                add_action({
                    type = "copy",
                    entry_type = entry[FIELD_TYPE],
                    src_url = cache.get_parent_url(id) .. entry[FIELD_NAME],
                    -- Use the destination URL we stored earlier on the diff
                    ---@diagnostic disable-next-line: undefined-field
                    dest_url = diff.dest,
                })
            end
        end
    end

    return M.enforce_action_order(actions)
end

---Enforce proper ordering of file operations to prevent conflicts
---
---This function implements a topological sort with cycle detection for file operations.
---It ensures operations are executed in the correct order by:
---1. Building dependency relationships between actions (e.g., create parent before child)
---2. Detecting and resolving cycles (e.g., swap operations: mv A->B, mv B->A)
---3. Returning actions in dependency order (leaves first, then parents)
---
---Algorithm overview:
---1. Build two tries: src_trie (for sources) and dest_trie (for destinations)
---2. For each action, dynamically compute dependencies using trie queries
---3. Find leaf actions (no dependencies) and add them to result
---4. If a cycle is detected, split one move into two temporary moves
---5. Repeat until all actions are processed
---
---@param actions oil.Action[] Unordered list of file operations
---@return oil.Action[] Ordered list where dependencies are satisfied
M.enforce_action_order = function(actions)
    -- Build spatial indices using tries for efficient parent/child queries
    local src_trie = Trie.new()
    local dest_trie = Trie.new()
    for _, action in ipairs(actions) do
        if action.type == "delete" or action.type == "change" then
            src_trie:insert_action(action.url, action)
        elseif action.type == "create" then
            dest_trie:insert_action(action.url, action)
        else
            -- Move/copy operations affect both source and destination
            dest_trie:insert_action(action.dest_url, action)
            src_trie:insert_action(action.src_url, action)
        end
    end

    ---Dynamically compute dependencies for an action by querying the tries
    ---Dependencies ensure operations happen in the correct order, e.g.:
    ---  - Create parent directories before children
    ---  - Move children out before deleting parent
    ---  - Delete/move source before creating at same destination
    ---@param action oil.Action
    ---@return oil.Action[] List of actions that must complete before this one
    local function get_deps(action)
        local ret = {}
        if action.type == "delete" then
            src_trie:accum_children_of(action.url, ret)
        elseif action.type == "create" then
            -- Finish operating on parents first
            -- e.g. NEW /a BEFORE NEW /a/b
            dest_trie:accum_first_parents_of(action.url, ret)
            -- Process remove path before creating new path
            -- e.g. DELETE /a BEFORE NEW /a
            src_trie:accum_actions_at(action.url, ret, function(a)
                return a.type == "move" or a.type == "delete"
            end)
        elseif action.type == "change" then
            -- Finish operating on parents first
            -- e.g. NEW /a BEFORE CHANGE /a/b
            dest_trie:accum_first_parents_of(action.url, ret)
            -- Finish operations on this path first
            -- e.g. NEW /a BEFORE CHANGE /a
            dest_trie:accum_actions_at(action.url, ret)
            -- Finish copy from operations first
            -- e.g. COPY /a -> /b BEFORE CHANGE /a
            src_trie:accum_actions_at(action.url, ret, function(entry)
                return entry.type == "copy"
            end)
        elseif action.type == "move" then
            -- Finish operating on parents first
            -- e.g. NEW /a BEFORE MOVE /z -> /a/b
            dest_trie:accum_first_parents_of(action.dest_url, ret)
            -- Process children before moving
            -- e.g. NEW /a/b BEFORE MOVE /a -> /b
            dest_trie:accum_children_of(action.src_url, ret)
            -- Process children before moving parent dir
            -- e.g. COPY /a/b -> /b BEFORE MOVE /a -> /d
            -- e.g. CHANGE /a/b BEFORE MOVE /a -> /d
            src_trie:accum_children_of(action.src_url, ret)
            -- Process remove path before moving to new path
            -- e.g. MOVE /a -> /b BEFORE MOVE /c -> /a
            src_trie:accum_actions_at(action.dest_url, ret, function(a)
                return a.type == "move" or a.type == "delete"
            end)
        elseif action.type == "copy" then
            -- Finish operating on parents first
            -- e.g. NEW /a BEFORE COPY /z -> /a/b
            dest_trie:accum_first_parents_of(action.dest_url, ret)
            -- Process children before copying
            -- e.g. NEW /a/b BEFORE COPY /a -> /b
            dest_trie:accum_children_of(action.src_url, ret)
            -- Process remove path before copying to new path
            -- e.g. MOVE /a -> /b BEFORE COPY /c -> /a
            src_trie:accum_actions_at(action.dest_url, ret, function(a)
                return a.type == "move" or a.type == "delete"
            end)
        end
        return ret
    end

    ---Find a leaf action (one with no dependencies) by traversing the dependency graph
    ---Uses depth-first search with cycle detection
    ---@param action oil.Action The action to start searching from
    ---@param seen? table<oil.Action, boolean> Tracks visited actions to detect cycles
    ---@return nil|oil.Action leaf The leaf action if found (has no dependencies)
    ---@return nil|oil.Action loop_action If no leaf found, returns an action involved in a cycle
    local function find_leaf(action, seen)
        if not seen then
            seen = {}
        elseif seen[action] then
            -- We've visited this action before - we're in a cycle
            return nil, action
        end
        seen[action] = true
        
        local deps = get_deps(action)
        if vim.tbl_isempty(deps) then
            -- No dependencies - this is a leaf action, can execute immediately
            return action
        end
        
        -- Recursively search dependencies for a leaf
        local action_in_loop
        for _, dep in ipairs(deps) do
            local leaf, loop_action = find_leaf(dep, seen)
            if leaf then
                return leaf
            elseif not action_in_loop and loop_action then
                -- Track one action from the cycle for later resolution
                action_in_loop = loop_action
            end
        end
        return nil, action_in_loop
    end

    -- Main loop: process actions in dependency order
    local ret = {}
    local after = {}
    while not vim.tbl_isempty(actions) do
        local action = actions[1]
        local selected, loop_action = find_leaf(action)
        local to_remove
        if selected then
            to_remove = selected
        else
            if loop_action and loop_action.type == "move" then
                -- Validate cycle is not a parent-into-child move (impossible operation)
                if vim.startswith(loop_action.dest_url, loop_action.src_url) then
                    error(string.format(
                        "Cannot move parent directory into itself: %s -> %s",
                        loop_action.src_url,
                        loop_action.dest_url
                    ))
                end

                -- Detected a move cycle (e.g., MOVE /a -> /b AND MOVE /b -> /a)
                -- Resolve by splitting one move into two operations via a temporary location:
                --   Original: MOVE /a -> /b
                --   Split into: MOVE /a -> /a__oil_tmp_12345, then MOVE /a__oil_tmp_12345 -> /b
                local intermediate_url =
                    string.format("%s__oil_tmp_%05d", loop_action.src_url, math.random(999999))
                local move_1 = {
                    type = "move",
                    entry_type = loop_action.entry_type,
                    src_url = loop_action.src_url,
                    dest_url = intermediate_url,
                }
                local move_2 = {
                    type = "move",
                    entry_type = loop_action.entry_type,
                    src_url = intermediate_url,
                    dest_url = loop_action.dest_url,
                }
                to_remove = loop_action
                table.insert(actions, move_1)
                table.insert(after, move_2)
                -- Register the temporary move in our tries for dependency tracking
                dest_trie:insert_action(move_1.dest_url, move_1)
                src_trie:insert_action(move_1.src_url, move_1)
            else
                error(string.format(
                    "Detected unresolvable cycle in file operations. Action type: %s",
                    loop_action and loop_action.type or "unknown"
                ))
            end
        end

        if selected then
            -- Validate selected action doesn't try to move/copy parent into child
            if selected.type == "move" or selected.type == "copy" then
                if vim.startswith(selected.dest_url, selected.src_url .. "/") then
                    error(
                        string.format(
                            "Invalid %s operation: cannot move parent directory into its own subdirectory (%s -> %s)",
                            selected.type:upper(),
                            selected.src_url,
                            selected.dest_url
                        )
                    )
                end
            end
            table.insert(ret, selected)
        end

        -- Remove processed action from tries and action list
        if to_remove then
            if to_remove.type == "delete" or to_remove.type == "change" then
                src_trie:remove_action(to_remove.url, to_remove)
            elseif to_remove.type == "create" then
                dest_trie:remove_action(to_remove.url, to_remove)
            else
                dest_trie:remove_action(to_remove.dest_url, to_remove)
                src_trie:remove_action(to_remove.src_url, to_remove)
            end
            for i, a in ipairs(actions) do
                if a == to_remove then
                    table.remove(actions, i)
                    break
                end
            end
        end
    end

    vim.list_extend(ret, after)
    return ret
end

local progress

---@param actions oil.Action[]
---@param cb fun(err: nil|string)
M.process_actions = function(actions, cb)
    vim.api.nvim_exec_autocmds(
        "User",
        { pattern = "OilActionsPre", modeline = false, data = { actions = actions } }
    )

    local did_complete = nil
    if config.lsp_file_methods.enabled then
        did_complete = lsp_helpers.will_perform_file_operations(actions)
    end

    -- Convert some cross-adapter moves to a copy + delete
    for _, action in ipairs(actions) do
        if action.type == "move" then
            local _, cross_action = util.get_adapter_for_action(action)
            -- Only do the conversion if the cross-adapter support is "copy"
            if cross_action == "copy" then
                ---@diagnostic disable-next-line: assign-type-mismatch
                action.type = "copy"
                table.insert(actions, {
                    type = "delete",
                    url = action.src_url,
                    entry_type = action.entry_type,
                })
            end
        end
    end

    local finished = false
    progress = Progress.new()
    local function finish(err)
        if not finished then
            finished = true
            progress:close()
            progress = nil
            vim.api.nvim_exec_autocmds(
                "User",
                { pattern = "OilActionsPost", modeline = false, data = { err = err, actions = actions } }
            )
            cb(err)
        end
    end

    -- Defer showing the progress to avoid flicker for fast operations
    vim.defer_fn(function()
        if not finished then
            progress:show({
                -- TODO some actions are actually cancelable.
                -- We should stop them instead of stopping after the current action
                cancel = function()
                    finish("Canceled")
                end,
            })
        end
    end, 100)

    local idx = 1
    local next_action
    next_action = function()
        if finished then
            return
        end
        if idx > #actions then
            if did_complete then
                did_complete()
            end
            finish()
            return
        end
        local action = actions[idx]
        progress:set_action(action, idx, #actions)
        idx = idx + 1
        local ok, adapter = pcall(util.get_adapter_for_action, action)
        if not ok then
            return finish(adapter)
        end
        local callback = vim.schedule_wrap(function(err)
            if finished then
                -- This can happen if the user canceled out of the progress window
                return
            elseif err then
                finish(err)
            else
                cache.perform_action(action)
                next_action()
            end
        end)
        if action.type == "change" then
            ---@cast action oil.ChangeAction
            columns.perform_change_action(adapter, action, callback)
        else
            adapter.perform_action(action, callback)
        end
    end
    next_action()
end

M.show_progress = function()
    if progress then
        progress:restore()
    end
end

local mutation_in_progress = false

---@return boolean
M.is_mutating = function()
    return mutation_in_progress
end

---@param confirm nil|boolean
---@param cb? fun(err: nil|string)
M.try_write_changes = function(confirm, cb)
    if not cb then
        cb = function(_err) end
    end
    if mutation_in_progress then
        cb("Cannot perform mutation when already in progress")
        return
    end
    local current_buf = vim.api.nvim_get_current_buf()
    local was_modified = vim.bo.modified
    local buffers = view.get_all_buffers()
    local all_diffs = {}
    ---@type table<integer, oil.ParseError[]>
    local all_errors = {}

    mutation_in_progress = true
    -- Lock the buffer to prevent race conditions from the user modifying them during parsing
    view.lock_buffers()
    for _, bufnr in ipairs(buffers) do
        if vim.bo[bufnr].modified then
            local diffs, errors = parser.parse(bufnr)
            all_diffs[bufnr] = diffs
            local adapter = assert(util.get_adapter(bufnr, true))
            if adapter.filter_error then
                errors = vim.tbl_filter(adapter.filter_error, errors)
            end
            if not vim.tbl_isempty(errors) then
                all_errors[bufnr] = errors
            end
        end
    end
    local function unlock()
        view.unlock_buffers()
        -- The ":write" will set nomodified even if we cancel here, so we need to restore it
        if was_modified then
            vim.bo[current_buf].modified = true
        end
        mutation_in_progress = false
    end

    local ns = vim.api.nvim_create_namespace("Oil")
    vim.diagnostic.reset(ns)
    if not vim.tbl_isempty(all_errors) then
        for bufnr, errors in pairs(all_errors) do
            vim.diagnostic.set(ns, bufnr, errors)
        end

        -- Jump to an error
        local curbuf = vim.api.nvim_get_current_buf()
        if all_errors[curbuf] then
            pcall(
                vim.api.nvim_win_set_cursor,
                0,
                { all_errors[curbuf][1].lnum + 1, all_errors[curbuf][1].col }
            )
        else
            local bufnr, errs = next(all_errors)
            assert(bufnr)
            assert(errs)
            -- HACK: This is a workaround for the fact that we can't switch buffers in the middle of a
            -- BufWriteCmd.
            vim.schedule(function()
                vim.api.nvim_win_set_buf(0, bufnr)
                pcall(vim.api.nvim_win_set_cursor, 0, { errs[1].lnum + 1, errs[1].col })
            end)
        end
        unlock()
        cb("Error parsing oil buffers")
        return
    end

    local actions = M.create_actions_from_diffs(all_diffs)
    confirmation.show(actions, confirm, function(proceed)
        if not proceed then
            unlock()
            cb("Canceled")
            return
        end

        M.process_actions(
            actions,
            vim.schedule_wrap(function(err)
                view.unlock_buffers()
                if err then
                    err = string.format("[oil] Error applying actions: %s", err)
                    view.rerender_all_oil_buffers(nil, function()
                        cb(err)
                    end)
                else
                    local current_entry = oil.get_cursor_entry()
                    if current_entry then
                        -- get the entry under the cursor and make sure the cursor stays on it
                        view.set_last_cursor(
                            vim.api.nvim_buf_get_name(0),
                            vim.split(current_entry.parsed_name or current_entry.name, "/")[1]
                        )
                    end
                    view.rerender_all_oil_buffers(nil, function(render_err)
                        vim.api.nvim_exec_autocmds(
                            "User",
                            { pattern = "OilMutationComplete", modeline = false }
                        )
                        cb(render_err)
                    end)
                end
                mutation_in_progress = false
            end)
        )
    end)
end

return M

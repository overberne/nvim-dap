---How the editor works:
---On buffer creation:
---- Render existing bps in buffer
---- Store breakpoint positions so we can navigate to them.
---On save:
---- Parse buffer
---- Diff parsed with old bps
---- Diff current bps with old bps
---- Merge changes
---- Show conflicts if any

local api = vim.api
local utils = require('dap.utils')
local breakpoints = require('dap.breakpoints')

local M = {}

---Stores snapshots of breakpoints per open editor buffer.
---Snapshots created on buffer open/render
---@type table<integer, dap.bp|dap.bp.func>
local bp_by_lnum = {}

local BUFFER_NAME = 'dap-breakpoints://editor'

local diagnostic_ns = api.nvim_create_namespace('dap_breakpoints_editor_diagnostics')
local diagnostic_source = 'dap-breakpoints-editor'

local valid_breakpoint_fields = {
  condition    = true,
  hitCondition = true,
  logMessage   = true,
}
local valid_function_fields = {
  condition    = true,
  hitCondition = true,
}
local valid_breakpoint_fields_err = 'Invalid field name, expected `condition`, `hitCondition` or `logMessage`'
local valid_function_fields_err = 'Invalid field name, expected `condition`, `hitCondition`'

---@param bp dap.bp|dap.bp.func
---@return string
local function bp_key(bp)
  return ('%s:%s:%s'):format(
    bp.buf or '',
    bp.line or '',
    bp.name or ''
  )
end

local function normalize_path(path)
  if path:match('^buf://%d+$') then
    return path
  end
  path = vim.fn.fnamemodify(path, ':p')
  if vim.fs and vim.fs.normalize then
    return vim.fs.normalize(path)
  end
  return path
end

local function is_absolute(path)
  if vim.fs and vim.fs.is_absolute then
    return vim.fs.is_absolute(path)
  end
  return path:sub(1, 1) == '/' or path:match('^%a:[/\\]') ~= nil
end

local function project_root()
  local cwd = normalize_path(vim.fn.getcwd())
  local git_root = vim.fs
      and vim.fs.root
      and vim.fs.root(0, { '.git' })
      or nil
  if git_root then
    return normalize_path(git_root)
  end
  return cwd
end

local function display_path(path)
  if path:match('^buf://%d+$') then
    return path
  end
  local root = project_root()
  local separator = package.config:sub(1, 1)
  local prefix = root
  if prefix:sub(-1) ~= separator then
    prefix = prefix .. separator
  end
  if path:sub(1, #prefix) == prefix then
    return path:sub(#prefix + 1)
  end
  return path
end

local function resolve_path(path)
  if path:match('^buf://%d+$') then
    return path
  end
  --Paths within the project are displayed as  relative paths,
  --so make them absolute again.
  if not is_absolute(path) then
    local separator = package.config:sub(1, 1)
    path = project_root() .. separator .. path
  end
  return normalize_path(path)
end

local function path_for_buffer(bufnr)
  local path = api.nvim_buf_get_name(bufnr)
  if path == '' then
    return 'buf://' .. bufnr
  end
  return normalize_path(path)
end

local function append_optional_field(lines, label, value)
  if value ~= nil then
    lines[#lines + 1] = ('  %s: %s'):format(label, value)
  end
end

---@param bp dap.bp|dap.bp.func
local function header_for(bp)
  if bp.buf then
    local path = display_path(path_for_buffer(bp.buf))
    return ('%s:%d'):format(path, bp.line)
  else
    return 'function ' .. bp.name
  end
end

local function render(bufnr)
  bp_by_lnum = {}
  local lines = {}
  local bps = breakpoints.get()
  local buffers = vim.tbl_keys(bps)
  table.sort(buffers, function(a, b)
    return path_for_buffer(a) < path_for_buffer(b)
  end)
  for _, buf in ipairs(buffers) do
    local path = display_path(path_for_buffer(buf))
    local buf_bps = bps[buf]
    table.sort(buf_bps, function(a, b)
      return a.line < b.line
    end)
    for _, bp in ipairs(buf_bps) do
      lines[#lines + 1] = header_for(bp)
      bp_by_lnum[#lines] = bp
      append_optional_field(lines, 'condition', bp.condition)
      append_optional_field(lines, 'hitCondition', bp.hitCondition)
      append_optional_field(lines, 'logMessage', bp.logMessage)
    end
  end
  local fbps = breakpoints.func.get()
  table.sort(fbps, function(a, b)
    return a.name < b.name
  end)
  for _, fbp in ipairs(fbps) do
    lines[#lines + 1] = header_for(fbp)
    bp_by_lnum[#lines] = fbp
    append_optional_field(lines, 'condition', fbp.condition)
    append_optional_field(lines, 'hitCondition', fbp.hitCondition)
  end
  api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.diagnostic.reset(diagnostic_ns, bufnr)
end

local function refresh_if_clean(bufnr)
  if not vim.bo[bufnr].modified then
    render(bufnr)
    vim.bo[bufnr].modified = false
    --TODO: Maybe store breakpoint at cursor pos and set cursor after render?
  end
end

local function trim_end(line)
  return (line:gsub('%s+$', ''))
end

--Also creates and loads buffer for a path if one does not exist.
---@return integer?, string?
local function buffer_for_path(path)
  local special_bufnr = path:match('^buf://(%d+)$')
  if special_bufnr then
    local bufnr = tonumber(special_bufnr)
    if bufnr and api.nvim_buf_is_valid(bufnr) then
      return bufnr
    end
    return nil, ('Buffer %s does not exist'):format(special_bufnr)
  end
  local bufnr = vim.fn.bufadd(resolve_path(path))
  if bufnr == -1 or bufnr == 0 then
    return nil, ('Could not create buffer for %q'):format(path)
  end
  --Must be loaded to o.a. place signs later.
  if not api.nvim_buf_is_loaded(bufnr) then
    vim.fn.bufload(bufnr)
  end
  return bufnr
end


---@param line string
---@param seen_sources table<string, boolean>
---@param seen_functions table<string, boolean>
---@param errors dap.breakpoints_editor.parse_error[]
---@param lnum integer
---@return dap.bp|dap.bp.func?
local function parse_header(line, seen_sources, seen_functions, errors, lnum)
  if vim.startswith(line, 'function') then
    local name = line:match('function%s+(.+)$')
    if not name then
      table.insert(errors, {
        lnum = lnum,
        message = 'Expected `function name`'
      })
      return nil
    end
    if seen_functions[name] then
      table.insert(errors, {
        lnum = lnum,
        message = ('Duplicate function "%s"'):format(name)
      })
      return nil
    end
    seen_functions[name] = true
    return {
      name = name,
    }
  else -- Normal breakpoint
    local path, row = line:match('(.+):(%d+)$')
    if not path or not row then
      table.insert(errors, {
        lnum = lnum,
        message = 'Expected `path:line`'
      })
      return nil
    end
    if tonumber(row) == 0 then
      table.insert(errors, {
        lnum = lnum,
        message = 'Line number must be positive'
      })
      return nil
    end
    local source = ('%s:%d'):format(path, row)
    if seen_sources[source] then
      table.insert(errors, {
        lnum = lnum,
        message = 'Duplicate breakpoint at ' .. source
      })
      return nil
    end
    seen_sources[source] = true
    local bufnr, err = buffer_for_path(path)
    if err ~= nil then
      table.insert(errors, { lnum = lnum, message = err })
      return nil
    end
    return {
      buf = bufnr,
      line = tonumber(row),
    }
  end
end

local function clean_field_value(value)
  value = trim_end(value)
  if value == '' then
    return nil
  end
  return value
end

---@param line string
---@param bp dap.bp|dap.bp.func
---@param errors dap.breakpoints_editor.parse_error[]
---@param lnum integer
local function parse_field(line, bp, errors, lnum)
  local field, value = line:match('^%s+(.*):%s*(.*)$')
  if not field or not value then
    table.insert(errors, { lnum = lnum, message = 'Expected `  field: value`' })
    return
  end
  if bp.buf and not valid_breakpoint_fields[field] then
    table.insert(errors, { lnum = lnum, message = valid_breakpoint_fields_err })
    return
  elseif bp.name and not valid_function_fields[field] then
    table.insert(errors, { lnum = lnum, message = valid_function_fields_err })
    return
  elseif bp[field] then
    table.insert(errors, {
      lnum = lnum,
      message = ('Duplicate field `%s`'):format(field)
    })
    return
  end
  bp[field] = clean_field_value(value)
end


---@class dap.breakpoints_editor.parse_error
---@field lnum integer
---@field message string

---@param bufnr integer
---@return dap.bp[]
---@return dap.bp.func[]
---@return dap.breakpoints_editor.parse_error[]
local function parse(bufnr)
  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local errors = {}
  local seen_sources = {}
  local seen_functions = {}
  local bps = {}
  local fbps = {}
  ---@type dap.bp|dap.bp.func?
  local bp = nil
  ---@type dap.bp|dap.bp.func?
  for lnum, line in ipairs(lines) do
    line = trim_end(line)
    if line == '' then
      goto continue
    end
    --Parse optional field
    if vim.startswith(line, '  ') then
      if not bp then
        table.insert(errors, {
          lnum = lnum,
          message = 'Expected `path:line` or `function name`'
        })
        goto continue
      end
      parse_field(line, bp, errors, lnum)
    else
      local new_bp = parse_header(line, seen_sources, seen_functions, errors, lnum)
      if not new_bp then
        goto continue
      end
      if bp then
        if bp.buf then
          table.insert(bps, bp)
        else
          table.insert(fbps, bp)
        end
      end
      bp = new_bp
    end
    ::continue::
  end
  if bp then
    if bp.buf then
      table.insert(bps, bp)
    else
      table.insert(fbps, bp)
    end
  end
  return bps, fbps, errors
end

---@param left dap.bp|dap.bp.func
---@param right dap.bp|dap.bp.func
---@return boolean
local function compare_breakpoint(left, right)
  if left.buf then
    return left.buf == right.buf
        and left.line == right.line
        and left.condition == right.condition
        and left.hitCondition == right.hitCondition
        and left.logMessage == right.logMessage
  end
  return left.name == right.name
      and left.condition == right.condition
      and left.hitCondition == right.hitCondition
end

---@class dap.breakpoints_editor.bp_diff
---@field action 'new'|'change'|'delete'
---@field old dap.bp|dap.bp.func?
---@field new dap.bp|dap.bp.func?

---@param bps dap.bp[]
---@param fbps dap.bp.func[]
---@return dap.breakpoints_editor.bp_diff[]
local function diff_breakpoints(bps, fbps)
  ---@type dap.breakpoints_editor.bp_diff[]
  local diffs = {}
  ---@type table<string, dap.bp|dap.bp.func>
  local old_bps = {}
  for _, bp in pairs(bp_by_lnum) do
    old_bps[bp_key(bp)] = bp
  end
  for _, bp in ipairs(bps) do
    local key = bp_key(bp)
    local old_bp = old_bps[key]
    if old_bp then
      --Remove so we can determine which old bps are deleted
      old_bps[key] = nil
      if not compare_breakpoint(old_bp, bp) then
        table.insert(diffs, { action = 'change', old = old_bp, new = bp })
      end
    else
      table.insert(diffs, { action = 'new', new = bp })
    end
  end
  for _, bp in ipairs(fbps) do
    local key = bp_key(bp)
    local old_bp = old_bps[key]
    if old_bp then
      old_bps[key] = nil
      if not compare_breakpoint(old_bp, bp) then
        table.insert(diffs, { action = 'change', old = old_bp, new = bp })
      end
    else
      table.insert(diffs, { action = 'new', new = bp })
    end
  end
  for _, bp in pairs(old_bps) do
    table.insert(diffs, { action = 'delete', old = bp })
  end
  return diffs
end

---@class dap.breakpoints_editor.bp_conflict
---@field editor dap.breakpoints_editor.bp_diff?
---@field live dap.breakpoints_editor.bp_diff?

---Finds conflicts between the editor and live diff, and returns filtered diffs
---to contain only changes which would update the live breakpoints.
---@param editor_diffs dap.breakpoints_editor.bp_diff[]
---@param live_diffs dap.breakpoints_editor.bp_diff[]
---@return dap.breakpoints_editor.bp_diff[], dap.breakpoints_editor.bp_diff[], dap.breakpoints_editor.bp_conflict[]
local function find_conflicts(editor_diffs, live_diffs)
  ---@type dap.breakpoints_editor.bp_diff[]
  local take_editor = {}
  ---@type dap.breakpoints_editor.bp_diff[]
  local take_live = {}
  ---@type dap.breakpoints_editor.bp_conflict[]
  local conflicts = {}
  local live_diffs_by_key = {}
  for _, diff in ipairs(live_diffs) do
    if diff.action ~= 'new' then
      live_diffs_by_key[bp_key(diff.old)] = diff
    end
  end
  for _, ediff in ipairs(editor_diffs) do
    if ediff.action == 'new' then
      table.insert(take_editor, ediff)
      table.insert(take_live, ediff)
      goto continue
    end
    local ldiff = live_diffs_by_key[bp_key(ediff.old)]
    if ediff.action == 'change' then
      if not ldiff then
        table.insert(take_editor, ediff)
        table.insert(take_live, ediff)
      elseif ldiff.action == 'change'
          and not compare_breakpoint(ediff.new, ldiff.new) then
        table.insert(take_editor, ediff)
        table.insert(conflicts, { editor = ediff, live = ldiff })
      elseif ldiff.action == 'delete' then
        table.insert(take_editor, ediff)
        table.insert(conflicts, { editor = ediff, live = ldiff })
      end
    elseif ediff.action == 'delete' then
      if not ldiff then
        table.insert(take_editor, ediff)
        table.insert(take_live, ediff)
      elseif ldiff.action == 'change' then
        table.insert(take_editor, ediff)
        table.insert(conflicts, { editor = ediff, live = ldiff })
      end
    end
    ::continue::
  end
  return take_editor, take_live, conflicts
end

---
---CONFLICT main.py:12
---editor: [(deleted)]
---  [condition: x]
---live: [(deleted)]
---  [condition: y]
---
---CHANGE main.py:12
---+ condition: x
---- condition: y
---~ condition: z

---@param a dap.bp|dap.bp.func?
---@param b dap.bp|dap.bp.func?
local function diff_fields(a, b)
  if a == nil then
    return nil, b
  end
  if b == nil then
    return a, nil
  end
  local a_diff = {}
  local b_diff = {}
  local fields = {}
  for key in pairs(a) do
    fields[key] = true
  end
  for key in pairs(b) do
    fields[key] = true
  end
  local keys = vim.tbl_keys(fields)
  table.sort(keys)
  for _, key in ipairs(keys) do
    local a_value = rawget(a, key)
    local b_value = rawget(b, key)
    if a_value ~= b_value then
      if a_value ~= nil then
        a_diff[key] = a_value
      end
      if b_value ~= nil then
        b_diff[key] = b_value
      end
    end
  end
  return a_diff, b_diff
end

local function append_fields(lines, obj)
  if obj == nil then
    return
  end
  for key, value in pairs(obj) do
    if key ~= 'buf' and key ~= 'line' and key ~= 'name' then
      lines[#lines + 1] = ('    %s: %s'):format(key, value)
    end
  end
end

---@param conflicts dap.breakpoints_editor.bp_conflict[]
---@return string
local function get_conflicts_prompt(conflicts)
  local lines = { 'Cannot apply breakpoint changes.\n' }
  for _, conflict in ipairs(conflicts) do
    table.insert(lines, 'CONFLICT ON ' .. header_for(conflict.editor.old))
    local editor_fields, live_fields = diff_fields(conflict.editor.new, conflict.live.new)
    if conflict.editor.action == 'change' and conflict.live.action == 'change' then
      table.insert(lines, '  editor:')
      append_fields(lines, editor_fields)
      table.insert(lines, '  live:')
      append_fields(lines, live_fields)
    elseif conflict.editor.action == 'delete' then
      table.insert(lines, '  editor: (deleted)')
      table.insert(lines, '  live:')
      append_fields(lines, live_fields)
    else
      table.insert(lines, '  editor:')
      append_fields(lines, editor_fields)
      table.insert(lines, '  live: (deleted)')
    end
    table.insert(lines, '')
  end
  return table.concat(lines, '\n')
end

---@param diff dap.breakpoints_editor.bp_diff
local function append_changed_fields(lines, diff)
  diff.old = diff.old or {}
  diff.new = diff.new or {}
  local fields = {}
  for key in pairs(diff.old) do
    fields[key] = true
  end
  for key in pairs(diff.new) do
    fields[key] = true
  end
  local keys = vim.tbl_keys(fields)
  table.sort(keys)
  for _, key in ipairs(keys) do
    local old_value = rawget(diff.old, key)
    local new_value = rawget(diff.new, key)
    if key == 'buf' then
      key = 'path'
      old_value = display_path(path_for_buffer(old_value))
      new_value = display_path(path_for_buffer(new_value))
    end
    if old_value ~= new_value then
      if old_value == nil then
        table.insert(lines, ('+ %s: %s'):format(key, new_value))
      elseif new_value == nil then
        table.insert(lines, ('- %s: %s'):format(key, old_value))
      else
        table.insert(lines, ('~ %s: %s -> %s'):format(key, old_value, new_value))
      end
    end
  end
end

---@param diffs dap.breakpoints_editor.bp_diff[]
---@return string
local function get_diff_prompt(diffs)
  local lines = { 'Apply breakpoint changes?\n' }
  local created = 0
  local changed = 0
  local deleted = 0
  for _, diff in ipairs(diffs) do
    if diff.action == 'new' then
      table.insert(lines, 'CREATE ' .. header_for(diff.new))
      append_optional_field(lines, 'condition', diff.new.condition)
      append_optional_field(lines, 'hitCondition', diff.new.hitCondition)
      append_optional_field(lines, 'logMessage', diff.new.logMessage)
      if diff.new.condition or diff.new.hitCondition or diff.new.logMessage then
        table.insert(lines, '')
      end
      created = created + 1
    end
  end
  for _, diff in ipairs(diffs) do
    if diff.action == 'change' then
      table.insert(lines, 'CHANGE ' .. header_for(diff.old))
      append_changed_fields(lines, diff)
      table.insert(lines, '')
      changed = changed + 1
    end
  end
  for _, diff in ipairs(diffs) do
    if diff.action == 'delete' then
      table.insert(lines, 'DELETE ' .. header_for(diff.old))
      deleted = deleted + 1
    end
  end
  if lines[#lines] ~= '' then
    table.insert(lines, '')
  end
  local status = ('%d created, %d changed, %d deleted'):format(created, changed, deleted)
  table.insert(lines, status)
  return table.concat(lines, '\n')
end

---@param diffs dap.breakpoints_editor.bp_diff[]
local function apply_diffs(diffs)
  local buffers = {}
  local functions_changed = false
  for _, diff in ipairs(diffs) do
    local old = diff.old
    if old then
      if old.buf then
        buffers[old.buf] = true
        breakpoints.remove(old.buf, old.line)
      elseif old.name then
        functions_changed = true
        breakpoints.func.remove(old.name)
      end
    end
    local new = diff.new
    if new then
      if new.buf then
        buffers[new.buf] = true
        breakpoints.set({
          bufnr = new.buf,
          lnum = new.line,
          condition = new.condition,
          hit_condition = new.hitCondition,
          log_message = new.logMessage,
        })
      elseif new.name then
        functions_changed = true
        breakpoints.func.set(new.name, {
          condition = new.condition,
          hit_condition = new.hitCondition,
        })
      end
    end
  end
  local sessions = require('dap').sessions()
  for buf in pairs(buffers) do
    local bps = breakpoints.get({ bufexpr = buf })
    utils.broadcast(sessions, function(s)
      s:set_breakpoints(bps)
    end)
  end
  if functions_changed then
    local fbps = breakpoints.func.get()
    utils.broadcast(sessions, function(s)
      s:set_function_breakpoints(fbps)
    end)
  end
end

local function jump_to_breakpoint(bp)
  local buf = vim.fn.bufnr(BUFFER_NAME)
  if buf >= 0 and vim.bo[buf].modified then
    utils.notify('Save breakpoints before jumping', vim.log.levels.ERROR)
    return
  end
  if bp == nil then
    bp = bp_by_lnum[vim.fn.line('.')]
  end
  if not bp or not bp.buf then
    return
  end
  api.nvim_win_close(0, false)
  api.nvim_win_set_buf(0, bp.buf)
  api.nvim_win_set_cursor(0, { bp.line, 0 })
  vim.cmd("normal! m'")
end

---@return integer
function M.new_buf()
  local bufnr = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(bufnr, BUFFER_NAME)
  vim.bo[bufnr].buftype = 'acwrite'
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].filetype = 'dap-breakpoints'
  vim.bo[bufnr].modifiable = true
  render(bufnr)
  vim.bo[bufnr].modified = false
  local group = api.nvim_create_augroup(
    'DapBreakpointsEditor_' .. bufnr,
    { clear = true }
  )
  api.nvim_create_autocmd('BufWriteCmd', {
    group = group,
    buffer = bufnr,
    callback = function(args)
      if vim.bo[bufnr] and vim.bo[bufnr].modified then
        M.save(args.buf)
      end
    end,
  })
  api.nvim_create_autocmd('BufEnter', {
    group = group,
    buffer = bufnr,
    callback = function()
      refresh_if_clean(bufnr)
    end,
  })
  api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = bufnr,
    once = true,
    callback = function()
      bp_by_lnum = {}
      pcall(api.nvim_del_augroup_by_id, group)
    end,
  })
  vim.keymap.set('n', '<CR>', jump_to_breakpoint, { buffer = bufnr })
  return bufnr
end

local function focus_buffer(bufnr)
  local winid = vim.fn.win_findbuf(bufnr)[1]
  if not winid then
    winid = api.nvim_get_current_win()
    api.nvim_win_set_buf(winid, bufnr)
  end
  api.nvim_set_current_win(winid)
end

---Open a new editor in the current window, or open an existing editor buffer
---in its corresponding window, defaulting to the current window.
---
---If opts are passed, it will try to focus the corresponding breakpoint.
---@param opts {
---  curline?: boolean,
---  bufnr?: integer,
---  lnum?: integer,
---  func?: string,
---}?
function M.open(opts)
  local buf = vim.fn.bufnr(BUFFER_NAME)
  if buf < 0 then
    buf = M.new_buf()
    vim.cmd.tabnew()
    vim.api.nvim_win_set_buf(0, buf)
  end
  focus_buffer(buf)
  if not opts then
    return
  end
  if not bp_by_lnum or #bp_by_lnum == 0 then
    return
  end
  local key
  if opts.curline then
    local bufnr = api.nvim_get_current_buf()
    local line = api.nvim_win_get_cursor(api.nvim_get_current_win())[1]
    local bps = breakpoints.get({ bufexpr = bufnr, lnum = line })[bufnr]
    key = bps and bp_key(bps[1]) or nil
  elseif opts.bufnr then
    if not opts.lnum then
      return
    end
    local bps = breakpoints.get({ bufexpr = opts.bufnr, lnum = opts.lnum })[opts.bufnr]
    key = bps and bp_key(bps[1]) or nil
  elseif opts.lnum then
    local bufnr = api.nvim_get_current_buf()
    local bps = breakpoints.get({ bufexpr = bufnr, lnum = opts.lnum })[bufnr]
    key = bps and bp_key(bps[1]) or nil
  elseif opts.func then
    local fbps = breakpoints.func.get({ name = opts.func })
    key = fbps and bp_key(fbps[1]) or nil
  end
  if not key then
    return
  end
  for lnum, bp in pairs(bp_by_lnum) do
    if bp_key(bp) == key then
      api.nvim_win_set_cursor(0, { lnum, 0 })
      return
    end
  end
end

---@param bufnr integer
function M.save(bufnr)
  if not api.nvim_buf_is_valid(bufnr) then
    utils.notify('Unable to save, buffer ' .. bufnr .. ' does not exist', vim.log.levels.WARN)
    return
  end
  local parsed_bps, parsed_fbps, errors = parse(bufnr)
  if #errors > 0 then
    local diagnostics = {}
    for _, err in ipairs(errors) do
      diagnostics[#diagnostics + 1] = {
        lnum = err.lnum - 1,
        col = 0,
        severity = vim.diagnostic.severity.ERROR,
        source = diagnostic_source,
        message = err.message,
      }
    end
    vim.diagnostic.set(diagnostic_ns, bufnr, diagnostics)
    return
  end
  local diffs = diff_breakpoints(parsed_bps, parsed_fbps)
  local live_bps = vim.iter(breakpoints.get()):flatten():totable()
  local live_fbps = breakpoints.func.get()
  local live_diffs = diff_breakpoints(live_bps, live_fbps)
  local conflicts
  diffs, live_diffs, conflicts = find_conflicts(diffs, live_diffs)
  if #conflicts > 0 then
    local msg = get_conflicts_prompt(conflicts)
    local confirm_res = vim.fn.confirm(msg, '&Cancel\nTake &Editor\nTake Live', 1, 'Question')
    if confirm_res == 0 or confirm_res == 1 then
      return
    elseif confirm_res == 3 then
      diffs = live_diffs
    end
  end
  if #diffs > 0 then
    local msg = get_diff_prompt(diffs)
    local confirm_res = vim.fn.confirm(msg, '&Yes\n&Cancel', 1, 'Question')
    if confirm_res == 0 or confirm_res == 2 then
      return
    end
    apply_diffs(diffs)
    --Render the updated breakpoints
    render(bufnr)
  end
  vim.bo[bufnr].modified = false
end

M.buffer_name = BUFFER_NAME
return M

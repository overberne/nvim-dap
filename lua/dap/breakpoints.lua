local api = vim.api
local non_empty = require('dap.utils').non_empty
local utils = require('dap.utils')

---@class dap.bp
---@field buf integer
---@field line integer
---@field condition string?
---@field logMessage string?
---@field hitCondition string?
---@field state dap.Breakpoint?

---@type table<integer, table<integer, dap.bp>> buffer → sign id → bp
local bp_by_sign_by_buf = {}

---@class dap.bp.func
---@field name string
---@field condition string?
---@field hitCondition string?
---@field state dap.Breakpoint?

---@type table<string, dap.bp.func>
local func_bp_by_name = {}

---@class dap.bp.data
---@field dataId string
---@field accessType dap.DataBreakpointAccessType?
---@field condition string?
---@field hitCondition string?
---@field canPersist boolean?
---@field state dap.Breakpoint?

---@type table<string, table<dap.DataBreakpointAccessType | "", dap.bp.data>>
local data_bp_by_type_by_id = {}

local ns = 'dap_breakpoints'
local M = {}
local M_func = {}
local M_data = {}


---@param bufexpr? string|integer
---@return vim.fn.sign_getplaced.ret.item[]
local function get_breakpoint_signs(bufexpr)
  if bufexpr then
    return vim.fn.sign_getplaced(bufexpr, { group = ns })
  end
  local bufs_with_signs = vim.fn.sign_getplaced()
  local result = {}
  for _, buf_signs in ipairs(bufs_with_signs) do
    buf_signs = vim.fn.sign_getplaced(buf_signs.bufnr, { group = ns })[1]
    if #buf_signs.signs > 0 then
      table.insert(result, buf_signs)
    end
  end
  return result
end

---@param bp dap.bp
local function get_sign_name(bp)
  if bp.state and bp.state.verified == false then
    return 'DapBreakpointRejected'
  elseif non_empty(bp.condition) then
    return 'DapBreakpointCondition'
  elseif non_empty(bp.logMessage) then
    return 'DapLogPoint'
  else
    return 'DapBreakpoint'
  end
end


---@param breakpoint dap.Breakpoint
function M.update(breakpoint)
  assert(breakpoint.id, "To update a breakpoint it must have an id property")
  for _, bp_by_sign in pairs(bp_by_sign_by_buf) do
    for sign_id, bp in pairs(bp_by_sign) do
      if bp.state and bp.state.id == breakpoint.id then
        local verified_changed = bp.state.verified ~= breakpoint.verified
        bp.state.verified = breakpoint.verified
        bp.state.message = breakpoint.message
        if verified_changed then
          vim.fn.sign_place(
            sign_id,
            ns,
            get_sign_name(bp),
            bp.buf,
            { lnum = bp.line, priority = 21, }
          )
        end
        return
      end
    end
  end
  for _, fbp in pairs(func_bp_by_name) do
    if fbp.state and fbp.state.id == breakpoint.id then
      fbp.state.verified = breakpoint.verified
      fbp.state.message = breakpoint.message
      return
    end
  end
  for _, data_bp_by_type in pairs(data_bp_by_type_by_id) do
    for _, dbp in pairs(data_bp_by_type) do
      if dbp.state and dbp.state.id == breakpoint.id then
        dbp.state.verified = breakpoint.verified
        dbp.state.message = breakpoint.message
        return
      end
    end
  end
end

---@param bufnr integer
---@param state dap.Breakpoint
function M.set_state(bufnr, state)
  local ok, placements = pcall(vim.fn.sign_getplaced, bufnr, { group = ns, lnum = state.line, })
  if not ok then
    return
  end
  local signs = (placements[1] or {}).signs
  if not signs or next(signs) == nil then
    return
  end
  for _, sign in pairs(signs) do
    local bp = bp_by_sign_by_buf[bufnr][sign.id]
    if bp then
      bp.state = state
    end
    if not state.verified then
      vim.fn.sign_place(
        sign.id,
        ns,
        'DapBreakpointRejected',
        bufnr,
        { lnum = state.line, priority = 21, }
      )
    end
  end
end

function M.remove(bufnr, lnum)
  local placements = vim.fn.sign_getplaced(bufnr, { group = ns, lnum = lnum, })
  local signs = placements[1].signs
  if signs and #signs > 0 then
    for _, sign in pairs(signs) do
      vim.fn.sign_unplace(ns, { buffer = bufnr, id = sign.id, })
      bp_by_sign_by_buf[bufnr][sign.id] = nil
    end
    return true
  else
    return false
  end
end

function M.remove_by_id(id)
  for _, bp_by_sign in pairs(bp_by_sign_by_buf) do
    for sign_id, bp in pairs(bp_by_sign) do
      if bp.state and bp.state.id == id then
        vim.fn.sign_unplace(ns, { buffer = bp.buf, id = sign_id, })
        bp_by_sign_by_buf[bp.buf][sign_id] = nil
        return
      end
    end
  end
  for name, fbp in pairs(func_bp_by_name) do
    if fbp.state and fbp.state.id == id then
      func_bp_by_name[name] = nil
      return
    end
  end
  for data_id, data_bp_by_type in pairs(data_bp_by_type_by_id) do
    for access_type, dbp in pairs(data_bp_by_type) do
      if dbp.state and dbp.state.id == id then
        data_bp_by_type_by_id[data_id][access_type] = nil
        if #data_bp_by_type == 0 then
          data_bp_by_type_by_id[data_id] = nil
        end
        return
      end
    end
  end
end

---@class dap.breakpoints.set.Opts
---@field bufnr? integer
---@field lnum? integer
---@field condition? string
---@field log_message? string
---@field hit_condition? string

--- Sets a breakpoint
---
---@param opts? dap.breakpoints.set.Opts
function M.set(opts)
  ---@type dap.breakpoints.toggle.Opts
  opts = opts or {}
  opts.replace = true
  M.toggle(opts)
end

---@class dap.breakpoints.toggle.Opts : dap.breakpoints.set.Opts
---@field replace? boolean

--- Toggles a breakpoint
---
---@param opts? dap.breakpoints.toggle.Opts
function M.toggle(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or api.nvim_get_current_buf()
  local lnum = opts.lnum or api.nvim_win_get_cursor(0)[1]
  if M.remove(bufnr, lnum) and not opts.replace then
    return
  end
  local bp = { ---@type dap.bp
    buf = bufnr,
    line = lnum,
    condition = opts.condition,
    logMessage = opts.log_message,
    hitCondition = opts.hit_condition
  }
  local sign_name = get_sign_name(bp)
  local sign_id = vim.fn.sign_place(
    0,
    ns,
    sign_name,
    bufnr,
    { lnum = lnum, priority = 21, }
  )
  if sign_id ~= -1 then
    if not bp_by_sign_by_buf[bufnr] then
      bp_by_sign_by_buf[bufnr] = {}
    end
    bp_by_sign_by_buf[bufnr][sign_id] = bp
  end
end


---@param name string
---@param state dap.Breakpoint
function M_func.set_state(name, state)
  local fbp = func_bp_by_name[name]
  if fbp then
    fbp.state = state
  end
  if not state.verified then
    utils.notify('Function breakpoint "' .. name .. '" rejected', vim.log.levels.ERROR)
  end
end

---@param name string
---@return boolean
function M_func.remove(name)
  if func_bp_by_name[name] then
    func_bp_by_name[name] = nil
    return true
  end
  return false
end


---@class dap.breakpoints.func.set.Opts
---@field condition? string
---@field hit_condition? string

---@param name string
---@param opts? dap.breakpoints.func.set.Opts
function M_func.set(name, opts)
  ---@type dap.breakpoints.func.toggle.Opts
  opts = opts or {}
  opts.replace = true
  M_func.toggle(name, opts)
end


---@class dap.breakpoints.func.toggle.Opts : dap.breakpoints.func.set.Opts
---@field replace? boolean

---@param name string
---@param opts? dap.breakpoints.func.toggle.Opts
function M_func.toggle(name, opts)
  opts = opts or {}
  if M_func.remove(name) and not opts.replace then
    return
  end
  local bp = { ---@type dap.bp.func
    name = name,
    condition = opts.condition,
    hitCondition = opts.hit_condition
  }
  func_bp_by_name[name] = bp
end


---@param data_id string
---@param access_type? dap.DataBreakpointAccessType
---@param state dap.Breakpoint
function M_data.set_state(data_id, access_type, state)
  local dbp = data_bp_by_type_by_id[data_id] and data_bp_by_type_by_id[data_id][access_type]
  if dbp then
    dbp.state = state
  end
  if not state.verified then
    if dbp.accessType then
      utils.notify(
        ('Data breakpoint "%s:%s" rejected: %s'):format(dbp.dataId, dbp.accessType, state.message),
        vim.log.levels.ERROR
      )
    else
      utils.notify(
        ('Data breakpoint "%s" rejected: %s'):format(dbp.dataId, state.message),
        vim.log.levels.ERROR
      )
    end
  end
end

---@param data_id string
---@param access_type dap.DataBreakpointAccessType | nil
---@return boolean
function M_data.remove(data_id, access_type)
  local data_bp_by_type = data_bp_by_type_by_id[data_id]
  if data_bp_by_type and data_bp_by_type[access_type or ""] then
    data_bp_by_type_by_id[data_id][access_type or ""] = nil
    if #data_bp_by_type == 0 then
      data_bp_by_type_by_id[data_id] = nil
    end
    return true
  end
  return false
end


---@class dap.breakpoints.data.set.Opts
---@field condition? string
---@field hit_condition? string
---@field can_persist? boolean

---@param data_id string
---@param access_type dap.DataBreakpointAccessType | nil
---@param opts? dap.breakpoints.data.set.Opts
function M_data.set(data_id, access_type, opts)
  ---@type dap.breakpoints.data.toggle.Opts
  opts = opts or {}
  opts.replace = true
  M_data.toggle(data_id, access_type, opts)
end


---@class dap.breakpoints.data.toggle.Opts : dap.breakpoints.data.set.Opts
---@field replace? boolean

---@param data_id string
---@param access_type dap.DataBreakpointAccessType | nil
---@param opts? dap.breakpoints.data.toggle.Opts
function M_data.toggle(data_id, access_type, opts)
  opts = opts or {}
  if M_data.remove(data_id, access_type) and not opts.replace then
    return
  end
  local dbp = { ---@type dap.bp.data
    dataId = data_id,
    accessType = access_type,
    condition = opts.condition,
    hitCondition = opts.hit_condition,
    canPersist = opts.can_persist
  }
  if not data_bp_by_type_by_id[data_id] then
    data_bp_by_type_by_id[data_id] = {}
  end
  data_bp_by_type_by_id[data_id][access_type or ""] = dbp
end

do
  local function matches(value, filter)
    return filter == nil or filter == (value ~= nil and value ~= "")
  end

  ---@class dap.breakpoints.get.Opts
  ---@field bufexpr? integer|string,
  ---@field lnum? integer,
  ---@field condition? boolean,
  ---@field log_message? boolean,
  ---@field hit_condition? boolean,

  --- Returns all breakpoints grouped by bufnr
  ---
  ---@param opts? dap.breakpoints.get.Opts
  ---@return table<integer, dap.bp[]>
  function M.get(opts)
    opts = opts or {}
    local signs = get_breakpoint_signs(opts.bufexpr)
    if #signs == 0 then
      return {}
    end
    local result = {}
    for _, buf_bp_signs in pairs(signs) do
      local breakpoints = {}
      local bufnr = buf_bp_signs.bufnr
      for _, sign in pairs(buf_bp_signs.signs) do
        local bp = bp_by_sign_by_buf[bufnr][sign.id] or {}
        if (opts.lnum == nil or sign.lnum == opts.lnum)
            and matches(bp.condition, opts.condition)
            and matches(bp.logMessage, opts.log_message)
            and matches(bp.hitCondition, opts.hit_condition)
        then
          table.insert(breakpoints, {
            buf = bufnr,
            line = sign.lnum,
            condition = bp.condition,
            hitCondition = bp.hitCondition,
            logMessage = bp.logMessage,
            state = bp.state,
          })
        end
      end
      if #breakpoints > 0 then
        result[bufnr] = breakpoints
      end
    end
    return result
  end

  ---@class dap.breakpoints.func.get.Opts
  ---@field name? string
  ---@field condition? boolean
  ---@field hit_condition? boolean

  ---@param opts? dap.breakpoints.func.get.Opts
  ---@return dap.bp.func[]
  function M_func.get(opts)
    opts = opts or {}
    local result = {}
    for _, fbp in pairs(func_bp_by_name) do
      if matches(fbp.name, opts.name)
          and matches(fbp.condition, opts.condition)
          and matches(fbp.hitCondition, opts.hit_condition)
      then
        table.insert(result, {
          name = fbp.name,
          condition = fbp.condition,
          hitCondition = fbp.hitCondition,
          state = fbp.state,
        })
      end
    end
    return result
  end

  ---@class dap.breakpoints.data.get.Opts
  ---@field data_id? string
  ---@field access_type? dap.DataBreakpointAccessType
  ---@field can_persist? boolean
  ---@field condition? boolean
  ---@field hit_condition? boolean

  ---@param opts? dap.breakpoints.data.get.Opts
  ---@return dap.bp.data[]
  function M_data.get(opts)
    opts = opts or {}
    local result = {}
    for _, data_bp_by_type in pairs(data_bp_by_type_by_id) do
      for _, dbp in pairs(data_bp_by_type) do
        if matches(dbp.dataId, opts.data_id)
            and matches(dbp.accessType, opts.access_type)
            and matches(dbp.canPersist, opts.can_persist)
            and matches(dbp.condition, opts.condition)
            and matches(dbp.hitCondition, opts.hit_condition)
        then
          table.insert(result, {
            dataId = dbp.dataId,
            accessType = dbp.accessType,
            condition = dbp.condition,
            hitCondition = dbp.hitCondition,
            canPersist = dbp.canPersist,
            state = dbp.state,
          })
        end
      end
    end
    return result
  end

  ---@class dap.breakpoints.clear.Opts : dap.breakpoints.get.Opts
  ---@field func? boolean
  ---@field data? boolean
  ---@field can_persist? boolean

  ---@param opts? dap.breakpoints.clear.Opts
  function M.clear(opts)
    if opts == nil or next(opts) == nil then
      vim.fn.sign_unplace(ns)
      bp_by_sign_by_buf = {}
      func_bp_by_name = {}
      data_bp_by_type_by_id = {}
      return
    end
    local signs = get_breakpoint_signs(opts.bufexpr)
    for _, buf_bp_signs in pairs(signs) do
      local bufnr = buf_bp_signs.bufnr
      local bp_by_sign = bp_by_sign_by_buf[bufnr]
      for _, sign in pairs(buf_bp_signs.signs) do
        local bp = bp_by_sign and bp_by_sign[sign.id] or {}
        if (opts.lnum == nil or sign.lnum == opts.lnum)
            and matches(bp.condition, opts.condition)
            and matches(bp.logMessage, opts.log_message)
            and matches(bp.hitCondition, opts.hit_condition)
        then
          vim.fn.sign_unplace(ns, {
            buffer = bufnr,
            id = sign.id,
          })
          if bp_by_sign then
            bp_by_sign[sign.id] = nil
          end
        end
      end
      if bp_by_sign and next(bp_by_sign) == nil then
        bp_by_sign_by_buf[bufnr] = nil
      end
    end
    if opts.func then
      for name, fbp in pairs(func_bp_by_name) do
        if matches(fbp.condition, opts.condition)
            and matches(fbp.hitCondition, opts.hit_condition)
        then
          func_bp_by_name[name] = nil
        end
      end
    end
    if opts.data then
      for data_id, data_bp_by_type in pairs(data_bp_by_type_by_id) do
        for access_type, dbp in pairs(data_bp_by_type) do
          if matches(dbp.canPersist, opts.can_persist)
              and matches(dbp.condition, opts.condition)
              and matches(dbp.hitCondition, opts.hit_condition)
          then
            data_bp_by_type_by_id[data_id][access_type] = nil
            if #data_bp_by_type == 0 then
              data_bp_by_type_by_id[data_id] = nil
            end
          end
        end
      end
    end
  end
end


do
  local function not_nil(x)
    return x ~= nil
  end

  --- Function breakpoints are excluded from qflist. qflist is made
  --- for jumping between breakpoints, function breakpoints have no location
  --- in a buffer.
  function M.to_qf_list(breakpoints)
    local qf_list = {}
    for bufnr, buf_bps in pairs(breakpoints) do
      for _, bp in pairs(buf_bps) do
        local state = bp.state or {}
        local text_parts = {
          unpack(api.nvim_buf_get_lines(bufnr, bp.line - 1, bp.line, false), 1),
          state.verified == false and (state.message and 'Rejected: ' .. state.message or 'Rejected') or nil,
          non_empty(bp.logMessage) and "Log message: " .. bp.logMessage or nil,
          non_empty(bp.condition) and "Condition: " .. bp.condition or nil,
          non_empty(bp.hitCondition) and "Hit condition: " .. bp.hitCondition or nil,
        }
        local text = table.concat(vim.tbl_filter(not_nil, text_parts), ', ')
        table.insert(qf_list, {
          bufnr = bufnr,
          lnum = bp.line,
          col = 0,
          text = text,
        })
      end
    end
    return qf_list
  end
end

--- Jump to next/prev breakpoint.
---
--- Returns false when no jump is available.
---
---@param count? integer
---@return boolean
function M.jump(count)
  if count == 0 then
    return true
  end
  count = count or 1
  local curbuf = api.nvim_get_current_buf()
  local curline = api.nvim_win_get_cursor(0)[1]
  local targets = {}
  local buffers = vim.tbl_keys(bp_by_sign_by_buf)
  table.sort(buffers)
  for _, bufnr in ipairs(buffers) do
    local bp_by_sign = bp_by_sign_by_buf[bufnr]
    local placed = vim.fn.sign_getplaced(bufnr, { group = ns })[1]
    local signs = placed and placed.signs or {}
    for _, sign in ipairs(signs) do
      if bp_by_sign[sign.id] then
        targets[#targets + 1] = {
          bufnr = bufnr,
          id = sign.id,
          lnum = sign.lnum,
        }
      end
    end
  end
  if #targets == 0 then
    return false
  end
  local direction = count > 0 and 1 or -1
  local start = 1
  if direction > 0 then
    for i, target in ipairs(targets) do
      if target.bufnr > curbuf
          or (target.bufnr == curbuf and target.lnum > curline)
      then
        start = i
        break
      end
    end
  else
    start = #targets
    for i = #targets, 1, -1 do
      local target = targets[i]
      if target.bufnr < curbuf
          or (target.bufnr == curbuf and target.lnum < curline)
      then
        start = i
        break
      end
    end
  end
  local offset = direction * (math.abs(count) - 1)
  local index = ((start - 1 + offset) % #targets) + 1
  local target = targets[index]
  vim.fn.sign_jump(target.id, ns, target.bufnr)
  return true
end

M.func = M_func
M.data = M_data
return M

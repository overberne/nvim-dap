local api = vim.api
local non_empty = require('dap.utils').non_empty

---@class dap.bp
---@field buf integer
---@field line integer
---@field condition string?
---@field logMessage string?
---@field hitCondition string?
---@field state dap.Breakpoint?

---@type table<integer, table<integer, dap.bp>> buffer → sign id → bp
local bp_by_sign_by_buf = {}
local ns = 'dap_breakpoints'
local M = {}


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
end

---@class BpSetOpts
---@field bufnr? integer
---@field lnum? integer
---@field condition? string
---@field log_message? string
---@field hit_condition? string

--- Sets a breakpoint
---
---@param opts? BpSetOpts
function M.set(opts)
  ---@type BpToggleOpts
  opts = opts or {}
  opts.replace = true
  M.toggle(opts)
end

---@class BpToggleOpts : BpSetOpts
---@field replace? boolean

--- Toggles a breakpoint
---
---@param opts? BpToggleOpts
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

---@class BpFilterOpts
---@field bufexpr? integer|string,
---@field lnum? integer,
---@field condition? boolean,
---@field log_message? boolean,
---@field hit_condition? boolean,

do
  local function matches(value, filter)
    return filter == nil or filter == (value ~= nil and value ~= "")
  end

  --- Returns all breakpoints grouped by bufnr
  ---
  ---@param opts? BpFilterOpts
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

  ---@param opts? BpFilterOpts
  function M.clear(opts)
    if opts == nil or next(opts) == nil then
      vim.fn.sign_unplace(ns)
      bp_by_sign_by_buf = {}
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
  end
end

do
  local function not_nil(x)
    return x ~= nil
  end

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

---@param count? integer
function M.jump(count)
  if count == 0 then
    return
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
        targets[#targets+1] = {
          bufnr = bufnr,
          id = sign.id,
          lnum = sign.lnum,
        }
      end
    end
  end
  if #targets == 0 then
    return
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
end

return M

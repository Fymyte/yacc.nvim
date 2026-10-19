--- Answers the CLI's `can_use_tool` requests with vim.ui.select. Requests from all
--- sessions share one queue so only one prompt is open at a time.

local api = vim.api

local M = {}

---@class yacc.PermissionItem
---@field session yacc.Session
---@field request_id string
---@field req table
---@field diff_tab? integer

---@type yacc.PermissionItem[]
local queue = {}
local prompting = false

---@param s string
---@param old string
---@param new string
---@param all boolean
---@return string
local function replace(s, old, new, all)
  if old == '' then
    return s
  end
  local out, i = {}, 1
  while true do
    local a, b = s:find(old, i, true)
    if not a then
      break
    end
    out[#out + 1] = s:sub(i, a - 1) .. new
    i = b + 1
    if not all then
      break
    end
  end
  out[#out + 1] = s:sub(i)
  return table.concat(out)
end

---@param req table
---@return string? path
---@return string? current
---@return string? proposed
local function proposed(req)
  local input = req.input or {}
  local path = input.file_path
  if type(path) ~= 'string' then
    return
  end
  local cur = ''
  if vim.fn.filereadable(path) == 1 then
    cur = table.concat(vim.fn.readfile(path, 'b'), '\n')
  end
  local name = req.tool_name
  if name == 'Write' then
    return path, cur, input.content or ''
  elseif name == 'Edit' then
    return path, cur, replace(cur, input.old_string or '', input.new_string or '', input.replace_all)
  elseif name == 'MultiEdit' then
    local new = cur
    for _, e in ipairs(input.edits or {}) do
      new = replace(new, e.old_string or '', e.new_string or '', e.replace_all)
    end
    return path, cur, new
  end
end

---@param text string
---@param ft string
---@return integer
local function scratch(text, ft)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, '\n', { plain = true }))
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = ft
  vim.bo[buf].modifiable = false
  return buf
end

---@param item yacc.PermissionItem
local function show_diff(item)
  local path, cur, new = proposed(item.req)
  if not path then
    return
  end
  local ft = vim.filetype.match { filename = path } or ''
  vim.cmd.tabnew()
  item.diff_tab = api.nvim_get_current_tabpage()
  local left = api.nvim_get_current_win()
  api.nvim_win_set_buf(left, scratch(cur, ft))
  vim.cmd.diffthis()
  vim.cmd 'rightbelow vsplit'
  api.nvim_win_set_buf(0, scratch(new, ft))
  vim.cmd.diffthis()
  vim.wo.winbar = ('Proposed: %s'):format(vim.fn.fnamemodify(path, ':~:.'))
  api.nvim_set_option_value('winbar', 'Current', { win = left })
end

---@param item yacc.PermissionItem
local function close_diff(item)
  if item.diff_tab and api.nvim_tabpage_is_valid(item.diff_tab) then
    vim.cmd.tabclose(api.nvim_tabpage_get_number(item.diff_tab))
  end
  item.diff_tab = nil
end

---@param s table permission_suggestions entry
---@return string
local function describe(s)
  local what
  if s.type == 'addRules' or s.type == 'replaceRules' then
    local rules = {}
    for _, r in ipairs(s.rules or {}) do
      rules[#rules + 1] = r.ruleContent and ('%s(%s)'):format(r.toolName, r.ruleContent) or r.toolName
    end
    what = table.concat(rules, ', ')
  elseif s.type == 'setMode' then
    what = 'mode ' .. tostring(s.mode)
  elseif s.type == 'addDirectories' then
    what = 'dir ' .. table.concat(s.directories or {}, ', ')
  else
    what = s.type
  end
  return s.destination and ('%s (%s)'):format(what, s.destination) or what
end

---@param item yacc.PermissionItem
local function remove(item)
  for i, q in ipairs(queue) do
    if q == item then
      table.remove(queue, i)
      break
    end
  end
  close_diff(item)
end

---@param item yacc.PermissionItem
---@param response table
local function answer(item, response)
  remove(item)
  item.session:respond(item.request_id, response)
end

local function deny(msg)
  return { behavior = 'deny', message = msg }
end

local next_prompt

---@param item yacc.PermissionItem
local function prompt(item)
  local req = item.req
  local input = req.input or {}
  local choices = {
    { label = 'Allow', act = 'allow' },
  }
  local suggestions = req.permission_suggestions or {}
  if #suggestions > 0 then
    local labels = vim.tbl_map(describe, suggestions)
    choices[#choices + 1] = { label = 'Allow always: ' .. table.concat(labels, '; '), act = 'always' }
  end
  if proposed(req) and not item.diff_tab then
    choices[#choices + 1] = { label = 'Show diff', act = 'diff' }
  end
  choices[#choices + 1] = { label = 'Deny', act = 'deny' }
  choices[#choices + 1] = { label = 'Deny with message…', act = 'deny_msg' }

  local desc = req.description or input.command or input.file_path or ''
  local title = ('Claude #%d: allow %s? %s'):format(item.session.id, req.display_name or req.tool_name, desc)
  if req.decision_reason then
    title = title .. (' (%s)'):format(req.decision_reason)
  end

  prompting = true
  vim.ui.select(choices, {
    prompt = title,
    kind = 'cc.permission',
    format_item = function(c)
      return c.label
    end,
  }, function(choice)
    prompting = false
    if not choice then
      vim.notify(('Claude #%d waits for a permission, :CCPermission to answer'):format(item.session.id))
      return
    end
    if choice.act == 'allow' then
      answer(item, { behavior = 'allow', updatedInput = input })
    elseif choice.act == 'always' then
      answer(item, { behavior = 'allow', updatedInput = input, updatedPermissions = suggestions })
    elseif choice.act == 'deny' then
      answer(item, deny 'The user denied this tool use.')
    elseif choice.act == 'deny_msg' then
      vim.ui.input({ prompt = 'Reason: ' }, function(msg)
        answer(item, deny(msg and msg ~= '' and msg or 'The user denied this tool use.'))
        vim.schedule(next_prompt)
      end)
      return
    elseif choice.act == 'diff' then
      show_diff(item)
    end
    vim.schedule(next_prompt)
  end)
end

---@param session? yacc.Session Only prompt for this session
next_prompt = function(session)
  if prompting then
    return
  end
  for _, item in ipairs(queue) do
    if not session or item.session == session then
      return prompt(item)
    end
  end
end

---@param session yacc.Session
---@param request_id string
---@param req table
function M.ask(session, request_id, req)
  queue[#queue + 1] = { session = session, request_id = request_id, req = req }
  next_prompt()
end

--- Open the prompt again after it was dismissed
---@param session? yacc.Session
function M.resume(session)
  next_prompt(session)
end

---@param session yacc.Session
---@return integer
function M.count(session)
  local n = 0
  for _, item in ipairs(queue) do
    n = n + (item.session == session and 1 or 0)
  end
  return n
end

--- The CLI gave up on a request, after an interrupt for example
---@param session yacc.Session
---@param request_id string
function M.cancel(session, request_id)
  for _, item in ipairs(queue) do
    if item.session == session and item.request_id == request_id then
      return remove(item)
    end
  end
end

--- Forget the requests of a session whose process is gone
---@param session yacc.Session
function M.drop(session)
  for i = #queue, 1, -1 do
    if queue[i].session == session then
      remove(queue[i])
    end
  end
end

return M

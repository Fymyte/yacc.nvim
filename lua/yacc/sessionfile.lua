--- Vim session files. `:mksession` cannot restore scratch buffers, it saves the panel as
--- an empty window with the output buffer's name, `claude://<n>/<uuid>`, over an empty
--- one for the input. Once the file is loaded, those windows get the session back.

local api = vim.api
local root = (...):match '^(.*%.)'
local session = require(root .. 'session')

local M = {}

--- The input window that `:mksession` saved under the output one
---@param win integer
---@return integer?
local function input_below(win)
  local below = api.nvim_win_call(win, function()
    return vim.fn.win_getid(vim.fn.winnr 'j')
  end)
  if below == 0 or below == win then
    return nil
  end
  local buf = api.nvim_win_get_buf(below)
  if
    api.nvim_buf_get_name(buf) == ''
    and vim.bo[buf].buftype == ''
    and not vim.bo[buf].modified
    and api.nvim_buf_line_count(buf) == 1
    and api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ''
  then
    return below
  end
end

--- `:file` in the session file fails with E95 on a name that a live output buffer has
function M.pre()
  for _, s in pairs(session.sessions) do
    s:set_name 'loading'
  end
end

local function restore()
  local ui = require(root .. 'ui')
  local history = require(root .. 'history')
  local found = {}
  for _, win in ipairs(api.nvim_list_wins()) do
    local buf = api.nvim_win_get_buf(win)
    local n, tag = api.nvim_buf_get_name(buf):match '^claude://(%d+)/(.+)$'
    if n and not vim.b[buf].cc_kind then
      found[#found + 1] = { win = win, buf = buf, n = tonumber(n), tag = tag }
    end
  end
  for _, f in ipairs(found) do
    local input = input_below(f.win)
    local input_buf = input and api.nvim_win_get_buf(input)
    -- Free the name before the session takes it, and keep the windows open
    if api.nvim_buf_is_valid(f.buf) then
      local scratch = api.nvim_create_buf(false, true)
      vim.bo[scratch].bufhidden = 'wipe'
      for _, w in ipairs(vim.fn.win_findbuf(f.buf)) do
        api.nvim_win_set_buf(w, scratch)
      end
      api.nvim_buf_delete(f.buf, { force = true })
    end
    -- A session that never sent a prompt has no transcript to resume
    local h = f.tag:match '^%x+%-' and history.find(f.tag)
    if h then
      ui.adopt(ui.resume(h, f.n), f.win, input)
    else
      for _, w in ipairs { input, f.win } do
        -- Fails on the last window
        pcall(api.nvim_win_close, w, true)
      end
    end
    if input_buf and api.nvim_buf_is_valid(input_buf) and #vim.fn.win_findbuf(input_buf) == 0 then
      api.nvim_buf_delete(input_buf, { force = true })
    end
  end
  for _, s in pairs(session.sessions) do
    s:set_name()
  end
end

local pending = false

--- `doautoall` runs SessionLoadPost once per buffer, restore once after the whole file
function M.post()
  if pending then
    return
  end
  pending = true
  vim.schedule(function()
    pending = false
    restore()
  end)
end

return M

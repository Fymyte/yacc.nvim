--- /usage: plan limits, session cost and what used them, from the CLI's get_usage request,
--- drawn in a float like the CLI's own /usage screen

local api = vim.api
local root = (...):match '^(.*%.)'

local M = {}

local ns = api.nvim_create_namespace 'yacc.usage'

local BAR = 50
local SMALL_BAR = 12
local EIGHTHS = { '▏', '▎', '▍', '▌', '▋', '▊', '▉' }

-- Keys of the behaviors the CLI finds in local transcripts
local BEHAVIORS = {
  cache_miss = 'cache misses',
  long_context = 'long context',
  subagent_heavy = 'subagent-heavy sessions',
  high_parallel = 'many sessions in parallel',
  cron = 'scheduled tasks',
  max_effort = 'max effort',
  workflow = 'workflows',
  always_on_context = 'always-on context',
  large_tool_results = 'large tool results',
}

---@class yacc.UsageText
---@field lines string[]
---@field hls [integer, integer, integer, string][] Row, start and end byte, group

---@return yacc.UsageText
local function text()
  return { lines = {}, hls = {} }
end

--- Append a line made of chunks
---@param t yacc.UsageText
---@param chunks? [string, string?][]
local function add(t, chunks)
  -- Two cells of left padding, draw() adds the same on the right
  local parts, col, row = { '  ' }, 2, #t.lines
  for _, c in ipairs(chunks or {}) do
    parts[#parts + 1] = c[1]
    if c[2] then
      t.hls[#t.hls + 1] = { row, col, col + #c[1], c[2] }
    end
    col = col + #c[1]
  end
  t.lines[#t.lines + 1] = table.concat(parts)
end

---@param pct number 0-100
---@return string
local function severity(pct)
  return pct >= 90 and 'CcUsageHigh' or pct >= 70 and 'CcUsageMedium' or 'CcUsageLow'
end

--- Bar chunks, filled to `pct` in eighths of a cell
---@param pct number 0-100
---@param width integer
---@param hl? string Fill color, by how close `pct` is to a limit when nil
---@return [string, string?][]
local function bar(pct, width, hl)
  local eighths = math.floor(math.max(0, math.min(pct, 100)) * width * 8 / 100 + 0.5)
  local full, rest = math.floor(eighths / 8), eighths % 8
  local filled = ('█'):rep(full) .. (rest > 0 and EIGHTHS[rest] or '')
  local empty = width - full - (rest > 0 and 1 or 0)
  return { { filled, hl or severity(pct) }, { ('░'):rep(empty), 'CcUsageEmpty' } }
end

---@param seconds number
---@return string
local function duration(seconds)
  seconds = math.max(0, math.floor(seconds))
  local d, h, m = math.floor(seconds / 86400), math.floor(seconds % 86400 / 3600), math.floor(seconds % 3600 / 60)
  if d > 0 then
    return ('%dd %dh'):format(d, h)
  elseif h > 0 then
    return ('%dh %dm'):format(h, m)
  elseif m > 0 then
    return ('%dm'):format(m)
  end
  return ('%ds'):format(seconds)
end

---@param iso? string
---@return string?
local function resets(iso)
  local t = iso and require(root .. 'history').iso_time(iso)
  if not t then
    return nil
  end
  -- The server sends 23:59:59.9 for midnight
  t = math.floor((t + 30) / 60) * 60
  local same_day = os.date('%Y%m%d', t) == os.date '%Y%m%d'
  local at = os.date(same_day and '%H:%M' or '%a %d %b %H:%M', t)
  return ('Resets %s (in %s)'):format(at, duration(t - os.time()))
end

--- One limit window: title, bar with the percentage, reset time
---@param t yacc.UsageText
---@param title string
---@param w? {utilization?: number, resets_at?: string}
local function window(t, title, w)
  if not w or not w.utilization then
    return
  end
  add(t, { { title, 'CcUsageTitle' } })
  local chunks = bar(w.utilization, BAR)
  chunks[#chunks + 1] = { ('  %d%% used'):format(math.floor(w.utilization + 0.5)) }
  add(t, chunks)
  local r = resets(w.resets_at)
  if r then
    add(t, { { r, 'CcHint' } })
  end
  add(t)
end

---@param t yacc.UsageText
---@param e? table extra_usage
local function extra(t, e)
  if not e then
    return
  end
  add(t, { { 'Extra usage', 'CcUsageTitle' } })
  if not e.is_enabled then
    add(t, { { 'Not enabled', 'CcHint' } })
  elseif e.utilization then
    local chunks = bar(e.utilization, BAR)
    chunks[#chunks + 1] = { ('  %d%% used'):format(math.floor(e.utilization + 0.5)) }
    add(t, chunks)
    if e.used_credits and e.monthly_limit then
      add(t, {
        { ('%.2f / %.2f %s this month'):format(e.used_credits, e.monthly_limit, e.currency or ''), 'CcHint' },
      })
    end
  else
    add(t, { { 'Enabled, no monthly limit', 'CcHint' } })
  end
  add(t)
end

---@param t yacc.UsageText
---@param s table session totals
local function session_cost(t, s)
  if not s then
    return
  end
  add(t, { { 'This session', 'CcUsageTitle' } })
  add(t, {
    { ('$%.2f'):format(s.total_cost_usd or 0) },
    {
      (' · API %s · wall %s · '):format(
        duration((s.total_api_duration_ms or 0) / 1000),
        duration((s.total_duration_ms or 0) / 1000)
      ),
      'CcHint',
    },
    { ('+%d'):format(s.total_lines_added or 0), 'CcUsageAdded' },
    { ' ' },
    { ('-%d'):format(s.total_lines_removed or 0), 'CcUsageRemoved' },
    { ' lines', 'CcHint' },
  })
  local models = vim.tbl_keys(s.model_usage or {})
  table.sort(models)
  for _, m in ipairs(models) do
    local cost = s.model_usage[m].costUSD
    if type(cost) == 'number' then
      add(t, { { '  ' .. (m:gsub('^claude%-', '')), 'CcHint' }, { ('  $%.2f'):format(cost) } })
    end
  end
  add(t)
end

--- Top entries of one attribution list, such as skills
---@param t yacc.UsageText
---@param label string
---@param list? {name: string, pct: number}[]
local function top(t, label, list)
  if not list or #list == 0 then
    return
  end
  local parts = {}
  for i = 1, math.min(#list, 4) do
    parts[#parts + 1] = ('%s %d%%'):format(list[i].name, math.floor(list[i].pct + 0.5))
  end
  add(t, { { ('  %-8s '):format(label), 'CcHint' }, { table.concat(parts, ' · ') } })
end

---@param t yacc.UsageText
---@param title string
---@param b? table one window of behaviors
local function behaviors(t, title, b)
  if not b then
    return
  end
  add(t, {
    { title, 'CcUsageSubtitle' },
    { (' · %d requests · %d sessions'):format(b.request_count or 0, b.session_count or 0), 'CcHint' },
  })
  for _, x in ipairs(b.behaviors or {}) do
    -- A share of the usage, not a limit
    local chunks = bar(x.pct, SMALL_BAR, 'CcUsageShare')
    table.insert(chunks, 1, { '  ' })
    chunks[#chunks + 1] = { (' %3d%%  %s'):format(math.floor(x.pct + 0.5), BEHAVIORS[x.key] or (x.key:gsub('_', ' '))) }
    chunks[#chunks + 1] = { (' (%d)'):format(x.count or 0), 'CcHint' }
    add(t, chunks)
  end
  top(t, 'agents', b.agents)
  top(t, 'skills', b.skills)
  top(t, 'plugins', b.plugins)
  top(t, 'mcp', b.mcp_servers)
  add(t)
end

--- Copy of a decoded JSON value with its nulls as nil, so `x or default` works
---@param v any
---@return any
local function denull(v)
  if v == vim.NIL then
    return nil
  elseif type(v) ~= 'table' then
    return v
  end
  local out = {}
  for k, x in pairs(v) do
    out[k] = denull(x)
  end
  return out
end

--- Lines of the float for a get_usage response
---@param u table
---@return yacc.UsageText
function M.format(u)
  u = denull(u)
  local t = text()
  add(t)
  local plan = u.subscription_type and (' · %s plan'):format(u.subscription_type) or ''
  add(t, { { 'Usage', 'CcUsageTitle' }, { plan, 'CcHint' } })
  add(t)
  local r = u.rate_limits
  if not u.rate_limits_available or not r then
    add(t, { { 'Plan limits do not apply to this session (API key or cloud provider)', 'CcHint' } })
    add(t)
  else
    window(t, 'Current session', r.five_hour)
    window(t, 'Current week (all models)', r.seven_day)
    window(t, 'Current week (Opus)', r.seven_day_opus)
    window(t, 'Current week (Sonnet)', r.seven_day_sonnet)
    for _, m in ipairs(r.model_scoped or {}) do
      window(t, ('Current week (%s)'):format(m.display_name), m)
    end
    extra(t, r.extra_usage)
  end
  session_cost(t, u.session)
  if u.behaviors then
    add(t, { { "What's contributing to your limits usage", 'CcUsageTitle' } })
    add(t, { { 'Approximate, from the sessions on this machine only', 'CcHint' } })
    add(t)
    behaviors(t, 'Last 24 hours', u.behaviors.day)
    behaviors(t, 'Last 7 days', u.behaviors.week)
  end
  return t
end

---@param buf integer
---@param win integer
---@param t yacc.UsageText
local function draw(buf, win, t)
  if not api.nvim_win_is_valid(win) then
    return
  end
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, t.lines)
  vim.bo[buf].modifiable = false
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(t.hls) do
    api.nvim_buf_set_extmark(buf, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end
  local width = 0
  for _, l in ipairs(t.lines) do
    width = math.max(width, api.nvim_strwidth(l) + 2)
  end
  width = math.min(width, vim.o.columns - 4)
  local height = math.min(#t.lines, vim.o.lines - 4)
  api.nvim_win_set_config(win, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
  })
end

--- Open the float and fill it when the CLI answers
---@param s yacc.Session
function M.show(s)
  if not s.proc then
    vim.notify('yacc: the session is not running', vim.log.levels.WARN)
    return
  end
  -- /usage is sent from the input in insert mode, the float only takes normal mode keys
  vim.cmd.stopinsert()
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'cc-usage'
  local win = api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = 40,
    height = 1,
    row = 1,
    col = 1,
    -- No number, sign or fold column from the user's global window options
    style = 'minimal',
    -- An empty 'winborder' means no border, the float needs one to stand out
    border = vim.o.winborder == '' and 'rounded' or nil,
    title = ' /usage ',
    title_pos = 'center',
  })
  vim.wo[win].wrap = false
  vim.wo[win].winhighlight = 'NormalFloat:Normal'
  local loading = text()
  add(loading, { { 'Loading usage…', 'CcHint' } })
  draw(buf, win, loading)
  for _, key in ipairs { 'q', '<Esc>' } do
    vim.keymap.set('n', key, function()
      pcall(api.nvim_win_close, win, true)
    end, { buffer = buf, nowait = true, desc = 'Close /usage' })
  end
  api.nvim_create_autocmd('WinLeave', {
    buffer = buf,
    once = true,
    callback = function()
      pcall(api.nvim_win_close, win, true)
    end,
  })
  s:request({ subtype = 'get_usage' }, function(resp)
    draw(buf, win, M.format(resp.response or {}))
  end, function(err)
    local t = text()
    add(t, { { 'get_usage failed: ' .. err, 'ErrorMsg' } })
    draw(buf, win, t)
  end)
end

return M

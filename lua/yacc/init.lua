--- Claude Code chat in two buffers, driven by `claude -p` in stream-json mode

local root = ... .. '.'
local config = require(root .. 'config')

local M = {}

---@param cmd string
---@return yacc.Session?
local function need_session(cmd)
  local s = require(root .. 'ui').current()
  if not s then
    vim.notify(('%s: no Claude session'):format(cmd), vim.log.levels.WARN)
  end
  return s
end

---@param s yacc.Session
---@return string[]
local function model_names(s)
  return vim.tbl_map(function(m)
    return m.value
  end, s.models)
end

local function commands()
  local ui = require(root .. 'ui')
  local function cmd(name, fn, opts)
    vim.api.nvim_create_user_command(name, fn, opts or {})
  end

  cmd('CCToggle', function(a)
    ui.toggle(a.count)
  end, { count = 0, desc = 'Toggle the Claude panel, a count picks the session' })

  cmd('CCNew', function()
    local s = ui.create()
    s:start()
    ui.show(s)
  end, { desc = 'New Claude session' })

  cmd('CCSessions', function(a)
    require(root .. 'picker').sessions(a.bang)
  end, { bang = true, desc = 'Pick a Claude session of this repository, ! for every project' })

  cmd('CCClose', function(a)
    local s = a.count > 0 and require(root .. 'session').sessions[a.count] or need_session 'CCClose'
    if s then
      ui.close(s)
    end
  end, { count = 0, desc = 'Stop a Claude session and wipe its buffers' })

  cmd('CCInterrupt', function()
    local s = need_session 'CCInterrupt'
    if s then
      s:interrupt()
    end
  end, { desc = 'Interrupt the running Claude turn' })

  cmd('CCAdd', function(a)
    local s = ui.current()
    if not s then
      s = ui.create()
      s:start()
    end
    local mention = ui.mention_of(0, a.range > 0, a.line1, a.line2)
    ui.append(s, mention)
    ui.show(s, { enter = false })
  end, { range = true, desc = 'Add the current file or range to the Claude input' })

  cmd('CCMode', function(a)
    local s = need_session 'CCMode'
    if not s then
      return
    end
    ui.mode(s, a.args)
  end, {
    nargs = '?',
    complete = function()
      return ui.modes
    end,
    desc = 'Set the permission mode of the Claude session',
  })

  cmd('CCModel', function(a)
    local s = need_session 'CCModel'
    if not s then
      return
    end
    ui.model(s, a.args)
  end, {
    nargs = '?',
    complete = function()
      local s = ui.current()
      return s and model_names(s) or {}
    end,
    desc = 'Set the model of the Claude session',
  })

  cmd('CCSearch', function(a)
    require(root .. 'picker').search(a.bang)
  end, { bang = true, desc = 'Fuzzy search past Claude sessions, ! for every project' })

  cmd('CCPrompts', function()
    local s = need_session 'CCPrompts'
    if s then
      require(root .. 'picker').prompts(s)
    end
  end, { desc = 'Pick one of your prompts and jump to it' })

  cmd('CCTasks', function()
    local s = need_session 'CCTasks'
    if s then
      require(root .. 'picker').tasks(s)
    end
  end, { desc = 'Pick a shell or subagent of the session, stop it or jump to it' })
  cmd('CCMarks', function()
    local s = need_session 'CCMarks'
    if s then
      require(root .. 'picker').marks(s)
    end
  end, { desc = 'Pick a mark of the conversation and jump to it' })

  cmd('CCRemote', function(a)
    local s = need_session 'CCRemote'
    if s then
      s:set_remote(not a.bang)
    end
  end, { bang = true, desc = 'Continue the session from claude.ai or the mobile app, ! turns it off' })
  cmd('CCPermission', function()
    require(root .. 'permission').resume(ui.current())
  end, { desc = 'Answer the pending Claude permission prompts' })

  cmd('CCTerm', function()
    local s = need_session 'CCTerm'
    if s then
      ui.term(s)
    end
  end, { desc = 'Continue the Claude session in an interactive terminal' })
end

-- opencode.nvim's dark theme values
local highlights_def = {
  CcMessageRoleUser = { link = 'Question' },
  CcMessageRoleAssistant = { link = 'Added' },
  CcHint = { link = 'Comment' },
  CcInputLegend = { link = '@label' },
  CcQueued = { fg = '#E5C07B', bold = true },
  CcBorder = { fg = '#616161' },
  CcToolBorder = { fg = '#3b4261', nocombine = true },
  CcReasoningText = { link = 'Comment' },
  CcDiffAdd = { bg = '#2B3328' },
  CcDiffDelete = { bg = '#43242B' },
  CcDiffGutter = { fg = '#6B7280', bg = '#252631' },
  CcDiffAddGutter = { fg = '#A5D6A7', bg = '#344032' },
  CcDiffDeleteGutter = { fg = '#EF9A9A', bg = '#52303A' },
  CcModeDefault = { fg = '#FFFFFF', bg = '#616161', bold = true },
  CcModePlan = { fg = '#FFFFFF', bg = '#61AFEF', bold = true },
  CcModeCustom = { fg = '#FFFFFF', bg = '#3b4261', bold = true },
  CcModeBypass = { fg = '#FFFFFF', bg = '#E06C75', bold = true },
  CcMark = { fg = '#E5C07B', bold = true },
  CcRemote = { link = 'DiagnosticOk' },
  CcToolTitle = { bold = true },
  CcToolValue = { link = '@markup.raw' },
}

local function highlights()
  for name, def in pairs(highlights_def) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend('force', def, { default = true }))
  end
end

---@param opts? yacc.Config|{}
function M.setup(opts)
  config.setup(opts)
  vim.treesitter.language.register('markdown', { 'cc-output', 'cc-input' })
  commands()
  highlights()

  local toggle = config.options.keys.toggle
  if toggle then
    vim.keymap.set({ 'n', 'i', 't' }, toggle, function()
      require(root .. 'ui').toggle(vim.v.count)
    end, { desc = 'Toggle Claude' })
  end

  local group = vim.api.nvim_create_augroup('yacc', { clear = true })
  vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = highlights })
  vim.api.nvim_create_autocmd('SessionLoadPre', {
    group = group,
    callback = function()
      require(root .. 'sessionfile').pre()
    end,
  })
  vim.api.nvim_create_autocmd('SessionLoadPost', {
    group = group,
    callback = function()
      require(root .. 'sessionfile').post()
    end,
  })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      for _, s in pairs(require(root .. 'session').sessions) do
        require(root .. 'marks').save(s)
        s:stop()
      end
    end,
  })
end

return M

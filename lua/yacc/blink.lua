--- blink.cmp source for the input buffer. It completes the plugin's own slash commands
--- and the list the CLI returns at initialize (built-ins, skills, custom commands). In
--- an empty input it offers the prompt the CLI suggests after a turn.
---
--- The plugin registers it as `claude` for the `cc-input` filetype when the first input
--- buffer is created, unless the `blink` option is false.
--- The suggestion shows as ghost text with `completion.ghost_text.enabled`, which can be
--- a function of the filetype.

local api = vim.api
local root = (...):match '^(.*%.)'
local session = require(root .. 'session')

---@class yacc.BlinkSource : blink.cmp.Source
local source = {}

--- Provider id the source is registered under, the suggestion opens the menu with it
source.provider = 'claude'

local registered = false

--- Add the source to blink.cmp, once. blink's setup() replaces its provider list, so
--- this waits for the first input buffer, when the user config has run.
function source.register()
  if registered then
    return
  end
  registered = true
  local ok, blink = pcall(require, 'blink.cmp')
  if not ok then
    return
  end
  -- A config that registers it itself keeps its own settings
  local providers = require('blink.cmp.config').sources.providers
  if providers[source.provider] == nil then
    blink.add_source_provider(source.provider, { name = 'Claude', module = root .. 'blink' })
  end
  local lok, lib = pcall(require, 'blink.cmp.sources.lib')
  local ids = lok and lib.per_filetype_provider_ids and lib.per_filetype_provider_ids['cc-input'] or {}
  if not vim.tbl_contains(ids, source.provider) then
    blink.add_filetype_source('cc-input', source.provider)
  end
end

function source.new()
  return setmetatable({}, { __index = source })
end

function source:enabled()
  return vim.bo.filetype == 'cc-input'
end

function source:get_trigger_characters()
  return { '/' }
end

---@param ctx blink.cmp.Context
---@param cb fun(response?: blink.cmp.CompletionResponse)
function source:get_completions(ctx, cb)
  local response = { items = {}, is_incomplete_forward = false, is_incomplete_backward = false }
  local s = session.from_buf(ctx.bufnr)
  local row, col = ctx.cursor[1], ctx.cursor[2]
  local before = ctx.line:sub(1, col)
  if s and s.suggestion and api.nvim_buf_line_count(ctx.bufnr) == 1 and ctx.line == '' then
    response.items[1] = {
      label = s.suggestion,
      kind = require('blink.cmp.types').CompletionItemKind.Text,
      labelDetails = { description = 'suggestion' },
      textEdit = {
        newText = s.suggestion,
        range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 0 } },
      },
    }
    -- Ask again on the next key, so typing drops the suggestion
    response.is_incomplete_forward = true
    return cb(response)
  end
  -- The CLI only runs a slash command at the very start of the prompt
  if not s or row ~= 1 or not before:match '^/[%w:_%-]*$' then
    return cb(response)
  end
  local kind = require('blink.cmp.types').CompletionItemKind.Function
  local commands = {}
  local seen = {}
  for name, c in pairs(require(root .. 'ui').local_commands()) do
    commands[#commands + 1] = { name = name, description = c.desc, argumentHint = c.arg }
    seen[name] = true
  end
  for _, c in ipairs(s.commands) do
    if not seen[c.name] then
      commands[#commands + 1] = c
    end
  end
  for _, c in ipairs(commands) do
    local doc = c.description or ''
    if c.argumentHint and c.argumentHint ~= '' then
      doc = ('`/%s %s`\n\n%s'):format(c.name, c.argumentHint, doc)
    end
    response.items[#response.items + 1] = {
      label = '/' .. c.name,
      kind = kind,
      filterText = '/' .. c.name,
      labelDetails = c.argumentHint and { description = c.argumentHint } or nil,
      documentation = { kind = 'markdown', value = doc },
      textEdit = {
        newText = '/' .. c.name .. ' ',
        range = { start = { line = row - 1, character = 0 }, ['end'] = { line = row - 1, character = col } },
      },
    }
  end
  cb(response)
end

return source

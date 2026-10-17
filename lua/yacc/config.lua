---@class cc.Config
---@field cmd string[] Claude CLI executable and the arguments every run gets, such as { 'claude', '--add-dir', '../lib' }
---@field model? string Model for new sessions, CLI default when nil
---@field permission_mode? string Permission mode for new sessions, CLI default when nil
---@field env table<string, string> Extra environment for the `claude` process
---@field allow_api_key boolean Keep ANTHROPIC_API_KEY in the `claude` environment
---@field partial_messages boolean Stream text token by token
---@field max_lines integer Lines kept from one tool output, the rest is cut
---@field fold_tools boolean Fold the body of every tool call and reasoning block, closed
---@field fold_threshold integer With fold_tools off, tool output lines shown before the rest is folded
---@field code_fold_lines integer Code blocks in answers start folded above this many lines, open otherwise
---@field commands table<string, cc.LocalCommand> Slash commands answered in nvim, added to /model, /mode, /clear
---@field history_limit integer Past sessions listed in the session picker
---@field suggestions boolean Ask the CLI for a next prompt after each turn, one more small API request
---@field blink boolean Register the completion source with blink.cmp, when it is installed
---@field remote_control boolean|'auto' Turn Remote Control on when a session starts. 'auto' follows the CLI's remoteControlAtStartup setting
---@field send_delay_ms integer A sent message waits this long before it reaches the CLI, the interrupt key cancels it meanwhile. 0 sends at once
---@field win cc.WinConfig
---@field keys cc.Keys

---@class cc.WinConfig
---@field width number Panel width, columns or a fraction of 'columns'
---@field input_min number Smallest input height, a fraction of 'lines'
---@field input_max number Largest input height, a fraction of 'lines'

---@class cc.Keys
---@field toggle string|false Global key that toggles the panel, a count picks the session
---@field submit_insert string[] Submit the input from insert mode
---@field submit_normal string[] Submit the input from normal mode
---@field interrupt string[] Cancel a message still in its send delay, else interrupt the running turn, in both buffers
---@field close string[] Press twice to close the session, in both buffers. None by default
---@field double_press_ms integer Window for the second press of close
---@field hide string[] Hide the panel from the output buffer
---@field focus_input string[] Jump from the output buffer to the input in insert mode
---@field mention string|false Insert-mode key that opens the file picker in the input buffer
---@field paste_image string|false Insert-mode key that attaches the clipboard image, if it holds one
---@field window string[] Insert-mode keys that leave insert mode and start a window command
---@field history_prev string[] On the first input line: edit the last queued message, else the previous prompt
---@field history_next string[] On the last input line: the next prompt of the history
---@field prompt_next string[] Output buffer: jump to the next prompt
---@field prompt_prev string[] Output buffer: jump to the previous prompt
---@field mark string|false Output buffer: set a mark, like `m`, and show and save it
---@field accept_suggestion string|false Input buffer, normal mode: take the suggested prompt. In insert mode blink accepts it
---@field stop_task string Tasks picker: stop the selected shell or subagent
---@field mark_delete string|false Output buffer: delete a mark, followed by its letter

local M = {}

---@type cc.Config
M.defaults = {
  cmd = { 'claude' },
  model = nil,
  permission_mode = nil,
  env = {},
  allow_api_key = false,
  partial_messages = true,
  max_lines = 500,
  fold_tools = true,
  fold_threshold = 25,
  code_fold_lines = 20,
  commands = {},
  history_limit = 50,
  suggestions = false,
  send_delay_ms = 1000,
  remote_control = 'auto',
  blink = true,
  win = { width = 0.4, input_min = 0.10, input_max = 0.25 },
  keys = {
    toggle = false,
    submit_insert = { '<C-CR>', '<S-CR>' },
    submit_normal = { '<CR>' },
    interrupt = { '<C-c>' },
    close = {},
    double_press_ms = 1000,
    hide = { 'q' },
    focus_input = { 'i', 'a' },
    mention = '@',
    paste_image = '<C-v>',
    window = { '<C-w>' },
    history_prev = { '<Up>' },
    history_next = { '<Down>' },
    prompt_next = { ']]' },
    prompt_prev = { '[[' },
    mark = 'm',
    mark_delete = 'dm',
    accept_suggestion = '<C-y>',
    stop_task = '<C-x>',
  },
}

---@type cc.Config
M.options = vim.deepcopy(M.defaults)

---@param opts? cc.Config|{}
function M.setup(opts)
  -- tbl_deep_extend merges lists by index, a user key list must replace the default one
  local function merge(base, over)
    for k, v in pairs(over) do
      if type(v) == 'table' and type(base[k]) == 'table' and not vim.islist(v) then
        merge(base[k], v)
      else
        base[k] = v
      end
    end
    return base
  end
  M.options = merge(vim.deepcopy(M.defaults), opts or {})
end

return M

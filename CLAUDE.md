# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

yacc.nvim runs Claude Code inside Neovim 0.12 as a chat. It drives `claude -p` with stream-json on stdin
and stdout, with no TUI and no MCP server. The README is the user documentation.

## Checks

Run from the repository root, both must pass before a commit:

```sh
stylua --check lua/
selene lua/
```

There is no test suite. To check that every module still loads:

```sh
nvim --headless --cmd 'set rtp^=.' -c 'lua require("yacc").setup{}' -c q
```

`neovim.yml` is the selene std. Its base is `lua51` because selene has no LuaJIT std, so `bit` is declared
there and `bad_string_escape` is off for the `\u{...}` escapes.

## Architecture

- `session.lua` owns one `claude -p` process per session. `S:_handle` dispatches every stdout message.
  Control requests go out through `S:request` (`initialize`, `interrupt`, `set_model`,
  `set_permission_mode`, `remote_control`, `stop_task`, `cancel_async_message`). The CLI's `can_use_tool` requests go to
  `permission.lua`, which keeps one queue for all sessions so only one prompt is open at a time.
- `render.lua` is the only writer of the output buffer. The same `R:` methods render the live stream and
  replay a transcript (`history.load`), so a rendering change affects both. `history.messages` applies the
  same filters as `history.load`, so prompt numbers in `:CCSearch` match the output. Keep them in sync.
- The output buffer holds plain markdown. Headers, gutter bars and diff gutters are extmarks. Folds come
  from `foldexpr`, which reads fold ranges from extmarks in the `cc.render` (closed) and `cc.render.open`
  namespaces. Write through `R:_modify`. It handles `modifiable`, keeps following windows at the end, and
  runs the write in normal mode when the user is in insert mode. A fold mark added after its lines needs
  `R:_touch`, or the fold level stays stale.
- `ui.lua` owns the panel, the input buffer, keymaps, the winbar, the footer and the slash commands the
  plugin answers itself.
- The CLI's transcript `~/.claude/projects/<dir>/<session_id>.jsonl` is the source of truth for past
  sessions. `ui.rerender` rebuilds the output from it. The plugin only stores its own marks, under
  `stdpath('data')/yacc/marks`.
- The output buffer is named `claude://<n>/<session_id>`. `:mksession` keeps that name on an empty
  window, and `sessionfile.lua` resumes the session there on `SessionLoadPost`.
- Two processes on one session both append to its transcript. Stop the stream process (`S:stop_then`)
  before anything else resumes the session, as `:CCTerm` does.

## Conventions

- Modules require each other relative to their own name: `local root = (...):match '^(.*%.)'`, then
  `require(root .. 'session')`. Requires inside functions break the cycles between `session`, `ui` and
  `picker`.
- snacks.nvim, blink.cmp and render-markdown.nvim are optional. Load them with `pcall(require, ...)` and
  keep a fallback.
- LuaCATS types use the `cc.` prefix (`cc.Session`, `cc.Render`). Highlight groups start with `Cc`, and
  their defaults in `init.lua` are set with `default = true`.
- A new option goes in three places: the `cc.Config` fields and `M.defaults` in `config.lua`, and the
  defaults block in the README.
- The session removes `ANTHROPIC_API_KEY` from the `claude` environment unless `allow_api_key` is set. In
  `-p` mode the CLI bills that key without asking, instead of the subscription.

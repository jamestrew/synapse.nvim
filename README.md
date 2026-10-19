# synapse.nvim

Code-anchored conversations between you and your coding agent, inside Neovim.

Inspired by Hunk's two-way agent review workflow—not its diff viewer.

[Usage and Lua interface](docs/usage.md) · [Agent skill](skills/synapse/SKILL.md)

## Scope

- Leave comments on lines or selected code in current working files for an
  external agent to read; historical revisions and deleted diff lines are outside
  the initial scope.
- Receive agent comments and exchange threaded replies beside the code.
- Follow Hunk's thread model initially: replies inherit the parent's anchor, and
  there is no separate open/resolved discussion state.
- Keep recorded file/line anchors fixed when code changes, as Hunk does. Following
  edits or semantically reanchoring comments is deferred.
- Follow Hunk's documented agent comment behavior, including deletion of human
  or agent comments. Individual deletion rejects comments with replies; bulk
  clearing must not leave dangling replies.
- Browse conversations with one entry per thread and filtering by human or agent
  authorship. The intended default browser is a quickfix list.
- Use Neovim's `vim.diagnostic` UI for thread location indicators, respecting
  users' diagnostic configuration. Render indicators without registering stored
  diagnostics: threads do not enter ordinary diagnostic counts, navigation,
  floats, or diagnostic quickfix lists. Read threads in floating outline/detail panes,
  with replies and edits docked below the selected comment.
- Compose comments and replies in a separate editable floating buffer, using
  normal Neovim editing and explicit submit/cancel actions. The thread transcript
  itself is read-only.
- Explicitly ask the agent to read or address comments; saving a comment does not
  invoke or notify an agent.
- Agent interaction requires a running Neovim instance and uses a documented
  agent-facing interface, guided by an agent skill. No separate daemon or
  additional executable is required.
- Sessions use a stable project root, with Git worktree root discovery where
  available, rather than following changes to the editor's working directory.
  Instances in the same project have independent sessions. A sole matching
  session can be targeted automatically; multiple matches require explicit
  selection, never broadcast writes.
- Discover live sessions through one small local file per instance, advertising
  its project root, session ID, and Neovim socket address. Remove the file on
  clean shutdown and ignore unreachable instances during discovery. Discovery
  files are separate from saved conversations.
- Save sessions locally so conversations survive editor restarts. Sessions are
  saved automatically after submitted changes, including replies and deletions;
  unsubmitted drafts are not saved initially. Sessions are not automatically
  committed, shared, or synchronized elsewhere.
- Expose explicit session resumption through the plugin interface; do not resume
  saved sessions automatically. Users may wire resumption to their own
  autocommands or keybindings.
- Work alongside existing Git and diff plugins without replacing them.

Whether a comment calls for discussion, code changes, or another action is up to
the human and agent, not prescribed by the plugin.

The [usage guide](docs/usage.md) documents diagnostic display, quickfix browsing,
saved-session selection, storage, and the agent-facing interface.

## Status

Session-backed comments, threaded replies, agent RPC, saved-session resumption,
and the outline/detail UI are implemented. See the [usage guide](docs/usage.md).

To load the local checkout:

```lua
vim.opt.rtp:prepend(vim.fn.expand('~/projects/synapse.nvim'))
require('synapse').setup()
```

## Development

Use tools on `PATH`: a recent Neovim, `emmylua_ls`, `emmylua_check`, StyLua,
and Make. No runtime plugin dependencies, build step, or LuaRocks are needed.
Versions are not pinned; this is currently a solo development setup.

Link your local Neovim **source checkout** (not its installation directory):

```sh
make setup                         # defaults to ../neovim
# Or: make setup NVIM_SOURCE=/path/to/neovim
```

This creates an ignored `.deps/neovim` symlink. Both the editor and CLI checker
read `.emmyrc.json`, using LuaJIT and the checkout's Neovim/test type annotations.
Restart `emmylua_ls` after first-time setup. StyLua owns formatting, including
format requests sent through EmmyLua.

```sh
make fmt                           # format Lua files
make format-check                  # check without rewriting
make typecheck                     # EmmyLua; warnings fail the command
make test                          # Neovim functional tests
make check                         # all checks (also the default make target)
```

Plugin APIs and session data use EmmyLua `---@class`, `---@param`, and
`---@return` annotations. `emmylua_check` does check types, but unannotated
parameters can leave mistakes unchecked. `make typecheck` also runs positive
and negative probes against the public API, ensuring argument, assignment, and
return-type mistakes really fail rather than silently resolving Synapse as `any`.
Runtime validation remains in place for JSON, RPC, and untyped Lua callers.

### Tests

Tests use Neovim's private `test/runner.lua`, RPC helpers, and `Screen:expect()`.
The harness starts child Neovim instances; `tests/preload.lua` loads the plugin
into each one and supplies the path metadata normally generated by CMake.
No Neovim build is needed. A temporary working directory isolates test files,
XDG directories, logs, and the harness's relative runtime/test paths; it is removed
when the test command exits.

Use `*_spec.lua` files. Ordinary Lua unit tests can use the same harness without
starting a child; editor integration tests should use `n.clear()` in
`before_each`, as in `tests/synapse_spec.lua`.

```sh
make test TEST_FILE=tests/synapse_spec.lua
make test TEST_ARGS='--filter="calls setup"'
make test TEST_ARGS='--repeat=10'
make test NVIM=/absolute/path/to/nvim
```

`TEST_ARGS` is a shell argument list forwarded to Neovim's harness. `NVIM`,
`EMMYLUA_CHECK`, and `STYLUA` override the corresponding executables.
The test adapter targets the current Neovim checkout and uses its runtime;
keep the installed binary and checkout reasonably aligned. Its private APIs
may need adjustment when Neovim changes. A minimum supported plugin version
and CI are intentionally not chosen yet.

# synapse.nvim

Code-anchored conversations between you and your coding agent, inside Neovim.

Inspired by Hunk's two-way agent review workflow—not its diff viewer.

## Scope

- Leave comments on lines or selected code for an external agent to read.
- Receive agent comments and exchange threaded replies beside the code.
- Browse all comments, with filtering by human or agent authorship.
- Explicitly ask the agent to read or address comments; saving a comment does not
  invoke or notify an agent.
- Work alongside existing Git and diff plugins without replacing them.

Comment presentation, persistence, anchoring across edits, the all-comments view,
and the agent-facing interface are still to be designed.

## Status

Bootstrap only. The Lua entry point loads, but no review features are implemented.

To load the local checkout:

```lua
vim.opt.rtp:prepend(vim.fn.expand('~/projects/synapse.nvim'))
require('synapse').setup()
```

## Development

Run the dependency-free smoke test with Neovim on your PATH:

```sh
make test
```

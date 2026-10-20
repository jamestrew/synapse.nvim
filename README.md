# synapse.nvim

Code-anchored conversations with your coding agent, inside Neovim.

Leave comments on a line or selection, ask your agent to respond, and read its
replies beside the code. Browse threads through quickfix or open them in a
floating outline/detail view. Synapse works alongside your existing Git and diff
plugins; it isn't a diff viewer or an agent runner.

## Install

Requires a recent Neovim. No runtime plugin dependencies or build step.

With Neovim's built-in plugin manager, add to `init.lua`:

```lua
vim.pack.add({ 'https://github.com/jamestrew/synapse.nvim' })
require('synapse').setup()
```

With lazy.nvim:

```lua
{
  'jamestrew/synapse.nvim',
  opts = {},
}
```

### Agent skill

Link the bundled skill into your agent's skills directory, replacing
`/path/to/synapse.nvim` with the plugin's installation path:

```sh
mkdir -p ~/.agents/skills
ln -s /path/to/synapse.nvim/skills/synapse ~/.agents/skills/synapse
```

## Use

1. Run `:SynapseComment` on a line or visual selection. Write your comment in
   the floating editor; **Ctrl-S** submits, **q** in normal mode cancels.
2. Give your agent the bundled [Synapse skill](skills/synapse/SKILL.md), then
   explicitly ask it to read or address your comments. Keep Neovim running.
   Saving a comment does **not** invoke or notify an agent.
3. Run `:SynapseBrowse` to list threads in quickfix. Press **Enter** to jump to
   the code and open the conversation. Use `:SynapseBrowse agent` to show threads
   with agent participation.
4. Run `:SynapseThread` at the cursor to read a conversation. In the thread view,
   **r** replies, **e** edits your comment, **Tab** switches panes, and **q** closes.

Optional keymaps:

```lua
vim.keymap.set({ 'n', 'x' }, '<leader>sc', ':SynapseComment<CR>', { desc = 'Comment on code' })
vim.keymap.set({ 'n', 'x' }, '<leader>st', ':SynapseThread<CR>', { desc = 'View thread' })
vim.keymap.set('n', '<leader>sb', '<cmd>SynapseBrowse<CR>', { desc = 'Browse threads' })
```

Submitted comments and replies are saved locally. Run `:SynapseResume` to restore
this project's latest saved conversation; nothing is resumed automatically.
Unsubmitted drafts are not saved. Line anchors stay fixed when code changes.

See the [usage guide](docs/usage.md) for configuration, all commands, session
selection, and the Lua API.

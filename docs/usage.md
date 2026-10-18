# Using Synapse

Load the plugin on Neovim's runtime path, then initialize it once:

```lua
require('synapse').setup({
  -- root = '/absolute/project', -- optional: Git worktree root, otherwise initial cwd
  -- discovery_dir = vim.fn.stdpath('state') .. '/synapse/live',
  -- storage_dir = vim.fn.stdpath('data') .. '/synapse/sessions',
  -- diagnostics = { virtual_text = true }, -- optional namespace-specific overrides
})
```

The root is canonicalized and stays fixed after `:cd`, `:lcd`, or `:tcd`.
For a non-Git project, initialize from its root or supply `root`. Setup is
idempotent: it does not switch projects, reset comments, or resume history.
Storage/discovery overrides are canonicalized at setup and must be different
directories. There are no runtime plugin dependencies. Git is optional.

## Human workflow

- `:SynapseComment` composes a comment at the cursor. A visual selection or
  `:2,5SynapseComment` records an inclusive line range.
- Composition opens a separate editable Markdown float in normal mode. Use
  ordinary editing (`i`, `o`, etc.). **Ctrl-S** submits in normal or insert mode;
  **q** in normal mode or **Ctrl-C** cancels. A terminal may require disabling
  software flow control for Ctrl-S to reach Neovim.
- `:SynapseBrowse [human|agent]` opens quickfix, one entry per thread. An authorship
  filter matches **any** participant and retains the whole thread. **Enter** jumps
  to the recorded location and opens its read-only transcript. After resuming a
  saved session, reopen the browser: stale lists reject Enter before navigation.
- `:SynapseThread {comment-id}` reads that comment's entire thread. Move to a
  comment and press **r** to reply or **e** to edit a human comment. **q** closes.
- `:SynapseReply {comment-id}` and `:SynapseEdit {human-comment-id}` compose directly.
- `:SynapseDelete {comment-id}` removes one comment if it has no replies.
- `:SynapseClear` asks before removing agent comments. `:SynapseClear!` asks before
  removing **all** comments, including human comments. A partial clear that would
  leave dangling replies is rejected rather than cascading silently.

Saving never starts or notifies an agent. Explicitly ask your agent to use the
[Synapse skill](../skills/synapse/SKILL.md) when you want a handoff. Comments do
not prescribe whether the response should be discussion or code changes.

## Anchors and display

Coordinates are **1-based, inclusive**, relative to current working files. Paths
returned by the plugin are relative to the stable project root. Creation accepts
relative or absolute paths within that root and checks the current loaded buffer
(or the file on disk). Replies inherit their parent's anchor, including when its
file has disappeared. There is no open/resolved status.

Recorded coordinates never follow edits. Native decorations are repainted from
those coordinates after buffer changes and on leaving insert mode. If a range
extends beyond the buffer, only the available portion is decorated; if its start
is past EOF, there is no marker. Missing files do not delete conversations.

Markers use `vim.diagnostic.show()` with explicit **HINT** severity, not
`vim.diagnostic.set()`. They respect native signs, range underlining, virtual
text/lines, severity filtering, and display configuration. A sign is at the start
line, not every line of a range. Threads are absent from stored diagnostic counts,
jumps, generic diagnostic floats, and diagnostic-generated quickfix lists.

For overrides, use `setup({ diagnostics = ... })`, or configure the `synapse`
namespace with `vim.diagnostic.config()`. Call `require('synapse').refresh()` after
changing diagnostic configuration to immediately repaint display-only markers.

## Durability and explicit resumption

Each instance has a new independent Session ID. Submitted changes are saved
synchronously as versioned JSON in `storage_dir/{session-id}.json`; private
permissions, a flushed temporary file, and atomic rename protect the previous
snapshot. A failed save raises an error and leaves the live accepted state
unchanged. UI submission failures retain the draft for retry.

Discovery advertisements are separate files in
`stdpath('state') .. '/synapse/live/{session-id}.json'` by default. This location is
shared between processes even when `XDG_RUNTIME_DIR` is unset. Each contains
`version`, `project_root`, `session_id`, and Neovim's `socket` address. Clean exit
removes the advertisement, never the saved conversation. Crash leftovers are
ignored unless a live RPC probe verifies their identities. Probes use a bounded
short-lived invocation of the same Neovim executable (not another tool), with a
1,000 ms default timeout per candidate. Agent callers can set `timeout_ms` for
slow or busy editors; explicit Session IDs are filtered before probing. Use the same
`NVIM_APPNAME`/XDG environment (or an explicit discovery directory) in clients.

Nothing is automatically restored, committed, or synchronized. Use:

```lua
local s = require('synapse')
vim.print(s.saved_sessions()) -- valid snapshots for this project, with comment_count
s.resume('24-character-session-id')
```

`:SynapseResume {session-id}` supports saved-ID completion. Resumption **copies**
the chosen snapshot into this instance's independent identity, even if the source
session is still live. It never takes over or writes the source session's file.
Replacing nonempty conversations requires the explicit Lua option
`s.resume(id, { confirm = true })`. You may invoke resumption from your own
keymaps/autocommands; the plugin installs no auto-resume behavior. Drafts are not
saved, including on exit. Resumption invalidates open compositions: their text
is retained, but submission is rejected; copy it into a new composition to
explicitly choose its target. Saved snapshots for other projects cannot be resumed.

## Public Lua interface

All methods below are on `require('synapse')`. Errors raise Lua exceptions;
validation/save failures do not partially apply conversation changes. Returned
comments and threads are detached copies.

| Method | Result / semantics |
| --- | --- |
| `setup(opts?)` / `info()` | `{ session_id, generation, project_root, socket, discovery_dir, storage_dir }` |
| `comment({file, line, end_line?, body})` | New human Comment |
| `comment({parent_id, body})` | Human reply; no independent anchor fields allowed |
| `edit(id, body)` | Updated human Comment; same ID, anchor, and replies |
| `delete(id)` | `true`; rejects comments with replies |
| `clear({confirm=true, include_human?})` | Number removed; defaults to agent-only |
| `threads(author?)` | Threads in creation order; optional `human`/`agent` filter |
| `saved_sessions()` | `{session_id, project_root, comment_count}` entries |
| `resume(id, {confirm?}?)` | Session info after independently copying the snapshot |
| `compose({file?, line?, end_line?, parent_id?, id?}?)` | `{bufnr, winid}`; `id` edits, `parent_id` replies, otherwise new comment |
| `view(comment_id)` | `{bufnr, winid}` for the read-only whole thread |
| `browse(author?)` | Quickfix entries; opens the browser |
| `refresh()` | Repaint native markers from recorded coordinates |

`generation` is a live conversation token incremented on successful resumption;
it is not persisted. Composition uses it to reject stale drafts.

A Comment has `{id, author, body, anchor, parent_id?}`; an anchor has
`{file, line, end_line}`. A Thread has `{id, anchor, comments}` with the root's ID
and all replies in creation order. Parent IDs may identify replies as well as
root comments. Bodies must contain non-whitespace text. No agent operation can
edit human text or choose human authorship. Agents can delete either author's
comments subject to the same integrity checks.

The agent interface is documented in the skill. It uses trusted local Neovim RPC,
not an authorization sandbox. Neither skill conventions nor operation names limit
what an agent with arbitrary shell/Neovim access could otherwise execute.

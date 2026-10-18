---
name: synapse
description: Read or respond to code-anchored human–agent conversations in a running Neovim Synapse session. Use when asked to inspect comments, reply to a thread, leave code observations, or delete or clear conversation comments.
---

# Synapse conversations

Work only after an explicit human handoff. Synapse carries conversations; it does
not decide whether feedback calls for discussion, edits, or another action.

## Connect and select

Use the installed `nvim` executable as a short-lived RPC client. No daemon,
additional executable, or offline saved-state writer is needed. Locate the
installed `synapse.nvim` directory and the target project's canonical root first
(Git worktree root when applicable). Use the same `NVIM_APPNAME` and XDG environment
as the running editor, or obtain its configured discovery directory from the user.

Write this temporary Lua request script, e.g. `/tmp/synapse-request.lua`:

```lua
vim.opt.rtp:prepend(assert(vim.env.SYNAPSE_PLUGIN))
local agent = require('synapse.agent')
local request = vim.json.decode(assert(vim.env.SYNAPSE_REQUEST))
local result = request.op and agent.request(request) or agent.discover(request)
io.write(vim.json.encode(result), '\n')
```

Discover live sessions (substitute the two absolute paths):

```sh
SYNAPSE_PLUGIN=/absolute/path/to/synapse.nvim \
SYNAPSE_REQUEST='{"project_root":"/absolute/project"}' \
nvim --headless -u NONE -i NONE -l /tmp/synapse-request.lua
```

Discovery probes one small advertisement per editor in
`stdpath('state') .. '/synapse/live/*.json'`. Each advertises `project_root`,
`session_id`, and `socket`; crashed/unreachable or identity-mismatched entries are
ineligible. Liveness probes use the same Neovim executable with a 1,000 ms timeout
per candidate; set `timeout_ms` in the request for slow or busy editors. Explicit
Session IDs are filtered before connecting. Add `"discovery_dir":"/configured/path"` when overridden by the user.
The client does **not** call `setup()`.

A sole matching live session is automatically selected by `request()`. With
multiple matches, obtain the intended **session_id** and include it in every
request; mutations are never broadcast. If none are live, ask the human to open
Neovim and initialize Synapse. Do not mutate saved JSON files.

## Read, respond, verify

Using the same command, replace `SYNAPSE_REQUEST` with an operation below. Include
`project_root`, optional `session_id`, optional `discovery_dir`, `op`, and `args`:

```json
{"project_root":"/absolute/project","op":"threads","args":{}}
```

Read the complete thread and its current working file before responding. Threads
have `{id, anchor, comments}`; comments have `{id, author, body, anchor, parent_id?}`.
Anchors contain project-relative `file` and **1-based inclusive** `line` and
`end_line`. Recorded coordinates stay fixed across edits and missing files;
inspect the working file rather than assuming the anchor follows moved code.

Supported operations:

| `op` | `args` | Result |
| --- | --- | --- |
| `threads` | `{}` or `{"author":"human"}` / `{"author":"agent"}` | Whole threads, matching any participant without dropping context |
| `comment` | `{"file":"src/main.lua","line":2,"end_line":5,"body":"Observation\nMore detail"}` | New agent-authored Comment; omit `end_line` for a single line |
| `comment` | `{"parent_id":"c1","body":"Reply"}` | Agent reply inheriting its parent's anchor |
| `delete` | `{"id":"c2"}` | `true`; either author, but rejects a comment with replies |
| `clear` | `{"confirm":true}` | Number of agent comments removed; rejects dangling human replies |
| `clear` | `{"confirm":true,"include_human":true}` | Number of all comments removed |

Obtain deliberate confirmation before clearing; include humans only when that
scope is explicitly requested. Individual deletion never cascades. Reply parents
may themselves be replies. Send only a parent ID and body for replies; they cannot
retarget the thread. Agent creation never accepts human authorship, and there is
no agent edit operation or open/resolved lifecycle.

Validation and save failures leave accepted live state unchanged. If a connection
fails after a write, reconnect and inspect threads before retrying: a lost reply
does not prove the write failed. After a mutation, read `threads` again to
verify the intended result, then report what you discussed or changed to the
human. Do not automatically activate another agent or infer task completion from
a reply.

For direct RPC integrations, connect to the advertised socket using Neovim RPC
and call `nvim_exec_lua` with code
`return require('synapse.agent').dispatch(...)` and arguments
`[{session_id=..., project_root=..., op=..., args=...}]`. The supplied client helper
performs live probing, unambiguous selection, and identity validation for you.
This is trusted local Neovim access, not a security sandbox.

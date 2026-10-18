#!/bin/sh
# Check the checker too: resolving Synapse as `any` must not produce a false green.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
checker=${1:-emmylua_check}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
# Keep probes and modules in one workspace so analysis order cannot hide contracts.
cp -R "$root/lua" "$root/.emmyrc.json" "$work/"
ln -s "$root/.deps" "$work/.deps"

cat > "$work/probe.lua" <<'LUA'
local synapse = require('synapse')
synapse.setup({ diagnostics = { signs = false } })
local comment = synapse.comment({ file = 'code.lua', line = 1, body = 'question' })
---@type string
local body = comment.body
---@return synapse.Comment
local function reply()
  return synapse.comment({ parent_id = comment.id, body = body })
end
return reply
LUA

check() {
  "$checker" "$work" --severity warn --warnings-as-errors > "$work/output" 2>&1
}

if ! check; then
  cat "$work/output" >&2
  exit 1
fi

cat > "$work/probe.lua" <<'LUA'
local synapse = require('synapse')
synapse.setup({ diagnostics = 'invalid' })
local comment = synapse.comment({ file = 'code.lua', line = 1, body = 'question' })
---@type integer
local body = comment.body
---@return synapse.Comment
local function reply()
  return body
end
return reply
LUA

if check; then
  echo 'Type checker accepted deliberately invalid Synapse types' >&2
  exit 1
fi
for code in param-type-mismatch assign-type-mismatch return-type-mismatch; do
  if ! grep -q "$code" "$work/output"; then
    cat "$work/output" >&2
    echo "Type checker did not report $code" >&2
    exit 1
  fi
done
echo 'Type-check regression probes passed'

#!/bin/sh
# Reuse the user's Codex login, without personal tools, hooks or stored sessions.
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec "${CLIPPY_CODEX_BIN:-$project_dir/node_modules/.bin/codex}" "$@" --ignore-user-config --ignore-rules --ephemeral

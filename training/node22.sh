#!/usr/bin/env bash
# TensorFlow.js 4.22 expects APIs removed in Node 26. Run the training tools with Node 22.
set -euo pipefail
NODE_BIN=$(command -v node)
if test -x /opt/homebrew/opt/node@22/bin/node; then NODE_BIN=/opt/homebrew/opt/node@22/bin/node; fi
MAJOR=$("$NODE_BIN" -p 'process.versions.node.split(".")[0]')
if test "$MAJOR" != 22; then
  echo "Node.js 22 ist für TensorFlow.js 4.22 nötig (gefunden: $MAJOR)." >&2
  exit 1
fi
exec "$NODE_BIN" "$@"

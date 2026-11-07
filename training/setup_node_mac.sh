#!/usr/bin/env bash
# Build tfjs-node for Apple Silicon in a temporary path without spaces.
# node-gyp in tfjs-node 4.22 does not quote its include path when the checkout name has spaces.
set -euo pipefail
if test "$(uname -m)" != arm64; then
  echo "Dieses Setup-Skript ist für Macs mit Apple Silicon vorgesehen." >&2
  exit 1
fi
HERE=$(cd "$(dirname "$0")" && pwd)
BUILD=$(mktemp -d /tmp/safari-node.XXXXXX)
trap 'rm -rf "$BUILD"' EXIT
if test -x /opt/homebrew/opt/node@22/bin/node; then
  export PATH="/opt/homebrew/opt/node@22/bin:$PATH"
fi
cp "$HERE/package.json" "$HERE/package-lock.json" "$BUILD/"
(cd "$BUILD" && npm ci --ignore-scripts)

ARCHIVE=${SPOTTER_LIBTENSORFLOW_ARCHIVE:-"$BUILD/libtensorflow-arm64.tar.gz"}
if ! test -f "$ARCHIVE"; then
  curl --fail --location --retry 3 --connect-timeout 10 --output "$ARCHIVE" \
    https://storage.googleapis.com/tf-builds/libtensorflow_r2_7_darwin_arm64_cpu.tar.gz
fi
DEPS="$BUILD/node_modules/@tensorflow/tfjs-node/deps"
mkdir -p "$DEPS"
tar -xzf "$ARCHIVE" -C "$DEPS"
test -f "$DEPS/lib/libtensorflow.dylib"
(cd "$BUILD" && npm_config_build_from_source=true npm rebuild @tensorflow/tfjs-node)
ditto "$BUILD/node_modules" "$HERE/node_modules"
(cd "$HERE" && node -e 'const tf=require("@tensorflow/tfjs-node"); if(tf.getBackend()!=="tensorflow" || tf.tensor1d([2,3]).sum().dataSync()[0]!==5) process.exit(1)')
echo "TensorFlow.js für Safari Spotter ist einsatzbereit."

#!/usr/bin/env bash
# Tags a built web dir with a version: index.html loads index.js?v=<version>,
# and web/shell.html's locateFile gives index.wasm the same tag. GitHub Pages
# caches every file for 10 minutes under one name, so without this a reload
# can pair a new index.html with an old index.js or index.wasm.
# Usage: web/stamp.sh <dir> <version>   (e.g. zig-out/web "$GITHUB_SHA")
set -euo pipefail
dir=$1
version=$2
html=$dir/index.html
# emcc writes the tag unquoted (src=index.js); accept quoted too.
pattern='src=["]\{0,1\}index\.js["]\{0,1\}'
if ! grep -q "$pattern" "$html"; then
    echo "stamp.sh: no index.js script tag in $html" >&2
    exit 1
fi
sed -i "s|$pattern|src=\"index.js?v=$version\"|" "$html"
grep -o 'src="index\.js?v=[^"]*"' "$html"

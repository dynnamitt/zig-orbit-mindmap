#!/usr/bin/env bash
# Tags a built web dir with a version: index.html loads index.js?v=<version>,
# and web/shell.html's locateFile gives index.wasm the same tag. GitHub Pages
# caches every file for 10 minutes under one name, so without this a reload
# can pair a new index.html with an old index.js or index.wasm.
# Usage: web/stamp.sh <dir> <version>   (CI: zig-out/web "${GITHUB_SHA::8}")
set -euo pipefail
html=$1/index.html
# emcc writes the tag unquoted (src=index.js); accept quotes too. Only an
# unstamped tag matches, so stamping twice fails instead of doubling ?v=.
pattern='src="?index\.js"?([ >])'
grep -Eq "$pattern" "$html" || { echo "stamp.sh: no unstamped index.js script tag in $html" >&2; exit 1; }
sed -Ei "s|$pattern|src=\"index.js?v=$2\"\\1|" "$html"

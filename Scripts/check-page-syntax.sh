#!/usr/bin/env bash
# The dashboard is one inline script inside Page.swift, and a single JS syntax error there
# is a page that never renders — which shipped once (#58: a redeclared `const ok`) and cost
# a live debugging session to find. This extracts the script and parses it with node when
# node (or docker) is available; where neither exists it warns rather than lying about
# having checked.
set -euo pipefail

page="Sources/HatcheryWeb/Page.swift"
out="$(mktemp -t page-script.XXXXXX).js"

python3 - "$page" "$out" <<'EOF'
import re, sys
swift = open(sys.argv[1]).read()
m = re.search(r'<script>(.*)</script>', swift, re.S)
if not m:
    print("::error::no <script> block found in Page.swift")
    sys.exit(1)
open(sys.argv[2], "w").write(m.group(1))
print(f"extracted {len(m.group(1))} bytes of page script")
EOF

if command -v node >/dev/null 2>&1; then
  node --check "$out"
  echo "page script parses (node)"
elif docker info >/dev/null 2>&1; then
  # Mounted, not piped: node cannot --check a stdin pipe through docker's fd relay.
  docker run --rm -v "$out":/page.js:ro node:20-alpine node --check /page.js
  echo "page script parses (node via docker)"
else
  echo "::warning::neither node nor docker available — page script NOT syntax-checked"
fi

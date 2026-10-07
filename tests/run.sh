#!/usr/bin/env bash
# Offline tests: the radio's server side in Lua 5.1 against a GMod shim, the relay in
# Python against fake yt-dlp/ffmpeg, and a parse check of every Lua file.
# Needs lua5.1 (or Docker) and python3.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${LUA_IMAGE:-nickblah/lua:5.1-luarocks-alpine}"
rc=0
echo "▶ lua syntax"
"$ROOT/tools/syntax-check.sh" || rc=1
echo "▶ lua: server side"
LUA="${LUA:-}"
if [ -z "$LUA" ]; then
  for c in lua5.1 lua; do
    command -v "$c" >/dev/null 2>&1 && "$c" -v 2>&1 | grep -q 'Lua 5\.1' && { LUA="$c"; break; }
  done
fi
if [ -n "$LUA" ]; then
  (cd "$ROOT" && "$LUA" tests/test_radio.lua) || rc=1
  (cd "$ROOT" && "$LUA" tests/test_client.lua) || rc=1
else
  docker run --rm -v "$ROOT:/w:ro" -w /w "$IMAGE" sh -c "lua tests/test_radio.lua && lua tests/test_client.lua" || rc=1
fi
echo "▶ python: relay"
(cd "$ROOT" && python3 -m unittest discover -s tests -p 'test_*.py') || rc=1
exit $rc

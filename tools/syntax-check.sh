#!/usr/bin/env bash
# Parse every .lua file in the addon with a real Lua 5.1 front end.
#
# GLua is Lua 5.1 plus a handful of extensions, so a stock 5.1 parser catches
# every genuine syntax error and trips over exactly the things that are legal
# only in GMod. Those are rewritten into syntactically-equivalent stand-ins for
# the duration of the check. The copy is thrown away; the real file is untouched:
#
#   continue        -> a function call        (GLua keyword, no 5.1 equivalent)
#   !=  &&  ||      -> ~= / and / or          (GLua C-style operator aliases)
#
# This does NOT run the code, so it will not catch a nil index or a typo'd API
# name. It catches the class of mistake that stops the addon loading at all,
# which is the one worth catching before a server round-trip.
#
# Uses a local luac if there is one, otherwise Docker. Override with:
#   LUAC=/path/to/luac tools/syntax-check.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${LUA_IMAGE:-nickblah/lua:5.1-luarocks-alpine}"

LUAC="${LUAC:-}"
if [ -z "$LUAC" ]; then
  for cand in luac5.1 luac; do
    if command -v "$cand" >/dev/null 2>&1; then LUAC="$cand"; break; fi
  done
fi

if [ -z "$LUAC" ] && ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: no luac and no docker. Install lua5.1, or set LUAC=." >&2
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

count=0
while IFS= read -r -d '' f; do
  rel="${f#"$ROOT"/}"
  out="$WORK/$rel"
  mkdir -p "$(dirname "$out")"
  sed -e 's/\bcontinue\b/__continue()/g' \
      -e 's/!=/~=/g' \
      -e 's/&&/ and /g' \
      -e 's/||/ or /g' \
      "$f" > "$out"
  count=$((count + 1))
done < <(find "$ROOT/lua" -name '*.lua' -print0)

# One script, run either directly or inside the container. Keeping it in a
# variable rather than duplicating it is what stops the two paths drifting apart
# and reporting different results on CI than on a workstation.
CHECK='rc=0; for f in $(find . -name "*.lua" | sort); do
         if ! LUACBIN -p "$f" 2>/tmp/bmx_e; then
           echo "FAIL ${f#./}"; sed "s/^/     /" /tmp/bmx_e; rc=1
         fi
       done
       [ $rc -eq 0 ] && echo "all files parse clean"
       exit $rc'

if [ -n "$LUAC" ]; then
  echo "checking $count files with $LUAC ..."
  ( cd "$WORK" && sh -c "${CHECK//LUACBIN/$LUAC}" )
else
  echo "checking $count files with $IMAGE ..."
  docker run --rm -v "$WORK:/w:ro" -w /w "$IMAGE" \
    sh -c "${CHECK//LUACBIN/luac}"
fi

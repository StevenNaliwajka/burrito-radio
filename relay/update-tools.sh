#!/usr/bin/env bash
# Fetch the newest yt-dlp and deno (yt-dlp's JavaScript runtime for YouTube) into
# /opt/naliwajka-radio/bin. YouTube changes its player every few weeks and an old
# yt-dlp then fails every download, so this runs daily (naliwajka-radio-update.timer).
set -euo pipefail
BIN=/opt/naliwajka-radio/bin
install -d -m 0755 "$BIN"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/yt-dlp" https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_linux
chmod 0755 "$tmp/yt-dlp"
"$tmp/yt-dlp" --version >/dev/null
new="$("$tmp/yt-dlp" --version)"
old="$("$BIN/yt-dlp" --version 2>/dev/null || echo none)"
if [ "$new" != "$old" ]; then mv "$tmp/yt-dlp" "$BIN/yt-dlp"; echo "yt-dlp $old -> $new"; else echo "yt-dlp $old (current)"; fi
if [ ! -x "$BIN/deno" ] || [ "${1:-}" = "--deno" ]; then
  curl -fsSL -o "$tmp/deno.zip" https://github.com/denoland/deno/releases/latest/download/deno-x86_64-unknown-linux-gnu.zip
  python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extract('deno', sys.argv[2])" "$tmp/deno.zip" "$tmp"
  chmod 0755 "$tmp/deno"
  mv "$tmp/deno" "$BIN/deno"
  echo "deno $("$BIN/deno" --version | head -1)"
fi
